#!/usr/bin/env bats
# Tests for lib/x25519.sh helpers

load ../test_helper

setup() {
  setup_test_env
  # shellcheck source=lib/x25519.sh
  . "${PROJECT_ROOT}/lib/x25519.sh"
}

teardown() {
  cleanup_test_env
}

@test "x25519::parse_keys extracts private and public values" {
  local output
  output=$(x25519::parse_keys $'Private key: AAAA=\nPublic key: BBBB=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "AAAA=" ]
  [ "${public}" = "BBBB=" ]
}

@test "x25519::parse_keys accepts Base64URL characters" {
  local output
  output=$(x25519::parse_keys $'Private key: AAAA-_==\nPublic key: BBBB-_==')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "AAAA-_==" ]
  [ "${public}" = "BBBB-_==" ]
}

@test "x25519::parse_keys tolerates uppercase labels and whitespace" {
  local output
  output=$(x25519::parse_keys $'  PUBLIC KEY :  CCCC=\r\n  private KEY:\tDDDD=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "DDDD=" ]
  [ "${public}" = "CCCC=" ]
}

@test "x25519::parse_keys handles annotated labels" {
  local output
  output=$(x25519::parse_keys $'Private key (hex): EEEE=\nPublic key (display): FFFF=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "EEEE=" ]
  [ "${public}" = "FFFF=" ]
}

@test "x25519::parse_keys handles multiline values" {
  local output
  output=$(x25519::parse_keys $'Private key:\n  GGGG=\nPublic key:\n  HHHH=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "GGGG=" ]
  [ "${public}" = "HHHH=" ]
}

@test "x25519::parse_keys handles new PrivateKey/Password format" {
  local output
  output=$(x25519::parse_keys $'PrivateKey: cAP6oEHFfJ1MK3yB4xxY6hW1t4xiwA1YbX6Zx1vVumI\nPassword: j5-GwxUecl-6rL6WFFRwjj0gJKz9V3Etwi8srN3_Mn4\nHash32: HybzUCUvGM1ImrMBtuDDdNmGSVZWj-1_kU94OracVT8')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "cAP6oEHFfJ1MK3yB4xxY6hW1t4xiwA1YbX6Zx1vVumI" ]
  [ "${public}" = "j5-GwxUecl-6rL6WFFRwjj0gJKz9V3Etwi8srN3_Mn4" ]
}

@test "x25519::parse_keys handles new format with std-encoding" {
  local output
  output=$(x25519::parse_keys $'PrivateKey: AAdaiNXJJ0vBspzw8/7Eko+9BvbbCKN7DaI/W1/XJVA=\nPassword: mZfV1WnfSeV9suWvikz6p/GWCJWl7XA6e39sVe7Mkho=\nHash32: D3xVwaYj8qQ738EqlV1pAFvaTud/NSduEX8b07gM83M=')
  local -a parsed=()
  readarray -t parsed <<< "${output}"
  local private="${parsed[0]:-}"
  local public="${parsed[1]:-}"
  [ "${private}" = "AAdaiNXJJ0vBspzw8/7Eko+9BvbbCKN7DaI/W1/XJVA=" ]
  [ "${public}" = "mZfV1WnfSeV9suWvikz6p/GWCJWl7XA6e39sVe7Mkho=" ]
}

@test "x25519::derive_public_key parses the official Password output" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-bin"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 3 && "$1" == x25519 && "$2" == -i ]] || exit 2
printf 'PrivateKey: %s\nPassword: derived-%s\n' "$3" "$3"
SCRIPT
  chmod +x "${fake_xray}"

  local result
  result="$(x25519::derive_public_key "${fake_xray}" "aaaa=")"
  [ "${result}" = "derived-aaaa=" ]
}

@test "x25519::derive_public_key returns failure when no output" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-empty"
  cat <<'SCRIPT' > "${fake_xray}"
#!/usr/bin/env bash
set -euo pipefail
exit 1
SCRIPT
  chmod +x "${fake_xray}"

  run x25519::derive_public_key "${fake_xray}" "cccc="
  [ "$status" -ne 0 ]
}

@test "x25519::derive_public_key uses current -i private-key interface" {
  local fake_xray="${BATS_TEST_TMPDIR}/xray-current"
  cat > "${fake_xray}" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$#" -eq 3 && "$1" == x25519 && "$2" == -i && "$3" == privatekey ]] || exit 2
printf 'PrivateKey: privatekey\nPassword: current-public\n'
SCRIPT
  chmod +x "${fake_xray}"
  run x25519::derive_public_key "${fake_xray}" privatekey
  [ "$status" -eq 0 ]
  [ "$output" = current-public ]
}
