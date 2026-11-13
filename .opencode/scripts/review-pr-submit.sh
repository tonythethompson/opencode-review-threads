#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}
state_dir="${HOME}/.config/opencode/review-state"
context_file="${state_dir}/context.json"
initial_payload="${state_dir}/initial.json"
validated_payload="${state_dir}/validated-initial.json"
update_payload="${state_dir}/update.json"
review_id_file="${state_dir}/review_id"
session_file="${HOME}/.config/opencode/review-session-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
submission_attempt_file="${state_dir}/submission-attempted"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trusted_context_lib="${script_dir}/review-pr-context.sh"
[[ -f "${trusted_context_lib}" ]] || fail "Trusted review context helper is unavailable."
# shellcheck source=/dev/null
source "${trusted_context_lib}"

load_token_lib() {
  local opencode_app_token_lib="${HOME}/.config/opencode/scripts/resolve-app-token.sh"
  [[ -f "${opencode_app_token_lib}" ]] || fail "OpenCode App token resolver is unavailable."
  # shellcheck source=/dev/null
  source "${opencode_app_token_lib}"
}

validate_initial_payload() {
  local comment_count index
  jq -e . "${initial_payload}" > /dev/null 2>&1 \
    || fail "Invalid initial review payload: expected valid JSON."
  jq -e 'type == "object"' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: top level must be an object."
  jq -e 'keys == ["body", "comments"]' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: top level must contain exactly body and comments."
  jq -e '.body | type == "string" and length > 0' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: body must be a nonempty string."
  jq -e '.comments | type == "array" and length > 0' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: comments must be a nonempty array."

  # Models sometimes repeat the severity already present in the required body
  # header as metadata. GitHub does not accept that field in review comments.
  jq -e 'all(.comments[]; if type == "object" and has("severity") then
    (.severity as $s | (["critical", "important", "suggestion"] | index($s)) != null
      and (.body | type == "string" and startswith("**" + $s + " · ")))
    else true end)' "${initial_payload}" > /dev/null \
    || fail "Invalid initial review payload: severity metadata must match the comment header."
  local metadata_tmp
  metadata_tmp="$(mktemp "${state_dir}/metadata.XXXXXX.json")"
  jq '.comments |= map(if type == "object" then del(.severity) else . end)' "${initial_payload}" > "${metadata_tmp}"
  mv "${metadata_tmp}" "${initial_payload}"

  comment_count="$(jq '.comments | length' "${initial_payload}")"
  for ((index = 0; index < comment_count; index++)); do
    jq -e --argjson index "${index}" '.comments[$index] | type == "object"' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} must be an object."
    jq -e --argjson index "${index}" '.comments[$index].body | type == "string" and length > 0' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} body must be a nonempty string."
    jq -e --argjson index "${index}" '
      .comments[$index].body
      | test("^\\*\\*(critical|important|suggestion) · [^*\\r\\n]+\\*\\*\\n\\n."; "s")
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} body must begin with a severity and reviewer source."
    jq -e --argjson index "${index}" '.comments[$index].path | type == "string" and length > 0' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} path must be a nonempty string."
    jq -e --argjson index "${index}" '
      .comments[$index].line | type == "number" and floor == . and . > 0
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} line must be a positive integer."
    jq -e --argjson index "${index}" '
      .comments[$index].side == "LEFT" or .comments[$index].side == "RIGHT"
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} side must be LEFT or RIGHT."
    jq -e --argjson index "${index}" '
      .comments[$index] as $comment
      | ($comment | has("start_line")) == ($comment | has("start_side"))
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} must include both start_line and start_side or neither."
    jq -e --argjson index "${index}" '
      .comments[$index] as $comment
      | if ($comment | has("start_line")) then
          ($comment.start_line | type == "number" and floor == . and . > 0)
          and $comment.start_line <= $comment.line
          and $comment.start_side == $comment.side
        else
          true
        end
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} range must use positive ordered lines on the same side."
    jq -e --argjson index "${index}" '
      .comments[$index] as $comment
      | if ($comment | has("start_line")) then
          ($comment | keys == ["body", "line", "path", "side", "start_line", "start_side"])
        else
          ($comment | keys == ["body", "line", "path", "side"])
        end
    ' "${initial_payload}" > /dev/null \
      || fail "Invalid initial review payload: comment ${index} contains unsupported or missing fields."
  done

  # Normalize degenerate ranges: start_line == line is a single-line comment
  # that must not carry a range (GitHub rejects it with HTTP 422). Strip
  # start_line/start_side in place so validation doubles as canonicalization.
  local normalized_tmp
  normalized_tmp="$(mktemp "${state_dir}/normalized.XXXXXX.json")"
  if jq '
    .comments |= map(
      if (.start_line != null and .start_line == .line)
      then del(.start_line, .start_side)
      else .
      end
    )
  ' "${initial_payload}" > "${normalized_tmp}" && ! cmp -s "${normalized_tmp}" "${initial_payload}"; then
    mv "${normalized_tmp}" "${initial_payload}"
    echo "::notice::normalized single-line comments that carried a start_line range"
  else
    rm -f "${normalized_tmp}"
  fi
}

