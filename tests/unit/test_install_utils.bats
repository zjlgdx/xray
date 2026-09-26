#!/usr/bin/env bats
# Unit tests for Xray installation utilities (services/xray/install_utils.sh)

load ../test_helper

setup() {
  setup_test_env
  # Source install utilities
  source "${PROJECT_ROOT}/services/xray/common.sh"
  source "${PROJECT_ROOT}/services/xray/install_utils.sh"
}

teardown() {
  cleanup_test_env
}

# Test: xray::extract_sha256_from_dgst
@test "xray::extract_sha256_from_dgst - labeled format (SHA256 = hash)" {
  local dgst_content="SHA256 (Xray-linux-64.zip) = abc123def456789012345678901234567890123456789012345678901234abcd"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ "$output" == "abc123def456789012345678901234567890123456789012345678901234abcd" ]]
}

@test "xray::extract_sha256_from_dgst - labeled format compact (SHA256=hash)" {
  local dgst_content="SHA256(Xray-linux-64.zip)=1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ "$output" == "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef" ]]
}

@test "xray::extract_sha256_from_dgst - SHA2-256 format (Xray v25.10.15+)" {
  # Regression test: Xray v25.10.15+ uses SHA2-256= instead of SHA256=
  # Real-world format from https://github.com/XTLS/Xray-core/releases
  local dgst_content="MD5= 91f998f23bddb85d15cbf8d2f969fa7b
SHA1= 90d8e336e4e3ca6161c82b89be23f88bf73eacd0
SHA2-256= df22ad60c1251c9fb63d7f85b3677872edf61c6715eba64b06adbfec658f4938
SHA2-512= 403fe28e933ce1916ea989b0e8fa7e5641648390daaa5d320ee79a94aac4bfabc9e9f9c790e4de9cca5fb76bc84630a0bb95896f62b301444c26a0d9cf509267"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ "$output" == "df22ad60c1251c9fb63d7f85b3677872edf61c6715eba64b06adbfec658f4938" ]]
}

@test "xray::extract_sha256_from_dgst - plain format (hash  filename)" {
  local dgst_content="fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321  Xray-linux-64.zip"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ "$output" == "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321" ]]
}

@test "xray::extract_sha256_from_dgst - plain format (hash only at line start)" {
  local dgst_content="1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ "$output" == "1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff" ]]
}

@test "xray::extract_sha256_from_dgst - SHA512 before SHA256 (regression test)" {
  # This is the critical bug scenario: .dgst with both SHA512 and SHA256
  # SHA512 comes first (128 chars), SHA256 comes second (64 chars)
  # Must NOT extract first 64 chars of SHA512
  local dgst_content="SHA512 (Xray-linux-64.zip) = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1111111111111111111111111111111111111111111111111111111111111111
SHA256 (Xray-linux-64.zip) = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  # Must extract SHA256, NOT first 64 chars of SHA512
  [[ "$output" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]]
  [[ "$output" != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
}

@test "xray::extract_sha256_from_dgst - multiple files with SHA256" {
  # Real-world scenario: .dgst with multiple files
  local dgst_content="SHA256 (Xray-linux-32.zip) = 1111111111111111111111111111111111111111111111111111111111111111
SHA256 (Xray-linux-64.zip) = 2222222222222222222222222222222222222222222222222222222222222222
SHA256 (Xray-linux-arm64.zip) = 3333333333333333333333333333333333333333333333333333333333333333"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  # Should extract first match (head -1)
  [[ "$output" == "1111111111111111111111111111111111111111111111111111111111111111" ]]
}

@test "xray::extract_sha256_from_dgst - case insensitive SHA256 label" {
  local dgst_content="sha256 (Xray-linux-64.zip) = abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ "$output" == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" ]]
}

