#!/usr/bin/env bats
# Production uninstall command with sandboxed paths.
load ../test_helper

setup() {
  setup_test_env
  export XRF_SYSTEMD_DIR="${TEST_TMPDIR}/systemd"
  mkdir -p "${XRF_PREFIX}/bin" "${XRF_ETC}/xray" "${XRF_SYSTEMD_DIR}" "${TEST_TMPDIR}/mockbin"
  cat > "${TEST_TMPDIR}/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XRF_SYSTEMCTL_CALLS"
case "$*" in
  'show --property=ActiveState --value xray.service') printf 'active\n' ;;
  'show --property=UnitFileState --value xray.service') printf 'enabled\n' ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/mockbin/systemctl"
  export XRF_SYSTEMCTL_CALLS="${TEST_TMPDIR}/systemctl.calls"
  export PATH="${TEST_TMPDIR}/mockbin:${PATH}"
  printf 'binary\n' > "${XRF_PREFIX}/bin/xray"
  printf 'config\n' > "${XRF_ETC}/xray/config.json"
  printf 'unit\n' > "${XRF_SYSTEMD_DIR}/xray.service"
  mkdir -p "${XRF_VAR}/backups"
  printf 'historical state\n' > "${XRF_VAR}/state.json"
  printf 'backup\n' > "${XRF_VAR}/backups/old.tar.gz"
}

teardown() { cleanup_test_env; }

@test "xrf uninstall removes Xray artifacts and retains historical state and backups" {
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
  [ ! -e "${XRF_ETC}/xray" ]
  [ ! -e "${XRF_SYSTEMD_DIR}/xray.service" ]
  [ -f "${XRF_VAR}/state.json" ]
  [ -f "${XRF_VAR}/backups/old.tar.gz" ]
  grep -q '^stop xray$' "${XRF_SYSTEMCTL_CALLS}"
  grep -q '^disable xray$' "${XRF_SYSTEMCTL_CALLS}"
}

@test "xrf uninstall is idempotent and leaves unrelated Caddy files alone" {
  local unrelated="${TEST_TMPDIR}/unrelated-caddy.service"
  printf 'unrelated\n' > "${unrelated}"
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -eq 0 ]
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -eq 0 ]
  [ -f "${unrelated}" ]
  [ -f "${XRF_VAR}/state.json" ]
}

@test "xrf uninstall waits on the shared configuration lock" {
  local lock="${XRF_VAR}/locks/configure.lock"
  mkdir -p "$(dirname "${lock}")"
  if command -v flock > /dev/null 2>&1; then
    bash -c 'exec 200>> "$1"; flock -x 200; touch "$2"; sleep 3' _ "${lock}" "${TEST_TMPDIR}/held" &
    local holder=$!
    while [[ ! -f "${TEST_TMPDIR}/held" ]]; do sleep 0.01; done
  else
    mkdir "${lock}.d"
  fi

  XRF_FLOCK_TIMEOUT_SEC=1 run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -ne 0 ]
  [ -f "${XRF_PREFIX}/bin/xray" ]
  [ -f "${XRF_ETC}/xray/config.json" ]

  if [[ -n "${holder:-}" ]]; then
    kill "${holder}" 2> /dev/null || true
    wait "${holder}" 2> /dev/null || true
  else
    rmdir "${lock}.d"
  fi
}

@test "xrf uninstall leaves binary and configuration when service stop fails" {
  cat > "${TEST_TMPDIR}/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == stop ]] && exit 1
case "$*" in
  'show --property=ActiveState --value xray.service') printf 'active\n' ;;
  'show --property=UnitFileState --value xray.service') printf 'enabled\n' ;;
esac
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/mockbin/systemctl"
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -ne 0 ]
  [ -f "${XRF_PREFIX}/bin/xray" ]
  [ -f "${XRF_ETC}/xray/config.json" ]
}

@test "xrf uninstall leaves files untouched when service state cannot be queried" {
  cat > "${TEST_TMPDIR}/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == is-active || "${1:-}" == show || "${1:-}" == is-enabled ]] && exit 1
exit 0
EOF
  chmod +x "${TEST_TMPDIR}/mockbin/systemctl"
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -ne 0 ]
  [ -f "${XRF_PREFIX}/bin/xray" ]
  [ -f "${XRF_ETC}/xray/config.json" ]
  [ -f "${XRF_SYSTEMD_DIR}/xray.service" ]
}

@test "xrf uninstall does not stop or delete files when unit enablement query fails" {
  cat > "${TEST_TMPDIR}/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XRF_SYSTEMCTL_CALLS"
case "$*" in
  'show --property=ActiveState --value xray.service') printf 'active\n' ;;
  'show --property=UnitFileState --value xray.service') exit 1 ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/mockbin/systemctl"
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -ne 0 ]
  [ -f "${XRF_PREFIX}/bin/xray" ]
  [ -f "${XRF_ETC}/xray/config.json" ]
  [ -f "${XRF_SYSTEMD_DIR}/xray.service" ]
  run grep -q '^stop xray$' "${XRF_SYSTEMCTL_CALLS}"
  [ "$status" -eq 1 ]
}

@test "xrf uninstall remains idempotent when the unit is absent and confirmed inactive" {
  rm -f "${XRF_SYSTEMD_DIR}/xray.service"
  cat > "${TEST_TMPDIR}/mockbin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  'show --property=ActiveState --value xray.service') printf 'inactive\n' ;;
  'show --property=UnitFileState --value xray.service') printf '\n' ;;
esac
EOF
  chmod +x "${TEST_TMPDIR}/mockbin/systemctl"
  run "${PROJECT_ROOT}/commands/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
  [ ! -e "${XRF_ETC}/xray" ]
}
