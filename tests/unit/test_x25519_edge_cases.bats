#!/usr/bin/env bats
# Edge case tests for lib/x25519.sh

load ../test_helper

setup() {
  setup_test_env
  # shellcheck source=lib/x25519.sh
  . "${PROJECT_ROOT}/lib/x25519.sh"
}

teardown() {
  cleanup_test_env
}

# x25519::trim edge cases
@test "x25519::trim - handles empty string" {
  local result
  result=$(x25519::trim "")
  [ -z "${result}" ]
}

@test "x25519::trim - handles only whitespace" {
  local result
  result=$(x25519::trim "   ")
  [ -z "${result}" ]
}

@test "x25519::trim - handles tabs and newlines" {
  local result
  result=$(x25519::trim $'\t\n  value  \t\n')
  [ "${result}" = "value" ]
}

@test "x25519::trim - preserves internal whitespace" {
  local result
  result=$(x25519::trim "  hello world  ")
  [ "${result}" = "hello world" ]
}

@test "x25519::trim - removes carriage returns" {
  local result
  result=$(x25519::trim $'value\r')
  [ "${result}" = "value" ]
}

@test "x25519::trim - handles mixed whitespace" {
  local result
  result=$(x25519::trim $' \t \r\n value \r\n \t ')
  [ "${result}" = "value" ]
}

@test "x25519::trim - handles no trimming needed" {
  local result
  result=$(x25519::trim "already-trimmed")
  [ "${result}" = "already-trimmed" ]
}

# x25519::sanitize_token edge cases
@test "x25519::sanitize_token - handles empty string" {
  local result
  result=$(x25519::sanitize_token "")
  [ -z "${result}" ]
}

@test "x25519::sanitize_token - removes special characters" {
  local result
  result=$(x25519::sanitize_token "ABC!@#\$%^&*()123")
  [ "${result}" = "ABC123" ]
}

@test "x25519::sanitize_token - preserves Base64 characters" {
  local result
  result=$(x25519::sanitize_token "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
  [ "${result}" = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=" ]
}

@test "x25519::sanitize_token - preserves Base64URL characters" {
  local result
  result=$(x25519::sanitize_token "ABC-_==")
  [ "${result}" = "ABC-_==" ]
}

@test "x25519::sanitize_token - removes carriage returns" {
  local result
  result=$(x25519::sanitize_token $'ABC\r123')
  [ "${result}" = "ABC123" ]
}

@test "x25519::sanitize_token - handles unicode characters" {
  local result
  result=$(x25519::sanitize_token "ABC你好123")
  [ "${result}" = "ABC123" ]
}

@test "x25519::sanitize_token - handles control characters" {
  # Note: null bytes (\x00) may truncate the string in bash
  # This test verifies non-null control chars are removed
  local result
  result=$(x25519::sanitize_token $'ABC\x01\x02123')
  [ "${result}" = "ABC123" ]
}

# x25519::parse_keys edge cases
@test "x25519::parse_keys - handles empty input" {
  local output
  output=$(x25519::parse_keys "")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ -z "${parsed[0]:-}" ]
  [ -z "${parsed[1]:-}" ]
}

@test "x25519::parse_keys - handles input with no keys" {
  local output
  output=$(x25519::parse_keys "Some random text without keys")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ -z "${parsed[0]:-}" ]
  [ -z "${parsed[1]:-}" ]
}

@test "x25519::parse_keys - handles only private key" {
  local output
  output=$(x25519::parse_keys "Private key: AAAA=")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ -z "${parsed[1]:-}" ]
}

