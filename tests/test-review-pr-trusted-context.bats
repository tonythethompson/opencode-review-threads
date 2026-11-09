#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2119,SC2120

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  context_lib="${repo_root}/.opencode/scripts/review-pr-context.sh"
  gh_helper="${repo_root}/.opencode/scripts/review-pr-gh.sh"
  submit_helper="${repo_root}/.opencode/scripts/review-pr-submit.sh"
  fake_home="$(mktemp -d "${BATS_TEST_TMPDIR}/home.XXXXXX")"
  fake_bin="${fake_home}/bin"
  event_path="${fake_home}/event.json"
  mkdir -p "${fake_bin}" "${fake_home}/.config/opencode/review-state"
}

write_event() {
  local number="${1:-42}"
  printf '{"pull_request":{"number":%s}}\n' "${number}" > "${event_path}"
}

write_context() {
  local repo="${1:-octo/repo}" number="${2:-42}"
  local base="${3:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  local head="${4:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  jq -n --arg repository "${repo}" --argjson pr_number "${number}" \
    --arg base_sha "${base}" --arg head_sha "${head}" \
    '{repository: $repository, pr_number: $pr_number, base_sha: $base_sha, head_sha: $head_sha}' \
    > "${fake_home}/.config/opencode/review-state/context.json"
}

write_gh_commit() {
  local head="${1:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  local resolved="${2:-${head}}"
  cat > "${fake_bin}/gh" << EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == "api repos/octo/repo/commits/${head} --jq .sha" ]]; then
  printf '%s\n' '${resolved}'
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"
}

run_trusted_context() {
  local repository="${1:-octo/repo}" path="${2:-${event_path}}"
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="${repository}" GITHUB_EVENT_PATH="${path}" \
    bash -c 'source "$1"; opencode_review_trusted_context' _ "${context_lib}"
}

assert_trusted_context_rejected() {
  run_trusted_context "$@"
  [ "${status}" -ne 0 ]
}

@test "trusted context accepts a matching event repository and pinned commit" {
  write_event
  write_context
  write_gh_commit

  run_trusted_context

  [ "${status}" -eq 0 ]
  [ "${output}" = $'octo/repo\t42\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]
}

@test "trusted context rejects a repository mismatch" {
  write_event
  write_context "other/repo"
  write_gh_commit

  assert_trusted_context_rejected
}

@test "trusted context rejects a pull request mismatch" {
  write_event 43
  write_context
  write_gh_commit

  assert_trusted_context_rejected
}

@test "trusted context accepts an advanced live head" {
  write_event
  write_context
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "api repos/octo/repo/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --jq .sha" ]]; then
  printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  run_trusted_context

  [ "${status}" -eq 0 ]
}

@test "trusted context rejects an unreadable pinned commit" {
  write_event
  write_context
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  assert_trusted_context_rejected
}

@test "trusted context rejects a commit response with a different valid SHA" {
  write_event
  write_context
  write_gh_commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa cccccccccccccccccccccccccccccccccccccccc

  assert_trusted_context_rejected
}

@test "trusted context rejects a resolved SHA that only prefixes the pinned SHA" {
  write_event
  write_context "octo/repo" 42 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "aaaaaaa"
  write_gh_commit aaaaaaa aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  assert_trusted_context_rejected
}

@test "trusted context rejects malformed or unavailable trust inputs" {
  local context_file="${fake_home}/.config/opencode/review-state/context.json"
  write_event
  write_gh_commit

  rm -f "${context_file}"
  assert_trusted_context_rejected

  : > "${context_file}"
  assert_trusted_context_rejected

  printf '{\n' > "${context_file}"
  assert_trusted_context_rejected

  jq -n --argjson pr_number 42 --arg head_sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    '{repository: 7, pr_number: $pr_number, head_sha: $head_sha}' > "${context_file}"
  assert_trusted_context_rejected

  write_context "octo/repo" 0
  assert_trusted_context_rejected

  write_context "octo/repo" 1.5
  assert_trusted_context_rejected

  write_context "octo/repo" 42 "not-a-sha"
  assert_trusted_context_rejected

  write_context "octo/repo" 42 "abcdef"
  assert_trusted_context_rejected

  write_context "octo/repo" 42 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  assert_trusted_context_rejected

  write_context
  assert_trusted_context_rejected "octo/repo" "${fake_home}/missing-event.json"

  printf '{\n' > "${event_path}"
  assert_trusted_context_rejected

  write_event
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${fake_bin}/gh"
  assert_trusted_context_rejected
}

