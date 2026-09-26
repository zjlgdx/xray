#!/usr/bin/env bats
# Integration tests for install.sh
#
# These tests verify the install script's core functionality without
# actually installing Xray (dry-run mode).

load '../test_helper'

setup() {
  setup_test_env

  # Create isolated test environment
  export TEST_INSTALL_DIR="${TEST_TMPDIR}/xray-fusion"
  export TEST_PREFIX="${TEST_TMPDIR}/prefix"
  export TEST_ETC="${TEST_TMPDIR}/etc"

  mkdir -p "${TEST_INSTALL_DIR}" "${TEST_PREFIX}" "${TEST_ETC}"

  # Copy project files to test location
  cp -r "${PROJECT_ROOT}"/* "${TEST_INSTALL_DIR}/" 2>/dev/null || true
}

teardown() {
  cleanup_test_env
}

setup_wrapper_env() {
  export XRF_FAKE_CALLS_FILE="${TEST_TMPDIR}/wrapper-calls.log"
  export XRF_FAKE_SYSTEMCTL_LOG="${TEST_TMPDIR}/systemctl.log"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"

  mkdir -p "${TEST_TMPDIR}/bin"
  cat > "${TEST_TMPDIR}/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
printf "%s\n" "$*" >> "${XRF_FAKE_SYSTEMCTL_LOG}"
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/systemctl"
}

create_fake_online_project() {
  local project_dir="${TEST_TMPDIR}/downloaded/xray-fusion"

  mkdir -p "${project_dir}/bin"
  cat > "${project_dir}/bin/xrf" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
calls_file="${XRF_FAKE_CALLS_FILE:?}"

case "${1:-}" in
  install)
    shift
    printf "install|%s\n" "$*" >> "${calls_file}"
    if [[ "${XRF_FAKE_FAIL_ON_INSTALL:-0}" == "1" ]]; then
      exit 1
    fi
    touch "${root}/.installed"
    ;;
  uninstall)
    printf "uninstall\n" >> "${calls_file}"
    rm -f "${root}/.installed"
    ;;
  status)
    [[ -f "${root}/.installed" ]]
    ;;
  *)
    printf "unknown|%s\n" "$*" >> "${calls_file}"
    ;;
esac
EOF
  chmod +x "${project_dir}/bin/xrf"
}

@test "online wrapper rejects retired topology and plugin flags" {
  run bash -c '
    source "$1/install.sh"
    TMP_DIR="$(mktemp -d)"
    source_args_module
    args::parse --topology reality-only
  ' _ "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument: --topology"* ]]
}

# =============================================================================
# Progress Indicator Tests
# =============================================================================

@test "install.sh - defines log_step function" {
  # Check if function is defined in the script
  grep -q "^log_step()" install.sh
}

@test "install.sh - defines log_substep function" {
  grep -q "^log_substep()" install.sh
}

@test "install.sh - defines show_spinner function" {
  grep -q "^show_spinner()" install.sh
}

@test "install.sh - defines check_dependencies function" {
  grep -q "^check_dependencies()" install.sh
}


# =============================================================================
# Dependency Checking Tests
# =============================================================================

@test "install.sh - check_dependencies detects missing tools" {
  skip "Requires complex mocking; functionality verified in unit tests"

  # The check_dependencies function is extensively tested in unit tests
  # Integration testing would require mocking system commands
}

@test "online wrapper clone failure leaves no installed tool" {
  run bash -c '
    source "$1/install.sh"
    TMP_DIR="$2/download"
    INSTALL_DIR="$2/tool"
    REPO_URL="$2/nonexistent-repository"
    BRANCH=main
    mkdir -p "$TMP_DIR"
    download_project
  ' _ "$PROJECT_ROOT" "$TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/tool" ]
}

@test "online wrapper verifies a cloned local repository before running its tool" {
  local repo="${TEST_TMPDIR}/source-repo"
  mkdir -p "${repo}/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${repo}/bin/xrf"
  git -C "${repo}" init -q -b main
  git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.com add bin/xrf
  git -C "${repo}" -c user.name=Fixture -c user.email=fixture@example.com commit -qm fixture
  local commit
  commit="$(git -C "${repo}" rev-parse HEAD)"

  run bash -c '
    source "$1/install.sh"
    REPO_URL="$2/source-repo"
    BRANCH=main
    TMP_DIR="$2/download-ok"
    XRF_EXPECTED_COMMIT="$3"
    mkdir -p "$TMP_DIR"
    download_project
    [ "$INTEGRITY_VERIFIED" = true ]
    [ "$(git -C "$TMP_DIR/xray-fusion" rev-parse HEAD)" = "$3" ]
  ' _ "$PROJECT_ROOT" "$TEST_TMPDIR" "$commit"
  [ "$status" -eq 0 ]

  run bash -c '
    source "$1/install.sh"
    REPO_URL="$2/source-repo"
    BRANCH=main
    TMP_DIR="$2/download-bad"
    XRF_EXPECTED_COMMIT=0000000000000000000000000000000000000000
    mkdir -p "$TMP_DIR"
    download_project
  ' _ "$PROJECT_ROOT" "$TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commit hash mismatch"* ]]
}

@test "online wrapper requires explicit SNI before dependency or repository work" {
  run bash -c '
    unset XRAY_SNI
    source "$1/install.sh"
    main --yes
  ' _ "$PROJECT_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"XRAY_SNI is required"* ]]
  [[ "$output" != *"Checking core dependencies"* ]]
}

# =============================================================================
# Documentation and Help Tests
# =============================================================================

@test "install.sh - contains usage documentation" {
  grep -q "Usage:" install.sh || grep -q "curl -sL" install.sh
}

@test "install.sh - defines error_exit function" {
  grep -q "^error_exit()" install.sh
}

@test "install.sh - sets correct shell options" {
  # Check if the script uses set -euo pipefail
  grep -q "set -euo pipefail" install.sh
}

@test "online wrapper rejects repeat install and permits reinstall after tool removal" {
  setup_wrapper_env
  create_fake_online_project

  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    source "'"${PROJECT_ROOT}"'/uninstall.sh"

    TMP_DIR="'"${TEST_TMPDIR}"'/downloaded"
    INSTALL_DIR="'"${TEST_TMPDIR}"'/online-install"
    SYMLINK_PATH="'"${TEST_TMPDIR}"'/bin/xrf"
    XRAY_SNI="example.com"
    VERSION="latest"
    DEBUG="false"
    XRF_YES="true"
    INTEGRITY_VERIFIED="true"

    install_xray_fusion
    run_xray_install

    if install_xray_fusion; then
      exit 42
    fi
    test -f "${INSTALL_DIR}/.installed"
    test -L "${SYMLINK_PATH}"

    run_xrf_uninstall
    rm -f "${SYMLINK_PATH}"
    rm -rf "${INSTALL_DIR}"

    install_xray_fusion
    run_xray_install
  '

  [ "${status}" -eq 0 ]
  [ -f "${TEST_TMPDIR}/online-install/.installed" ]
  [ "$(grep -c '^install|' "${XRF_FAKE_CALLS_FILE}")" -eq 2 ]
  [ "$(grep -c '^uninstall$' "${XRF_FAKE_CALLS_FILE}")" -eq 1 ]
}

@test "online wrapper cleanup removes fresh install after failed install" {
  setup_wrapper_env
  create_fake_online_project
  export XRF_FAKE_FAIL_ON_INSTALL="1"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"

    TMP_DIR="'"${TEST_TMPDIR}"'/downloaded"
    INSTALL_DIR="'"${TEST_TMPDIR}"'/failed-install"
    SYMLINK_PATH="'"${TEST_TMPDIR}"'/bin/failed-xrf"
    XRAY_SNI="example.com"
    VERSION="latest"
    DEBUG="false"
    XRF_YES="true"
    INTEGRITY_VERIFIED="true"

    install_xray_fusion
    run_xray_install
  '

  [ "${status}" -eq 1 ]
  [ ! -d "${TEST_TMPDIR}/failed-install" ]
  [ ! -L "${TEST_TMPDIR}/bin/failed-xrf" ]
}

# =============================================================================
# Integration Notes
# =============================================================================

# Most integration tests require:
# 1. Root privileges (for systemd operations)
# 2. Network access (for downloading)
# 3. System package manager (apt/yum/dnf)
#
# These are verified through manual testing on target systems.
# The unit tests provide comprehensive coverage of the core logic.