@test "x25519::parse_keys - handles only public key" {
  local output
  output=$(x25519::parse_keys "Public key: BBBB=")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ -z "${parsed[0]:-}" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles reversed order (public before private)" {
  local output
  output=$(x25519::parse_keys $'Public key: BBBB=\nPrivate key: AAAA=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - uses first private key when duplicated" {
  # When duplicate private key labels exist, only the first value is used
  # Note: public key must come before duplicate private key for correct parsing
  local output
  output=$(x25519::parse_keys $'Private key: FIRST=\nPublic key: PUBLIC=\nPrivate key: SECOND=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "FIRST=" ]
  [ "${parsed[1]}" = "PUBLIC=" ]
}

@test "x25519::parse_keys - handles very long keys" {
  local long_key
  long_key=$(printf 'A%.0s' {1..100})
  local output
  output=$(x25519::parse_keys "Private key: ${long_key}=")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "${long_key}=" ]
}

@test "x25519::parse_keys - handles Windows line endings" {
  local output
  output=$(x25519::parse_keys $'Private key: AAAA=\r\nPublic key: BBBB=\r\n')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles mixed line endings" {
  local output
  output=$(x25519::parse_keys $'Private key: AAAA=\r\nPublic key: BBBB=\n')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles blank lines" {
  local output
  output=$(x25519::parse_keys $'\n\nPrivate key: AAAA=\n\n\nPublic key: BBBB=\n\n')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles extra colons in value" {
  local output
  output=$(x25519::parse_keys "Private key: AA:BB:CC")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  # Value should be trimmed after first colon split
  [ "${parsed[0]}" = "AA:BB:CC" ]
}

@test "x25519::parse_keys - handles label with extra info in parens" {
  local output
  output=$(x25519::parse_keys $'Private key (base64): AAAA=\nPublic key (hex): BBBB=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles PrivateKey without space" {
  local output
  output=$(x25519::parse_keys $'PrivateKey: AAAA=\nPublicKey: BBBB=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles multiline with indentation" {
  local output
  output=$(x25519::parse_keys $'Private key:\n    AAAA=\nPublic key:\n    BBBB=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles Hash32 field (ignores it)" {
  local output
  output=$(x25519::parse_keys $'PrivateKey: AAAA=\nPassword: BBBB=\nHash32: CCCC=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - handles label case variations" {
  local output
  output=$(x25519::parse_keys $'PRIVATE KEY: AAAA=\nPUBLIC KEY: BBBB=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519::parse_keys - rejects too short values" {
  local output
  output=$(x25519::parse_keys "Private key: AB")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  # Value is too short (less than 4 chars), should be empty
  [ -z "${parsed[0]:-}" ]
}

@test "x25519::parse_keys - handles exactly 4 char value" {
  local output
  output=$(x25519::parse_keys "Private key: ABCD")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "ABCD" ]
}

# x25519::derive_public_key edge cases
@test "x25519::derive_public_key - handles xray binary not found" {
  run x25519::derive_public_key "/nonexistent/xray" "test-key"
  [ "$status" -ne 0 ]
}

@test "x25519::derive_public_key - handles xray returning empty output" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-empty"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
echo ""
exit 0
SCRIPT
  chmod +x "${fake_xray}"

  run x25519::derive_public_key "${fake_xray}" "test-key"
  [ "$status" -ne 0 ]
}

@test "x25519::derive_public_key - handles xray returning only private key" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-private-only"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
echo "Private key: AAAA="
exit 0
SCRIPT
  chmod +x "${fake_xray}"

  run x25519::derive_public_key "${fake_xray}" "test-key"
  [ "$status" -ne 0 ]
}

@test "x25519::derive_public_key - handles new Password format in output" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-password-format"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 3 && "${1}" == "x25519" && "${2}" == "-i" ]]; then
  printf 'PrivateKey: input-key\nPassword: derived-public-key\nHash32: some-hash\n'
  exit 0
fi
exit 1
SCRIPT
  chmod +x "${fake_xray}"

  local result
  result="$(x25519::derive_public_key "${fake_xray}" "input-key")"
  [ "${result}" = "derived-public-key" ]
}

@test "x25519::derive_public_key - handles stderr output gracefully" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-stderr"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
if [[ "${1}" == "x25519" ]]; then
  echo "Warning: something" >&2
  echo "Public key: GOODKEY="
  exit 0
fi
exit 1
SCRIPT
  chmod +x "${fake_xray}"

  local result
  result="$(x25519::derive_public_key "${fake_xray}" "test-key" 2>/dev/null)"
  [ "${result}" = "GOODKEY=" ]
}

@test "x25519::derive_public_key - handles xray crash gracefully" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-crash"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
exit 137  # Simulating SIGKILL
SCRIPT
  chmod +x "${fake_xray}"

  run x25519::derive_public_key "${fake_xray}" "test-key"
  [ "$status" -ne 0 ]
}

# Combined workflow tests
@test "x25519 workflow - sanitize then parse" {
  local raw_output=$'Private key: \r  AAAA= \r\nPublic key: BBBB=\r'
  local output
  output=$(x25519::parse_keys "${raw_output}")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAAA=" ]
  [ "${parsed[1]}" = "BBBB=" ]
}

@test "x25519 workflow - handles real-world Xray output format" {
  local real_output
  real_output=$(cat << 'EOF'
Private key: cAP6oEHFfJ1MK3yB4xxY6hW1t4xiwA1YbX6Zx1vVumI
Public key: j5-GwxUecl-6rL6WFFRwjj0gJKz9V3Etwi8srN3_Mn4
EOF
)
  local output
  output=$(x25519::parse_keys "${real_output}")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "cAP6oEHFfJ1MK3yB4xxY6hW1t4xiwA1YbX6Zx1vVumI" ]
  [ "${parsed[1]}" = "j5-GwxUecl-6rL6WFFRwjj0gJKz9V3Etwi8srN3_Mn4" ]
}

@test "x25519 workflow - handles Xray v25.8.31+ output format" {
  local new_output
  new_output=$(cat << 'EOF'
PrivateKey: AAdaiNXJJ0vBspzw8/7Eko+9BvbbCKN7DaI/W1/XJVA=
Password: mZfV1WnfSeV9suWvikz6p/GWCJWl7XA6e39sVe7Mkho=
Hash32: D3xVwaYj8qQ738EqlV1pAFvaTud/NSduEX8b07gM83M=
EOF
)
  local output
  output=$(x25519::parse_keys "${new_output}")
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  [ "${parsed[0]}" = "AAdaiNXJJ0vBspzw8/7Eko+9BvbbCKN7DaI/W1/XJVA=" ]
  [ "${parsed[1]}" = "mZfV1WnfSeV9suWvikz6p/GWCJWl7XA6e39sVe7Mkho=" ]
}
