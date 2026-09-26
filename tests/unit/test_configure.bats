#!/usr/bin/env bats
# Exercise the production renderer rather than copies of its helpers.
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/services/xray/configure.sh"
  export XRAY_PORT=443 XRAY_UUID=11111111-2222-4333-8444-555555555555
  export XRAY_SNI=www.microsoft.com XRAY_REALITY_DEST=www.microsoft.com:443
  export XRAY_SHORT_ID=abcd1234 XRAY_PRIVATE_KEY=privatekey
  mkdir -p "${TEST_TMPDIR}/release"
}
teardown() { cleanup_test_env; }

@test "renderer writes one RAW REALITY Vision-flow inbound" {
  xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0
  run jq -e '.inbounds | length == 1 and .[0].settings.decryption == "none" and .[0].settings.clients[0].flow == "xtls-rprx-vision" and .[0].streamSettings.network == "raw" and .[0].streamSettings.realitySettings.target == "www.microsoft.com:443" and .[0].streamSettings.realitySettings.shortIds == ["abcd1234"] and (.[0].streamSettings.realitySettings | has("dest") | not)' "${TEST_TMPDIR}/release/05_inbounds.json"
  [ "$status" -eq 0 ]
}

@test "renderer refuses missing SNI without a default target" {
  unset XRAY_SNI XRAY_REALITY_DEST
  run xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0
  [ "$status" -ne 0 ]
  [ ! -e "${TEST_TMPDIR}/release/05_inbounds.json" ]
}

@test "renderer rejects empty or invalid shortId" {
  export XRAY_SHORT_ID=
  run xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0
  [ "$status" -ne 0 ]
  export XRAY_SHORT_ID=not-hex
  run xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0
  [ "$status" -ne 0 ]
}

@test "renderer rejects unsafe target and invalid port" {
  export XRAY_REALITY_DEST='bad"host:443'
  run xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0
  [ "$status" -ne 0 ]
  export XRAY_REALITY_DEST=www.microsoft.com:99999
  run xray::render_reality_inbound "${TEST_TMPDIR}/release" false 0.0.0.0
  [ "$status" -ne 0 ]
}

@test "base configs send access and error logs to stdout for journald" {
  xray::write_base_configs "${TEST_TMPDIR}/release" UseIPv4
  run jq -e '.log.access == "" and .log.error == "" and .log.loglevel == "warning"' "${TEST_TMPDIR}/release/00_log.json"
  [ "$status" -eq 0 ]
}

@test "log level is JSON-escaped" {
  export XRAY_LOG_LEVEL='warning"bad'
  xray::write_base_configs "${TEST_TMPDIR}/release" UseIPv4
  run jq -e '.log.loglevel == "warning\"bad"' "${TEST_TMPDIR}/release/00_log.json"
  [ "$status" -eq 0 ]
}

@test "render release rejects retired dual topology" {
  run render_release vision-reality
  [ "$status" -ne 0 ]
}

@test "release includes DNS routing and outbound files" {
  run render_release reality-only
  [ "$status" -eq 0 ]
  release="$output"
  [ -f "${release}/05_inbounds.json" ]
  [ -f "${release}/06_outbounds.json" ]
  [ -f "${release}/07_dns.json" ]
  [ -f "${release}/09_routing.json" ]
}
