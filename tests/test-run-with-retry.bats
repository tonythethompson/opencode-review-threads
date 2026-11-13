#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  repo_root="$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  retry_script="${repo_root}/scripts/run-with-retry.sh"
  run_script="${repo_root}/scripts/run-opencode.sh"
  remote_repo="${BATS_TEST_TMPDIR}/remote.git"
  work_repo="${BATS_TEST_TMPDIR}/work"
  other_repo="${BATS_TEST_TMPDIR}/other"

  git init --bare --quiet "${remote_repo}"
  git init --quiet "${work_repo}"
  git -C "${work_repo}" config user.email "test@example.com"
  git -C "${work_repo}" config user.name "test"
  git -C "${work_repo}" checkout -qb feat
  printf 'base\n' > "${work_repo}/file.txt"
  git -C "${work_repo}" add file.txt
  git -C "${work_repo}" commit -qm "base"
  git -C "${work_repo}" remote add origin "${remote_repo}"
  git -C "${work_repo}" push -qu origin feat
}

_advance_remote() {
  git clone --quiet "${remote_repo}" "${other_repo}"
  git -C "${other_repo}" config user.email "test@example.com"
  git -C "${other_repo}" config user.name "test"
  git -C "${other_repo}" checkout -qb feat "origin/feat" 2> /dev/null || git -C "${other_repo}" checkout -qb feat
  printf 'remote\n' >> "${other_repo}/file.txt"
  git -C "${other_repo}" commit -qam "remote advance"
  git -C "${other_repo}" push -q origin feat
}

_local_agent_commit() {
  printf 'agent\n' >> "${work_repo}/agent.txt"
  git -C "${work_repo}" add agent.txt
  git -C "${work_repo}" commit -qm "agent work"
}

@test "successful review session validates and submits an unfinished payload" {
  mkdir -p "${BATS_TEST_TMPDIR}/home/.config/opencode/review-state" "${BATS_TEST_TMPDIR}/home/.config/opencode/scripts"
  printf '{}' > "${BATS_TEST_TMPDIR}/home/.config/opencode/review-state/initial.json"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$1" >> "$HOME/calls"' > "${BATS_TEST_TMPDIR}/home/.config/opencode/scripts/review-pr-submit.sh"
  run env HOME="${BATS_TEST_TMPDIR}/home" REVIEW_ONLY=true bash -c 'source "$1"; opencode_retry_complete_review' _ "${retry_script}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/home/calls")" = "$(printf 'validate-initial\nsubmit-initial')" ]
}

@test "unfinished review fails if validation fails" {
  mkdir -p "${BATS_TEST_TMPDIR}/home/.config/opencode/review-state" "${BATS_TEST_TMPDIR}/home/.config/opencode/scripts"
  printf '{}' > "${BATS_TEST_TMPDIR}/home/.config/opencode/review-state/initial.json"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "${BATS_TEST_TMPDIR}/home/.config/opencode/scripts/review-pr-submit.sh"
  run env HOME="${BATS_TEST_TMPDIR}/home" REVIEW_ONLY=true bash -c 'source "$1"; opencode_retry_complete_review' _ "${retry_script}"
  [ "${status}" -ne 0 ]
}

@test "salvage rebases local agent commits onto the advanced remote and pushes" {
  _advance_remote
  _local_agent_commit
  unset GH_TOKEN 2> /dev/null || true

  run bash -euo pipefail -c '
    cd "$2"
    source "$1"
    opencode_retry_salvage feat
  ' _ "${retry_script}" "${work_repo}"
  [ "${status}" -eq 0 ]

  run git -C "${remote_repo}" log --format=%s feat
  [[ "${output}" == *"agent work"* ]]
  [[ "${output}" == *"remote advance"* ]]
  run bash -c 'cd "$1" && git log --format=%s -2' _ "${work_repo}"
  [[ "${output}" == *"agent work"* ]]
}

@test "salvage declines when there are no local-only commits" {
  run bash -euo pipefail -c '
    cd "$2"
    source "$1"
    opencode_retry_salvage feat
  ' _ "${retry_script}" "${work_repo}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"no local-only commits"* ]]
}

@test "salvage declines on a detached or empty branch" {
  run bash -euo pipefail -c '
    cd "$2"
    source "$1"
    opencode_retry_salvage HEAD
  ' _ "${retry_script}" "${work_repo}"
  [ "${status}" -ne 0 ]
}

@test "resync checks the branch out at the remote tip" {
  _advance_remote
  _local_agent_commit
  run bash -euo pipefail -c '
    cd "$2"
    source "$1"
    opencode_retry_resync feat
  ' _ "${retry_script}" "${work_repo}"
  [ "${status}" -eq 0 ]

  run git -C "${work_repo}" log --format=%s -1
  [ "${output}" = "remote advance" ]
  run git -C "${work_repo}" status --porcelain
  [ -z "${output}" ]
}

