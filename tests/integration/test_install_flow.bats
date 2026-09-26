#!/usr/bin/env bats
# Production command and subcommands with a local synthetic Xray archive.
load test_helper

setup() {
  setup_integration_env
  export XRF_SYSTEMD_DIR="${TEST_ROOT}/systemd"
  mkdir -p "${XRF_SYSTEMD_DIR}" "${TEST_ROOT}/payload"
  cat > "${TEST_ROOT}/payload/xray" <<'XRAY'
#!/usr/bin/env bash
case "$1" in
  -version) echo 'Xray 26.9.9';;
  uuid) echo '11111111-2222-4333-8444-555555555555';;
  x25519)
    if [[ "$#" -eq 1 ]]; then
      echo 'PrivateKey: privatekey'
      echo 'Password: publickey'
    elif [[ "$#" -eq 3 && "$2" == -i && "$3" == privatekey ]]; then
      echo 'PrivateKey: privatekey'
      echo 'Password: publickey'
    else
      exit 2
    fi
    ;;
  -test) exit "${FAKE_XRAY_TEST_STATUS:-0}";;
  *) exit 0;;
esac
XRAY
  chmod +x "${TEST_ROOT}/payload/xray"
  (cd "${TEST_ROOT}/payload" && zip -q "${TEST_ROOT}/xray.zip" xray)
  export XRAY_URL="file://${TEST_ROOT}/xray.zip"
  XRAY_SHA256="$(sha256sum "${TEST_ROOT}/xray.zip" | awk '{print $1}')"
  export XRAY_SHA256
  export XRAY_PRIVATE_KEY=privatekey XRAY_SHORT_ID=abcd1234 XRAY_SERVER_IP=203.0.113.10 XRAY_SNI=www.microsoft.com
  # The fake group database and chown avoid changing host identities.
  cat > "${TEST_ROOT}/bin/getent" <<'STUB'
#!/usr/bin/env bash
case "$1" in group) echo 'xray:x:1001:';; passwd) echo 'xray:x:1001:1001::/var/lib/xray:/usr/sbin/nologin';; esac
STUB
  cat > "${TEST_ROOT}/bin/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "${TEST_ROOT}/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${XRF_VAR}/systemctl.log"
case "$1" in
  is-active) [[ "${FAKE_INACTIVE_AFTER_ENABLE:-}" != true ]] && [ -f "${XRF_VAR}/service-active" ];;
  enable) [[ "${FAIL_ENABLE:-}" != true ]] || exit 1; : > "${XRF_VAR}/service-active";;
  disable) rm -f "${XRF_VAR}/service-active";;
esac
STUB
  cat > "${TEST_ROOT}/bin/mv" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -Tf && "$(uname)" == Darwin ]]; then
  shift
  exec /bin/mv -fh "$@"
fi
exec /bin/mv "$@"
STUB
  chmod +x "${TEST_ROOT}/bin/getent" "${TEST_ROOT}/bin/chown" "${TEST_ROOT}/bin/systemctl" "${TEST_ROOT}/bin/mv"
}
teardown() { cleanup_integration_env; }

@test "fresh install builds one REALITY config and private committed links" {
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&3; fi
  [ "$status" -eq 0 ]
  [ -f "${XRF_VAR}/state.json" ]
  [ "$(stat -c '%a' "${XRF_VAR}" 2>/dev/null || stat -f '%Lp' "${XRF_VAR}")" = 700 ]
  [ "$(stat -c '%a' "${XRF_VAR}/state.json" 2>/dev/null || stat -f '%Lp' "${XRF_VAR}/state.json")" = 600 ]
  jq -e '.inbounds | length == 1 and .[0].streamSettings.network == "raw" and .[0].streamSettings.realitySettings.target == "www.microsoft.com:443"' "${XRF_ETC}/xray/active/05_inbounds.json"
  [[ "$output" == *'vless://11111111-2222-4333-8444-555555555555@203.0.113.10'* ]]
  grep -q '^enable --now xray$' "${XRF_VAR}/systemctl.log"
}

@test "failed candidate binary validation cleans fresh artifacts" {
  export FAKE_XRAY_TEST_STATUS=1
  printf '%s\n' '{"historical":"unchanged"}' > "${XRF_VAR}/state.json"
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  [ "$status" -ne 0 ]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
  [ ! -e "${XRF_ETC}/xray" ]
  [ ! -e "${XRF_SYSTEMD_DIR}/xray.service" ]
  [ "$(cat "${XRF_VAR}/state.json")" = '{"historical":"unchanged"}' ]
}

@test "failed service activation removes fresh artifacts and preserves historical state" {
  export FAIL_ENABLE=true
  printf '%s\n' '{"historical":"unchanged"}' > "${XRF_VAR}/state.json"
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  [ "$status" -ne 0 ]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
  [ ! -e "${XRF_ETC}/xray" ]
  [ ! -e "${XRF_SYSTEMD_DIR}/xray.service" ]
  [ "$(cat "${XRF_VAR}/state.json")" = '{"historical":"unchanged"}' ]
}

