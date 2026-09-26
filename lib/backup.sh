#!/usr/bin/env bash
# Backup and restore system for Xray configurations
# Provides comprehensive backup, restore, and verification capabilities

# Source guard: prevent double-sourcing
[[ -n "${_XRF_BACKUP_LOADED:-}" ]] && return 0
readonly _XRF_BACKUP_LOADED=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
. "${HERE}/lib/core.sh"
# shellcheck source=modules/io.sh
. "${HERE}/modules/io.sh"
# shellcheck source=modules/state.sh
. "${HERE}/modules/state.sh"
# shellcheck source=services/xray/common.sh
. "${HERE}/services/xray/common.sh"

# Backup retention policy
readonly BACKUP_RETENTION=10 # Keep last 10 backups

##
# Internal: Check if jq is available
#
# Validates that jq is installed and accessible. This is required
# for JSON processing in backup operations.
#
# Returns:
#   0 - jq is available
#   1 - jq is not available (error logged with installation hint)
#
# Example:
#   backup::_require_jq || return 1
##
backup::_require_jq() {
  if ! command -v jq > /dev/null 2>&1; then
    core::log error "jq is required but not installed" '{"hint":"Install with: apt install jq / yum install jq / brew install jq"}'
    return 1
  fi
  return 0
}

##
# Internal: Check if openssl is available
#
# Returns:
#   0 - openssl is available
#   1 - openssl is not available
##
backup::_require_openssl() {
  if ! command -v openssl > /dev/null 2>&1; then
    core::log error "openssl is required for encrypted backups" '{"hint":"Install with: apt install openssl / yum install openssl / brew install openssl"}'
    return 1
  fi
  return 0
}

##
# Internal: Validate encryption password strength
#
# Arguments:
#   $1 - Password (required)
#
# Returns:
#   0 - Password is valid
#   1 - Password is invalid
##
backup::_validate_password() {
  local password="${1:-}"
  if [[ -z "${password}" || "${#password}" -lt 32 ]]; then
    core::log error "encryption password must be at least 32 characters" '{}'
    return 1
  fi
  return 0
}

##
# Internal: Generate random encryption password
#
# Output:
#   Generated password to stdout
#
# Returns:
#   0 - Password generated
#   1 - Failed to generate
##
backup::_generate_password() {
  backup::_require_openssl || return 1
  openssl rand -base64 48 | tr -d '\r\n'
}

##
# Internal: Resolve backup archive file path and encryption flag
#
# Arguments:
#   $1 - Backup name (required)
#
# Output:
#   "<archive_path>\t<encrypted_flag>"
#
# Returns:
#   0 - Archive found
#   1 - Archive not found
##
backup::_resolve_archive() {
  local name="${1:?backup name required}"
  local backup_dir plain_file enc_file
  backup_dir="$(backup::dir)"
  plain_file="${backup_dir}/${name}.tar.gz"
  enc_file="${backup_dir}/${name}.tar.gz.enc"

  if [[ -f "${plain_file}" ]]; then
    printf '%s\tfalse\n' "${plain_file}"
    return 0
  fi
  if [[ -f "${enc_file}" ]]; then
    printf '%s\ttrue\n' "${enc_file}"
    return 0
  fi
  return 1
}

##
# Get backup directory path
#
# Returns the backup storage directory path, respecting XRF_VAR override.
#
# Arguments:
#   None
#
# Output:
#   Backup directory path to stdout
#
# Returns:
#   0 - Always succeeds
#
# Example:
#   backup::dir
##
backup::dir() {
  echo "${XRF_VAR:-/var/lib/xray-fusion}/backups"
}

