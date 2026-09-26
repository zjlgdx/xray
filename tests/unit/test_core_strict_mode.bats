#!/usr/bin/env bats
# Verify core initialization enables strict shell options

load ../test_helper

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "core::init enables strict mode" {
  run bash -c '
    source '"${PROJECT_ROOT}"'/lib/core.sh
    core::init
    [[ $- == *e* && $- == *u* && $- == *E* ]]
    [[ "$(set -o | grep pipefail)" == *on* ]]
  '
  [ "$status" -eq 0 ]
}
