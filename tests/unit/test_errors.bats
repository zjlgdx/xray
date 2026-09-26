#!/usr/bin/env bats
# Error constants remain safe to source repeatedly.
load ../test_helper

@test "errors.sh can be sourced repeatedly and retains invalid-argument exit status" {
  run bash -eu -c 'source "$1/lib/errors.sh"; source "$1/lib/errors.sh"; exit "${ERR_INVALID_ARG}"' _ "${PROJECT_ROOT}"
  [ "$status" -eq 2 ]
}