##
# Create a configuration backup
#
# Creates a tar.gz archive containing:
# - Xray configuration directory (/usr/local/etc/xray/)
# - State file (state.json)
# - Backup metadata (metadata.json)
#
# Arguments:
#   $1 - Backup name (optional, default: auto-generated timestamp)
#
# Output:
#   Backup creation confirmation to stderr (via core::log)
#
# Returns:
#   0 - Backup created successfully
#   1 - Backup creation failed
#
# Security:
#   Creates backup with restricted permissions (0600)
#   Validates backup integrity with SHA256 hash
#
# Example:
#   backup::create "pre-upgrade"
#   backup::create  # Auto-generated name
##
backup::create() {
  local name="${1:-}" encrypt="${2:-false}" password="${3:-}"
  backup::_require_jq || return 1
  # shellcheck disable=SC2034 # Read by commands/backup.sh after the locked call.
  BACKUP_LAST_PASSWORD=""
  if [[ "${encrypt}" == true && -z "${password}" ]]; then
    password="$(backup::_generate_password)" || return 1
    backup::_validate_password "${password}" || return 1
    # shellcheck disable=SC2034 # Read by commands/backup.sh.
    BACKUP_LAST_PASSWORD="${password}"
  fi
  core::with_flock "$(state::lock)" backup::_create_locked "${name}" "${encrypt}" "${password}"
}

backup::_create_locked() {
  # Check jq dependency
  backup::_require_jq || return 1

  local name="${1:-}"
  local encrypt="${2:-false}"
  local password="${3:-}"
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  if [[ "${encrypt}" != "true" && "${encrypt}" != "false" ]]; then
    core::log error "invalid encrypt flag" "$(printf '{"encrypt":"%s"}' "${encrypt}")"
    return 1
  fi

  # Generate backup name if not provided
  if [[ -z "${name}" ]]; then
    name="backup-${timestamp}"
  else
    # Sanitize name (allow alphanumeric, dash, underscore)
    name=$(echo "${name}" | tr -cd '[:alnum:]-_')
    name="${name}-${timestamp}"
  fi

  local backup_dir
  backup_dir="$(backup::dir)"
  io::ensure_dir "${backup_dir}" 0700 || return 1
  chmod 0700 "${backup_dir}" || return 1

  local backup_file="${backup_dir}/${name}.tar.gz"
  local metadata_file="${backup_dir}/${name}.metadata.json"

  core::log info "creating backup" "$(printf '{"name":"%s","file":"%s"}' "${name}" "${backup_file}")"

  local encrypted=false
  if [[ "${encrypt}" == "true" ]]; then
    backup::_require_openssl || return 1
    if [[ -n "${password}" ]]; then
      backup::_validate_password "${password}" || return 1
    else
      core::log error "encryption password required" '{}'
      return 1
    fi
  fi

  # A backup must contain both credential state and the matching config stamp.
  local state_file digest_file
  state_file="$(state::path)"
  digest_file="$(state::digest)"
  if [[ ! -f "${state_file}" || -L "${state_file}" || ! -f "${digest_file}" || -L "${digest_file}" ]]; then
    core::log error "managed state or config digest missing; refusing incomplete backup" '{}'
    return 1
  fi

  # Load current state
  local state
  state=$(cat "${state_file}") || return 1
  if ! jq -e '.name == "reality-only"' <<< "${state}" > /dev/null 2>&1; then
    core::log error "managed REALITY state is invalid" '{}'
    return 1
  fi

  # Extract metadata from state
  local topology version
  topology=$(echo "${state}" | jq -r '.name // "unknown"')
  version=$(echo "${state}" | jq -r '.version // "unknown"')

  # Create temporary directory for backup staging
  # Use hidden prefix to avoid conflicts if cleanup fails (CWE-362)
  local tmpdir
  tmpdir=$(mktemp -d -t .xray-backup.XXXXXX) || return 1

  # Copy configuration files
  local xray_etc
  xray_etc="$(xray::confbase)"

  if [[ ! -d "${xray_etc}" ]]; then
    core::log error "xray configuration directory not found" "$(printf '{"path":"%s"}' "${xray_etc}")"
    rm -rf "${tmpdir}" 2> /dev/null || true
    return 1
  fi

  # Copy xray configuration
  if ! cp -a "${xray_etc}" "${tmpdir}/xray" 2> /dev/null; then
    core::log error "failed to copy xray configuration" "{}"
    rm -rf "${tmpdir}" 2> /dev/null || true
    return 1
  fi

  # Copy state file
  if ! cp -p "${state_file}" "${tmpdir}/state.json" 2> /dev/null; then
    core::log error "failed to copy state file" "$(printf '{"file":"%s"}' "${state_file}")"
    rm -rf "${tmpdir}" 2> /dev/null || true
    return 1
  fi
  if ! cp -p "${digest_file}" "${tmpdir}/config.sha256" 2> /dev/null; then
    core::log error "failed to copy configuration digest" '{}'
    rm -rf "${tmpdir}" 2> /dev/null || true
    return 1
  fi

  # Create tar.gz archive
  if ! tar -czf "${backup_file}" -C "${tmpdir}" . 2> /dev/null; then
    core::log error "failed to create backup archive" "$(printf '{"file":"%s"}' "${backup_file}")"
    rm -rf "${tmpdir}" 2> /dev/null || true
    return 1
  fi

  # Cleanup temporary directory (archive created successfully)
  rm -rf "${tmpdir}" 2> /dev/null || true

  if [[ "${encrypt}" == "true" ]]; then
    local encrypted_file="${backup_file}.enc"
    if ! openssl enc -aes-256-cbc -pbkdf2 -salt -in "${backup_file}" -out "${encrypted_file}" -pass "pass:${password}" 2> /dev/null; then
      core::log error "failed to encrypt backup archive" "$(printf '{"file":"%s"}' "${backup_file}")"
      rm -f "${backup_file}" "${encrypted_file}" 2> /dev/null || true
      return 1
    fi
    if ! rm -f "${backup_file}" 2> /dev/null; then
      core::log error "failed to remove unencrypted staging archive" '{}'
      rm -f "${encrypted_file}" 2> /dev/null || true
      return 1
    fi
    backup_file="${encrypted_file}"
    encrypted=true
  fi

  # Set restrictive permissions
  if ! chmod 0600 "${backup_file}" 2> /dev/null; then
    core::log error "failed to restrict backup archive permissions" '{}'
    rm -f "${backup_file}" "${metadata_file}" 2> /dev/null || true
    return 1
  fi

  # Calculate backup hash
  local backup_hash
  if ! backup_hash=$(sha256sum "${backup_file}" | awk '{print $1}'); then
    core::log error "failed to hash backup archive" '{}'
    rm -f "${backup_file}" "${metadata_file}" 2> /dev/null || true
    return 1
  fi

  # Create metadata
  local backup_size
  backup_size=$(stat -f%z "${backup_file}" 2> /dev/null || stat -c%s "${backup_file}" 2> /dev/null || echo "0")

  if ! jq -n \
    --arg name "${name}" \
    --arg ts "${timestamp}" \
    --arg topology "${topology}" \
    --arg version "${version}" \
    --arg hash "${backup_hash}" \
    --arg size "${backup_size}" \
    --arg file "${backup_file}" \
    --argjson encrypted "${encrypted}" \
    '{
      name: $name,
      timestamp: $ts,
      topology: $topology,
      xray_version: $version,
      hash: $hash,
      size: ($size | tonumber),
      file: $file,
      encrypted: $encrypted,
      created_at: (now | todate)
    }' > "${metadata_file}"; then
    core::log error "failed to write backup metadata" '{}'
    rm -f "${backup_file}" "${metadata_file}" 2> /dev/null || true
    return 1
  fi

  if ! chmod 0600 "${metadata_file}" 2> /dev/null; then
    core::log error "failed to restrict backup metadata permissions" '{}'
    rm -f "${backup_file}" "${metadata_file}" 2> /dev/null || true
    return 1
  fi

  core::log info "backup created successfully" "$(printf '{"name":"%s","size":"%s bytes","hash":"%s"}' "${name}" "${backup_size}" "${backup_hash:0:8}")"

  # Cleanup old backups (retention policy)
  backup::_cleanup_old

  return 0
}

