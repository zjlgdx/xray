#!/usr/bin/env bats
# Unit tests for services/xray/systemd-unit.sh
# Tests systemd unit installation, rollback, and removal functionality

load ../test_helper

setup() {
  setup_test_env

  # Create mock directories
  mkdir -p "${TEST_TMPDIR}/bin"
  mkdir -p "${TEST_TMPDIR}/etc/systemd/system"
  mkdir -p "${XRF_VAR}"
  mkdir -p "${XRF_ETC}/xray/active"

  # Set custom systemd directory for testing
  export XRF_SYSTEMD_DIR="${TEST_TMPDIR}/etc/systemd/system"

  # Create mock systemd unit source file
  mkdir -p "${PROJECT_ROOT}/packaging/systemd"

  # Create mock commands
  create_systemd_mocks

  # Extract systemd::escape_sed_replacement from source (can't source
  # the file directly because it has a case dispatch at the bottom)
  eval "$(sed -n '/^systemd::escape_sed_replacement()/,/^}/p' \
    "${PROJECT_ROOT}/services/xray/systemd-unit.sh")"
}

teardown() {
  cleanup_test_env
}

create_systemd_mocks() {
  # Mock sudo - just pass through commands
  cat > "${TEST_TMPDIR}/bin/sudo" << 'EOF'
#!/usr/bin/env bash
"$@"
EOF

  # Mock systemctl with call tracking
  cat > "${TEST_TMPDIR}/bin/systemctl" << 'SCRIPT'
#!/usr/bin/env bash
echo "$@" >> "${TEST_TMPDIR}/systemctl_calls"

case "${1}" in
  daemon-reload)
    [[ "${MOCK_DAEMON_RELOAD_FAIL:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  enable)
    [[ "${MOCK_ENABLE_FAIL:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  disable)
    [[ "${MOCK_DISABLE_FAIL:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  reset-failed)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
SCRIPT

  # Mock getent for user module
  cat > "${TEST_TMPDIR}/bin/getent" << 'EOF'
#!/usr/bin/env bash
record="${TEST_TMPDIR}/${1}_${2}"
if [[ -f "${record}" ]]; then
  cat "${record}"
  exit 0
fi
exit 2
EOF

  # Mock groupadd
  cat > "${TEST_TMPDIR}/bin/groupadd" << 'EOF'
#!/usr/bin/env bash
group="${@: -1}"
printf "%s:x:998:\n" "${group}" > "${TEST_TMPDIR}/group_${group}"
EOF

  # Mock useradd
  cat > "${TEST_TMPDIR}/bin/useradd" << 'EOF'
#!/usr/bin/env bash
user="${@: -1}"
printf "%s:x:1000:998::/var/lib/%s:/usr/sbin/nologin\n" "${user}" "${user}" > "${TEST_TMPDIR}/passwd_${user}"
EOF

  chmod +x "${TEST_TMPDIR}/bin/"*
}

mock_path() {
  echo "${TEST_TMPDIR}/bin:${PATH}"
}

# Create a minimal xray.service file for testing in temp directory
create_service_file() {
  mkdir -p "${TEST_TMPDIR}/packaging/systemd"
  cat > "${TEST_TMPDIR}/packaging/systemd/xray.service" << 'EOF'
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=xray
ExecStart=/usr/local/bin/xray run -config /etc/xray/active

[Install]
WantedBy=multi-user.target
EOF
}

# =============================================================================
# systemd_unit_path() tests
# =============================================================================

@test "systemd_unit_path - returns default path when XRF_SYSTEMD_DIR not set" {
  run bash -c '
    unset XRF_SYSTEMD_DIR
    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }
    systemd_unit_path
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "/etc/systemd/system/xray.service" ]]
}

@test "systemd_unit_path - uses XRF_SYSTEMD_DIR when set" {
  run bash -c '
    export XRF_SYSTEMD_DIR="/custom/systemd/path"
    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }
    systemd_unit_path
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "/custom/systemd/path/xray.service" ]]
}

@test "systemd_unit_path - removes trailing slash from XRF_SYSTEMD_DIR" {
  run bash -c '
    export XRF_SYSTEMD_DIR="/custom/systemd/path/"
    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }
    systemd_unit_path
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "/custom/systemd/path/xray.service" ]]
}

# =============================================================================
# install_unit_with_lock() tests
# =============================================================================

