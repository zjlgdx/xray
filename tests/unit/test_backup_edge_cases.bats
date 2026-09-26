#!/usr/bin/env bats
# Edge case tests for backup module (lib/backup.sh)
# These tests cover boundary conditions and error handling scenarios

load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/backup.sh"
  source "${PROJECT_ROOT}/modules/state.sh"

  # Override backup directory for testing
  export XRF_VAR="${TEST_TMPDIR}/var"
}

# Test helper: Create mock xray configuration
setup_mock_xray() {
  local xray_etc="${XRF_ETC}/xray"
  mkdir -p "${xray_etc}/active"
  printf '%s\n' '{"inbounds":[{"port":443}]}' > "${xray_etc}/active/config.json"

  local state_content='{"name":"reality-only","version":"v1.8.0"}'
  io::ensure_dir "$(dirname "$(state::path)")" 0755
  printf '%s\n' "${state_content}" > "$(state::path)"
  printf 'digest\n' > "$(state::digest)"
}

# Test helper: Create mock backup
create_mock_backup() {
  local name="${1}"
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  printf 'test content for %s\n' "${name}" > "${backup_dir}/${name}.tar.gz"

  local actual_hash
  actual_hash=$(sha256sum "${backup_dir}/${name}.tar.gz" | awk '{print $1}')

  jq -n \
    --arg name "${name}" \
    --arg hash "${actual_hash}" \
    '{name:$name,timestamp:"20231201-120000",topology:"reality-only",xray_version:"v1.8.0",hash:$hash,size:1024}' \
    > "${backup_dir}/${name}.metadata.json"
}

teardown() {
  cleanup_test_env
}

# =============================================================================
# backup::dir edge cases
# =============================================================================

@test "backup::dir - returns default when XRF_VAR not set" {
  unset XRF_VAR
  result=$(backup::dir)
  [[ "$result" == "/var/lib/xray-fusion/backups" ]]
}

@test "backup::dir - uses XRF_VAR when set" {
  export XRF_VAR="/custom/var"
  result=$(backup::dir)
  [[ "$result" == "/custom/var/backups" ]]
}

@test "backup::dir - handles XRF_VAR with trailing slash" {
  export XRF_VAR="/custom/var/"
  result=$(backup::dir)
  [[ "$result" == "/custom/var//backups" ]]
}

# =============================================================================
# backup::create edge cases
# =============================================================================

@test "backup::create - sanitizes name with special characters" {
  setup_mock_xray

  # Try to create backup with various special characters
  backup::create "test!@#\$%^&*()name"

  local backup_dir
  backup_dir="$(backup::dir)"

  # Find created backup
  local backup_file
  backup_file=$(find "${backup_dir}" -name "*.tar.gz" | head -1)
  [ -f "${backup_file}" ]

  # Filename should only contain safe characters
  local basename
  basename=$(basename "${backup_file}")
  [[ "$basename" =~ ^[a-zA-Z0-9_-]+\.tar\.gz$ ]]
}

@test "backup::create - handles empty name (auto-generate)" {
  setup_mock_xray

  backup::create ""

  local backup_dir
  backup_dir="$(backup::dir)"

  # Should create backup with timestamp pattern
  local backup_count
  backup_count=$(find "${backup_dir}" -name "backup-*.tar.gz" | wc -l)
  [[ "${backup_count}" -ge 1 ]]
}

@test "backup::create - creates backup directory if not exists" {
  setup_mock_xray

  local backup_dir
  backup_dir="$(backup::dir)"

  # Ensure directory doesn't exist
  rm -rf "${backup_dir}"

  backup::create "test"

  [ -d "${backup_dir}" ]
}

@test "backup::create - backup has restrictive permissions" {
  setup_mock_xray

  backup::create "perms-test"

  local backup_dir
  backup_dir="$(backup::dir)"

  local backup_file
  backup_file=$(find "${backup_dir}" -name "perms-test-*.tar.gz" | head -1)

  local perms
  perms=$(stat -c "%a" "${backup_file}" 2>/dev/null || stat -f "%Lp" "${backup_file}")
  [[ "${perms}" == "600" ]]
}