##
# List available backups
#
# Lists all available backups with metadata.
# Supports both text and JSON output formats.
#
# Arguments:
#   None
#
# Globals:
#   XRF_JSON - If "true", output JSON format
#
# Output:
#   Backup list to stdout (text or JSON format)
#
# Returns:
#   0 - Success
#
# Example:
#   backup::list
#   XRF_JSON=true backup::list
##
backup::list() {
  # Check jq dependency (needed for parsing metadata)
  backup::_require_jq || return 1

  local backup_dir
  backup_dir="$(backup::dir)"

  if [[ ! -d "${backup_dir}" ]]; then
    core::log info "no backups found" "$(printf '{"dir":"%s"}' "$(core::json_escape "${backup_dir}")")"
    return 0
  fi

  # Find all metadata files
  local metadata_files=()
  while IFS= read -r file; do
    metadata_files+=("${file}")
  done < <(find "${backup_dir}" -name "*.metadata.json" -type f 2> /dev/null | sort -r)

  if [[ "${#metadata_files[@]}" -eq 0 ]]; then
    if [[ "${XRF_JSON}" == "true" ]]; then
      printf '{"backups":[]}\n'
    else
      printf '\nNo backups found.\n\n'
    fi
    return 0
  fi

  # shellcheck disable=SC2154  # XRF_JSON is set by core::init
  if [[ "${XRF_JSON}" == "true" ]]; then
    # JSON format
    printf '{\n  "backups": [\n'
    local first=1
    for meta_file in "${metadata_files[@]}"; do
      if [[ -f "${meta_file}" ]]; then
        [[ "${first}" -eq 0 ]] && printf ',\n'
        printf '    %s' "$(cat "${meta_file}")"
        first=0
      fi
    done
    printf '\n  ]\n}\n'
  else
    # Text format
    printf '\nAvailable Backups:\n\n'

    for meta_file in "${metadata_files[@]}"; do
      if [[ ! -f "${meta_file}" ]]; then
        continue
      fi

      local metadata
      metadata=$(cat "${meta_file}")

      local name timestamp topology size
      name=$(echo "${metadata}" | jq -r '.name')
      timestamp=$(echo "${metadata}" | jq -r '.timestamp')
      topology=$(echo "${metadata}" | jq -r '.topology')
      size=$(echo "${metadata}" | jq -r '.size')

      # Convert size to human-readable format
      local size_hr
      if [[ "${size}" -gt 1048576 ]]; then
        size_hr=$(awk "BEGIN {printf \"%.1f MB\", ${size}/1048576}")
      elif [[ "${size}" -gt 1024 ]]; then
        size_hr=$(awk "BEGIN {printf \"%.1f KB\", ${size}/1024}")
      else
        size_hr="${size} B"
      fi

      printf '  [%s]\n' "${name}"
      printf '    Created:  %s\n' "${timestamp}"
      printf '    Topology: %s\n' "${topology}"
      printf '    Size:     %s\n' "${size_hr}"
      printf '\n'
    done
  fi
}

