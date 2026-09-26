#!/usr/bin/env bats
# Unit tests for the top-level online uninstall.sh wrapper.

load ../test_helper

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "online uninstaller rejects unsupported keep-config with exit 2" {
  run bash -c '
    source "$1/uninstall.sh"
    parse_args --keep-config
  ' _ "$PROJECT_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown option: --keep-config"* ]]
}

@test "online uninstaller rejects arbitrary unknown option with exit 2" {
  run bash -c '
    source "$1/uninstall.sh"
    parse_args --force --unexpected
  ' _ "$PROJECT_ROOT"
  [ "$status" -eq 2 ]
}

@test "online unknown option exits before invoking installed xrf" {
  local install_dir="${TEST_TMPDIR}/tool"
  mkdir -p "${install_dir}/bin"
  printf '#!/usr/bin/env bash\ntouch "$XRF_UNINSTALL_CALLED"\n' >"${install_dir}/bin/xrf"
  chmod +x "${install_dir}/bin/xrf"
  export XRF_UNINSTALL_CALLED="${TEST_TMPDIR}/uninstall.called"
  run bash -c '
    source "$1/uninstall.sh"
    INSTALL_DIR="$2/tool"
    main --unexpected
  ' _ "$PROJECT_ROOT" "$TEST_TMPDIR"
  [ "$status" -eq 2 ]
  [ ! -e "${XRF_UNINSTALL_CALLED}" ]
}

@test "online cleanup removes only the selected custom installation link" {
  local install_dir="${TEST_TMPDIR}/custom-tool"
  local link="${TEST_TMPDIR}/xrf"
  mkdir -p "${install_dir}/bin"
  : >"${install_dir}/bin/xrf"
  ln -s "${install_dir}/bin/xrf" "${link}"
  run bash -c '
    source "$1/uninstall.sh"
    INSTALL_DIR="$2"
    TEST_LINK="$3"
    rm() { [[ "${*: -1}" == "$TEST_LINK" ]] && command rm "$@"; }
    cleanup_symlinks "$TEST_LINK"
  ' _ "$PROJECT_ROOT" "$install_dir" "$link"
  [ "$status" -eq 0 ]
  [ ! -L "$link" ]
}

@test "online cleanup retains unrelated live and dangling links" {
  local install_dir="${TEST_TMPDIR}/custom-tool"
  local unrelated="${TEST_TMPDIR}/other-tool/bin/xrf"
  local link="${TEST_TMPDIR}/xrf"
  mkdir -p "${install_dir}/bin" "$(dirname "$unrelated")"
  : >"${unrelated}"
  for target in "$unrelated" "${TEST_TMPDIR}/absent/xrf"; do
    ln -s "$target" "$link"
    run bash -c '
      source "$1/uninstall.sh"
      INSTALL_DIR="$2"
      TEST_LINK="$3"
      rm() { [[ "$1" == "$TEST_LINK" ]] && command rm "$@"; }
      cleanup_symlinks "$TEST_LINK"
    ' _ "$PROJECT_ROOT" "$install_dir" "$link"
    [ "$status" -eq 0 ]
    [ -L "$link" ]
    [ "$(readlink "$link")" = "$target" ]
    command rm "$link"
  done
}

@test "online cleanup succeeds when no owned link exists" {
  local link="${TEST_TMPDIR}/absent-xrf"
  run bash -c '
    source "$1/uninstall.sh"
    INSTALL_DIR="$2/custom-tool"
    TEST_LINK="$2/absent-xrf"
    rm() { [[ "$1" == "$TEST_LINK" ]] && command rm "$@"; }
    cleanup_symlinks "$TEST_LINK"
  ' _ "$PROJECT_ROOT" "$TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

@test "uninstall.sh - parse_args accepts non-interactive flags" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/uninstall.sh"
    parse_args --force --remove-install-dir --debug
    printf "%s|%s|%s" "${FORCE}" "${REMOVE_INSTALL_DIR}" "${DEBUG}"
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "true|true|true" ]
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
  [[ "$(cat "${workdir}/calls.log")" == *"|uninstall" ]]
}

@test "uninstall.sh refuses missing installed command without touching service" {
  run bash -c '
    source "$1/uninstall.sh"
    INSTALL_DIR="$2/missing"
    run_xrf_uninstall
  ' _ "$PROJECT_ROOT" "$TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Installed xrf command is unavailable"* ]]
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
