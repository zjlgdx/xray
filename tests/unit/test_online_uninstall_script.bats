#!/usr/bin/env bats
# Unit tests for the top-level online uninstall.sh wrapper.

load ../test_helper

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "uninstall.sh - parse_args accepts non-interactive flags" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    parse_args --force --keep-config --remove-install-dir --debug
    printf "%s|%s|%s|%s" "${FORCE}" "${KEEP_CONFIG}" "${REMOVE_INSTALL_DIR}" "${DEBUG}"
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "true|true|true|true" ]
}

@test "uninstall.sh - cleanup returns success when TMP_DIR is unset" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    unset TMP_DIR

    cleanup
  '

  [ "${status}" -eq 0 ]
}

@test "uninstall.sh - cleanup removes temporary directory when present" {
  local tmp_dir="${TEST_TMPDIR}/uninstall-tmp"
  mkdir -p "${tmp_dir}"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    TMP_DIR="'"${tmp_dir}"'"

    cleanup
  '

  [ "${status}" -eq 0 ]
  [ ! -d "${tmp_dir}" ]
}

@test "uninstall.sh - check_installation fails in non-interactive mode without --force" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    empty_bin="$(mktemp -d)"
    trap '"'"'/bin/rm -rf "${empty_bin}"'"'"' EXIT
    PATH="${empty_bin}:/bin:/usr/bin"
    INSTALL_DIR="'"${TEST_TMPDIR}"'/missing-install"
    FORCE=""

    check_installation
  '

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"use --force parameter to force uninstallation"* ]]
}

@test "uninstall.sh - check_installation allows missing install when --force is set" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    empty_bin="$(mktemp -d)"
    trap '"'"'/bin/rm -rf "${empty_bin}"'"'"' EXIT
    PATH="${empty_bin}:/bin:/usr/bin"
    INSTALL_DIR="'"${TEST_TMPDIR}"'/missing-install"
    FORCE="true"

    check_installation
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"not installed or not found"* ]]
}

@test "uninstall.sh - confirm_uninstallation auto-continues in non-interactive mode" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    KEEP_CONFIG="true"
    FORCE=""

    confirm_uninstallation
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Non-interactive mode detected"* ]]
}

@test "uninstall.sh - run_xrf_uninstall prefers installed xrf" {
  local workdir="${TEST_TMPDIR}/prefer-install-dir"
  mkdir -p "${workdir}/install/bin"

  cat > "${workdir}/install/bin/xrf" <<'EOF'
#!/usr/bin/env bash
printf "%s|%s\n" "$PWD" "$*" >> "__CALLS_FILE__"
exit 0
EOF
  sed -i.bak "s|__CALLS_FILE__|${workdir}/calls.log|" "${workdir}/install/bin/xrf"
  chmod +x "${workdir}/install/bin/xrf"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    INSTALL_DIR="'"${workdir}"'/install"
    TMP_DIR="'"${workdir}"'/tmp"
    mkdir -p "${TMP_DIR}/xray-fusion/bin"

    run_xrf_uninstall
  '

  [ "${status}" -eq 0 ]
  [ "$(cat "${workdir}/calls.log")" = "${workdir}/install|uninstall" ]
}

@test "uninstall.sh - run_xrf_uninstall falls back to downloaded xrf" {
  local workdir="${TEST_TMPDIR}/fallback-downloaded-xrf"
  mkdir -p "${workdir}/tmp/xray-fusion/bin"

  cat > "${workdir}/tmp/xray-fusion/bin/xrf" <<'EOF'
#!/usr/bin/env bash
printf "%s|%s\n" "$PWD" "$*" >> "__CALLS_FILE__"
exit 0
EOF
  sed -i.bak "s|__CALLS_FILE__|${workdir}/calls.log|" "${workdir}/tmp/xray-fusion/bin/xrf"
  chmod +x "${workdir}/tmp/xray-fusion/bin/xrf"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    INSTALL_DIR="'"${workdir}"'/missing-install"
    TMP_DIR="'"${workdir}"'/tmp"

    run_xrf_uninstall
  '

  [ "${status}" -eq 0 ]
  [ "$(cat "${workdir}/calls.log")" = "${workdir}/tmp/xray-fusion|uninstall" ]
}

@test "uninstall.sh - remove_installation_directory honors --remove-install-dir" {
  local install_dir="${TEST_TMPDIR}/remove-install-dir"
  mkdir -p "${install_dir}"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    INSTALL_DIR="'"${install_dir}"'"
    REMOVE_INSTALL_DIR="true"

    remove_installation_directory
  '

  [ "${status}" -eq 0 ]
  [ ! -d "${install_dir}" ]
}

@test "uninstall.sh - remove_installation_directory preserves install directory by default" {
  local install_dir="${TEST_TMPDIR}/keep-install-dir"
  mkdir -p "${install_dir}"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    INSTALL_DIR="'"${install_dir}"'"
    REMOVE_INSTALL_DIR=""

    remove_installation_directory
  '

  [ "${status}" -eq 0 ]
  [ -d "${install_dir}" ]
}
