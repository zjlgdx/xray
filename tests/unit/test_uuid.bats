#!/usr/bin/env bats
# Unit tests for lib/uuid.sh

load ../test_helper

setup() {
  setup_test_env
  # Source the UUID module (test_helper doesn't include it)
  source "${PROJECT_ROOT}/lib/uuid.sh"
  source "${PROJECT_ROOT}/lib/validators.sh"
}

teardown() {
  cleanup_test_env
}

# ==============================================================================
# uuid::generate Tests
# ==============================================================================

@test "uuid::generate - generates valid UUID without xray" {
  # Skip if no UUID generation tools available
  if ! command -v uuidgen >/dev/null 2>&1 && ! [[ -r /proc/sys/kernel/random/uuid ]]; then
    skip "no UUID generation tools available"
  fi

  run uuid::generate ""
  [ "$status" -eq 0 ]

  # Validate generated UUID format
  run validators::uuid "${output}"
  [ "$status" -eq 0 ]
}

@test "uuid::generate - uses uuidgen fallback" {
  # Skip if uuidgen not available
  if ! command -v uuidgen >/dev/null 2>&1; then
    skip "uuidgen not available"
  fi

  # Call without xray binary (trigger fallback)
  run uuid::generate ""
  [ "$status" -eq 0 ]

  # Validate format
  [[ "${output}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

@test "uuid::generate - uses /proc/sys/kernel/random/uuid fallback" {
  # Skip if /proc UUID not available
  if ! [[ -r /proc/sys/kernel/random/uuid ]]; then
    skip "/proc/sys/kernel/random/uuid not available"
  fi

  # Mock uuidgen to fail (force /proc fallback)
  uuidgen() { return 1; }
  export -f uuidgen

  run uuid::generate ""
  [ "$status" -eq 0 ]

  # Validate format
  [[ "${output}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]

  unset -f uuidgen
}

# ==============================================================================
# uuid::from_string Tests
# ==============================================================================

@test "uuid::from_string - requires input string" {
  run uuid::from_string
  [ "$status" -ne 0 ]
  [[ "${output}" == *"requires input string"* ]]
}

@test "uuid::from_string - requires xray binary" {
  run uuid::from_string "alice" ""
  [ "$status" -ne 0 ]
  [[ "${output}" == *"xray binary required"* ]]
}

@test "uuid::from_string - validates xray binary is executable" {
  # Create a non-executable file
  local fake_xray="${TEST_TMPDIR}/fake_xray"
  touch "${fake_xray}"
  chmod 644 "${fake_xray}"

  run uuid::from_string "alice" "${fake_xray}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"not executable"* ]]
}

@test "uuid::from_string - handles xray uuid -i failure" {
  # Create a mock xray that fails
  local mock_xray="${TEST_TMPDIR}/mock_xray"
  cat > "${mock_xray}" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "${mock_xray}"

  run uuid::from_string "alice" "${mock_xray}"
  [ "$status" -ne 0 ]
  [[ "${output}" == *"xray uuid -i failed"* ]]
}

@test "uuid::from_string - generates UUID from string (mock)" {
  # Create a mock xray that returns a fixed UUID
  local mock_xray="${TEST_TMPDIR}/mock_xray"
  cat > "${mock_xray}" <<'EOF'
#!/bin/bash
if [[ "$1" == "uuid" && "$2" == "-i" && "$3" == "alice" ]]; then
  echo "b0d82e7d-4d24-5b5c-9b6e-3c4e1f0a8c9d"
else
  exit 1
fi
EOF
  chmod +x "${mock_xray}"

  run uuid::from_string "alice" "${mock_xray}"
  [ "$status" -eq 0 ]
  [ "${output}" = "b0d82e7d-4d24-5b5c-9b6e-3c4e1f0a8c9d" ]
}

@test "uuid::from_string - same string produces same UUID (deterministic)" {
  # Create a mock xray that simulates deterministic behavior
  local mock_xray="${TEST_TMPDIR}/mock_xray"
  cat > "${mock_xray}" <<'EOF'
#!/bin/bash
if [[ "$1" == "uuid" && "$2" == "-i" ]]; then
  # Simulate deterministic UUID generation from input string
  # Real xray uses UUIDv5, this is a simple mock
  echo "b0d82e7d-4d24-5b5c-9b6e-3c4e1f0a8c9d"
else
  exit 1
fi
EOF
  chmod +x "${mock_xray}"

  # Generate UUID twice with same string
  uuid1=$(uuid::from_string "alice" "${mock_xray}")
  uuid2=$(uuid::from_string "alice" "${mock_xray}")

  [ "${uuid1}" = "${uuid2}" ]
}

# ==============================================================================
# Integration Tests
# ==============================================================================

@test "integration - uuid::generate produces valid UUID" {
  # Skip if no UUID generation tools
  if ! command -v uuidgen >/dev/null 2>&1 && ! [[ -r /proc/sys/kernel/random/uuid ]]; then
    skip "no UUID generation tools available"
  fi

  # Generate 5 UUIDs and validate all
  for i in {1..5}; do
    uuid=$(uuid::generate "")
    run validators::uuid "${uuid}"
    [ "$status" -eq 0 ]
  done
}

@test "integration - generated UUIDs are unique" {
  # Skip if no UUID generation tools
  if ! command -v uuidgen >/dev/null 2>&1 && ! [[ -r /proc/sys/kernel/random/uuid ]]; then
    skip "no UUID generation tools available"
  fi

  # Generate multiple UUIDs
  uuid1=$(uuid::generate "")
  uuid2=$(uuid::generate "")
  uuid3=$(uuid::generate "")

  # Verify they are all different
  [ "${uuid1}" != "${uuid2}" ]
  [ "${uuid2}" != "${uuid3}" ]
  [ "${uuid1}" != "${uuid3}" ]
}
