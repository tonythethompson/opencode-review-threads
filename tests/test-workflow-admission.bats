#!/usr/bin/env bats

@test "workflow admission gate accepts multiline commands and configured mentions" {
  cd "$(git -C "${BATS_TEST_DIRNAME}" rev-parse --show-toplevel)"
  run node tests/test-workflow-admission.cjs
  [ "${status}" -eq 0 ]
}