##
# Restore from backup
#
# Restores Xray configuration from a backup archive.
# Includes verification of backup integrity before restoration.
#
# Arguments:
#   $1 - Backup name (required)
#
# Output:
#   Restoration progress to stderr (via core::log)
#
# Returns:
#   0 - Restoration successful
#   1 - Restoration failed (backup not found, verification failed, etc.)
#
# Security:
#   Verifies backup integrity with SHA256 hash before restoration
#   Creates automatic backup before restore (rollback capability)
#
# Example:
#   backup::restore "pre-upgrade-20231201-120000"
##
backup::_restore_rollback() {
  local recovery="${1}" xray_etc="${2}" was_active="${3}" old_moved="${4}"
  local had_state="${5}" had_digest="${6}"
  local failed=false config_ok=true

  if [[ "${old_moved}" == true ]]; then
    if [[ -e "${xray_etc}" || -L "${xray_etc}" ]]; then
      rm -rf "${xray_etc}" || {
        failed=true
        config_ok=false
      }
    fi
    if [[ "${config_ok}" == true ]]; then
      mv "${recovery}/old" "${xray_etc}" || {
        failed=true
        config_ok=false
      }
    fi
  fi
  if [[ "${had_state}" == true ]]; then
    cp -p "${recovery}/state.json" "$(state::path)" || failed=true
  else
    rm -f "$(state::path)" || failed=true
  fi
  if [[ "${had_digest}" == true ]]; then
    cp -p "${recovery}/config.sha256" "$(state::digest)" || failed=true
  else
    rm -f "$(state::digest)" || failed=true
  fi
  if [[ "${config_ok}" == true ]]; then
    if [[ "${was_active}" == true ]]; then
      systemctl start xray.service && systemctl is-active --quiet xray.service || failed=true
    elif systemctl is-active --quiet xray.service 2> /dev/null; then
      systemctl stop xray.service || failed=true
    fi
  fi

  if [[ "${failed}" == true ]]; then
    core::log error "restore rollback incomplete; recovery retained" "$(printf '{"path":"%s"}' "${recovery}")"
    return 1
  fi
  rm -rf "${recovery}" || return 1
  core::log warn "restore rolled back" '{}'
}