@test "backup::create - metadata file has restrictive permissions" {
  setup_mock_xray

  backup::create "meta-perms"

  local backup_dir
  backup_dir="$(backup::dir)"

  local meta_file
  meta_file=$(find "${backup_dir}" -name "meta-perms-*.metadata.json" | head -1)

  local perms
  perms=$(stat -c "%a" "${meta_file}" 2>/dev/null || stat -f "%Lp" "${meta_file}")
  [[ "${perms}" == "600" ]]
}

# =============================================================================
# backup::list edge cases
# =============================================================================

@test "backup::list - handles empty backup directory" {
  mkdir -p "$(backup::dir)"

  run backup::list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No backups found"* ]]
}

@test "backup::list - handles non-existent backup directory" {
  rm -rf "$(backup::dir)"

  run backup::list
  [ "$status" -eq 0 ]
}

@test "backup::list - JSON output for empty list" {
  mkdir -p "$(backup::dir)"
  export XRF_JSON="true"

  run backup::list
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.backups | length == 0'
}

@test "backup::list - lists multiple backups in order" {
  create_mock_backup "backup-a"
  create_mock_backup "backup-b"
  create_mock_backup "backup-c"

  run backup::list
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-a"* ]]
  [[ "$output" == *"backup-b"* ]]
  [[ "$output" == *"backup-c"* ]]
}

@test "backup::list - JSON format includes all backups" {
  create_mock_backup "json-test-1"
  create_mock_backup "json-test-2"

  export XRF_JSON="true"
  run backup::list
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.backups | length >= 2'
}

# =============================================================================
# backup::verify edge cases
# =============================================================================

@test "backup::verify - fails for empty backup name" {
  run backup::verify ""
  [ "$status" -ne 0 ]
}

@test "backup::verify - fails when metadata missing" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  # Create backup file without metadata
  echo "content" > "${backup_dir}/no-meta.tar.gz"

  run backup::verify "no-meta"
  [ "$status" -ne 0 ]
}

@test "backup::verify - fails when backup file missing" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  # Create metadata without backup file
  echo '{"hash":"abc123"}' > "${backup_dir}/no-file.metadata.json"

  run backup::verify "no-file"
  [ "$status" -ne 0 ]
}

@test "backup::verify - fails when hash is null in metadata" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  echo "content" > "${backup_dir}/null-hash.tar.gz"
  echo '{"name":"null-hash","hash":null}' > "${backup_dir}/null-hash.metadata.json"

  run backup::verify "null-hash"
  [ "$status" -ne 0 ]
}

@test "backup::verify - fails when hash is empty in metadata" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  echo "content" > "${backup_dir}/empty-hash.tar.gz"
  echo '{"name":"empty-hash","hash":""}' > "${backup_dir}/empty-hash.metadata.json"

  run backup::verify "empty-hash"
  [ "$status" -ne 0 ]
}

@test "backup::verify - detects corrupted backup file" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  echo "original content" > "${backup_dir}/corrupt.tar.gz"
  local original_hash
  original_hash=$(sha256sum "${backup_dir}/corrupt.tar.gz" | awk '{print $1}')

  jq -n --arg hash "${original_hash}" '{hash:$hash}' > "${backup_dir}/corrupt.metadata.json"

  # Corrupt the file
  echo "corrupted" > "${backup_dir}/corrupt.tar.gz"

  run backup::verify "corrupt"
  [ "$status" -ne 0 ]
}

@test "backup::verify - succeeds for valid backup" {
  create_mock_backup "valid-backup"

  run backup::verify "valid-backup"
  [ "$status" -eq 0 ]
}

@test "backup::verify - succeeds for encrypted backup file" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  local enc_file="${backup_dir}/enc-valid.tar.gz.enc"
  printf 'encrypted payload\n' > "${enc_file}"
  local hash
  hash=$(sha256sum "${enc_file}" | awk '{print $1}')
  jq -n --arg hash "${hash}" '{name:"enc-valid",hash:$hash,encrypted:true}' > "${backup_dir}/enc-valid.metadata.json"

  run backup::verify "enc-valid"
  [ "$status" -eq 0 ]
}

# =============================================================================
# backup::delete edge cases
# =============================================================================

@test "backup::delete - fails for empty name" {
  run backup::delete ""
  [ "$status" -ne 0 ]
}

@test "backup::delete - fails for non-existent backup" {
  run backup::delete "does-not-exist"
  [ "$status" -ne 0 ]
}

