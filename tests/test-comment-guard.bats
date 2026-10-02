#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  guard_script="${repo_root}/scripts/comment-guard.sh"
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  fake_temp="${BATS_TEST_TMPDIR}/rt"
  mkdir -p "${fake_bin}" "${fake_temp}"
  export RUNNER_TEMP="${fake_temp}"
  export REPOSITORY="owner/repo"
  export PR_NUM="7"

  # gh stub: serves canned comment lists from $FAKE_ISSUE_COMMENTS and
  # $FAKE_PULL_COMMENTS (JSON array files the test mutates between calls).
  cat > "${fake_bin}/gh" << 'EOF'
#!/usr/bin/env bash
url="" jq_expr="" slurp="" method="GET" prev=""
for arg in "$@"; do
  if [[ "${prev}" == "--jq" ]]; then jq_expr="${arg}"; fi
  if [[ "${prev}" == "--method" || "${prev}" == "-X" ]]; then method="${arg}"; fi
  case "${arg}" in
    repos/*) url="${arg}" ;;
    --slurp) slurp="true" ;;
  esac
  prev="${arg}"
done
if [[ "${method}" == "DELETE" ]]; then
  printf '%s\n' "${url}" >> "${FAKE_DELETED:?}"
  exit 0
fi
case "${url}" in
  */issues/*) file="${FAKE_ISSUE_COMMENTS:?}" ;;
  */pulls/*) file="${FAKE_PULL_COMMENTS:?}" ;;
  *) exit 1 ;;
esac
if [[ -n "${slurp}" ]]; then
  printf '[%s]' "$(cat "${file}")"
elif [[ -n "${jq_expr}" ]]; then
  jq -r "${jq_expr}" "${file}"
fi
EOF
  chmod +x "${fake_bin}/gh"
  export PATH="${fake_bin}:${PATH}"

  issue_file="${BATS_TEST_TMPDIR}/issue.json"
  pull_file="${BATS_TEST_TMPDIR}/pull.json"
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}}]\n' > "${issue_file}"
  printf '[{"id":22,"body":"older","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}}]\n' > "${pull_file}"
  export FAKE_ISSUE_COMMENTS="${issue_file}"
  export FAKE_PULL_COMMENTS="${pull_file}"
  deleted_file="${BATS_TEST_TMPDIR}/deleted.txt"
  : > "${deleted_file}"
  export FAKE_DELETED="${deleted_file}"
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p "${TMPDIR}"
  export GITHUB_RUN_ID="test-run-1"
}

@test "snapshot records sorted issue and review comment ids" {
  run "${guard_script}" snapshot
  [ "${status}" -eq 0 ]
  run cat "${RUNNER_TEMP}/opencode-comments-before"
  [ "${output}" = $'11\n22' ]
}

@test "verify passes when no new comments were posted" {
  "${guard_script}" snapshot
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No new comments"* ]]
}

@test "verify passes clean new comments" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":33,"body":"looks good to me","created_at":"2999-01-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No leaked path tokens"* ]]
}

@test "verify fails when a new comment leaks an @path token" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":33,"body":"see @/tmp/opencode/finding.md","created_at":"2999-01-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"leaked path token"* ]]
}

@test "verify fails when a new review comment leaks a /tmp/ path" {
  "${guard_script}" snapshot
  printf '[{"id":22,"body":"older","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":44,"body":"content lives in /tmp/opencode/x.md","created_at":"2999-01-01T00:00:00Z","user":{"login":"opencode-agent[bot]"}}]\n' > "${FAKE_PULL_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"leaked path token"* ]]
}

@test "verify ignores a leaked path from a different author (concurrent run)" {
  "${guard_script}" snapshot
  printf 'cached-app-tok\n' > "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}"
  printf '[{"id":22,"body":"older","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":44,"body":"@/tmp/opencode/r1.md","created_at":"2999-01-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_PULL_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No leaked path tokens"* ]]
}

@test "verify still fails on a leaked path from this run's own identity" {
  "${guard_script}" snapshot
  printf 'cached-app-tok\n' > "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}"
  printf '[{"id":22,"body":"older","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":44,"body":"@/tmp/opencode/r1.md","created_at":"2999-01-01T00:00:00Z","user":{"login":"opencode-agent[bot]"}}]\n' > "${FAKE_PULL_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"leaked path token"* ]]
}

@test "verify ignores comments created before the snapshot" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":33,"body":"see @/tmp/leak.md","created_at":"2000-06-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No leaked path tokens"* ]]
}

@test "verify attributes github-actions[bot] comments under use-github-token" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":33,"body":"@/tmp/opencode/x.md","created_at":"2999-01-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run env USE_GITHUB_TOKEN=true "${guard_script}" verify
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"leaked path token"* ]]
}

@test "verify warns and passes without a prior snapshot" {
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"snapshot is unavailable"* ]]
}

@test "verify is a no-op without a PR number" {
  unset PR_NUM
  run "${guard_script}" verify
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "unknown subcommand fails" {
  run "${guard_script}" frobnicate
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Unknown comment-guard command"* ]]
}

@test "suppress-clean deletes a no-findings narration from this run" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":33,"body":"No noteworthy issues found. The incremental diff introduces no new defects and no code changes are needed.","created_at":"2999-01-01T00:00:00Z","user":{"login":"opencode-agent[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" suppress-clean
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Removed a no-findings pull request comment (33)"* ]]
  [[ "$(cat "${FAKE_DELETED}")" == "repos/owner/repo/issues/comments/33" ]]
}

@test "suppress-clean deletes the clean sentinel" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":34,"body":"<!-- opencode-review:clean -->","created_at":"2999-01-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" suppress-clean
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Removed a no-findings pull request comment (34)"* ]]
}

@test "suppress-clean keeps a submitted review summary" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":35,"body":"Review submitted: https://github.com/owner/repo/pull/7#pullrequestreview-1\\n\\nOne inline finding.","created_at":"2999-01-01T00:00:00Z","user":{"login":"opencode-agent[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" suppress-clean
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No no-findings review comments to remove"* ]]
  [ ! -s "${FAKE_DELETED}" ]
}

@test "suppress-clean keeps an unanchored findings summary" {
  "${guard_script}" snapshot
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":36,"body":"The migration drops the column with no backfill, so existing rows lose the value.","created_at":"2999-01-01T00:00:00Z","user":{"login":"opencode-agent[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" suppress-clean
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No no-findings review comments to remove"* ]]
  [ ! -s "${FAKE_DELETED}" ]
}

@test "suppress-clean ignores a clean comment from another author" {
  "${guard_script}" snapshot
  printf 'cached-app-tok\n' > "${TMPDIR}/opencode-app-token.${GITHUB_RUN_ID}"
  printf '[{"id":11,"body":"old","created_at":"2000-01-01T00:00:00Z","user":{"login":"human"}},{"id":37,"body":"No noteworthy issues found.","created_at":"2999-01-01T00:00:00Z","user":{"login":"github-actions[bot]"}}]\n' > "${FAKE_ISSUE_COMMENTS}"
  run "${guard_script}" suppress-clean
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No no-findings review comments to remove"* ]]
  [ ! -s "${FAKE_DELETED}" ]
}
