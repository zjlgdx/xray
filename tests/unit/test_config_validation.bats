#!/usr/bin/env bats
# Unit tests for lib/config_validation.sh

load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/core.sh"
  source "${PROJECT_ROOT}/lib/validators.sh"
  source "${PROJECT_ROOT}/services/xray/common.sh"
  source "${PROJECT_ROOT}/lib/config_validation.sh"
}

teardown() {
  cleanup_test_env
}

make_valid_confdir() {
  local confdir="${1}"
  mkdir -p "${confdir}"
  cat > "${confdir}/00_log.json" <<'JSON'
{"log":{"access":"none","error":"none","loglevel":"warning"}}
JSON
  cat > "${confdir}/05_inbounds.json" <<'JSON'
{
  "inbounds": [
    {
      "tag": "reality",
      "port": 443,
      "protocol": "vless",
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "serverNames": ["www.microsoft.com"],
          "shortIds": ["", "abcd1234"]
        }
      }
    }
  ]
}
JSON
  cat > "${confdir}/06_outbounds.json" <<'JSON'
{
  "outbounds": [
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"blackhole","tag":"block"}
  ]
}
JSON
  cat > "${confdir}/09_routing.json" <<'JSON'
{"routing":{"domainStrategy":"IPIfNonMatch","rules":[]}}
JSON
}

@test "config::validate_json_syntax - passes for valid json files" {
  local confdir="${TEST_TMPDIR}/conf-valid-json"
  make_valid_confdir "${confdir}"

  run config::validate_json_syntax "${confdir}"
  [ "$status" -eq 0 ]
}

@test "config::validate_json_syntax - fails for invalid json" {
  local confdir="${TEST_TMPDIR}/conf-invalid-json"
  make_valid_confdir "${confdir}"
  printf '{invalid-json\n' > "${confdir}/09_routing.json"

  run config::validate_json_syntax "${confdir}"
  [ "$status" -eq 1 ]
}

@test "config::validate_schema - fails when inbounds missing" {
  local confdir="${TEST_TMPDIR}/conf-missing-inbounds"
  make_valid_confdir "${confdir}"
  printf '{"note":"no inbounds"}\n' > "${confdir}/05_inbounds.json"

  run config::validate_schema "${confdir}"
  [ "$status" -eq 1 ]
}

@test "config::validate_schema - fails when outbounds is not array" {
  local confdir="${TEST_TMPDIR}/conf-outbounds-not-array"
  make_valid_confdir "${confdir}"
  printf '{"outbounds":{"protocol":"freedom"}}\n' > "${confdir}/06_outbounds.json"

  run config::validate_schema "${confdir}"
  [ "$status" -eq 1 ]
}

@test "config::validate_business_rules - fails for duplicate inbound ports" {
  local confdir="${TEST_TMPDIR}/conf-dup-ports"
  make_valid_confdir "${confdir}"
  cat > "${confdir}/05_inbounds.json" <<'JSON'
{
  "inbounds": [
    {"tag":"a","port":443,"protocol":"vless"},
    {"tag":"b","port":443,"protocol":"vless"}
  ]
}
JSON

  run config::validate_business_rules "${confdir}"
  [ "$status" -eq 1 ]
}

@test "config::validate_business_rules - fails for duplicate outbound tags" {
  local confdir="${TEST_TMPDIR}/conf-dup-tags"
  make_valid_confdir "${confdir}"
  cat > "${confdir}/06_outbounds.json" <<'JSON'
{
  "outbounds": [
    {"protocol":"freedom","tag":"dup"},
    {"protocol":"blackhole","tag":"dup"}
  ]
}
JSON

  run config::validate_business_rules "${confdir}"
  [ "$status" -eq 1 ]
}

@test "config::validate_deep - passes for valid config directory" {
  local confdir="${TEST_TMPDIR}/conf-valid-deep"
  make_valid_confdir "${confdir}"

  run config::validate_deep "${confdir}"
  [ "$status" -eq 0 ]
}

@test "config::validate_deep - parses each file once and merges once" {
  local confdir="${TEST_TMPDIR}/conf-deep-once"
  make_valid_confdir "${confdir}"
  local trace="${TEST_TMPDIR}/jq-calls"
  jq() {
    printf '%s\n' "${1}" >> "${trace}"
    command jq "$@"
  }

  run config::validate_deep "${confdir}"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^empty$' "${trace}")" -eq 4 ]
  [ "$(grep -c '^-s$' "${trace}")" -eq 1 ]
}

@test "config validation - standalone layers and deep reject invalid syntax and empty directories" {
  local confdir="${TEST_TMPDIR}/conf-invalid" validator
  make_valid_confdir "${confdir}"
  printf '{invalid-json\n' > "${confdir}/09_routing.json"
  mkdir -p "${TEST_TMPDIR}/empty"
  for validator in config::validate_schema config::validate_business_rules config::validate_deep; do
    run "${validator}" "${confdir}"
    [ "$status" -eq 1 ]
    run "${validator}" "${TEST_TMPDIR}/empty"
    [ "$status" -eq 1 ]
    run "${validator}" "${TEST_TMPDIR}/missing"
    [ "$status" -eq 1 ]
  done
}

@test "config validation - standalone layers and deep propagate merge failures" {
  local confdir="${TEST_TMPDIR}/conf-merge-failure" validator
  make_valid_confdir "${confdir}"
  config::_merge() { return 1; }
  for validator in config::validate_schema config::validate_business_rules config::validate_deep; do
    run "${validator}" "${confdir}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed to merge json configuration"* ]]
  done
}

@test "config::validate_deep - preserves schema and business rule failures" {
  local confdir="${TEST_TMPDIR}/conf-deep-invalid"
  make_valid_confdir "${confdir}"
  printf '{"outbounds":{}}\n' > "${confdir}/06_outbounds.json"
  run config::validate_deep "${confdir}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema validation failed"* ]]

  make_valid_confdir "${confdir}"
  printf '{"routing":{"domainStrategy":"invalid"}}\n' > "${confdir}/09_routing.json"
  run config::validate_deep "${confdir}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"business rule violation"* ]]
}

@test "config validation - standalone layers accept valid merged fragments" {
  local confdir="${TEST_TMPDIR}/conf-standalone" validator
  make_valid_confdir "${confdir}"
  for validator in config::validate_schema config::validate_business_rules; do
    run "${validator}" "${confdir}"
    [ "$status" -eq 0 ]
  done
}