@test "backup::delete - removes both tar.gz and metadata" {
  create_mock_backup "delete-test"

  local backup_dir
  backup_dir="$(backup::dir)"

  # Verify files exist before delete
  [ -f "${backup_dir}/delete-test.tar.gz" ]
  [ -f "${backup_dir}/delete-test.metadata.json" ]

  backup::delete "delete-test"

  # Verify files are gone
  [ ! -f "${backup_dir}/delete-test.tar.gz" ]
  [ ! -f "${backup_dir}/delete-test.metadata.json" ]
}

@test "backup::delete - removes encrypted backup and metadata" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  printf 'encrypted payload\n' > "${backup_dir}/enc-delete.tar.gz.enc"
  jq -n '{name:"enc-delete",hash:"dummy",encrypted:true}' > "${backup_dir}/enc-delete.metadata.json"

  run backup::delete "enc-delete"
  [ "$status" -eq 0 ]
  [ ! -f "${backup_dir}/enc-delete.tar.gz.enc" ]
  [ ! -f "${backup_dir}/enc-delete.metadata.json" ]
}

@test "backup::delete - succeeds if only metadata exists" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  # Only create metadata (no tar.gz)
  echo '{"name":"meta-only"}' > "${backup_dir}/meta-only.metadata.json"

  run backup::delete "meta-only"
  [ "$status" -eq 0 ]
  [ ! -f "${backup_dir}/meta-only.metadata.json" ]
}

@test "backup::delete - succeeds if only tar.gz exists" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  # Only create tar.gz (no metadata)
  echo "content" > "${backup_dir}/tar-only.tar.gz"

  run backup::delete "tar-only"
  [ "$status" -eq 0 ]
  [ ! -f "${backup_dir}/tar-only.tar.gz" ]
}

# =============================================================================
# backup::restore edge cases
# =============================================================================

@test "backup::restore - fails for empty name" {
  run backup::restore ""
  [ "$status" -ne 0 ]
}

@test "backup::restore - fails for non-existent backup" {
  run backup::restore "ghost-backup"
  [ "$status" -ne 0 ]
}

@test "backup::restore - fails when verification fails" {
  local backup_dir
  backup_dir="$(backup::dir)"
  mkdir -p "${backup_dir}"

  echo "content" > "${backup_dir}/bad-restore.tar.gz"
  echo '{"hash":"wronghash"}' > "${backup_dir}/bad-restore.metadata.json"

  run backup::restore "bad-restore"
  [ "$status" -ne 0 ]
}

# =============================================================================
# backup::_cleanup_old edge cases
# =============================================================================

@test "backup::_cleanup_old - keeps backups under retention limit" {
  # Create 5 backups (under default BACKUP_RETENTION of 10)
  for i in {1..5}; do
    create_mock_backup "keep-${i}"
  done

  local backup_dir
  backup_dir="$(backup::dir)"

  local count_before
  count_before=$(find "${backup_dir}" -name "*.tar.gz" | wc -l)
  [[ "${count_before}" -eq 5 ]]

  backup::_cleanup_old

  local count_after
  count_after=$(find "${backup_dir}" -name "*.tar.gz" | wc -l)
  [[ "${count_after}" -eq 5 ]]
}

@test "backup::_cleanup_old - handles empty backup directory" {
  mkdir -p "$(backup::dir)"

  run backup::_cleanup_old
  [ "$status" -eq 0 ]
}

@test "backup::_cleanup_old - handles non-existent directory" {
  rm -rf "$(backup::dir)"

  run backup::_cleanup_old
  [ "$status" -eq 0 ]
}

# =============================================================================
# Integration tests
# =============================================================================

@test "backup integration - full cycle create, verify, list, delete" {
  setup_mock_xray

  # Create
  backup::create "integration-test"

  # Find the exact name (includes timestamp)
  local backup_dir
  backup_dir="$(backup::dir)"
  local backup_name
  backup_name=$(basename "$(find "${backup_dir}" -name "integration-test-*.tar.gz" | head -1)" .tar.gz)

  # Verify
  run backup::verify "${backup_name}"
  [ "$status" -eq 0 ]

  # List
  run backup::list
  [ "$status" -eq 0 ]
  [[ "$output" == *"integration-test"* ]]

  # Delete
  run backup::delete "${backup_name}"
  [ "$status" -eq 0 ]

  # Verify deletion
  run backup::list
  [[ "$output" == *"No backups found"* ]] || [[ "$output" != *"integration-test"* ]]
}