@test "review-only re-imports the action-generated probe config after clearing caller overrides" {
  probe_file="${BATS_TEST_TMPDIR}/probe-config.json"
  printf '%s\n' '{"model":"opencode/big-pickle","instructions":["github-commands.md"]}' > "${probe_file}"

  run env \
    HOME="${BATS_TEST_TMPDIR}/home" \
    ACTION_PATH="${repo_root}" \
    GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace" \
    REVIEW_ONLY="true" \
    USE_BUNDLED_TOOLKIT="true" \
    MODEL="opencode/big-pickle" \
    OPENCODE_CONFIG_CONTENT='{"injected":true}' \
    OPENCODE_PROBE_CONFIG_FILE="${probe_file}" \
    bash -euo pipefail -c '
      mkdir -p "${GITHUB_WORKSPACE}" "${HOME}"
      source "$1"
      opencode_configure_run
      printf "%s" "${OPENCODE_CONFIG_CONTENT}"
    ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  run jq -r '.model' <<< "${output}"
  [ "${output}" = "opencode/big-pickle" ]
  run jq -e '.injected' <<< "${output}"
  [ "${status}" -ne 0 ]
}

_stub_submit_helper() {
  fake_home="${BATS_TEST_TMPDIR}/home"
  state_dir="${fake_home}/.config/opencode/review-state"
  calls_file="${BATS_TEST_TMPDIR}/helper-calls"
  mkdir -p "${state_dir}" "${fake_home}/.config/opencode/scripts"
  printf '%s\n' '{"body":"stub","comments":[]}' > "${state_dir}/initial.json"
  printf '%s\n' '{"body":"stub","comments":[]}' > "${state_dir}/validated-initial.json"
  cat > "${fake_home}/.config/opencode/scripts/review-pr-submit.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "${calls_file}"
EOF
  chmod +x "${fake_home}/.config/opencode/scripts/review-pr-submit.sh"
}

@test "review salvage posts a sealed payload that was never submitted" {
  _stub_submit_helper
  run env HOME="${fake_home}" REVIEW_ONLY="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_retry_salvage_review
    ' _ "${retry_script}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${calls_file}")" = "submit-initial" ]
}

@test "review salvage skips when submission was already attempted" {
  _stub_submit_helper
  : > "${state_dir}/submission-attempted"
  run env HOME="${fake_home}" REVIEW_ONLY="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_retry_salvage_review
    ' _ "${retry_script}"
  [ "${status}" -ne 0 ]
  [ ! -f "${calls_file}" ]
}

@test "review salvage is a no-op outside review mode" {
  _stub_submit_helper
  run env HOME="${fake_home}" REVIEW_ONLY="false" \
    bash -euo pipefail -c '
      source "$1"
      opencode_retry_salvage_review
    ' _ "${retry_script}"
  [ "${status}" -ne 0 ]
  [ ! -f "${calls_file}" ]
}

@test "review salvage declines when no sealed payload exists" {
  _stub_submit_helper
  : > "${state_dir}/validated-initial.json"
  run env HOME="${fake_home}" REVIEW_ONLY="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_retry_salvage_review
    ' _ "${retry_script}"
  [ "${status}" -ne 0 ]
  [ ! -f "${calls_file}" ]
}

@test "clearing review state removes the session marker and payload dir" {
  _stub_submit_helper
  session_marker="${fake_home}/.config/opencode/review-session-1-1"
  : > "${session_marker}"
  run env HOME="${fake_home}" REVIEW_ONLY="true" \
    bash -euo pipefail -c '
      source "$1"
      opencode_retry_clear_review_state
    ' _ "${retry_script}"
  [ "${status}" -eq 0 ]
  [ ! -e "${state_dir}" ]
  [ ! -e "${session_marker}" ]
}

@test "clearing review state is a no-op outside review mode" {
  _stub_submit_helper
  run env HOME="${fake_home}" REVIEW_ONLY="false" \
    bash -euo pipefail -c '
      source "$1"
      opencode_retry_clear_review_state
    ' _ "${retry_script}"
  [ "${status}" -eq 0 ]
  [ -d "${state_dir}" ]
}

@test "deadline override drives the timeout command for both attempts" {
  run bash -euo pipefail -c '
    source "$1"
    OPENCODE_DEADLINE_EPOCH=$(( $(date +%s) + 300 ))
    opencode_select_timeout_command 60
    printf "%s" "${OPENCODE_TIMEOUT_COMMAND[*]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ ^timeout\ --signal=TERM\ --kill-after=60\ [0-9]+$ ]]

  run bash -euo pipefail -c '
    source "$1"
    OPENCODE_DEADLINE_EPOCH=$(( $(date +%s) - 10 ))
    opencode_select_timeout_command 60
    printf "%s" "${OPENCODE_TIMEOUT_COMMAND[*]}"
  ' _ "${run_script}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "timeout 60m" ]
}
