#!/usr/bin/env bash
# Detection net for the leaked-`@path` failure mode. `opencode github run`
# posts the agent's reply text verbatim, so if a reply references a temp file
# (e.g. "@/tmp/opencode/summary.md") that token leaks into a public comment.
#
# Subcommands:
#   snapshot       record the current issue+review comment ids for the PR
#   verify         diff the snapshot against current comments and fail if any new
#                  comment body contains a `@/` or `/tmp/` path token
#   suppress-clean delete this run's top-level "no findings / no code changes"
#                  comments so a clean review leaves the pull request untouched
#
# Env in: GH_TOKEN, REPOSITORY (owner/name), PR_NUM, RUNNER_TEMP (optional)

_opencode_guard_state_dir() {
  printf '%s' "${RUNNER_TEMP:-$(mktemp -d)}"
}

opencode_comment_snapshot() {
  local before
  before="$(_opencode_guard_state_dir)/opencode-comments-before"
  : >"${before}"
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$(_opencode_guard_state_dir)/opencode-comments-ts"
  if [[ -n "${PR_NUM:-}" ]]; then
    gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --jq '.[].id' | tr -d '\r' >>"${before}"
    gh api "repos/${REPOSITORY}/pulls/${PR_NUM}/comments" --paginate --jq '.[].id' | tr -d '\r' >>"${before}"
    sort -n -o "${before}" "${before}"
  fi
}

# Logins this run could have posted under. With use-github-token the run only
# ever writes as github-actions[bot]. In App-token mode the session's gh shim
# and upstream's own posting both use the verified App identity once it is
# cached; without a cached token the agent's calls fall back to the ambient
# workflow token, so either identity may be ours. Scoping by author keeps a
# concurrent run's leaked comment from failing this run's guard.
_opencode_guard_authors() {
  local bot_login="${OPENCODE_REVIEW_BOT_LOGIN:-opencode-agent[bot]}"
  local app_cache="${TMPDIR:-/tmp}/opencode-app-token.${GITHUB_RUN_ID:-session}"
  if [[ "${USE_GITHUB_TOKEN:-false}" == "true" ]]; then
    jq -n '["github-actions[bot]"]'
  elif [[ -s "${app_cache}" && "$(head -n 1 "${app_cache}")" != "DENIED" ]]; then
    jq -n --arg l "${bot_login}" '[$l]'
  else
    jq -n --arg l "${bot_login}" '[$l, "github-actions[bot]"]'
  fi
}

