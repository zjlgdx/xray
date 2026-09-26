#!/usr/bin/env bats
# Unit tests for the top-level online install.sh wrapper.

load ../test_helper

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "install.sh - parse_args accepts --yes" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    TMP_DIR="$(mktemp -d)"
    trap '"'"'rm -rf "${TMP_DIR}"'"'"' EXIT
    source_args_module
    parse_args --yes
    printf "%s" "${XRF_YES}"
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

@test "install.sh - help documents --yes" {
  run grep -n -- '--yes, -y' "${PROJECT_ROOT}/install.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Auto-confirm fresh installation"* ]]
}

@test "online install help exports required SNI before the sudo pipeline" {
  run bash -c '
    source "$1/install.sh"
    TMP_DIR="$(mktemp -d)"
    trap '\''rm -rf "${TMP_DIR}"'\'' EXIT
    source_args_module
    args::show_help
  ' _ "${PROJECT_ROOT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'export XRAY_SNI='* ]]
  [[ "${output}" == *'curl -fsSL https://raw.githubusercontent.com/zjlgdx/xray/main/install.sh | sudo -E bash'* ]]
  [[ "${output}" != *'XRAY_SNI=example.com curl'* ]]
}

@test "install.sh - run_xray_install forwards --yes to xrf install" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    workdir="$(mktemp -d)"
    trap '"'"'rm -rf "${workdir}"'"'"' EXIT

    INSTALL_DIR="${workdir}/install"
    SYMLINK_PATH="${workdir}/xrf"
    mkdir -p "${INSTALL_DIR}/bin"

    cat > "${INSTALL_DIR}/bin/xrf" <<'"'"'EOF'"'"'
#!/usr/bin/env bash
printf "%s\n" "$*" >> "__CALLS_FILE__"
exit 0
EOF
    sed -i.bak "s|__CALLS_FILE__|${workdir}/calls.log|" "${INSTALL_DIR}/bin/xrf"
    chmod +x "${INSTALL_DIR}/bin/xrf"

    XRAY_SNI="vpn.example.com"
    VERSION="v1.2.3"
    DEBUG="true"
    XRF_YES="true"
    INTEGRITY_VERIFIED="true"

    run_xray_install >/dev/null
    cat "${workdir}/calls.log"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"install --version v1.2.3 --debug --yes"* ]]
  [[ "${output}" == *"status"* ]]
}

@test "install.sh - setup_environment exports debug and signed tag requirements" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    TMP_DIR="$(mktemp -d)"
    trap '"'"'rm -rf "${TMP_DIR}"'"'"' EXIT

    DEBUG="true"
    BRANCH="v1.2.3"
    ALLOW_UNSIGNED_TAG="false"

    setup_environment
    printf "%s|%s" "${XRF_DEBUG}" "${REQUIRE_SIGNED_TAG}"
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "true|true" ]
}

@test "install.sh - cleanup_partial_installation removes fresh install artifacts" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    workdir="$(mktemp -d)"
    trap '"'"'rm -rf "${workdir}"'"'"' EXIT

    INSTALL_DIR="${workdir}/install"
    SYMLINK_PATH="${workdir}/bin/xrf"
    mkdir -p "${INSTALL_DIR}/bin" "${workdir}/bin"
    touch "${INSTALL_DIR}/bin/xrf"
    ln -s "${INSTALL_DIR}/bin/xrf" "${SYMLINK_PATH}"

    INSTALL_DIR_PREEXISTING="false"
    INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
    : > "${INSTALL_MARKER}"

    cleanup_partial_installation

    printf "RESULT:%s|%s|%s" \
      "$(test -e "${INSTALL_DIR}" && echo present || echo missing)" \
      "$(test -L "${SYMLINK_PATH}" && echo present || echo missing)" \
      "$(test -e "${INSTALL_MARKER}" && echo present || echo missing)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESULT:missing|missing|missing" ]]
}

@test "install.sh - cleanup_partial_installation preserves preexisting install directory" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    workdir="$(mktemp -d)"
    trap '"'"'rm -rf "${workdir}"'"'"' EXIT

    INSTALL_DIR="${workdir}/install"
    SYMLINK_PATH="${workdir}/bin/xrf"
    mkdir -p "${INSTALL_DIR}/bin" "${workdir}/bin"
    touch "${INSTALL_DIR}/keep.txt" "${INSTALL_DIR}/bin/xrf"
    ln -s "${INSTALL_DIR}/bin/xrf" "${SYMLINK_PATH}"

    INSTALL_DIR_PREEXISTING="true"
    INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
    : > "${INSTALL_MARKER}"

    cleanup_partial_installation

    printf "RESULT:%s|%s|%s|%s" \
      "$(test -d "${INSTALL_DIR}" && echo present || echo missing)" \
      "$(test -f "${INSTALL_DIR}/keep.txt" && echo present || echo missing)" \
      "$(test -L "${SYMLINK_PATH}" && echo present || echo missing)" \
      "$(test -e "${INSTALL_MARKER}" && echo present || echo missing)"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RESULT:present|present|present|missing" ]]
}

