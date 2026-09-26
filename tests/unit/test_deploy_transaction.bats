#!/usr/bin/env bats
# Exercise production functions, not copied implementations.
# shellcheck disable=SC2154
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/services/xray/configure.sh"
  mkdir -p "${XRF_ETC}/xray/releases/old" "${XRF_ETC}/xray/releases/new" "${XRF_VAR}" "${XRF_PREFIX}/bin"
  export OLD="${XRF_ETC}/xray/releases/old" NEW="${XRF_ETC}/xray/releases/new"
  printf '%s\n' '{"log":{"access":"/var/log/xray/access.log","error":"/var/log/xray/error.log","loglevel":"debug","dnsLog":true}}' > "${OLD}/00_log.json"
  cp "${OLD}/00_log.json" "${NEW}/00_log.json"
  ln -s "$OLD" "$(xray::active)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$(xray::bin)"
  chmod +x "$(xray::bin)"
  digest_confdir "$OLD" > "$(state::digest)"
  sha256sum "$(xray::bin)" | awk '{print $1}' > "${XRF_VAR}/binary.sha256"
  export DEPLOY_CALLS="${TEST_TMPDIR}/calls"
  config::validate_deep() { return 0; }
  config::validate_binary() { return 0; }
  plugins::emit() { return 0; }
  # GNU mv -T is not available on the macOS test host.
  mv() {
    if [[ "${1}" == -Tf ]]; then
      shift
      if [[ -f "${TEST_TMPDIR}/fail-first-mv" ]]; then rm -f "${TEST_TMPDIR}/fail-first-mv"; return 1; fi
      if [[ "${FAIL_ROLLBACK_MV:-}" == true && "$(readlink "$1" 2>/dev/null)" == "$OLD" ]]; then return 1; fi
      if [[ "$(uname)" == Darwin ]]; then command mv -fh "$@"; else command mv -Tf "$@"; fi
    else command mv "$@"; fi
  }
  systemctl() {
    printf '%s\n' "$*" >> "${DEPLOY_CALLS}"
    if [[ "${1}" == is-active && "${INACTIVE_SERVICE:-}" == true ]]; then return 1; fi
    if [[ "${1}" == restart && "${FAIL_NEW:-}" == true && "$(readlink "$(xray::active)")" == "$NEW" ]]; then return 1; fi
    return 0
  }
  eval "$(declare -f io::atomic_write | sed '1s/io::atomic_write/io::real_atomic_write/')"
  io::atomic_write() {
    if [[ "${1}" == "${FAIL_DIGEST_PATH:-}" ]]; then return 1; fi
    io::real_atomic_write "$@"
  }
}

@test "first active switch failure restores old link without writing into candidate" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  : > "${TEST_TMPDIR}/fail-first-mv"
  local before
  before="$(cat "$(state::digest)")"
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ "$(readlink -f "$(xray::active)")" = "$(readlink -f "$OLD")" ]
  [ ! -e "$(xray::active).new" ]
  [ ! -e "${NEW}/active.new" ]
  [ ! -e "${NEW}/active" ]
  [ "$(cat "$(state::digest)")" = "$before" ]
}

@test "first active switch failure with no previous active removes temporary link" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  rm -f "$(xray::active)"
  export INACTIVE_SERVICE=true
  : > "${TEST_TMPDIR}/fail-first-mv"
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ ! -e "$(xray::active)" ]
  [ ! -L "$(xray::active).new" ]
  [ ! -e "${NEW}/active.new" ]
  [ ! -e "${NEW}/active" ]
}

teardown() { cleanup_test_env; }

@test "log rendering preserves existing paths, level and extra fields" {
  run xray::write_base_configs "$NEW"
  [ "$status" -eq 0 ]
  [ "$(jq -Sc .log "${OLD}/00_log.json")" = "$(jq -Sc .log "${NEW}/00_log.json")" ]
}