@test "xray::extract_sha256_from_dgst - empty input" {
  run xray::extract_sha256_from_dgst ""
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "xray::extract_sha256_from_dgst - no SHA256 found (only SHA512)" {
  local dgst_content="SHA512 (file) = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1111111111111111111111111111111111111111111111111111111111111111"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "xray::extract_sha256_from_dgst - invalid format (no hash)" {
  local dgst_content="SHA256 (file) = invalid"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "xray::extract_sha256_from_dgst - hash in middle of line (should not match)" {
  local dgst_content="Some text 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef more text"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  # Plain format requires hash at line start, so this should not match
  [[ -z "$output" ]]
}

@test "xray::extract_sha256_from_dgst - mixed format (labeled takes priority)" {
  # Both labeled and plain format present, labeled should take priority
  local dgst_content="0000000000000000000000000000000000000000000000000000000000000000  file1.zip
SHA256 (file2.zip) = 1111111111111111111111111111111111111111111111111111111111111111"

  run xray::extract_sha256_from_dgst "${dgst_content}"
  [ "$status" -eq 0 ]
  # Labeled format takes priority
  [[ "$output" == "1111111111111111111111111111111111111111111111111111111111111111" ]]
}

# Test: xray::validate_sha256_format
@test "xray::validate_sha256_format - valid lowercase hash" {
  run xray::validate_sha256_format "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  [ "$status" -eq 0 ]
}

@test "xray::validate_sha256_format - valid uppercase hash" {
  run xray::validate_sha256_format "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
  [ "$status" -eq 0 ]
}

@test "xray::validate_sha256_format - valid mixed case hash" {
  run xray::validate_sha256_format "AbCdEf0123456789aBcDeF0123456789AbCdEf0123456789aBcDeF0123456789"
  [ "$status" -eq 0 ]
}

@test "xray::validate_sha256_format - invalid too short" {
  run xray::validate_sha256_format "abcdef012345678"
  [ "$status" -eq 1 ]
}

@test "xray::validate_sha256_format - invalid too long" {
  run xray::validate_sha256_format "abcdef0123456789abcdef0123456789abcdef0123456789abcdef012345678900"
  [ "$status" -eq 1 ]
}

@test "xray::validate_sha256_format - invalid non-hex characters" {
  run xray::validate_sha256_format "ghijkl0123456789ghijkl0123456789ghijkl0123456789ghijkl0123456789"
  [ "$status" -eq 1 ]
}

@test "xray::validate_sha256_format - invalid empty string" {
  run xray::validate_sha256_format ""
  [ "$status" -eq 1 ]
}

@test "xray::validate_sha256_format - invalid with spaces" {
  run xray::validate_sha256_format "abcdef01 23456789abcdef0123456789abcdef0123456789abcdef0123456789"
  [ "$status" -eq 1 ]
}

# Test: xray::verify_file_checksum
@test "xray::verify_file_checksum - matching checksum" {
  local test_file="${TEST_TMPDIR}/test_file.txt"
  echo "test content" > "${test_file}"

  # Compute expected SHA256
  local expected_sha
  expected_sha="$(sha256sum "${test_file}" | awk '{print $1}')"

  run xray::verify_file_checksum "${test_file}" "${expected_sha}"
  [ "$status" -eq 0 ]
}

@test "xray::verify_file_checksum - mismatched checksum" {
  local test_file="${TEST_TMPDIR}/test_file.txt"
  echo "test content" > "${test_file}"

  local wrong_sha="0000000000000000000000000000000000000000000000000000000000000000"

  run xray::verify_file_checksum "${test_file}" "${wrong_sha}"
  [ "$status" -eq 1 ]
}

@test "xray::verify_file_checksum - file not found" {
  local nonexistent="${TEST_TMPDIR}/nonexistent.txt"
  local sha="1111111111111111111111111111111111111111111111111111111111111111"

  run xray::verify_file_checksum "${nonexistent}" "${sha}"
  [ "$status" -eq 1 ]
}

@test "xray::verify_file_checksum - empty file" {
  local test_file="${TEST_TMPDIR}/empty.txt"
  touch "${test_file}"

  # SHA256 of empty file
  local expected_sha="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  run xray::verify_file_checksum "${test_file}" "${expected_sha}"
  [ "$status" -eq 0 ]
}

@test "xray::verify_file_checksum - large file" {
  local test_file="${TEST_TMPDIR}/large.txt"
  # Create 1MB file
  dd if=/dev/zero of="${test_file}" bs=1024 count=1024 2>/dev/null

  local expected_sha
  expected_sha="$(sha256sum "${test_file}" | awk '{print $1}')"

  run xray::verify_file_checksum "${test_file}" "${expected_sha}"
  [ "$status" -eq 0 ]
}

# Integration test: Extract and validate workflow
@test "integration - extract from dgst and validate format" {
  local dgst_content="SHA256 (Xray-linux-64.zip) = 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

  local sha
  sha="$(xray::extract_sha256_from_dgst "${dgst_content}")"

  [ -n "${sha}" ]

  run xray::validate_sha256_format "${sha}"
  [ "$status" -eq 0 ]
}

@test "integration - extract, validate, and verify file" {
  local test_file="${TEST_TMPDIR}/test.zip"
  echo "test zip content" > "${test_file}"

  local actual_sha
  actual_sha="$(sha256sum "${test_file}" | awk '{print $1}')"

  # Simulate .dgst file content
  local dgst_content="SHA256 (test.zip) = ${actual_sha}"

  # Extract
  local extracted_sha
  extracted_sha="$(xray::extract_sha256_from_dgst "${dgst_content}")"
  [ -n "${extracted_sha}" ]

  # Validate format
  run xray::validate_sha256_format "${extracted_sha}"
  [ "$status" -eq 0 ]

  # Verify file
  run xray::verify_file_checksum "${test_file}" "${extracted_sha}"
  [ "$status" -eq 0 ]
}

# Test: latest published release tag parsing helpers
@test "xray::extract_latest_tag_from_release_json - selects newest published release including prerelease" {
  local payload='[{"tag_name":"v26.3.27","draft":false,"prerelease":false,"published_at":"2026-03-27T00:00:00Z"},{"tag_name":"v26.9.9","draft":false,"prerelease":true,"published_at":"2026-09-08T22:28:10Z"},{"tag_name":"v26.7.28","draft":false,"prerelease":true,"published_at":"2026-07-28T08:00:45Z"}]'

  run xray::extract_latest_tag_from_release_json "${payload}"
  [ "$status" -eq 0 ]
  [ "$output" = "v26.9.9" ]
}

@test "xray::extract_latest_tag_from_release_json - sorts by publication time, not API order or version" {
  local payload='[{"tag_name":"v99.1.0","draft":false,"published_at":"2026-01-01T00:00:00Z"},{"tag_name":"v1.2.3","draft":false,"published_at":"2026-09-09T00:00:00Z"}]'

  run xray::extract_latest_tag_from_release_json "${payload}"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.2.3" ]
}

@test "xray::extract_latest_tag_from_release_json - ignores drafts and older noncanonical tags" {
  local payload='[{"tag_name":"v99.0.0","draft":true,"published_at":"2026-12-01T00:00:00Z"},{"tag_name":"99.0.0","draft":false,"published_at":"2026-01-01T00:00:00Z"},{"tag_name":"nightly","draft":false,"published_at":"2026-02-01T00:00:00Z"},{"tag_name":"v26.9.9","draft":true,"published_at":null},{"tag_name":"v26.8.1","draft":false,"published_at":"2026-08-01T00:00:00Z"}]'

  run xray::extract_latest_tag_from_release_json "${payload}"
  [ "$status" -eq 0 ]
  [ "$output" = "v26.8.1" ]
}

@test "xray::extract_latest_tag_from_release_json - refuses newer invalid tag instead of old version" {
  local payload='[{"tag_name":"v26.9.9-beta","draft":false,"published_at":"2026-09-09T00:00:00Z"},{"tag_name":"v26.3.27","draft":false,"published_at":"2026-03-27T00:00:00Z"}]'

  run xray::extract_latest_tag_from_release_json "${payload}"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "xray::extract_latest_tag_from_release_json - refuses malformed publication time instead of old version" {
  local payload
  for payload in \
    '[{"tag_name":"v26.9.9","draft":false,"published_at":null},{"tag_name":"v26.3.27","draft":false,"published_at":"2026-03-27T00:00:00Z"}]' \
    '[{"tag_name":"v26.9.9","draft":false,"published_at":"tomorrow"},{"tag_name":"v26.3.27","draft":false,"published_at":"2026-03-27T00:00:00Z"}]'; do
    run xray::extract_latest_tag_from_release_json "${payload}"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "xray::extract_latest_tag_from_release_json - fails closed on empty or invalid API result" {
  local payload
  for payload in '[]' '{}' '{bad json' '[{"tag_name":"v26.9.9","draft":true,"published_at":"2026-09-08T22:28:10Z"}]' '[{"tag_name":"v26.9.9","draft":false,"published_at":"tomorrow"}]'; do
    run xray::extract_latest_tag_from_release_json "${payload}"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "xray::resolve_latest_tag - requests release list and selects published prerelease" {
  export API_REQUEST_FILE="${TEST_TMPDIR}/requested-url"
  core::retry() {
    printf '%s' "$*" > "${API_REQUEST_FILE}"
    printf '%s' '[{"tag_name":"v26.3.27","draft":false,"published_at":"2026-03-27T00:00:00Z"},{"tag_name":"v26.9.9","draft":false,"prerelease":true,"published_at":"2026-09-08T22:28:10Z"}]'
  }

  run xray::resolve_latest_tag
  [ "$status" -eq 0 ]
  [ "$output" = "v26.9.9" ]
  grep -Fq 'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100' "${API_REQUEST_FILE}"
  run grep -q '/releases/latest' "${API_REQUEST_FILE}"
  [ "$status" -ne 0 ]
  unset -f core::retry
}

@test "xray::resolve_latest_tag - fails when API is unavailable or has no usable release" {
  core::retry() { return 22; }
  run xray::resolve_latest_tag
  [ "$status" -ne 0 ]

  core::retry() { printf '%s' '[]'; }
  run xray::resolve_latest_tag
  [ "$status" -ne 0 ]
  unset -f core::retry
}

@test "xray::resolve_latest_tag - searches later pages by publication time" {
  local first_page
  first_page="$(jq -n '[range(0;100) | {tag_name:"v26.9.8",draft:false,published_at:"2026-09-08T09:49:08Z"}]')"
  core::retry() {
    case "$*" in
      *'page=1') printf '%s' "${first_page}" ;;
      *'page=2') printf '%s' '[{"tag_name":"v26.9.9","draft":false,"prerelease":true,"published_at":"2026-09-08T22:28:10Z"}]' ;;
      *) return 1 ;;
    esac
  }

  run xray::resolve_latest_tag
  [ "$status" -eq 0 ]
  [ "$output" = v26.9.9 ]
  unset -f core::retry
}

@test "xray::resolve_latest_tag - fails closed if a later page fails or repeats" {
  local first_page
  first_page="$(jq -n '[range(0;100) | {tag_name:"v26.9.8",draft:false,published_at:"2026-09-08T09:49:08Z"}]')"
  core::retry() {
    [[ "$*" != *'page=2' ]] || return 22
    printf '%s' "${first_page}"
  }
  run xray::resolve_latest_tag
  [ "$status" -ne 0 ]

  core::retry() { printf '%s' "${first_page}"; }
  run xray::resolve_latest_tag
  [ "$status" -ne 0 ]
  unset -f core::retry
}