opencode_comment_verify() {
  local state_dir before after new_ids issue_json review_json new_ids_json leaked
  state_dir="$(_opencode_guard_state_dir)"
  before="${state_dir}/opencode-comments-before"
  after="${state_dir}/opencode-comments-after"
  new_ids="${state_dir}/opencode-comments-new"
  issue_json="${state_dir}/opencode-issue-comments.json"
  review_json="${state_dir}/opencode-review-comments.json"

  [[ -n "${PR_NUM:-}" ]] || return 0
  : >"${after}"
  if [[ ! -f "${before}" ]]; then
    echo "::warning::Comment snapshot is unavailable; no agent invocation was verified."
    return 0
  fi

  gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --jq '.[].id' | tr -d '\r' >>"${after}"
  gh api "repos/${REPOSITORY}/pulls/${PR_NUM}/comments" --paginate --jq '.[].id' | tr -d '\r' >>"${after}"
  sort -n -o "${after}" "${after}"
  comm -13 "${before}" "${after}" >"${new_ids}"
  if [[ ! -s "${new_ids}" ]]; then
    echo "::notice::No new comments were posted by this invocation."
    return 0
  fi

  gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --slurp | jq 'add' >"${issue_json}"
  gh api "repos/${REPOSITORY}/pulls/${PR_NUM}/comments" --paginate --slurp | jq 'add' >"${review_json}"
  new_ids_json="$(jq -Rsc '[split("\n")[] | select(length > 0) | tonumber]' "${new_ids}")"
  local since_ts authors_json
  since_ts="$(cat "${state_dir}/opencode-comments-ts" 2>/dev/null || true)"
  [[ -n "${since_ts}" ]] || since_ts="1970-01-01T00:00:00Z"
  authors_json="$(_opencode_guard_authors)"
  leaked="$({
    jq -r --argjson ids "${new_ids_json}" --arg ts "${since_ts}" --argjson authors "${authors_json}" \
      '.[] | select(.id as $id | ($ids | index($id)) != null)
         | select((.created_at // "") >= $ts)
         | select((.user.login // "") as $l | ($authors | index($l)) != null)
         | .body' "${issue_json}"
    jq -r --argjson ids "${new_ids_json}" --arg ts "${since_ts}" --argjson authors "${authors_json}" \
      '.[] | select(.id as $id | ($ids | index($id)) != null)
         | select((.created_at // "") >= $ts)
         | select((.user.login // "") as $l | ($authors | index($l)) != null)
         | .body' "${review_json}"
  } | grep -E '@/|/tmp/' || true)"
  if [[ -n "${leaked}" ]]; then
    echo "::error::A comment posted by this run contains a leaked path token instead of content:"
    echo "${leaked}"
    echo "The temp file no longer exists on this runner, so the intended content cannot"
    echo "be recovered. Re-run the command and inline the content rather than a @/tmp/... path."
    return 1
  fi
  echo "::notice::No leaked path tokens in comments posted by this run."
}

# True when a top-level completion comment is a clean bill of health.
# `opencode github run` posts the agent's final text verbatim, and models
# keep narrating that no code changes are needed. Those comments are noise.
# A submitted review (html link) or an inline severity header is a real
# finding summary and stays.
opencode_comment_is_clean_bill() {
  local body="${1}"
  if grep -q 'pullrequestreview-' <<< "${body}"; then
    return 1
  fi
  if grep -Eq '\*\*(critical|important|suggestion)' <<< "${body}"; then
    return 1
  fi
  if grep -Eq '^[[:space:]]*<!--[[:space:]]*opencode-review:clean[[:space:]]-->[[:space:]]*$' <<< "${body}"; then
    return 0
  fi
  if grep -Eiq \
    'no noteworthy issues found|no new changes require review|no actionable findings' \
    <<< "${body}"; then
    return 0
  fi
  return 1
}

opencode_comment_suppress_clean() {
  local state_dir before after new_ids issue_json new_ids_json since_ts authors_json
  local row id body deleted
  state_dir="$(_opencode_guard_state_dir)"
  before="${state_dir}/opencode-comments-before"
  after="${state_dir}/opencode-comments-after-suppress"
  new_ids="${state_dir}/opencode-comments-new-suppress"
  issue_json="${state_dir}/opencode-issue-comments-suppress.json"

  [[ -n "${PR_NUM:-}" ]] || return 0
  if [[ ! -f "${before}" ]]; then
    echo "::warning::Comment snapshot is unavailable; no-findings comments were not removed."
    return 0
  fi

  : >"${after}"
  gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --jq '.[].id' | tr -d '\r' >>"${after}"
  sort -n -o "${after}" "${after}"
  comm -13 "${before}" "${after}" >"${new_ids}"
  if [[ ! -s "${new_ids}" ]]; then
    echo "::notice::No new comments were posted by this invocation."
    return 0
  fi

  gh api "repos/${REPOSITORY}/issues/${PR_NUM}/comments" --paginate --slurp | jq 'add' >"${issue_json}"
  new_ids_json="$(jq -Rsc '[split("\n")[] | select(length > 0) | tonumber]' "${new_ids}")"
  since_ts="$(cat "${state_dir}/opencode-comments-ts" 2>/dev/null || true)"
  [[ -n "${since_ts}" ]] || since_ts="1970-01-01T00:00:00Z"
  authors_json="$(_opencode_guard_authors)"

  deleted=0
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    id="$(jq -r '.id' <<< "${row}")"
    body="$(jq -r '.body' <<< "${row}")"
    if opencode_comment_is_clean_bill "${body}"; then
      if grep -E '@/|/tmp/' <<< "${body}" > /dev/null; then
        echo "::error::A no-findings comment posted by this run contains a leaked path token:"
        echo "${body}"
        return 1
      fi
      gh api --method DELETE "repos/${REPOSITORY}/issues/comments/${id}" > /dev/null
      echo "::notice::Removed a no-findings pull request comment (${id})."
      deleted=$((deleted + 1))
    fi
  done < <(jq -c \
    --argjson ids "${new_ids_json}" \
    --arg ts "${since_ts}" \
    --argjson authors "${authors_json}" \
    '.[] | select(.id as $id | ($ids | index($id)) != null)
       | select((.created_at // "") >= $ts)
       | select((.user.login // "") as $l | ($authors | index($l)) != null)
       | {id, body}' "${issue_json}")

  if ((deleted == 0)); then
    echo "::notice::No no-findings review comments to remove."
  fi
}

_opencode_guard_main() {
  local command="${1:?usage: comment-guard.sh snapshot|verify|suppress-clean}"
  case "${command}" in
  snapshot) opencode_comment_snapshot ;;
  verify) opencode_comment_verify ;;
  suppress-clean) opencode_comment_suppress_clean ;;
  *)
    echo "::error::Unknown comment-guard command '${command}'." >&2
    return 1
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_guard_main "$@"
fi
