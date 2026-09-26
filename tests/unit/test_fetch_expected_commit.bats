#!/usr/bin/env bats
# Unit tests for fetch_expected_commit() retry and fallback logic

load ../test_helper

setup() {
  setup_test_env
  export XRF_JSON=false XRF_DEBUG=false
}

teardown() {
  cleanup_test_env
}

# Helper: source install.sh and extract fetch_expected_commit + dependencies
source_install_helpers() {
  cat << 'BASH'
    set -euo pipefail
    source "$1/install.sh"
BASH
}

@test "fetch_expected_commit - succeeds with XRF_EXPECTED_COMMIT env var" {
  run bash -c '
    export XRF_JSON=false XRF_DEBUG=false
    source "'"${PROJECT_ROOT}"'/install.sh"
    XRF_EXPECTED_COMMIT="aabbccddee00112233445566778899aabbccddee"
    EXPECTED_COMMIT=""
    fetch_expected_commit
    echo "${EXPECTED_COMMIT}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" =~ "aabbccddee00112233445566778899aabbccddee" ]]
}

@test "fetch_expected_commit - rejects invalid XRF_EXPECTED_COMMIT format" {
  run bash -c '
    export XRF_JSON=false XRF_DEBUG=false
    source "'"${PROJECT_ROOT}"'/install.sh"
    XRF_EXPECTED_COMMIT="not-a-valid-hash"
    EXPECTED_COMMIT=""
    fetch_expected_commit
  '
  [ "$status" -eq 1 ]
  [[ "${output}" =~ "Invalid XRF_EXPECTED_COMMIT format" ]]
}

@test "fetch_expected_commit - falls back to git ls-remote when API fails" {
  run bash -c '
    export XRF_JSON=false XRF_DEBUG=false
    source "'"${PROJECT_ROOT}"'/install.sh"
    EXPECTED_COMMIT=""
    REPO_URL="https://github.com/xrf9268-hue/xray.git"
    BRANCH="main"

    # Mock curl to always fail (simulate API unavailability)
    curl() { return 1; }
    export -f curl

    # Mock git ls-remote to return a known hash
    git() {
      if [[ "${1:-}" == "ls-remote" ]]; then
        echo "aabbccddee00112233445566778899aabbccddee	refs/heads/main"
        return 0
      fi
      command git "$@"
    }
    export -f git

    fetch_expected_commit
    echo "${EXPECTED_COMMIT}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" =~ "aabbccddee00112233445566778899aabbccddee" ]]
}

@test "fetch_expected_commit - fails when both API and git ls-remote fail" {
  run bash -c '
    export XRF_JSON=false XRF_DEBUG=false
    source "'"${PROJECT_ROOT}"'/install.sh"
    EXPECTED_COMMIT=""
    REPO_URL="https://github.com/xrf9268-hue/xray.git"
    BRANCH="main"

    # Mock curl to always fail
    curl() { return 1; }
    export -f curl

    # Mock git ls-remote to fail
    git() {
      if [[ "${1:-}" == "ls-remote" ]]; then
        return 1
      fi
      command git "$@"
    }
    export -f git

    fetch_expected_commit
  '
  [ "$status" -eq 1 ]
  [[ "${output}" =~ "Failed to determine expected commit from GitHub API and git ls-remote" ]]
}

@test "fetch_expected_commit - skips fetch when EXPECTED_COMMIT already set" {
  run bash -c '
    export XRF_JSON=false XRF_DEBUG=false
    source "'"${PROJECT_ROOT}"'/install.sh"
    EXPECTED_COMMIT="aabbccddee00112233445566778899aabbccddee"
    fetch_expected_commit
    echo "${EXPECTED_COMMIT}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" =~ "aabbccddee00112233445566778899aabbccddee" ]]
}

@test "fetch_expected_commit - succeeds on API retry after initial failure" {
  run bash -c '
    export XRF_JSON=false XRF_DEBUG=false
    source "'"${PROJECT_ROOT}"'/install.sh"
    EXPECTED_COMMIT=""
    REPO_URL="https://github.com/xrf9268-hue/xray.git"
    BRANCH="main"

    mockbin="$(mktemp -d)"
    trap '"'"'rm -rf "${mockbin}"'"'"' EXIT

    # Track call count via temp file
    CALL_COUNT_FILE="${mockbin}/curl.calls"
    echo "0" > "${CALL_COUNT_FILE}"

    cat > "${mockbin}/curl" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
set -euo pipefail
count_file="__COUNT_FILE__"
count="$(cat "${count_file}")"
count=$((count + 1))
printf "%s" "${count}" > "${count_file}"
if [[ "${count}" -lt 2 ]]; then
  exit 1
fi
printf "{\"sha\": \"1234567890abcdef1234567890abcdef12345678\"}"
EOF
    sed -i.bak "s|__COUNT_FILE__|${CALL_COUNT_FILE}|" "${mockbin}/curl"
    chmod +x "${mockbin}/curl"

    cat > "${mockbin}/git" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
exit 99
EOF
    chmod +x "${mockbin}/git"

    cat > "${mockbin}/sleep" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${mockbin}/sleep"

    PATH="${mockbin}:${PATH}"

    fetch_expected_commit
    echo "${EXPECTED_COMMIT}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" =~ "1234567890abcdef1234567890abcdef12345678" ]]
}