@test "successful enable without active service fails and cleans fresh install" {
  export FAKE_INACTIVE_AFTER_ENABLE=true
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  [ "$status" -ne 0 ]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
  [ ! -e "${XRF_ETC}/xray" ]
  [ ! -e "${XRF_SYSTEMD_DIR}/xray.service" ]
}

@test "SNI whitespace is normalized identically in config state and URI" {
  export XRAY_SNI=' www.microsoft.com, alt.example.com'
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  if [ "$status" -ne 0 ]; then printf '%s\n' "$output" >&3; fi
  [ "$status" -eq 0 ]
  [ "$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames | join(",")' "${XRF_ETC}/xray/active/05_inbounds.json")" = 'www.microsoft.com,alt.example.com' ]
  [ "$(jq -r .xray.reality_sni "${XRF_VAR}/state.json")" = 'www.microsoft.com,alt.example.com' ]
  [[ "$output" == *'SNI: www.microsoft.com,alt.example.com'* ]]
  [[ "$output" == *'Target: www.microsoft.com:443'* ]]
  [[ "$output" == *'sni=www.microsoft.com&'* ]]
  [[ "$output" != *'sni= www.microsoft.com'* ]]
}

@test "existing artifacts reject without overwriting" {
  unset XRAY_SNI
  mkdir -p "${XRF_PREFIX}/bin"
  printf 'preserve\n' > "${XRF_PREFIX}/bin/xray"
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *'use xrf upgrade'* ]]
  [ "$(cat "${XRF_PREFIX}/bin/xray")" = preserve ]
}

@test "retired dual topology is rejected" {
  run "${PROJECT_ROOT}/commands/install.sh" --topology vision-reality --dry-run
  [ "$status" -ne 0 ]
}

@test "fresh install requires explicit SNI before downloading Xray" {
  unset XRAY_SNI
  run "${PROJECT_ROOT}/commands/install.sh" --yes --version v26.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *'XRAY_SNI is required'* ]]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
  [ ! -e "${XRF_ETC}/xray" ]
}

@test "help works without SNI and dry-run rejects missing SNI" {
  unset XRAY_SNI
  run "${PROJECT_ROOT}/commands/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'XRAY_SNI=<required host[,host]>'* ]]
  run "${PROJECT_ROOT}/commands/install.sh" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *'XRAY_SNI is required'* ]]
  [ ! -e "${XRF_PREFIX}/bin/xray" ]
}

@test "concurrent fresh installer cannot clean a winner after losing the guard" {
  export RACE_ROOT="${TEST_ROOT}/race" XRF_FLOCK_TIMEOUT_SEC=10
  mkdir -p "${RACE_ROOT}"
  bash -c '
    source "${PROJECT_ROOT}/commands/install.sh"
    install::run_fresh() {
      : > "${RACE_ROOT}/a-running"
      for ((i=0;i<200;i++)); do [[ -f "${RACE_ROOT}/release-a" ]] && break; sleep .02; done
      mkdir -p "$(dirname "$(xray::bin)")"
      printf "winner\n" > "$(xray::bin)"
      : > "${RACE_ROOT}/a-created"
    }
    main --yes --version v26.9.9
  ' > "${RACE_ROOT}/a.log" 2>&1 &
  local a_pid=$!
  for ((i=0;i<200;i++)); do [[ -f "${RACE_ROOT}/a-running" ]] && break; sleep .02; done
  [ -f "${RACE_ROOT}/a-running" ]
  bash -c '
    source "${PROJECT_ROOT}/commands/install.sh"
    install::run_fresh() {
      : > "${RACE_ROOT}/b-entered"
      for ((i=0;i<200;i++)); do [[ -f "${RACE_ROOT}/a-created" ]] && break; sleep .02; done
      return 1
    }
    : > "${RACE_ROOT}/b-before-main"
    main --yes --version v26.9.9
  ' > "${RACE_ROOT}/b.log" 2>&1 &
  local b_pid=$!
  for ((i=0;i<200;i++)); do [[ -f "${RACE_ROOT}/b-before-main" ]] && break; sleep .02; done
  [ -f "${RACE_ROOT}/b-before-main" ]
  for ((i=0;i<50;i++)); do [[ -f "${RACE_ROOT}/b-entered" ]] && break; sleep .02; done
  : > "${RACE_ROOT}/release-a"
  local a_rc=0 b_rc=0
  wait "$a_pid" || a_rc=$?
  wait "$b_pid" || b_rc=$?
  [ "$a_rc" -eq 0 ]
  [ "$b_rc" -ne 0 ]
  [ "$(cat "${XRF_PREFIX}/bin/xray" 2>/dev/null)" = winner ]
  [ ! -e "${RACE_ROOT}/b-entered" ]
}
