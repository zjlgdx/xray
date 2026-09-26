#!/usr/bin/env bats
# shellcheck disable=SC2154
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/services/xray/upgrade.sh"
  mkdir -p "${XRF_PREFIX}/bin" "${XRF_ETC}/xray/releases/old" "${XRF_VAR}"
  ln -s "${XRF_ETC}/xray/releases/old" "${XRF_ETC}/xray/active"
  printf '%s\n' '{"log":{"access":"/var/log/xray/access.log","loglevel":"debug"}}' > "${XRF_ETC}/xray/active/00_log.json"
  printf '%s\n' '{"version":"v1.0.0","xray":{"uuid":"keep-me"}}' > "$(state::path)"
  cat > "$(xray::bin)" <<'SCRIPT'
#!/usr/bin/env bash
printf 'Xray 1.0.0\n'
SCRIPT
  chmod +x "$(xray::bin)"
  sha256sum "$(xray::bin)" | awk '{print $1}' > "${XRF_VAR}/binary.sha256"
  export UPGRADE_CALLS="${TEST_TMPDIR}/calls"
  xray::stage_upgrade() {
    [[ "${FAIL_STAGE:-}" != true ]] || return 1
    mkdir -p "${1}/bin"
    cat > "${1}/bin/xray" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == run ]]; then
  [[ "${FAIL_VALIDATE:-}" != true ]]
else
  printf 'Xray 2.0.0\n'
fi
SCRIPT
    chmod +x "${1}/bin/xray"
  }
  systemctl() {
    printf '%s\n' "$*" >> "${UPGRADE_CALLS}"
    if [[ "${1}" == restart && "${FAIL_RESTART:-}" == true && "$(xray::installed_version)" == v2.0.0 ]]; then
      return 1
    fi
    [[ "${INACTIVE:-}" != true ]]
  }
  xray::verify_running_binary() {
    [[ "${FAIL_VERIFY:-}" != true || "$(xray::installed_version)" == v1.0.0 ]]
  }
}

teardown() { cleanup_test_env; }

@test "upgrade preserves config and credentials, restarts and commits version" {
  before="$(sha256sum "${XRF_ETC}/xray/active/00_log.json")"
  run xray::upgrade v2.0.0
  [ "$status" -eq 0 ]
  [ "$(xray::installed_version)" = v2.0.0 ]
  [ "$(jq -r .version "$(state::path)")" = v2.0.0 ]
  [ "$(jq -r .xray.uuid "$(state::path)")" = keep-me ]
  [ "$before" = "$(sha256sum "${XRF_ETC}/xray/active/00_log.json")" ]
  grep -q '^restart xray$' "${UPGRADE_CALLS}"
  backup="$(find "${XRF_VAR}/upgrades" -name state.json | head -n 1)"
  [ "$(jq -r .version "$backup")" = v1.0.0 ]
}

@test "candidate validation failure leaves old binary and service untouched" {
  export FAIL_VALIDATE=true
  run xray::upgrade v2.0.0
  [ "$status" -ne 0 ]
  [ "$(xray::installed_version)" = v1.0.0 ]
  ! grep -q '^restart' "${UPGRADE_CALLS}"
}

@test "download failure leaves old binary and service untouched" {
  export FAIL_STAGE=true
  run xray::upgrade v2.0.0
  [ "$status" -ne 0 ]
  [ "$(xray::installed_version)" = v1.0.0 ]
  ! grep -q '^restart' "${UPGRADE_CALLS}"
}

@test "wrong downloaded version cannot replace the old binary" {
  run xray::upgrade v3.0.0
  [ "$status" -ne 0 ]
  [ "$(xray::installed_version)" = v1.0.0 ]
}

@test "restart failure rolls back binary and metadata and reports failure" {
  export FAIL_RESTART=true
  before="$(cat "${XRF_VAR}/binary.sha256")"
  run xray::upgrade v2.0.0
  [ "$status" -ne 0 ]
  [ "$(xray::installed_version)" = v1.0.0 ]
  [ "$(jq -r .version "$(state::path)")" = v1.0.0 ]
  [ "$(cat "${XRF_VAR}/binary.sha256")" = "$before" ]
  [ "$(grep -c '^restart' "${UPGRADE_CALLS}")" -eq 2 ]
}

@test "running binary verification failure also rolls back" {
  export FAIL_VERIFY=true
  run xray::upgrade v2.0.0
  [ "$status" -ne 0 ]
  [ "$(xray::installed_version)" = v1.0.0 ]
}

@test "state write failure rolls back a successfully started candidate" {
  state::save() { return 1; }
  run xray::upgrade v2.0.0
  [ "$status" -ne 0 ]
  [ "$(xray::installed_version)" = v1.0.0 ]
  [ "$(jq -r .version "$(state::path)")" = v1.0.0 ]
}

@test "inactive service is not started implicitly" {
  export INACTIVE=true
  run xray::upgrade v2.0.0
  [ "$status" -ne 0 ]
  ! grep -q '^restart' "${UPGRADE_CALLS}"
}

@test "upgrade command requires an explicit version before making changes" {
  run "${PROJECT_ROOT}/services/xray/upgrade.sh"
  [ "$status" -eq 2 ]
  [ ! -d "${XRF_VAR}/upgrades" ]
}

@test "install refuses to regenerate credentials for an existing installation" {
  run "${PROJECT_ROOT}/commands/install.sh" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'use xrf upgrade'* ]]
  [ "$(jq -r .xray.uuid "$(state::path)")" = keep-me ]
}

@test "install rejects a leftover binary when active is missing" {
  rm -f "$(xray::active)" "$(state::path)"
  run "${PROJECT_ROOT}/commands/install.sh" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'use xrf upgrade'* ]]
  [ "$(xray::installed_version)" = v1.0.0 ]
}

@test "install rejects retained releases when active is missing" {
  rm -f "$(xray::active)" "$(state::path)" "$(xray::bin)"
  run "${PROJECT_ROOT}/commands/install.sh" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'use xrf upgrade'* ]]
  [ -d "$(xray::releases)/old" ]
}

@test "install permits a dry-run after uninstall left only historical state" {
  rm -rf "$(xray::confbase)" "$(xray::bin)"
  run "${PROJECT_ROOT}/commands/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'Installation Preview'* ]]
  [ "$(jq -r .xray.uuid "$(state::path)")" = keep-me ]
}

@test "install help stays available with partial installation residue" {
  rm -f "$(xray::active)"
  run "${PROJECT_ROOT}/commands/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'Usage: xrf install'* ]]
}