@test "metadata reads the captured snapshot without checking the live head" {
  local calls="${fake_home}/gh-calls"
  local base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_event
  write_context octo/repo 42 "${base}" "${head}"
  jq -n --arg base_sha "${base}" --arg head_sha "${head}" \
    '{
      number: 42,
      title: "Review",
      body: "Body",
      baseRefName: "main",
      baseRefOid: $base_sha,
      headRefName: "topic",
      headRefOid: $head_sha,
      files: [{path: "file.txt", additions: 1, deletions: 0}],
      url: "https://github.com/octo/repo/pull/42"
    }' > "${fake_home}/.config/opencode/review-state/metadata.json"
  cat > "${fake_bin}/gh" << EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'call\n' >>'${calls}'
if [[ "\$*" == "api repos/octo/repo/commits/${head} --jq .sha" ]]; then
  printf '%s\n' '${head}'
  exit 0
fi
exit 1
EOF
  chmod +x "${fake_bin}/gh"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${gh_helper}" metadata

  [ "${status}" -eq 0 ]
  [ "$(wc -l < "${calls}")" -eq 1 ]
  jq -e --arg head_sha "${head}" \
    '.headRefOid == $head_sha and .baseRefOid == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and .files[0].path == "file.txt"' \
    <<< "${output}" > /dev/null
}

@test "metadata rejects a pinned snapshot that no longer matches the trusted context" {
  local base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local mismatched_head=cccccccccccccccccccccccccccccccccccccccc
  write_event
  write_context octo/repo 42 "${base}" "${head}"
  jq -n --arg base_sha "${base}" --arg head_sha "${mismatched_head}" \
    '{
      number: 42,
      title: "Review",
      body: "Body",
      baseRefName: "main",
      baseRefOid: $base_sha,
      headRefName: "topic",
      headRefOid: $head_sha,
      files: [{path: "file.txt", additions: 1, deletions: 0}],
      url: "https://github.com/octo/repo/pull/42"
    }' > "${fake_home}/.config/opencode/review-state/metadata.json"
  write_gh_commit "${head}"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${gh_helper}" metadata

  [ "${status}" -ne 0 ]
}

@test "both review helpers source the canonical trusted context implementation" {
  grep -Fq 'review-pr-context.sh' "${gh_helper}"
  grep -Fq 'review-pr-context.sh' "${submit_helper}"

  run grep -Eq '^(event_pr_number|read_context|trusted_context)\(\)' "${gh_helper}" "${submit_helper}"
  [ "${status}" -eq 1 ]
}

@test "installed read helper ignores repository-controlled trusted context files" {
  local installed_dir checkout marker
  installed_dir="${fake_home}/.config/opencode/scripts"
  checkout="${fake_home}/checkout"
  marker="${fake_home}/repository-helper-ran"
  mkdir -p "${installed_dir}" "${checkout}/.opencode/scripts"
  cp "${gh_helper}" "${installed_dir}/review-pr-gh.sh"
  cp "${context_lib}" "${installed_dir}/review-pr-context.sh"
  cat > "${installed_dir}/resolve-app-token.sh" << 'EOF'
opencode_prepare_gh_token() { return 0; }
EOF
  cat > "${checkout}/.opencode/scripts/review-pr-context.sh" << EOF
touch '${marker}'
opencode_review_trusted_context() { return 0; }
opencode_review_event_pr_number() { printf '42'; }
EOF
  write_event
  write_context
  write_gh_commit

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'cd "$1"; bash "$2" validate' _ "${checkout}" "${installed_dir}/review-pr-gh.sh"

  [ "${status}" -eq 0 ]
  [ ! -e "${marker}" ]
}

