#!/usr/bin/env bats
# Online wrapper commit resolution uses one Git remote.

load ../test_helper

setup() { setup_test_env; }
teardown() { cleanup_test_env; }

@test "fetch_expected_commit accepts an exact pinned commit" {
  run bash -c '
    source "$1/install.sh"
    XRF_EXPECTED_COMMIT=aabbccddee00112233445566778899aabbccddee
    fetch_expected_commit
    printf "%s" "$EXPECTED_COMMIT"
  ' _ "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *aabbccddee00112233445566778899aabbccddee* ]]
}

@test "fetch_expected_commit rejects malformed pinned commit" {
  run bash -c '
    source "$1/install.sh"
    XRF_EXPECTED_COMMIT=not-a-commit
    fetch_expected_commit
  ' _ "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid or unavailable expected commit"* ]]
}

@test "fetch_expected_commit resolves the selected branch with one ls-remote" {
  run bash -c '
    source "$1/install.sh"
    REPO_URL=https://github.com/zjlgdx/xray.git
    BRANCH=main
    git() {
      [ "$1" = ls-remote ] || return 99
      [ "$2" = "$REPO_URL" ] && [ "$3" = refs/heads/main ] || return 98
      printf "aabbccddee00112233445566778899aabbccddee\trefs/heads/main\n"
    }
    fetch_expected_commit
    printf "%s" "$EXPECTED_COMMIT"
  ' _ "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *aabbccddee00112233445566778899aabbccddee* ]]
}

@test "fetch_expected_commit selects peeled annotated tag commit" {
  run bash -c '
    source "$1/install.sh"
    BRANCH=v26.9.9
    git() {
      [ "$1" = ls-remote ] || return 99
      printf "1111111111111111111111111111111111111111\trefs/tags/v26.9.9\n"
      printf "2222222222222222222222222222222222222222\trefs/tags/v26.9.9^{}\n"
    }
    fetch_expected_commit
    printf "%s" "$EXPECTED_COMMIT"
  ' _ "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *2222222222222222222222222222222222222222* ]]
}

@test "fetch_expected_commit fails when ls-remote fails" {
  run bash -c '
    source "$1/install.sh"
    git() { return 1; }
    fetch_expected_commit
  ' _ "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
}

@test "fetch_expected_commit fails when ref is absent" {
  run bash -c '
    source "$1/install.sh"
    git() { return 0; }
    fetch_expected_commit
  ' _ "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Invalid or unavailable expected commit"* ]]
}