@test "log level override preserves destinations and permits explicit stdout" {
  export XRAY_LOG_LEVEL=info XRAY_ERROR_LOG=''
  run xray::write_base_configs "$NEW"
  [ "$status" -eq 0 ]
  [ "$(jq -r .log.loglevel "${NEW}/00_log.json")" = info ]
  [ "$(jq -r .log.access "${NEW}/00_log.json")" = /var/log/xray/access.log ]
  [ "$(jq -r .log.error "${NEW}/00_log.json")" = '' ]
}

@test "unchanged config and binary skip restart" {
  run deploy_release "$NEW"
  [ "$status" -eq 0 ]
  ! grep -q '^restart' "${DEPLOY_CALLS}"
}

@test "binary change restarts even when configuration digest is unchanged" {
  printf '\n# new binary\n' >> "$(xray::bin)"
  run deploy_release "$NEW"
  [ "$status" -eq 0 ]
  grep -q '^restart xray$' "${DEPLOY_CALLS}"
  [ "$(cat "${XRF_VAR}/binary.sha256")" = "$(sha256sum "$(xray::bin)" | awk '{print $1}')" ]
}

@test "failed restart restores active symlink and leaves digest unchanged" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  export FAIL_NEW=true
  before="$(cat "$(state::digest)")"
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ "$(readlink -f "$(xray::active)")" = "$(readlink -f "$OLD")" ]
  [ "$(cat "$(state::digest)")" = "$before" ]
  [ "$(grep -c '^restart' "${DEPLOY_CALLS}")" -eq 2 ]
  [[ "$output" != *'"msg":"deployed"'* ]]
}

@test "invalid candidate never changes the active configuration" {
  config::validate_binary() { return 1; }
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ "$(readlink -f "$(xray::active)")" = "$(readlink -f "$OLD")" ]
}

@test "config digest write failure restores active, service and both old digest bytes" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  FAIL_DIGEST_PATH="$(state::digest)"
  export FAIL_DIGEST_PATH
  old_config="$(cat "$(state::digest)")"
  old_binary="$(cat "${XRF_VAR}/binary.sha256")"
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ "$(readlink -f "$(xray::active)")" = "$(readlink -f "$OLD")" ]
  [ "$(cat "$(state::digest)")" = "$old_config" ]
  [ "$(cat "${XRF_VAR}/binary.sha256")" = "$old_binary" ]
  [ "$(grep -c '^restart' "${DEPLOY_CALLS}")" -eq 2 ]
}

@test "binary digest write failure restores active, service and both old digest bytes" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  export FAIL_DIGEST_PATH="${XRF_VAR}/binary.sha256"
  old_config="$(cat "$(state::digest)")"
  old_binary="$(cat "${XRF_VAR}/binary.sha256")"
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ "$(readlink -f "$(xray::active)")" = "$(readlink -f "$OLD")" ]
  [ "$(cat "$(state::digest)")" = "$old_config" ]
  [ "$(cat "${XRF_VAR}/binary.sha256")" = "$old_binary" ]
  [ "$(grep -c '^restart' "${DEPLOY_CALLS}")" -eq 2 ]
}

@test "digest failure restores originally absent digest files" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  rm -f "$(state::digest)" "${XRF_VAR}/binary.sha256"
  export FAIL_DIGEST_PATH="${XRF_VAR}/binary.sha256"
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [ "$(readlink -f "$(xray::active)")" = "$(readlink -f "$OLD")" ]
  [ ! -e "$(state::digest)" ]
  [ ! -e "${XRF_VAR}/binary.sha256" ]
}

@test "failed rollback retains the protected old link and digest files" {
  printf '%s\n' '{"log":{"loglevel":"info"}}' > "${NEW}/00_log.json"
  FAIL_DIGEST_PATH="$(state::digest)"
  export FAIL_DIGEST_PATH FAIL_ROLLBACK_MV=true
  run deploy_release "$NEW"
  [ "$status" -ne 0 ]
  [[ "$output" == *'recovery files retained'* ]]
  local saved
  saved="$(printf '%s\n' "$output" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p' | tail -1)"
  [ -d "$saved" ]
  [ "$(readlink "${saved}/active")" = "$OLD" ]
  [ -f "${saved}/config.sha256" ]
  [ -f "${saved}/binary.sha256" ]
}