@test "installed submission helper ignores repository-controlled trusted context files" {
  local installed_dir checkout marker
  installed_dir="${fake_home}/.config/opencode/scripts"
  checkout="${fake_home}/checkout"
  marker="${fake_home}/repository-helper-ran"
  mkdir -p "${installed_dir}" "${checkout}/.opencode/scripts"
  cp "${submit_helper}" "${installed_dir}/review-pr-submit.sh"
  cp "${context_lib}" "${installed_dir}/review-pr-context.sh"
  cat > "${checkout}/.opencode/scripts/review-pr-context.sh" << EOF
touch '${marker}'
opencode_review_trusted_context() { return 0; }
opencode_review_event_pr_number() { printf '42'; }
EOF

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    bash -c 'cd "$1"; bash "$2" prepare' _ "${checkout}" "${installed_dir}/review-pr-submit.sh"

  [ "${status}" -eq 0 ]
  [ ! -e "${marker}" ]
}

write_gh_with_reviews() {
  local reviews="${1:-[]}" verify_sha="${2:-}"
  printf '%s\n' "${reviews}" > "${fake_home}/reviews.json"
  cat > "${fake_bin}/gh" << GHSTUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "api repos/octo/repo/pulls/42/reviews --paginate")
    cat '${fake_home}/reviews.json'
    ;;
  "api repos/octo/repo/commits/${verify_sha} --jq .sha")
    [[ -n '${verify_sha}' ]] || exit 1
    printf '%s\n' '${verify_sha}'
    ;;
  *)
    exit 1
    ;;
esac
GHSTUB
  chmod +x "${fake_bin}/gh"
}

run_incremental_base() {
  local base="${1:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" \
    bash -c 'source "$1"; opencode_review_incremental_base octo/repo 42 "$2"' \
    _ "${context_lib}" "${base}"
}

@test "incremental base falls back to the pull request base without prior reviews" {
  write_gh_with_reviews '[]'

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
}

@test "incremental base falls back when the reviews request fails" {
  cat > "${fake_bin}/gh" << 'GHSTUB'
#!/usr/bin/env bash
exit 1
GHSTUB
  chmod +x "${fake_bin}/gh"

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
}

@test "incremental base uses the last bot review head commit" {
  local last=cccccccccccccccccccccccccccccccccccccccc
  write_gh_with_reviews "$(jq -n --arg sha "${last}" '[
    {id: 10, state: "COMMENTED", commit_id: "dddddddddddddddddddddddddddddddddddddddd", user: {login: "opencode-agent[bot]"}},
    {id: 11, state: "COMMENTED", commit_id: $sha, user: {login: "opencode-agent[bot]"}}
  ]')" "${last}"

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "${last}" ]
}

@test "incremental base ignores reviews from other actors" {
  write_gh_with_reviews '[
    {"id": 10, "state": "COMMENTED", "commit_id": "cccccccccccccccccccccccccccccccccccccccc", "user": {"login": "octocat"}},
    {"id": 11, "state": "COMMENTED", "commit_id": "dddddddddddddddddddddddddddddddddddddddd", "user": {"login": "coderabbitai[bot]"}}
  ]'

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
}

@test "incremental base falls back when the last reviewed commit is unreadable" {
  write_gh_with_reviews '[{"id":10,"state":"COMMENTED","commit_id":"cccccccccccccccccccccccccccccccccccccccc","user":{"login":"opencode-agent[bot]"}}]' \
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
}

@test "incremental base keeps the last reviewed commit even when it is the pinned head" {
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_gh_with_reviews "$(jq -n --arg sha "${head}" '[
    {id: 10, state: "COMMENTED", commit_id: $sha, user: {login: "opencode-agent[bot]"}}
  ]')" "${head}"

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "${head}" ]
}

@test "incremental base accepts github-actions bot reviews" {
  local last=cccccccccccccccccccccccccccccccccccccccc
  write_gh_with_reviews "$(jq -n --arg sha "${last}" '[
    {id: 10, state: "COMMENTED", commit_id: $sha, user: {login: "github-actions[bot]"}}
  ]')" "${last}"

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "${last}" ]
}