backup::_restore_locked() {
  local name="${1:?backup name required}" password="${2:-}"
  local backup_dir backup_file metadata_file encrypted=false resolved
  backup_dir="$(backup::dir)"
  if ! resolved="$(backup::_resolve_archive "${name}")"; then
    core::log error "backup not found" "$(printf '{"name":"%s"}' "${name}")"
    return 1
  fi
  IFS=$'\t' read -r backup_file encrypted <<< "${resolved}"
  metadata_file="${backup_dir}/${name}.metadata.json"
  [[ -f "${metadata_file}" ]] || {
    core::log error "backup metadata not found" "$(printf '{"name":"%s"}' "${name}")"
    return 1
  }
  backup::verify "${name}" || return 1

  local xray_etc recovery candidate archive_to_extract target relative release
  xray_etc="$(xray::confbase)"
  if [[ ! -L "${xray_etc}/active" || ! -x "$(xray::bin)" ]]; then
    core::log error "current managed installation is incomplete; refusing restore" '{}'
    return 1
  fi
  recovery="$(mktemp -d "$(dirname "${xray_etc}")/.xray-restore.XXXXXX")" || return 1
  chmod 0700 "${recovery}" || return 1
  candidate="${recovery}/candidate"
  mkdir -m 0700 "${candidate}" || return 1
  archive_to_extract="${backup_file}"
  if [[ "${encrypted}" == true ]]; then
    backup::_require_openssl || {
      rm -rf "${recovery}"
      return 1
    }
    if [[ -z "${password}" ]]; then
      if [[ -t 0 ]]; then
        read -rsp "Encryption password: " password
        printf '\n'
      else
        core::log error "password required for encrypted backup restore" '{}'
        rm -rf "${recovery}"
        return 1
      fi
    fi
    backup::_validate_password "${password}" || {
      rm -rf "${recovery}"
      return 1
    }
    archive_to_extract="${recovery}/decrypted.tar.gz"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -in "${backup_file}" -out "${archive_to_extract}" -pass "pass:${password}" 2> /dev/null; then
      core::log error "failed to decrypt backup archive" '{}'
      rm -rf "${recovery}"
      return 1
    fi
  fi
  if ! tar -xzf "${archive_to_extract}" -C "${candidate}" 2> /dev/null; then
    core::log error "failed to extract backup" '{}'
    rm -rf "${recovery}"
    return 1
  fi

  # The archive's active symlink is absolute. Test its archived release, never
  # the live release that the symlink still names before installation.
  target="$(readlink "${candidate}/xray/active" 2> /dev/null || true)"
  relative="${target#"${xray_etc}/"}"
  if [[ "${target}" != "${xray_etc}/"* || ! "${relative}" =~ ^releases/[0-9]{14}$ ]]; then
    core::log error "backup does not contain a current managed active release" '{}'
    rm -rf "${recovery}"
    return 1
  fi
  release="${candidate}/xray/${relative}"
  # Only the active pointer may be a symlink. Every directory and config file
  # that Xray reads must be a physical member of the extracted archive.
  local linked=""
  if [[ ! -d "${candidate}/xray" || -L "${candidate}/xray" ||
    ! -d "${candidate}/xray/releases" || -L "${candidate}/xray/releases" ||
    ! -d "${release}" || -L "${release}" ]] \
    || ! linked="$(find "${candidate}/xray/releases" -type l -print -quit)" \
    || [[ -n "${linked}" || ! -f "${candidate}/state.json" || -L "${candidate}/state.json" ||
      ! -f "${candidate}/config.sha256" || -L "${candidate}/config.sha256" ]] \
    || ! jq -e '.name == "reality-only"' "${candidate}/state.json" > /dev/null 2>&1 \
    || ! "$(xray::bin)" -test -confdir "${release}" -format json > /dev/null 2>&1; then
    core::log error "backup candidate configuration is invalid" '{}'
    rm -rf "${recovery}"
    return 1
  fi

  # A pre-restore archive is required; failure must leave the live service alone.
  if ! backup::_create_locked "pre-restore-${name}"; then
    core::log error "pre-restore backup failed" '{}'
    rm -rf "${recovery}"
    return 1
  fi
  local had_state=false had_digest=false was_active=false old_moved=false
  if [[ -f "$(state::path)" ]]; then
    had_state=true
    cp -p "$(state::path)" "${recovery}/state.json" || {
      rm -rf "${recovery}"
      return 1
    }
  fi
  if [[ -f "$(state::digest)" ]]; then
    had_digest=true
    cp -p "$(state::digest)" "${recovery}/config.sha256" || {
      rm -rf "${recovery}"
      return 1
    }
  fi
  local active_state
  if ! active_state="$(systemctl show --property=ActiveState --value xray.service)"; then
    core::log error "failed to query xray service state" '{}'
    rm -rf "${recovery}"
    return 1
  fi
  case "${active_state}" in
    active)
      was_active=true
      if ! systemctl stop xray.service; then
        core::log error "failed to stop xray service" '{}'
        backup::_restore_rollback "${recovery}" "${xray_etc}" "${was_active}" false "${had_state}" "${had_digest}" || return 1
        return 1
      fi
      ;;
    inactive | failed) ;;
    *)
      core::log error "unknown xray service state" "$(printf '{"state":"%s"}' "${active_state}")"
      rm -rf "${recovery}"
      return 1
      ;;
  esac

  if ! mv "${xray_etc}" "${recovery}/old"; then
    core::log error "failed to preserve current configuration" '{}'
    backup::_restore_rollback "${recovery}" "${xray_etc}" "${was_active}" false "${had_state}" "${had_digest}" || return 1
    return 1
  fi
  old_moved=true
  local failed=false
  if ! cp -a "${candidate}/xray" "${xray_etc}"; then
    failed=true
  elif ! state::save "$(cat "${candidate}/state.json")"; then
    failed=true
  elif ! cp -p "${candidate}/config.sha256" "$(state::digest)"; then
    failed=true
  elif [[ "${was_active}" == true ]] && ! systemctl start xray.service; then
    failed=true
  elif [[ "${was_active}" == true ]] && ! systemctl is-active --quiet xray.service; then
    failed=true
  fi
  if [[ "${failed}" == true ]]; then
    core::log error "restore failed; restoring previous installation" '{}'
    backup::_restore_rollback "${recovery}" "${xray_etc}" "${was_active}" "${old_moved}" "${had_state}" "${had_digest}" || return 1
    return 1
  fi

  rm -rf "${recovery}" || {
    core::log error "restored but failed to remove recovery directory" "$(printf '{"path":"%s"}' "${recovery}")"
    return 1
  }
  core::log info "restoration completed successfully" "$(printf '{"backup":"%s"}' "${name}")"
}

