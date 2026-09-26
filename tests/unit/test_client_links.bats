#!/usr/bin/env bats
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/modules/state.sh"
}
teardown() { cleanup_test_env; }

valid_state() {
  state::save '{"name":"reality-only","xray":{"port":443,"uuid":"11111111-2222-4333-8444-555555555555","reality_sni":"www.microsoft.com,alt.example.com","short_id":"abcd1234","reality_public_key":"Base64PublicKey","fingerprint":"chrome"}}'
}

@test "links uses all committed REALITY credentials and emits exactly one URI" {
  valid_state
  run env XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'vless://11111111-2222-4333-8444-555555555555@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=Base64PublicKey&sid=abcd1234&spx=%2F'* ]]
  [ "$(grep -o 'vless://' <<< "$output" | wc -l | tr -d ' ')" = 1 ]
}

@test "links brackets IPv6 address" {
  valid_state
  run env XRAY_SERVER_IP=2001:db8::1 "${PROJECT_ROOT}/services/xray/client-links.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'@[2001:db8::1]:443?'* ]]
}

@test "links fails closed when private state is missing" {
  run env XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *'vless://'* ]]
}

@test "links fails closed when required credential is missing" {
  state::save '{"name":"reality-only","xray":{"uuid":"11111111-2222-4333-8444-555555555555"}}'
  run env XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *'vless://'* ]]
}

@test "links rejects retired topology state" {
  state::save '{"name":"vision-reality","xray":{}}'
  run env XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh"
  [ "$status" -ne 0 ]
}

@test "links rejects whitespace or query delimiters in saved URI fields" {
  local field value
  for field in reality_sni reality_public_key fingerprint; do
    case "${field}" in
      reality_sni) value=' www.microsoft.com' ;;
      reality_public_key) value='public&admin=true' ;;
      fingerprint) value='chrome&admin=true' ;;
    esac
    valid_state
    jq --arg field "${field}" --arg value "${value}" '.xray[$field]=$value' "$(state::path)" > "${BATS_TEST_TMPDIR}/mutated.json"
    state::save "$(cat "${BATS_TEST_TMPDIR}/mutated.json")"
    run env XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh"
    [ "$status" -ne 0 ]
    [[ "$output" != *'vless://'* ]]
  done
}

@test "links rejects unsafe server IP override" {
  valid_state
  run env XRAY_SERVER_IP='203.0.113.10?admin=true' "${PROJECT_ROOT}/services/xray/client-links.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *'vless://'* ]]
}

@test "unprivileged Linux caller cannot read private connection state" {
  [[ "$(uname)" == Linux && "$(id -u)" -eq 0 ]] || skip "requires root on Linux"
  command -v runuser > /dev/null || skip "runuser unavailable"
  id nobody > /dev/null 2>&1 || skip "nobody unavailable"
  runuser -u nobody -- test -r "${PROJECT_ROOT}/services/xray/client-links.sh" || skip "repository inaccessible to nobody"
  local private_root
  private_root="$(mktemp -d /tmp/xrf-private-links.XXXXXX)"
  chmod 0755 "${private_root}"
  export XRF_VAR="${private_root}/state"
  valid_state
  run runuser -u nobody -- env XRF_VAR="${XRF_VAR}" XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh"
  rm -rf "${private_root}"
  [ "$status" -ne 0 ]
  [[ "$output" == *'connection state is not readable'* ]]
  [[ "$output" != *'vless://'* ]]
}