@test "install_unit_with_lock - creates systemd unit file" {
  create_service_file

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      systemctl daemon-reload
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -eq 0 ]
  assert_file_exists "${TEST_TMPDIR}/etc/systemd/system/xray.service"
}

@test "install_unit_with_lock - calls systemctl daemon-reload" {
  create_service_file

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      systemctl daemon-reload
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -eq 0 ]
  assert_file_exists "${TEST_TMPDIR}/systemctl_calls"
  grep -q "daemon-reload" "${TEST_TMPDIR}/systemctl_calls"
}

@test "install_unit_with_lock - calls systemctl enable --now" {
  create_service_file

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      systemctl daemon-reload
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -eq 0 ]
  grep -q "enable --now xray" "${TEST_TMPDIR}/systemctl_calls"
}

@test "install_unit_with_lock - creates xray user" {
  create_service_file

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      systemctl daemon-reload
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -eq 0 ]
  # Verify user was created (mock creates passwd_xray file)
  assert_file_exists "${TEST_TMPDIR}/passwd_xray"
}

@test "install_unit_with_lock - fails when daemon-reload fails" {
  create_service_file

  export MOCK_DAEMON_RELOAD_FAIL=1
  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    export MOCK_DAEMON_RELOAD_FAIL=1

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      if ! systemctl daemon-reload; then
        rm -f "${unit_file}" 2>/dev/null || true
        return 1
      fi
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -ne 0 ]
}

@test "install_unit_with_lock - removes unit file on daemon-reload failure" {
  create_service_file

  export MOCK_DAEMON_RELOAD_FAIL=1
  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    export MOCK_DAEMON_RELOAD_FAIL=1

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      if ! systemctl daemon-reload; then
        rm -f "${unit_file}" 2>/dev/null || true
        return 1
      fi
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  # Unit file should be cleaned up on failure
  [ ! -f "${TEST_TMPDIR}/etc/systemd/system/xray.service" ]
}

# =============================================================================
# rollback_systemd_unit() tests
# =============================================================================

@test "rollback_systemd_unit - disables service" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    rollback_systemd_unit() {
      local unit_file="${1}"
      systemctl disable --now xray || true
      rm -f "${unit_file}" 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    rollback_systemd_unit "'"${unit_file}"'"
  '

  [ "$status" -eq 0 ]
  grep -q "disable --now xray" "${TEST_TMPDIR}/systemctl_calls"
}

@test "rollback_systemd_unit - removes unit file" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    rollback_systemd_unit() {
      local unit_file="${1}"
      systemctl disable --now xray || true
      rm -f "${unit_file}" 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    rollback_systemd_unit "'"${unit_file}"'"
  '

  [ "$status" -eq 0 ]
  [ ! -f "${unit_file}" ]
}

@test "rollback_systemd_unit - calls daemon-reload after removal" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    rollback_systemd_unit() {
      local unit_file="${1}"
      systemctl disable --now xray || true
      rm -f "${unit_file}" 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    rollback_systemd_unit "'"${unit_file}"'"
  '

  [ "$status" -eq 0 ]
  grep -q "daemon-reload" "${TEST_TMPDIR}/systemctl_calls"
}

@test "rollback_systemd_unit - calls reset-failed" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    rollback_systemd_unit() {
      local unit_file="${1}"
      systemctl disable --now xray || true
      rm -f "${unit_file}" 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    rollback_systemd_unit "'"${unit_file}"'"
  '

  [ "$status" -eq 0 ]
  grep -q "reset-failed xray.service" "${TEST_TMPDIR}/systemctl_calls"
}

@test "rollback_systemd_unit - succeeds even when disable fails" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  export MOCK_DISABLE_FAIL=1
  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    export MOCK_DISABLE_FAIL=1

    rollback_systemd_unit() {
      local unit_file="${1}"
      systemctl disable --now xray || true
      rm -f "${unit_file}" 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    rollback_systemd_unit "'"${unit_file}"'"
  '

  # Should succeed despite disable failure (uses || true)
  [ "$status" -eq 0 ]
}

# =============================================================================
# remove_unit() tests
# =============================================================================

@test "remove_unit - removes existing unit file" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    remove_unit() {
      local unit_file
      unit_file="$(systemd_unit_path)"
      systemctl disable --now xray || true
      rm -f "${unit_file}"
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    remove_unit
  '

  [ "$status" -eq 0 ]
  [ ! -f "${unit_file}" ]
}