backup::restore() {
  local name="${1:?backup name required}"
  core::with_flock "$(state::lock)" backup::_restore_locked "${name}" "${2:-}"
}

##
# Delete a backup
#
# Removes a backup archive and its metadata file.
#
# Arguments:
#   $1 - Backup name (required)
#
# Output:
#   Deletion confirmation to stderr (via core::log)
#
# Returns:
#   0 - Backup deleted successfully
#   1 - Backup not found or deletion failed
#
# Example:
#   backup::delete "old-backup-20231101-100000"
##
backup::delete() {
  local name="${1:?backup name required}"

  local backup_dir
  backup_dir="$(backup::dir)"

  local backup_file backup_enc_file metadata_file
  backup_file="${backup_dir}/${name}.tar.gz"
  backup_enc_file="${backup_dir}/${name}.tar.gz.enc"
  metadata_file="${backup_dir}/${name}.metadata.json"

  if [[ ! -f "${backup_file}" && ! -f "${backup_enc_file}" && ! -f "${metadata_file}" ]]; then
    core::log error "backup not found" "$(printf '{"name":"%s"}' "${name}")"
    return 1
  fi

  core::log info "deleting backup" "$(printf '{"name":"%s"}' "${name}")"

  # Delete backup file
  if [[ -f "${backup_file}" ]]; then
    rm -f "${backup_file}" 2> /dev/null || {
      core::log error "failed to delete backup file" "$(printf '{"file":"%s"}' "${backup_file}")"
      return 1
    }
  fi

  # Delete encrypted backup file
  if [[ -f "${backup_enc_file}" ]]; then
    rm -f "${backup_enc_file}" 2> /dev/null || {
      core::log error "failed to delete encrypted backup file" "$(printf '{"file":"%s"}' "${backup_enc_file}")"
      return 1
    }
  fi

  # Delete metadata file
  if [[ -f "${metadata_file}" ]]; then
    rm -f "${metadata_file}" 2> /dev/null || {
      core::log warn "failed to delete metadata file" "$(printf '{"file":"%s"}' "${metadata_file}")"
    }
  fi

  core::log info "backup deleted" "$(printf '{"name":"%s"}' "${name}")"
  return 0
}