@test "incremental base ignores pending reviews that were never submitted" {
  local last=cccccccccccccccccccccccccccccccccccccccc
  write_gh_with_reviews "$(jq -n --arg sha "${last}" '[
    {id: 10, state: "COMMENTED", commit_id: "dddddddddddddddddddddddddddddddddddddddd", user: {login: "opencode-agent[bot]"}},
    {id: 11, state: "PENDING", commit_id: $sha, user: {login: "opencode-agent[bot]"}}
  ]')" "dddddddddddddddddddddddddddddddddddddddd"

  run_incremental_base

  [ "${status}" -eq 0 ]
  [ "${output}" = "dddddddddddddddddddddddddddddddddddddddd" ]
}

@test "diff reads the incremental range recorded in the pinned context" {
  local base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local review=cccccccccccccccccccccccccccccccccccccccc
  write_event
  jq -n --arg repository octo/repo --argjson pr_number 42 \
    --arg base_sha "${base}" --arg head_sha "${head}" --arg review_base "${review}" \
    '{repository: $repository, pr_number: $pr_number, base_sha: $base_sha, head_sha: $head_sha, review_base: $review_base}' \
    > "${fake_home}/.config/opencode/review-state/context.json"
  cat > "${fake_bin}/gh" << GHSTUB
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "api repos/octo/repo/commits/${head} --jq .sha")
    printf '%s\n' '${head}'
    ;;
  "api -H Accept: application/vnd.github.diff repos/octo/repo/compare/${review}...${head}")
    printf 'diff-output\n'
    ;;
  *)
    exit 1
    ;;
esac
GHSTUB
  chmod +x "${fake_bin}/gh"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash "${gh_helper}" diff

  [ "${status}" -eq 0 ]
  [ "${output}" = "diff-output" ]
}

@test "context pins the incremental base from the last bot review" {
  if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
    skip "jq --slurpfile process substitution is unavailable on Windows"
  fi
  local base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  local head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local last=cccccccccccccccccccccccccccccccccccccccc
  jq -n --arg base "${base}" --arg head "${head}" '{
    pull_request: {
      number: 42,
      title: "Review",
      body: "Body",
      base: {ref: "main", sha: $base},
      head: {ref: "topic", sha: $head},
      html_url: "https://github.com/octo/repo/pull/42"
    }
  }' > "${event_path}"
  cat > "${fake_bin}/gh" << GHSTUB
#!/usr/bin/env bash
set -euo pipefail
sha="\$(printf '%s' "\$*" | sed -n 's|api repos/octo/repo/commits/\([0-9a-f]*\) --jq .sha|\1|p')"
if [[ -n "\${sha}" ]]; then
  printf '%s\n' "\${sha}"
  exit 0
fi
case "\$*" in
  "api repos/octo/repo/pulls/42/reviews --paginate")
    printf '[{"id":10,"state":"COMMENTED","commit_id":"${last}","user":{"login":"opencode-agent[bot]"}}]\n'
    ;;
  "api repos/octo/repo/compare/${last}...${head}")
    printf '{"files":[{"filename":"file.txt","additions":1,"deletions":0}]}\n'
    ;;
  *)
    exit 1
    ;;
esac
GHSTUB
  chmod +x "${fake_bin}/gh"

  run env HOME="${fake_home}" PATH="${fake_bin}:${PATH}" \
    GITHUB_REPOSITORY="octo/repo" GITHUB_EVENT_PATH="${event_path}" \
    bash -c 'mkdir -p "$1"; bash "$2" context' _ "${fake_home}/.config/opencode/review-state" "${gh_helper}"

  [ "${status}" -eq 0 ]
  jq -e --arg base "${base}" --arg head "${head}" --arg review "${last}" \
    '.base_sha == $base and .head_sha == $head and .review_base == $review' \
    <<< "${output}" > /dev/null
  jq -e '.files[0].path == "file.txt" and .baseRefOid == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "${fake_home}/.config/opencode/review-state/metadata.json" > /dev/null
}
