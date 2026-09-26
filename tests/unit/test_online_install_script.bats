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
    parse_args --topology reality-only --yes
    printf "%s" "${XRF_YES}"
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

@test "install.sh - help documents --yes" {
  run grep -n -- '--yes, -y' "${PROJECT_ROOT}/install.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Auto-confirm installation"* ]]
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

    TOPOLOGY="reality-only"
    DOMAIN="vpn.example.com"
    VERSION="v1.2.3"
    PLUGINS="cert-auto,firewall"
    DEBUG="true"
    XRF_YES="true"
    INTEGRITY_VERIFIED="true"

    run_xray_install >/dev/null
    cat "${workdir}/calls.log"
  '

  [ "${status}" -eq 0 ]
  [[ "${output}" == *"install --topology reality-only --domain vpn.example.com --version v1.2.3 --plugins cert-auto,firewall --debug --yes"* ]]
  [[ "${output}" == *"status"* ]]
}

@test "install.sh - setup_environment exports domain debug and signed tag requirements" {
  run bash -c '
    source "'"${PROJECT_ROOT}"'/install.sh"
    TMP_DIR="$(mktemp -d)"
    trap '"'"'rm -rf "${TMP_DIR}"'"'"' EXIT

    DOMAIN="vpn.example.com"
    DEBUG="true"
    BRANCH="v1.2.3"
    ALLOW_UNSIGNED_TAG="false"

    setup_environment
    printf "%s|%s|%s|%s" "${XRAY_DOMAIN}" "${XRF_DEBUG}" "${REF_TYPE}" "${REQUIRE_SIGNED_TAG}"
  '

  [ "${status}" -eq 0 ]
  [ "${output}" = "vpn.example.com|true|tags|true" ]
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
  [[ "${output}" == *"RESULT:present|present|missing|missing" ]]
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
    TOPOLOGY="reality-only"
    DOMAIN=""
    VERSION="latest"
    PLUGINS=""
    DEBUG="false"
    XRF_YES="true"
    INTEGRITY_VERIFIED="false"

    run_xray_install
  '

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Integrity checks did not complete successfully"* ]]
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