# Validate every comment anchor against the pinned base..head diff before the
# submission marker is set. GitHub rejects the whole review when any comment
# targets a file or line outside the PR diff (HTTP 422), and the one-shot
# marker makes that rejection unrecoverable. Anchors are computed against the
# incremental review range, so files that net to unchanged versus the PR base
# cannot take inline comments at all. Report each invalid comment and fail so
# the caller can demote or fix the anchors and resubmit.
opencode_review_preflight_anchors() {
  local repo="${1}" base_sha="${2}" head_sha="${3}" payload="${4}"
  local files_json index_file file_count truncated
  files_json="$(gh api "repos/${repo}/compare/${base_sha}...${head_sha}" \
    | jq -c '[.files[]? | {filename, previous_filename, status, patch}]')" \
    || fail "Anchor preflight could not read the pinned diff."

  index_file="$(mktemp "${TMPDIR:-/tmp}/opencode-anchor-index.XXXXXX")"
  jq -r '.[] | "F\t" + .filename + "\t" + (.previous_filename // "") + "\n" + (.patch // "") + "\n"' \
    <<< "${files_json}" | awk -F '\t' '
    BEGIN { file = "" }
    /^F\t/ { file = $2; prev = $3; next }
    /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
      if (file == "") next
      h = $0
      sub(/^@@ -/, "", h); sub(/ @@.*/, "", h)
      split(h, parts, " \\+")
      old = parts[1] + 0; sub(/,.*/, "", old)
      newl = parts[2] + 0; sub(/,.*/, "", newl)
      next
    }
    /^\+/ { if (file != "") { print file "\tRIGHT\t" newl; newl++ } next }
    /^-/  { if (file != "") { print file "\tLEFT\t"  old;   old++  } next }
    /^ /  { if (file != "") { print file "\tRIGHT\t" newl; print file "\tLEFT\t" old; newl++; old++ } next }
  ' > "${index_file}"

  file_count="$(jq 'length' <<< "${files_json}")"
  truncated="false"
  # The compare endpoint truncates at 300 files; do not reject anchors whose
  # file may simply be past the cut.
  ((file_count >= 300)) && truncated="true"

  local invalid=0 index path side line start_line lookup_path has_patch
  local comment_count
  comment_count="$(jq '.comments | length' <<< "${payload}")"
  for ((index = 0; index < comment_count; index++)); do
    IFS=$'\t' read -r path side line start_line < <(
      jq -r --argjson i "${index}" '
        .comments[$i] | [.path, .side, .line, (.start_line // 0)] | @tsv' <<< "${payload}" \
        | tr -d '\r'
    )

    lookup_path="$(jq -r --arg p "${path}" '
      map(select(.filename == $p or ((.previous_filename // "") == $p and $p != ""))) | .[0].filename // ""
    ' <<< "${files_json}")"

    if [[ -z "${lookup_path}" ]]; then
      if [[ "${truncated}" == "true" ]]; then
        echo "::warning::anchor preflight skipped comment ${index} (${path}:${line}): file may be beyond the compare endpoint's 300-file cap"
        continue
      fi
      echo "::error::comment ${index} anchors '${path}' which is not in the PR's base-to-head diff; demote it to summary_only or re-anchor"
      ((invalid++)) || true
      continue
    fi

    has_patch="$(jq -r --arg f "${lookup_path}" '
      map(select(.filename == $f)) | .[0] | has("patch") and (.patch != null)
    ' <<< "${files_json}")"
    [[ "${has_patch}" == "true" ]] || continue

    if ! awk -F '\t' -v f="${lookup_path}" -v s="${side}" -v l="${line}" \
      '$1 == f && $2 == s && $3 == l { found = 1 } END { exit !found }' "${index_file}"; then
      echo "::error::comment ${index} anchors ${lookup_path}:${line} (${side}) outside the diff hunks; demote it to summary_only or re-anchor"
      ((invalid++)) || true
      continue
    fi
    if ((start_line > 0)); then
      if ! awk -F '\t' -v f="${lookup_path}" -v s="${side}" -v l="${start_line}" \
        '$1 == f && $2 == s && $3 == l { found = 1 } END { exit !found }' "${index_file}"; then
        echo "::error::comment ${index} range starts at ${lookup_path}:${start_line} (${side}) outside the diff hunks; demote it to summary_only or re-anchor"
        ((invalid++)) || true
      fi
    fi
  done

  rm -f "${index_file}"
  ((invalid == 0)) || fail "Anchor preflight rejected ${invalid} comment(s); fix or demote them and resubmit."
}

operation="${1:-}"
[[ "$#" -eq 1 ]] || fail "Review helper operations take exactly one operation name and no additional arguments."

case "${operation}" in
  prepare)
    mkdir -p "${HOME}/.config/opencode"
    if ! (
      set -o noclobber
      : > "${session_file}"
    ) 2> /dev/null; then
      fail "Review submission state was already prepared for this run."
    fi
    rm -rf "${state_dir}"
    (
      umask 077
      mkdir -p "${state_dir}"
      : > "${context_file}"
      : > "${initial_payload}"
      : > "${update_payload}"
    )
    ;;
  validate-initial)
    [[ ! -e "${submission_attempt_file}" ]] \
      || fail "Initial review submission was already attempted for this run."
    rm -f "${validated_payload}"
    validate_initial_payload
    validated_payload_tmp="$(mktemp "${state_dir}/validated-initial.XXXXXX.json")"
    trap 'rm -f "${validated_payload_tmp}"' EXIT
    jq -cS . "${initial_payload}" > "${validated_payload_tmp}"
    mv "${validated_payload_tmp}" "${validated_payload}"
    trap - EXIT
    ;;
  submit-initial)
    [[ -s "${validated_payload}" ]] \
      || fail "Initial review payload must pass validate-initial before submission."
    validate_initial_payload
    current_payload="$(jq -cS . "${initial_payload}")" \
      || fail "Initial review payload changed to invalid JSON after validation."
    [[ "${current_payload}" == "$(cat "${validated_payload}")" ]] \
      || fail "Initial review payload changed after validation; submission must stop."
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    context="$(opencode_review_trusted_context)" || fail "Pinned PR context is unavailable or the pinned commit cannot be read."
    IFS=$'\t' read -r repo pr_number base_sha head_sha _review_base <<< "${context}"
    # Anchor preflight happens before the one-shot marker so an invalid anchor
    # is a fixable local error instead of a terminal API rejection.
    opencode_review_preflight_anchors "${repo}" "${base_sha}" "${head_sha}" "${current_payload}"
    if ! (
      set -o noclobber
      : > "${submission_attempt_file}"
    ) 2> /dev/null; then
      fail "Initial review submission was already attempted for this run."
    fi
    rm -f "${validated_payload}"
    request="$(mktemp "${TMPDIR:-/tmp}/opencode-pr-review.XXXXXX.json")"
    trap 'rm -f "${request}"' EXIT
    jq --arg commit_id "${head_sha}" '. + {commit_id: $commit_id, event: "COMMENT"}' <<< "${current_payload}" > "${request}"
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    opencode_review_verify_commit "${repo}" "${head_sha}" \
      || fail "Pinned PR commit cannot be read after token verification."
    response="$(gh api --method POST "repos/${repo}/pulls/${pr_number}/reviews" --input "${request}")" \
      || fail "Failed to submit the review."
    review_id="$(jq -r '.id // empty' <<< "${response}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Review ID was not returned."
    printf '%s' "${review_id}" > "${review_id_file}"
    printf '%s\n' "${response}"
    ;;
  update)
    load_token_lib
    opencode_prepare_gh_token "${USE_GITHUB_TOKEN:-false}" || true
    context="$(opencode_review_trusted_context)" || fail "Pinned PR context is unavailable or the pinned commit cannot be read."
    IFS=$'\t' read -r repo pr_number _base_sha head_sha _review_base <<< "${context}"
    jq -e 'keys == ["body"] and (.body | type == "string" and length > 0)' "${update_payload}" > /dev/null \
      || fail "Invalid review update payload."
    [[ -f "${review_id_file}" ]] || fail "This run has no recorded review ID."
    review_id="$(cat "${review_id_file}")"
    [[ "${review_id}" =~ ^[1-9][0-9]*$ ]] || fail "Recorded review ID is invalid."
    opencode_require_app_token_for_review "${USE_GITHUB_TOKEN:-false}" "${repo}" "${pr_number}"
    opencode_review_verify_commit "${repo}" "${head_sha}" \
      || fail "Pinned PR commit cannot be read after token verification."
    gh api --method PUT "repos/${repo}/pulls/${pr_number}/reviews/${review_id}" --input "${update_payload}" \
      || fail "Failed to submit the review update."
    ;;
  *) fail "Unsupported review submission operation." ;;
esac
