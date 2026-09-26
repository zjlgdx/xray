#!/usr/bin/env bats
# Unit tests for commands/check.sh

load ../test_helper

setup() {
  setup_test_env
  mkdir -p "${XRF_ETC}/xray/active"
  mkdir -p "${XRF_PREFIX}/bin"

  cat > "${XRF_PREFIX}/bin/xray" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-test" ]]; then
  exit 0
fi
exit 0
EOF
  chmod +x "${XRF_PREFIX}/bin/xray"

  cat > "${XRF_ETC}/xray/active/05_inbounds.json" << 'JSON'
{"inbounds":[{"tag":"reality","port":443,"protocol":"vless"}]}
JSON
  cat > "${XRF_ETC}/xray/active/06_outbounds.json" << 'JSON'
{"outbounds":[{"protocol":"freedom","tag":"direct"}]}
JSON
}

teardown() {
  cleanup_test_env
}

@test "check command --deep passes on valid config" {
  run "${PROJECT_ROOT}/commands/check.sh" --deep --confdir "${XRF_ETC}/xray/active"
  [ "$status" -eq 0 ]
}

@test "check command --deep fails on invalid json" {
  printf '{bad-json\n' > "${XRF_ETC}/xray/active/06_outbounds.json"
  run "${PROJECT_ROOT}/commands/check.sh" --deep --confdir "${XRF_ETC}/xray/active"
  [ "$status" -eq 1 ]
}

@test "check command without --deep runs binary validation" {
  run "${PROJECT_ROOT}/commands/check.sh" --confdir "${XRF_ETC}/xray/active"
  [ "$status" -eq 0 ]
}

@test "check command rejects unknown option" {
  run "${PROJECT_ROOT}/commands/check.sh" --bad-option
  [ "$status" -eq 1 ]
  [[ "${output}" == *"Usage: xrf check"* ]]
}

# =============================================================================
# Additional edge case tests
# =============================================================================

@test "check command --help shows usage" {
  run "${PROJECT_ROOT}/commands/check.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: xrf check"* ]]
}

@test "check command -h shows usage" {
  run "${PROJECT_ROOT}/commands/check.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: xrf check"* ]]
}

@test "check command --help lists options" {
  run "${PROJECT_ROOT}/commands/check.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--deep"* ]]
  [[ "$output" == *"--confdir"* ]]
}

@test "check command --confdir without value fails" {
  run "${PROJECT_ROOT}/commands/check.sh" --confdir
  [ "$status" -eq 1 ]
}

@test "check command --confdir passes custom path to validator" {
  # Mock xray that echoes the confdir argument it received
  cat > "${XRF_PREFIX}/bin/xray" << 'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do echo "$arg"; done
exit 0
MOCK
  chmod +x "${XRF_PREFIX}/bin/xray"

  local custom_dir="${TEST_TMPDIR}/custom_conf"
  mkdir -p "${custom_dir}"
  run "${PROJECT_ROOT}/commands/check.sh" --confdir "${custom_dir}"
  [ "$status" -eq 0 ]
  # Verify the custom path was actually forwarded to xray -test
  [[ "$output" == *"${custom_dir}"* ]]
}

@test "check command --deep with empty confdir fails" {
  local empty_dir="${TEST_TMPDIR}/empty_conf"
  mkdir -p "${empty_dir}"
  run "${PROJECT_ROOT}/commands/check.sh" --deep --confdir "${empty_dir}"
  # Should fail because no JSON files to validate
  [ "$status" -eq 1 ]
}

@test "check command --deep validates JSON syntax first" {
  # Create a file with broken JSON
  echo "not json at all" > "${XRF_ETC}/xray/active/05_inbounds.json"
  run "${PROJECT_ROOT}/commands/check.sh" --deep --confdir "${XRF_ETC}/xray/active"
  [ "$status" -eq 1 ]
}

@test "check command passes with multiple valid config files" {
  cat > "${XRF_ETC}/xray/active/01_log.json" << 'JSON'
{"log":{"loglevel":"warning"}}
JSON
  cat > "${XRF_ETC}/xray/active/02_api.json" << 'JSON'
{"api":{"tag":"api","services":["StatsService"]}}
JSON

  run "${PROJECT_ROOT}/commands/check.sh" --deep --confdir "${XRF_ETC}/xray/active"
  [ "$status" -eq 0 ]
}

@test "check command --deep follows the installed active symlink" {
  local release="${XRF_ETC}/xray/releases/release with spaces"
  mkdir -p "${XRF_ETC}/xray/releases"
  mv "${XRF_ETC}/xray/active" "${release}"
  ln -s 'releases/release with spaces' "${XRF_ETC}/xray/active"
  # Use the real CLI and its default confdir, as on an installed host.
  run "${PROJECT_ROOT}/bin/xrf" check --deep
  [ "$status" -eq 0 ]
  [[ "$output" == *"configuration validation passed"* ]]

  printf '{bad-json\n' > "${release}/06_outbounds.json"
  run "${PROJECT_ROOT}/bin/xrf" check --deep
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid json syntax"* ]]
}
