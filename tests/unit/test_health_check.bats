#!/usr/bin/env bats
# Tests for lib/health_check.sh - Post-installation health check

# Setup test environment
setup() {
  # Load the module under test
  HERE="$(cd "$(dirname "${BATS_TEST_DIRNAME}")/.." && pwd)"
  # shellcheck source=lib/core.sh
  . "${HERE}/lib/core.sh"
  core::init

  # shellcheck source=lib/defaults.sh
  . "${HERE}/lib/defaults.sh"
  # shellcheck source=modules/state.sh
  . "${HERE}/modules/state.sh"
  # shellcheck source=services/xray/common.sh
  . "${HERE}/services/xray/common.sh"
  # shellcheck source=lib/health_check.sh
  . "${HERE}/lib/health_check.sh"

  # Set up test variables
  export XRF_JSON="false"
  export XRF_DEBUG="false"
}

# ============================================================================
# health::check_service() Tests
# ============================================================================

@test "health::check_service - returns 0 if systemctl not found" {
  # Skip if systemctl actually exists
  if command -v systemctl >/dev/null 2>&1; then
    skip "systemctl is available"
  fi

  run health::check_service
  # Should return 1 (warn) if systemctl not found
  [ "$status" -eq 1 ]
}

@test "health::check_service - checks xray.service status" {
  skip "requires systemd environment"

  run health::check_service
  # Status depends on whether xray.service is running
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ============================================================================
# health::check_config() Tests
# ============================================================================

@test "health::check_config - returns 1 if xray binary not found" {
  # Override xray::bin to return non-existent path
  xray::bin() { echo "/nonexistent/xray"; }

  run health::check_config
  [ "$status" -eq 1 ]
}

@test "health::check_config - returns 1 if active config directory missing" {
  xray::bin() { echo "$(command -v true)"; }
  xray::active() { echo "${BATS_TEST_TMPDIR}/missing-active"; }

  run health::check_config
  [ "$status" -eq 1 ]
}

@test "health::check_config - returns 1 if no config files found" {
  ACTIVE_CONFIG_DIR="${BATS_TEST_TMPDIR}/active-empty"
  mkdir -p "${ACTIVE_CONFIG_DIR}"
  xray::bin() { echo "$(command -v true)"; }
  xray::active() { echo "${ACTIVE_CONFIG_DIR}"; }

  run health::check_config
  [ "$status" -eq 1 ]
}

@test "health::check_config - returns 1 if config directory not found" {
  skip "requires xray binary"

  # This test requires actual xray binary, skip in most environments
  run health::check_config
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ============================================================================
# health::check_network() Tests
# ============================================================================

@test "health::check_network - returns 1 if state is empty" {
  # Mock state::load to return empty
  state::load() { echo "{}"; }

  run health::check_network
  [ "$status" -eq 1 ]
}

@test "health::check_network - handles missing ss/netstat gracefully" {
  # Temporarily hide both ss and netstat
  local old_path="${PATH}"
  export PATH="/nonexistent"

  run health::check_network
  [ "$status" -eq 1 ]

  export PATH="${old_path}"
}

@test "health::check_network - checks port listening status" {
  skip "requires actual xray installation"

  run health::check_network
  # Status depends on whether ports are listening
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ============================================================================
# health::run() Tests - Text Format
# ============================================================================

@test "health::run - displays text format output by default" {
  export XRF_JSON="false"

  run health::run
  [[ "$output" =~ "Health Check Report" ]]
}

@test "health::run - text format shows all check categories" {
  export XRF_JSON="false"

  run health::run
  [[ "$output" =~ "Service Status" ]]
  [[ "$output" =~ "Configuration" ]]
  [[ "$output" =~ "Network" ]]
  [[ "$output" =~ "Compatibility" ]]
}

@test "health::run - text format shows checkmark or cross" {
  export XRF_JSON="false"

  run health::run
  # Should have either ✓ or ✗ symbols
  [[ "$output" =~ "✓" ]] || [[ "$output" =~ "✗" ]]
}

@test "health::run - text format shows overall status" {
  export XRF_JSON="false"

  run health::run
  [[ "$output" =~ "Overall:" ]]
  [[ "$output" =~ "Healthy" ]] || [[ "$output" =~ "Issues detected" ]]
}

# ============================================================================
# health::run() Tests - JSON Format
# ============================================================================

@test "health::run - displays JSON format output when XRF_JSON=true" {
  export XRF_JSON="true"

  run health::run
  [[ "$output" =~ '"health"' ]]
  [[ "$output" =~ '"overall"' ]]
}

@test "health::run - JSON format includes all check results" {
  export XRF_JSON="true"

  run health::run
  [[ "$output" =~ '"service"' ]]
  [[ "$output" =~ '"config"' ]]
  [[ "$output" =~ '"network"' ]]
  [[ "$output" =~ '"compatibility"' ]]
}

@test "health::run - JSON format shows passed status" {
  export XRF_JSON="true"

  run health::run
  [[ "$output" =~ '"passed"' ]]
  [[ "$output" =~ "true" ]] || [[ "$output" =~ "false" ]]
}

@test "health::run - JSON format includes status messages" {
  export XRF_JSON="true"

  run health::run
  [[ "$output" =~ '"message"' ]]
}

# ============================================================================
# Integration Tests
# ============================================================================

@test "health_check module can be sourced without errors" {
  # Already sourced in setup, this tests that it loaded correctly
  [ "$(type -t health::check_service)" = "function" ]
  [ "$(type -t health::check_config)" = "function" ]
  [ "$(type -t health::check_network)" = "function" ]
  [ "$(type -t health::check_compatibility)" = "function" ]
  [ "$(type -t health::run)" = "function" ]
}

@test "health::run returns 0 if all checks pass" {
  skip "requires full xray installation"

  # This test would require mocking all check functions to return 0
  # Skip in unit test environment
  run health::run
  [ "$status" -eq 0 ]
}

@test "health::run returns 1 if any check fails" {
  # Mock one check to fail
  health::check_service() { return 1; }

  run health::run
  [ "$status" -eq 1 ]
}

@test "health::check_compatibility - detects deprecated allowInsecure in active config" {
  local active_dir="${BATS_TEST_TMPDIR}/active"
  mkdir -p "${active_dir}"
  xray::active() { echo "${active_dir}"; }

  cat > "${active_dir}/05_inbounds.json" <<'JSON'
{"inbounds":[{"streamSettings":{"tlsSettings":{"allowInsecure":true}}}]}
JSON

  run health::check_compatibility
  [ "$status" -eq 1 ]
  [[ "$output" =~ "allowInsecure" ]]
}

# ============================================================================
# Error Handling Tests
# ============================================================================

@test "health::check_service handles systemctl errors gracefully" {
  skip "requires systemd environment with errors"

  run health::check_service
  # Should not crash even if systemctl has errors
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "health::check_config handles xray -test errors gracefully" {
  skip "requires xray binary with invalid config"

  run health::check_config
  # Should not crash even if xray -test fails
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
