#!/usr/bin/env bats
# Product contract through the production renderer, state writer and links command.

load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/services/xray/configure.sh"
  mkdir -p "${TEST_TMPDIR}/release"
}

teardown() { cleanup_test_env; }

@test "fresh renderer emits one RAW REALITY Vision-flow inbound" {
  export XRAY_PORT=443 XRAY_UUID=11111111-1111-4111-8111-111111111111
  export XRAY_SNI=www.microsoft.com XRAY_REALITY_DEST=www.microsoft.com:443
  export XRAY_SHORT_ID=abcd1234 XRAY_PRIVATE_KEY=privatekey
  xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0

  run jq -e '.inbounds | length == 1 and .[0].protocol == "vless" and .[0].settings.decryption == "none" and .[0].settings.clients[0].flow == "xtls-rprx-vision" and .[0].streamSettings.network == "raw" and .[0].streamSettings.security == "reality" and .[0].streamSettings.realitySettings.target == "www.microsoft.com:443" and .[0].streamSettings.realitySettings.serverNames == ["www.microsoft.com"] and .[0].streamSettings.realitySettings.shortIds == ["abcd1234"] and (.[0].streamSettings.realitySettings | has("dest") | not)' "${TEST_TMPDIR}/release/05_inbounds.json"
  [ "$status" -eq 0 ]
}

@test "state writer protects connection credentials" {
  state::save '{"xray":{"uuid":"secret"}}'
  dir_mode="$(stat -c '%a' "$(state::dir)" 2>/dev/null || stat -f '%Lp' "$(state::dir)")"
  file_mode="$(stat -c '%a' "$(state::path)" 2>/dev/null || stat -f '%Lp' "$(state::path)")"
  [ "$dir_mode" = 700 ]
  [ "$file_mode" = 600 ]
}

@test "links fails on incomplete credentials without emitting a placeholder" {
  state::save '{"name":"reality-only","xray":{}}'
  run env XRAY_SERVER_IP=203.0.113.10 "${PROJECT_ROOT}/services/xray/client-links.sh" reality-only
  [ "$status" -ne 0 ]
  [[ "$output" != *'vless://'* ]]
}