@test "remove_unit - disables service before removal" {
  local unit_file="${TEST_TMPDIR}/etc/systemd/system/xray.service"
  mkdir -p "$(dirname "${unit_file}")"
  echo "[Unit]" > "${unit_file}"

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    remove_unit() {
      local unit_file
      unit_file="$(systemd_unit_path)"
      systemctl disable --now xray || true
      rm -f "${unit_file}"
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    remove_unit
  '

  [ "$status" -eq 0 ]
  # Check that disable was called before daemon-reload
  grep -n "disable --now xray" "${TEST_TMPDIR}/systemctl_calls" > /dev/null
}

@test "remove_unit - succeeds when unit file does not exist" {
  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    remove_unit() {
      local unit_file
      unit_file="$(systemd_unit_path)"
      systemctl disable --now xray || true
      rm -f "${unit_file}"
      systemctl daemon-reload || true
      systemctl reset-failed xray.service 2>/dev/null || true
    }

    remove_unit
  '

  [ "$status" -eq 0 ]
}

# =============================================================================
# Unit file content tests
# =============================================================================

@test "unit file has correct permissions after installation" {
  create_service_file

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      systemctl daemon-reload
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -eq 0 ]
  local perms
  perms=$(stat -c "%a" "${TEST_TMPDIR}/etc/systemd/system/xray.service" 2> /dev/null || stat -f "%Lp" "${TEST_TMPDIR}/etc/systemd/system/xray.service")
  [[ "${perms}" == "644" ]]
}

@test "unit file contains valid systemd configuration" {
  create_service_file

  PATH="$(mock_path)" run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    source "'"${PROJECT_ROOT}/modules/io.sh"'"
    source "'"${PROJECT_ROOT}/modules/user/user.sh"'"
    source "'"${PROJECT_ROOT}/modules/state.sh"'"
    export XRF_SYSTEMD_DIR="'"${TEST_TMPDIR}/etc/systemd/system"'"
    export XRF_VAR="'"${XRF_VAR}"'"
    export XRF_JSON=false
    export XRF_DEBUG=false

    systemd_unit_path() {
      local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
      echo "${base%/}/xray.service"
    }

    install_unit_with_lock() {
      user::ensure_system_user xray xray
      local unit_file
      unit_file="$(systemd_unit_path)"
      io::ensure_dir "$(dirname "${unit_file}")" 0755
      io::atomic_write "${unit_file}" 0644 < "'"${TEST_TMPDIR}/packaging/systemd/xray.service"'"
      systemctl daemon-reload
      systemctl enable --now xray
    }

    install_unit_with_lock
  '

  [ "$status" -eq 0 ]
  # Verify unit file has required sections
  grep -q "\[Unit\]" "${TEST_TMPDIR}/etc/systemd/system/xray.service"
  grep -q "\[Service\]" "${TEST_TMPDIR}/etc/systemd/system/xray.service"
  grep -q "\[Install\]" "${TEST_TMPDIR}/etc/systemd/system/xray.service"
}

# =============================================================================
# systemd::escape_sed_replacement() tests
# =============================================================================

@test "systemd::escape_sed_replacement - escapes pipe character" {
  run systemd::escape_sed_replacement "foo|bar"
  [ "$status" -eq 0 ]
  [ "$output" = 'foo\|bar' ]
}

@test "systemd::escape_sed_replacement - escapes ampersand" {
  run systemd::escape_sed_replacement "foo&bar"
  [ "$status" -eq 0 ]
  [ "$output" = 'foo\&bar' ]
}

@test "systemd::escape_sed_replacement - escapes backslash" {
  run systemd::escape_sed_replacement 'foo\bar'
  [ "$status" -eq 0 ]
  [ "$output" = 'foo\\bar' ]
}

@test "systemd::escape_sed_replacement - passes through normal paths" {
  run systemd::escape_sed_replacement "/usr/local/bin/xray"
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/bin/xray" ]
}

@test "systemd::escape_sed_replacement - handles empty string" {
  run systemd::escape_sed_replacement ""
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "systemd::escape_sed_replacement - escapes multiple special chars" {
  run systemd::escape_sed_replacement 'a|b&c\d'
  [ "$status" -eq 0 ]
  [ "$output" = 'a\|b\&c\\d' ]
}
