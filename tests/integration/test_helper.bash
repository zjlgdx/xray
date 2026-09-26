#!/usr/bin/env bash
# Integration test helper

# Setup isolated test environment
setup_integration_env() {
  if command -v locale > /dev/null 2>&1 && locale -a 2> /dev/null | grep -q '^C\.UTF-8$'; then
    export LANG="C.UTF-8"
    export LC_ALL="C.UTF-8"
  else
    export LANG="C"
    export LC_ALL="C"
  fi

  export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  export TEST_ROOT="${BATS_TEST_TMPDIR}/xrf-integration"
  export XRF_PREFIX="${TEST_ROOT}/prefix"
  export XRF_ETC="${TEST_ROOT}/etc"
  export XRF_VAR="${TEST_ROOT}/var"
  export XRF_SYSTEMD_DIR="${TEST_ROOT}/systemd"

  mkdir -p "${XRF_PREFIX}" "${XRF_ETC}" "${XRF_VAR}"

  # Mock systemctl for testing
  export PATH="${TEST_ROOT}/bin:${PATH}"
  mkdir -p "${TEST_ROOT}/bin"
  cat > "${TEST_ROOT}/bin/systemctl" << 'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "${XRF_VAR}/systemctl.log"
if [[ "${1:-}" == show ]]; then
  case "${2:-}" in
    --property=ActiveState) printf 'inactive\n' ;;
    --property=UnitFileState) printf '\n' ;;
    *) exit 1 ;;
  esac
fi
exit 0
EOF
  chmod +x "${TEST_ROOT}/bin/systemctl"
}

cleanup_integration_env() {
  rm -rf "${TEST_ROOT}" 2>/dev/null || true
}
