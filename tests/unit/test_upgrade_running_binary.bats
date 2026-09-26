#!/usr/bin/env bats
# Verify the real upgrade process-identity checker using controlled OS command outputs.
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/services/xray/upgrade.sh"
  mkdir -p "${XRF_PREFIX}/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$(xray::bin)"
  chmod +x "$(xray::bin)"
  export VERIFY_PID=1234 VERIFY_ACTUAL=match VERIFY_AFTER_PID=1234 VERIFY_ACTIVE=true
  export VERIFY_SHOW_COUNT="${TEST_TMPDIR}/show-count"
  printf 0 > "${VERIFY_SHOW_COUNT}"
  systemctl() {
    case "$1" in
      is-active) [[ "${VERIFY_ACTIVE}" == true ]] ;;
      show)
        local count
        count="$(cat "${VERIFY_SHOW_COUNT}")"
        count=$((count + 1))
        printf '%s' "${count}" > "${VERIFY_SHOW_COUNT}"
        if [[ "${count}" -eq 1 ]]; then printf '%s\n' "${VERIFY_PID}"; else printf '%s\n' "${VERIFY_AFTER_PID}"; fi ;;
    esac
  }
  sha256sum() {
    if [[ "$1" == /proc/*/exe ]]; then
      if [[ "${VERIFY_ACTUAL}" == match ]]; then
        command sha256sum "$(xray::bin)"
      else
        printf '%064d  %s\n' 0 "$1"
      fi
    else
      command sha256sum "$@"
    fi
  }
  sleep() { :; }
}

teardown() { cleanup_test_env; }

@test "real running-binary checker accepts matching hash and stable PID" {
  xray::verify_running_binary
  [ "$(cat "${VERIFY_SHOW_COUNT}")" -eq 2 ]
}

@test "real running-binary checker rejects a different executable hash" {
  export VERIFY_ACTUAL=mismatch
  run xray::verify_running_binary
  [ "$status" -ne 0 ]
}

@test "real running-binary checker rejects PID change after validation" {
  export VERIFY_AFTER_PID=4321
  run xray::verify_running_binary
  [ "$status" -ne 0 ]
}

@test "real running-binary checker rejects invalid PID without reading proc" {
  export VERIFY_PID=0
  run xray::verify_running_binary
  [ "$status" -ne 0 ]
}
