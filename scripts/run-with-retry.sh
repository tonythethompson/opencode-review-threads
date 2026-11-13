#!/usr/bin/env bash
# Run scripts/run-opencode.sh under a shared wall-clock deadline, with one
# retry. Between attempts the script first tries to salvage agent commits the
# CLI made locally before a rejected push (remote advanced mid-run), then
# resyncs the checkout's branch to the remote so a re-run pushes fast-forward.
#
# Env in: TIMEOUT_MINUTES  total agent budget in minutes, shared by both attempts
#         JOB_STARTED_AT   epoch the job started (defaults to this script's start)
#         GH_TOKEN         token used for salvage push auth (optional; without it
#                          salvage relies on credentials already in git config)
#         plus everything scripts/run-opencode.sh consumes (MODEL, PROMPT, ...)

opencode_retry_salvage() {
  local branch="${1}"
  local ahead
  [[ -n "${branch}" && "${branch}" != "HEAD" ]] || return 1

  echo "==> salvaging agent commits onto updated remote (branch: ${branch})"
  # actions/checkout is typically run with persist-credentials: false, so give
  # git a token explicitly before fetching or pushing.
  if [[ -n "${GH_TOKEN:-}" ]]; then
    git config --local http.https://github.com/.extraheader \
      "AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN}" | base64 -w 0)" 2> /dev/null || true
  fi
  git fetch --prune origin 2> /dev/null || true
  git rev-parse --verify "origin/${branch}" > /dev/null 2>&1 || return 1
  ahead="$(git rev-list --count "origin/${branch}"..HEAD 2> /dev/null || echo 0)"
  if ((ahead == 0)); then
    echo "::notice::no local-only commits; failure was not a rejected push"
    return 1
  fi
  if git rebase "origin/${branch}"; then
    if git push 2> /dev/null; then
      echo "::notice::salvaged agent work: rebased onto origin/${branch} and pushed"
      return 0
    fi
    echo "::warning::salvage push failed; falling back to synced re-run"
  fi
  git rebase --abort 2> /dev/null || true
  return 1
}

opencode_retry_resync() {
  local branch="${1}"
  [[ -n "${branch}" && "${branch}" != "HEAD" ]] || return 0

  echo "==> syncing branch to remote and retrying once"
  git fetch --prune origin 2> /dev/null || true
  if git rev-parse --verify "origin/${branch}" > /dev/null 2>&1; then
    git checkout -B "${branch}" "origin/${branch}" > /dev/null 2>&1 || true
    git reset --hard "origin/${branch}" > /dev/null 2>&1 || true
  fi
}

# If the session died after sealing a review payload but before submitting it,
# post the sealed findings rather than losing the whole pass. The helper's own
# checks keep this safe: it refuses unvalidated or mutated payloads, and the
# submission-attempted marker prevents double posting. No-op outside review
# mode or when nothing was sealed.
opencode_retry_salvage_review() {
  local state_dir helper
  state_dir="${HOME}/.config/opencode/review-state"
  [[ "${REVIEW_ONLY:-false}" == "true" ]] || return 1
  [[ -s "${state_dir}/validated-initial.json" && -s "${state_dir}/initial.json" ]] || return 1
  [[ ! -e "${state_dir}/submission-attempted" ]] || return 1
  helper="${HOME}/.config/opencode/scripts/review-pr-submit.sh"
  [[ -f "${helper}" ]] || helper="${ACTION_PATH:-}/.opencode/scripts/review-pr-submit.sh"
  [[ -f "${helper}" ]] || return 1
  echo "::notice::session ended with a sealed but unsubmitted review; posting it"
  bash "${helper}" submit-initial || return 1
}

# A successful agent exit does not prove that its prepared review was posted.
opencode_retry_complete_review() {
  local state_dir helper
  [[ "${REVIEW_ONLY:-false}" == "true" ]] || return 0
  state_dir="${HOME}/.config/opencode/review-state"
  [[ -s "${state_dir}/initial.json" ]] || return 0
  [[ -s "${state_dir}/review_id" ]] && return 0
  [[ ! -e "${state_dir}/submission-attempted" ]] || {
    echo "::error::Review submission was attempted but no review ID was recorded."
    return 1
  }
  helper="${HOME}/.config/opencode/scripts/review-pr-submit.sh"
  [[ -f "${helper}" ]] || helper="${ACTION_PATH:-}/.opencode/scripts/review-pr-submit.sh"
  [[ -f "${helper}" ]] || { echo "::error::Review submission helper is unavailable."; return 1; }
  echo "::notice::Completing the prepared review after the agent exited."
  bash "${helper}" validate-initial && bash "${helper}" submit-initial
}

# A retried review session must re-run prepare; the previous attempt's session
# marker would otherwise fail closed as "already prepared" and its stale state
# would block a fresh submission. Cleared only after the salvage check, which
# needs the sealed payload.
opencode_retry_clear_review_state() {
  [[ "${REVIEW_ONLY:-false}" == "true" ]] || return 0
  rm -rf "${HOME}/.config/opencode/review-state"
  rm -f "${HOME}"/.config/opencode/review-session-*
}

_opencode_retry_main() {
  local script_dir deadline branch status
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Absolute deadline for agent work; both attempts share it so a retry can
  # never overrun the job. run-opencode.sh reads OPENCODE_DEADLINE_EPOCH and
  # translates it into `timeout --signal=TERM --kill-after=60 <budget>`.
  deadline=$((${JOB_STARTED_AT:-$(date +%s)} + ${TIMEOUT_MINUTES:?TIMEOUT_MINUTES is required} * 60))
  export OPENCODE_DEADLINE_EPOCH="${deadline}"

  if (($(date +%s) >= deadline)); then
    echo "::error::No time budget remains for opencode (deadline already passed)."
    return 124
  fi

  status=0
  "${script_dir}/run-opencode.sh" || status=$?
  if ((status == 0)); then
    opencode_retry_complete_review || return 1
    echo "::notice::opencode github run succeeded (attempt 1)"
    return 0
  fi
  echo "::warning::opencode github run failed on attempt 1 (exit ${status})"

  # A sealed unsubmitted review payload survives the session; post it now so a
  # timeout does not zero out the findings. When it posts, skip the retry: the
  # deliverable already landed, and a fresh session would just see an empty
  # incremental diff. The original exit status is preserved on purpose — the
  # session did not complete.
  if opencode_retry_salvage_review; then
    echo "::warning::review findings salvaged from the failed session; not retrying"
    return "${status}"
  fi
  opencode_retry_clear_review_state

  branch="$(git rev-parse --abbrev-ref HEAD 2> /dev/null || echo '')"
  if opencode_retry_salvage "${branch}"; then
    return 0
  fi
  opencode_retry_resync "${branch}"

  if (($(date +%s) >= deadline)); then
    echo "::error::No time budget remains for a retry (deadline already passed)."
    return 124
  fi

  status=0
  "${script_dir}/run-opencode.sh" || status=$?
  if ((status == 0)); then
    opencode_retry_complete_review || return 1
    echo "::notice::opencode github run succeeded on retry"
    return 0
  fi
  if opencode_retry_salvage_review; then
    echo "::warning::review findings salvaged from the failed retry"
  fi
  echo "::error::opencode github run failed on both attempts"
  return "${status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _opencode_retry_main
fi