@test "install.sh - refuses existing tool before replacing its files or global link" {
  local workdir="${TEST_TMPDIR}/existing-tool"
  mkdir -p "${workdir}/downloaded/xray-fusion/bin" "${workdir}/install/bin" "${workdir}/bin"
  printf 'new tool\n' > "${workdir}/downloaded/xray-fusion/bin/xrf"
  printf 'old tool\n' > "${workdir}/install/bin/xrf"
  printf 'credential\n' > "${workdir}/install/credentials"
  ln -s "${workdir}/install/bin/xrf" "${workdir}/bin/xrf"

  run bash -c '
    source "$1/install.sh"
    TMP_DIR="$2/downloaded"
    INSTALL_DIR="$2/install"
    SYMLINK_PATH="$2/bin/xrf"
    install_xray_fusion
  ' _ "${PROJECT_ROOT}" "${workdir}"

  [ "${status}" -ne 0 ]
  [ "$(cat "${workdir}/install/bin/xrf")" = 'old tool' ]
  [ "$(cat "${workdir}/install/credentials")" = 'credential' ]
  [ "$(readlink "${workdir}/bin/xrf")" = "${workdir}/install/bin/xrf" ]
  [ ! -e "${workdir}/install/.install_in_progress" ]
}

@test "install.sh - refuses unrelated global link before creating fresh tool" {
  local workdir="${TEST_TMPDIR}/unrelated-global-link"
  mkdir -p "${workdir}/downloaded/xray-fusion/bin" "${workdir}/other/bin" "${workdir}/bin"
  printf 'new tool\n' > "${workdir}/downloaded/xray-fusion/bin/xrf"
  printf 'other tool\n' > "${workdir}/other/bin/xrf"
  ln -s "${workdir}/other/bin/xrf" "${workdir}/bin/xrf"

  run bash -c '
    source "$1/install.sh"
    TMP_DIR="$2/downloaded"
    INSTALL_DIR="$2/install"
    SYMLINK_PATH="$2/bin/xrf"
    install_xray_fusion
  ' _ "${PROJECT_ROOT}" "${workdir}"

  [ "${status}" -ne 0 ]
  [ ! -e "${workdir}/install" ]
  [ "$(readlink "${workdir}/bin/xrf")" = "${workdir}/other/bin/xrf" ]
  [ "$(cat "${workdir}/other/bin/xrf")" = 'other tool' ]
}

@test "install.sh - run_xray_install stops before execution when integrity is not verified" {
  local workdir="${TEST_TMPDIR}/install-no-integrity"
  mkdir -p "${workdir}/install/bin" "${workdir}/bin"

  cat > "${workdir}/install/bin/xrf" <<'EOF'
#!/usr/bin/env bash
printf "%s\n" "$*" >> "__CALLS_FILE__"
exit 0
EOF
  sed -i.bak "s|__CALLS_FILE__|${workdir}/calls.log|" "${workdir}/install/bin/xrf"
  chmod +x "${workdir}/install/bin/xrf"
  ln -s "${workdir}/install/bin/xrf" "${workdir}/bin/xrf"
  : > "${workdir}/install/.install_in_progress"

  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"

    INSTALL_DIR="'"${workdir}"'/install"
    SYMLINK_PATH="'"${workdir}"'/bin/xrf"
    INSTALL_DIR_PREEXISTING="false"
    INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
    XRAY_SNI="vpn.example.com"
    VERSION="latest"
    DEBUG="false"
    XRF_YES="true"
    INTEGRITY_VERIFIED="false"

    run_xray_install
  '

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Integrity checks did not complete"* ]]
  [ ! -e "${workdir}/install" ]
  [ ! -L "${workdir}/bin/xrf" ]
  [ ! -f "${workdir}/calls.log" ]
}

@test "install.sh - cleanup removes own symlink through an aliased install parent" {
  local workdir="${TEST_TMPDIR}/aliased-install"
  mkdir -p "${workdir}/real/install/bin" "${workdir}/bin"
  ln -s "${workdir}/real" "${workdir}/alias"
  touch "${workdir}/real/install/bin/xrf" "${workdir}/real/install/.install_in_progress"
  ln -s "${workdir}/alias/install/bin/xrf" "${workdir}/bin/xrf"

  run bash -c '
    source "$1/install.sh"
    INSTALL_DIR="$2/alias/install"
    SYMLINK_PATH="$2/bin/xrf"
    INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
    INSTALL_DIR_PREEXISTING=false
    cleanup_partial_installation
  ' _ "${PROJECT_ROOT}" "${workdir}"

  [ "${status}" -eq 0 ]
  [ ! -L "${workdir}/bin/xrf" ]
  [ ! -d "${workdir}/real/install" ]
  [ -L "${workdir}/alias" ]
}

@test "install.sh - cleanup preserves unrelated symlink and existing credentials" {
  local workdir="${TEST_TMPDIR}/unrelated-link"
  mkdir -p "${workdir}/install/bin" "${workdir}/other/bin" "${workdir}/bin"
  touch "${workdir}/install/bin/xrf" "${workdir}/other/bin/xrf"
  printf '%s' 'existing-credential' > "${workdir}/install/credentials"
  touch "${workdir}/install/.install_in_progress"
  ln -s "${workdir}/other/bin/xrf" "${workdir}/bin/xrf"

  run bash -c '
    source "$1/install.sh"
    INSTALL_DIR="$2/install"
    SYMLINK_PATH="$2/bin/xrf"
    INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
    INSTALL_DIR_PREEXISTING=true
    cleanup_partial_installation
  ' _ "${PROJECT_ROOT}" "${workdir}"

  [ "${status}" -eq 0 ]
  [ "$(readlink "${workdir}/bin/xrf")" = "${workdir}/other/bin/xrf" ]
  [ -f "${workdir}/other/bin/xrf" ]
  [ -f "${workdir}/install/bin/xrf" ]
  [ "$(cat "${workdir}/install/credentials")" = 'existing-credential' ]
  [ ! -e "${workdir}/install/.install_in_progress" ]
}