##
# Verify backup integrity
#
# Verifies backup integrity by comparing stored SHA256 hash
# with actual file hash.
#
# Arguments:
#   $1 - Backup name (required)
#
# Output:
#   Verification result to stderr (via core::log)
#
# Returns:
#   0 - Backup is valid
#   1 - Backup is corrupted or metadata missing
#
# Example:
#   backup::verify "backup-20231201-120000"
##
backup::verify() {
  # Check jq dependency
  backup::_require_jq || return 1

  local name="${1:?backup name required}"

  local backup_dir
  backup_dir="$(backup::dir)"

  local backup_file metadata_file resolved _encrypted
  if ! resolved="$(backup::_resolve_archive "${name}")"; then
    core::log error "backup file not found" "$(printf '{"name":"%s"}' "${name}")"
    return 1
  fi
  IFS=$'\t' read -r backup_file _encrypted <<< "${resolved}"
  metadata_file="${backup_dir}/${name}.metadata.json"

  if [[ ! -f "${metadata_file}" ]]; then
    core::log error "metadata file not found" "$(printf '{"name":"%s"}' "${name}")"
    return 1
  fi

  core::log debug "verifying backup integrity" "$(printf '{"name":"%s"}' "${name}")"

  # Read stored hash from metadata
  local stored_hash
  stored_hash=$(jq -r '.hash' "${metadata_file}")

  if [[ -z "${stored_hash}" || "${stored_hash}" == "null" ]]; then
    core::log error "hash not found in metadata" "$(printf '{"name":"%s"}' "${name}")"
    return 1
  fi

  # Calculate actual hash
  local actual_hash
  actual_hash=$(sha256sum "${backup_file}" | awk '{print $1}')

  # Compare hashes
  if [[ "${stored_hash}" != "${actual_hash}" ]]; then
    core::log error "backup integrity check failed" "$(printf '{"name":"%s","expected":"%s","actual":"%s"}' "${name}" "${stored_hash:0:8}" "${actual_hash:0:8}")"
    return 1
  fi

  core::log debug "backup integrity verified" "$(printf '{"name":"%s","hash":"%s"}' "${name}" "${actual_hash:0:8}")"
  return 0
}

##
# Internal function: Cleanup old backups
#
# Implements backup retention policy by deleting oldest backups
# when count exceeds BACKUP_RETENTION limit.
#
# Arguments:
#   None
#
# Globals:
#   BACKUP_RETENTION - Maximum number of backups to keep
#
# Returns:
#   0 - Always succeeds
##
backup::_cleanup_old() {
  local backup_dir
  backup_dir="$(backup::dir)"

  # Find all backup files, sorted by modification time (oldest first)
  local backup_files=()
  while IFS= read -r file; do
    backup_files+=("${file}")
  done < <(find "${backup_dir}" \( -name "*.tar.gz" -o -name "*.tar.gz.enc" \) -type f 2> /dev/null | sort)

  local count="${#backup_files[@]}"

  if [[ "${count}" -le "${BACKUP_RETENTION}" ]]; then
    return 0
  fi

  core::log debug "cleaning up old backups" "$(printf '{"count":%d,"retention":%d}' "${count}" "${BACKUP_RETENTION}")"

  # Delete oldest backups
  local to_delete=$((count - BACKUP_RETENTION))
  for ((i = 0; i < to_delete; i++)); do
    local backup_file="${backup_files[i]}"
    local backup_name
    if [[ "${backup_file}" == *.tar.gz.enc ]]; then
      backup_name=$(basename "${backup_file}" .tar.gz.enc)
    else
      backup_name=$(basename "${backup_file}" .tar.gz)
    fi

    core::log debug "deleting old backup" "$(printf '{"name":"%s"}' "${backup_name}")"
    backup::delete "${backup_name}" > /dev/null 2>&1 || true
  done

  return 0
}
