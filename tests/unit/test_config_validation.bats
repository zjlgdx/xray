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
