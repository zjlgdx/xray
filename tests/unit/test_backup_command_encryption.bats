#!/usr/bin/env bats
# Unit tests for encrypted backup command options (commands/backup.sh)

load ../test_helper

setup() {
  setup_test_env
  mkdir -p "${XRF_ETC}/xray/active"
  mkdir -p "${XRF_VAR}"
  printf '%s\n' '{"inbounds":[{"port":443,"protocol":"vless"}]}' > "${XRF_ETC}/xray/active/config.json"
  printf '%s\n' '{"name":"reality-only","version":"v1.8.0"}' > "${XRF_VAR}/state.json"
  printf 'digest\n' > "${XRF_VAR}/config.sha256"
}

teardown() {
  cleanup_test_env
}

@test "backup command create --encrypt --password creates .enc backup" {
  local password="0123456789abcdef0123456789abcdef"

  run "${PROJECT_ROOT}/commands/backup.sh" create --name cmd-enc --encrypt --password "${password}"
  [ "$status" -eq 0 ]

  local backup_dir="${XRF_VAR}/backups"
  local enc_file
  enc_file="$(find "${backup_dir}" -name "cmd-enc-*.tar.gz.enc" | head -1)"
  [ -f "${enc_file}" ]
}

@test "backup command create --encrypt rejects weak password" {
  run "${PROJECT_ROOT}/commands/backup.sh" create --name cmd-weak --encrypt --password "short"
  [ "$status" -eq 1 ]
  [[ "${output}" == *"at least 32 characters"* ]]
}

@test "backup command create --encrypt auto-generates password output" {
  run "${PROJECT_ROOT}/commands/backup.sh" create --name cmd-auto --encrypt
  [ "$status" -eq 0 ]
  [[ "${output}" == *"Encryption password:"* ]]
}

@test "backup command create rejects password without --encrypt" {
  local password="0123456789abcdef0123456789abcdef"
  run "${PROJECT_ROOT}/commands/backup.sh" create --name cmd-noenc --password "${password}"
  [ "$status" -eq 1 ]
  [[ "${output}" == *"password options require --encrypt"* ]]
}

@test "backup command create supports --password-file" {
  local pass_file="${TEST_TMPDIR}/backup.pass"
  printf '0123456789abcdef0123456789abcdef\n' > "${pass_file}"

  run "${PROJECT_ROOT}/commands/backup.sh" create --name cmd-file --encrypt --password-file "${pass_file}"
  [ "$status" -eq 0 ]

  local backup_dir="${XRF_VAR}/backups"
  local enc_file
  enc_file="$(find "${backup_dir}" -name "cmd-file-*.tar.gz.enc" | head -1)"
  [ -f "${enc_file}" ]
}
