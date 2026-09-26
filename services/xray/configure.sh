#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/lib/errors.sh"
. "${HERE}/lib/validators.sh"
. "${HERE}/lib/config_validation.sh"
. "${HERE}/modules/io.sh"
. "${HERE}/modules/state.sh"
. "${HERE}/services/xray/common.sh"

# Xray configuration file naming constants
# Files are numbered to control load order (Xray loads them alphabetically)
readonly XRAY_CONFIG_00_LOG="00_log.json"             # Logging configuration (loaded first)
readonly XRAY_CONFIG_05_INBOUNDS="05_inbounds.json"   # Inbound connections (VLESS/REALITY/Vision)
readonly XRAY_CONFIG_06_OUTBOUNDS="06_outbounds.json" # Outbound connections (direct/block)
readonly XRAY_CONFIG_07_DNS="07_dns.json"             # DNS strategy (IPv4-only / dual-stack)
readonly XRAY_CONFIG_09_ROUTING="09_routing.json"     # Routing rules (loaded last)

core::log debug "configure.sh started" "$(printf '{"args":"%s"}' "$*")"

# Helper: Sanitize user-derived strings for JSON safety
xray::sanitize_json_string() {
  local value="${1:-}" field="${2:-value}" sanitized

  sanitized="${value//$'\r'/}"
  sanitized="${sanitized//$'\n'/}"

  if [[ "${sanitized}" =~ [\"{}] ]]; then
    core::log error "unsafe characters in input" "$(printf '{"field":"%s"}' "${field}")"
    return "${ERR_INVALID_ARG}"
  fi

  printf '%s' "${sanitized}"
}

# Helper: Convert CSV to sanitized JSON array
json_array_from_csv() {
  local csv="${1}" field="${2:-value}" first_ref_name="${3:-}"
  local IFS=',' raw_items=() sanitized_items=()
  read -ra raw_items <<< "${csv}"

  local item trimmed sanitized first_assigned="false"
  for item in "${raw_items[@]}"; do
    IFS=$' \t\n' read -r trimmed <<< "${item}"
    [[ -z "${trimmed}" ]] && continue
    if ! validators::hostname "${trimmed}"; then
      core::log error "invalid host entry" "$(printf '{"field":"%s","value":"%s"}' "${field}" "${trimmed//\"/\\\\\"}")"
      return "${ERR_INVALID_ARG}"
    fi
    if ! sanitized="$(xray::sanitize_json_string "${trimmed}" "${field}")"; then
      return "${ERR_INVALID_ARG}"
    fi
    if [[ -n "${first_ref_name}" && "${first_assigned}" == "false" ]]; then
      printf -v "${first_ref_name}" '%s' "${sanitized}"
      first_assigned="true"
    fi
    sanitized_items+=("${sanitized}")
  done

  if [[ "${#sanitized_items[@]}" -eq 0 ]]; then
    printf '[]'
    return 0
  fi

  printf '%s\n' "${sanitized_items[@]}" | jq -R . | jq -s .
}

# Helper: Ensure reality destination format (hostname:port)
ensure_reality_dest() {
  local dest="${1}" default_host="${2}"
  IFS=$' \t\n' read -r dest <<< "${dest}"
  [[ -z "${dest}" ]] && dest="${default_host}"

  if [[ -z "${dest}" ]]; then
    core::log error "reality destination required" "{}"
    return "${ERR_INVALID_ARG}"
  fi

  local sanitized
  if ! sanitized="$(xray::sanitize_json_string "${dest}" "XRAY_REALITY_DEST")"; then
    return "${ERR_INVALID_ARG}"
  fi

  local host port
  if [[ "${sanitized}" == *:* ]]; then
    host="${sanitized%%:*}"
    port="${sanitized##*:}"
  else
    host="${sanitized}"
    port="443"
  fi

  if ! validators::hostname "${host}"; then
    core::log error "invalid destination host" "$(printf '{"host":"%s"}' "${host//\"/\\\"}")"
    return "${ERR_INVALID_ARG}"
  fi

  if ! validators::port "${port}"; then
    core::log error "invalid destination port" "$(printf '{"port":"%s"}' "${port}")"
    return "${ERR_INVALID_ARG}"
  fi

  # Warn about Apple/iCloud REALITY destinations (v26.3.27+: risk of IP blocking)
  case "${host,,}" in
    *icloud-content.com | *cdn-apple.com | *mzstatic.com | *icloud.com | *apple.com)
      core::log warn "Apple/iCloud REALITY dest may cause IP blocking (Xray v26.3.27+)" \
        "$(printf '{"host":"%s","suggestion":"Use a non-Apple domain such as www.microsoft.com"}' "${host}")"
      ;;
  esac

  printf '%s:%s' "${host}" "${port}"
}

# Helper: Build shortIds pool array
build_shortids_pool() {
  local primary="${1}"

  if [[ -z "${primary}" ]] || ! validators::shortid "${primary}"; then
    core::log error "invalid shortId provided" "{}"
    return "${ERR_INVALID_ARG}"
  fi

  jq -n --arg primary "${primary}" '[$primary]'
}

# Helper: Calculate config directory digest
digest_confdir() {
  local confdir="${1}"
  if command -v jq > /dev/null 2>&1; then
    (for f in "${confdir}"/*.json; do jq -S -c . "${f}"; done) | sha256sum | awk '{print $1}'
  else
    cat "${confdir}"/*.json | sha256sum | awk '{print $1}'
  fi
}

# Detect whether host supports global IPv6 connectivity.
xray::detect_ipv6_support() {
  local inet6_file="${XRF_IPV6_IF_INET6_PATH:-/proc/net/if_inet6}"
  [[ -f "${inet6_file}" ]] || return 1
  command -v ip > /dev/null 2>&1 || return 1
  ip -6 addr show 2> /dev/null \
    | grep -E -q 'inet6[[:space:]]+[0-9a-fA-F:]+/[0-9]+[[:space:]]+scope[[:space:]]+global'
}

# Resolve listen address and DNS strategy based on IPv6 capability.
xray::resolve_network_profile() {
  local listen_ref="${1:?listen_ref required}" dns_ref="${2:?dns_ref required}"
  local resolved_listen_addr="0.0.0.0" resolved_dns_query_strategy="UseIPv4"

  if xray::detect_ipv6_support; then
    resolved_listen_addr="::"
    resolved_dns_query_strategy="UseIP"
  fi

  printf -v "${listen_ref}" '%s' "${resolved_listen_addr}"
  printf -v "${dns_ref}" '%s' "${resolved_dns_query_strategy}"
}

# Prepare release directory with timestamp
xray::prepare_release_dir() {
  local releases_dir timestamp release_dir
  releases_dir="$(xray::releases)"
  io::ensure_dir "${releases_dir}" 0755 || return 1
  timestamp="$(date -u +%Y%m%d%H%M%S)"
  release_dir="${releases_dir}/${timestamp}"
  io::ensure_dir "${release_dir}" 0750 || return 1
  printf '%s' "${release_dir}"
}

# Write base configuration files (log, outbounds, routing)
xray::write_base_configs() {
  local release_dir="${1}"
  local dns_query_strategy="${2:-UseIPv4}"
  local log_level="${XRAY_LOG_LEVEL:-warning}"

  case "${dns_query_strategy}" in
    UseIP | UseIPv4 | UseIPv6) ;;
    *)
      core::log error "invalid DNS queryStrategy" "$(printf '{"strategy":"%s"}' "${dns_query_strategy}")"
      return "${ERR_INVALID_ARG}"
      ;;
  esac

  jq -n --arg level "${log_level}" '{log:{access:"",error:"",loglevel:$level}}' \
    | io::atomic_write "${release_dir}/${XRAY_CONFIG_00_LOG}" 0640 || return 1

  # Outbounds configuration
  printf '{"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]}' \
    | io::atomic_write "${release_dir}/${XRAY_CONFIG_06_OUTBOUNDS}" 0640 || return 1

  # DNS strategy configuration (IPv4-only or dual-stack auto profile)
  printf '{"dns":{"queryStrategy":"%s"}}' "${dns_query_strategy}" \
    | io::atomic_write "${release_dir}/${XRAY_CONFIG_07_DNS}" 0640 || return 1

  # Routing configuration
  printf '{"routing":{"domainStrategy":"IPIfNonMatch","rules":[]}}' \
    | io::atomic_write "${release_dir}/${XRAY_CONFIG_09_ROUTING}" 0640 || return 1

  core::log debug "base configs written" "$(printf '{"dir":"%s","dns_query_strategy":"%s"}' "${release_dir}" "${dns_query_strategy}")"
}

# Render Reality-only inbound configuration
xray::render_reality_inbound() {
  local release_dir="${1}"
  local sniff_bool="${2}"
  local listen_addr="${3:-0.0.0.0}"

  # Validate required variables
  : "${XRAY_PORT:=443}" : "${XRAY_UUID:?}"
  if [[ -z "${XRAY_SNI:-}" ]]; then
    core::log error "XRAY_SNI is required" '{}'
    return 1
  fi
  : "${XRAY_SHORT_ID:?}" : "${XRAY_PRIVATE_KEY:?}"

  validators::port "${XRAY_PORT}" || core::log fatal "invalid XRAY_PORT" "$(printf '{"port":"%s"}' "${XRAY_PORT}")"
  validators::uuid "${XRAY_UUID}" || core::log fatal "invalid XRAY_UUID format" "$(printf '{"uuid":"%s"}' "${XRAY_UUID}")"
  validators::shortid "${XRAY_SHORT_ID}" || core::log fatal "invalid XRAY_SHORT_ID" "{}"
  [[ -n "${XRAY_PRIVATE_KEY}" ]] || core::log fatal "XRAY_PRIVATE_KEY required" "{}"

  # Advisory: REALITY on non-443 port reduces stealth (v26.3.27+)
  if [[ "${XRAY_PORT}" -ne 443 ]]; then
    core::log warn "REALITY on non-443 port may reduce stealth (Xray v26.3.27+)" \
      "$(printf '{"port":%d,"recommended":443}' "${XRAY_PORT}")"
  fi

  # Prepare configuration values
  local first_sni="" reality_dest server_names shortids_pool sanitized_uuid sanitized_key
  server_names="$(json_array_from_csv "${XRAY_SNI}" "XRAY_SNI")" || return 1
  first_sni="$(jq -r '.[0] // empty' <<< "${server_names}")"
  [[ -n "${first_sni}" ]] || return 1
  reality_dest="$(ensure_reality_dest "${XRAY_REALITY_DEST:-}" "${first_sni}")" || return 1
  shortids_pool="$(build_shortids_pool "${XRAY_SHORT_ID}")" || return 1
  if ! sanitized_uuid="$(xray::sanitize_json_string "${XRAY_UUID}" "XRAY_UUID")"; then
    core::log fatal "invalid XRAY_UUID characters" "{}"
  fi
  if ! sanitized_key="$(xray::sanitize_json_string "${XRAY_PRIVATE_KEY}" "XRAY_PRIVATE_KEY")"; then
    core::log fatal "invalid XRAY_PRIVATE_KEY characters" "{}"
  fi

  # Write inbound configuration
  jq -n \
    --argjson port "${XRAY_PORT}" \
    --arg uuid "${sanitized_uuid}" \
    --arg dest "${reality_dest}" \
    --argjson serverNames "${server_names}" \
    --arg privateKey "${sanitized_key}" \
    --arg listen_addr "${listen_addr}" \
    --argjson shortIds "${shortids_pool}" \
    --argjson sniff "${sniff_bool}" \
    '{
      inbounds: [
        {
          tag: "reality",
          listen: $listen_addr,
          port: $port,
          protocol: "vless",
          settings: {clients: [{id: $uuid, flow: "xtls-rprx-vision"}], decryption: "none"},
          streamSettings: {
            network: "raw",
            security: "reality",
            realitySettings: {
              show: false,
              target: $dest,
              xver: 0,
              serverNames: $serverNames,
              privateKey: $privateKey,
              shortIds: $shortIds
            }
          },
          sniffing: {enabled: $sniff, destOverride: ["http","tls","quic"]}
        }
      ]
    }' | io::atomic_write "${release_dir}/${XRAY_CONFIG_05_INBOUNDS}" 0640

  core::log debug "reality-only inbound config written" "$(printf '{"port":%d}' "${XRAY_PORT}")"
}

# Set permissions for configuration directory and files
xray::set_config_permissions() {
  local release_dir="${1}"

  core::log debug "setting permissions" "$(printf '{"dir":"%s"}' "${release_dir}")"

  chmod 0750 "${release_dir}" || true
  chown root:xray "${release_dir}" 2> /dev/null || true

  # Batch set permissions for all config files (performance: log once instead of per-file)
  local file_count=0
  for f in "${release_dir}"/*.json; do
    [[ -f "${f}" ]] || continue
    chown root:xray "${f}" 2> /dev/null || true
    chmod 0640 "${f}" || true
    ((file_count += 1))
  done

  core::log debug "config file permissions set" "$(printf '{"dir":"%s","count":%d}' "${release_dir}" "${file_count}")"
}

# Main function: Orchestrate Xray configuration rendering
render_release() {
  local topology="${1}"
  [[ "${topology}" == reality-only ]] || return 1

  # Step 1: Prepare release directory
  local release_dir
  release_dir="$(xray::prepare_release_dir)" || return 1
  core::log debug "release directory created" "$(printf '{"dir":"%s"}' "${release_dir}")"

  # Step 2: Set sniffing mode
  : "${XRAY_SNIFFING:=false}"

  # Step 3: Write base configuration files
  local listen_addr dns_query_strategy
  xray::resolve_network_profile listen_addr dns_query_strategy
  xray::write_base_configs "${release_dir}" "${dns_query_strategy}" || return 1

  # Step 4: Determine sniffing mode
  local sniff_bool
  sniff_bool=$([[ "${XRAY_SNIFFING}" == "true" ]] && echo true || echo false)

  # Step 5: Render the sole REALITY inbound
  xray::render_reality_inbound "${release_dir}" "${sniff_bool}" "${listen_addr}" || return 1

  # Step 6: Set permissions on config directory and files
  xray::set_config_permissions "${release_dir}" || return 1

  # Step 7: Return release directory path to stdout
  core::log debug "render_release complete" "$(printf '{"release_dir":"%s"}' "${release_dir}")"
  printf '%s\n' "${release_dir}"
}

deploy_restore() {
  local saved="${1}" was_active="${2}" binary_stamp="${3}"
  local failed=false
  # The first switch may have failed before consuming this candidate symlink.
  # Remove it so cp cannot follow it into the candidate release directory.
  rm -f "$(xray::active).new" || failed=true
  if [[ -L "${saved}/active" ]]; then
    if [[ "${failed}" == false ]]; then
      cp -a "${saved}/active" "$(xray::active).new" || failed=true
    fi
    if [[ "${failed}" == false ]]; then
      mv -Tf "$(xray::active).new" "$(xray::active)" || failed=true
    fi
  else
    rm -f "$(xray::active)" || failed=true
  fi
  if [[ "${was_active}" == true && "${failed}" == false ]]; then
    systemctl restart xray && systemctl is-active --quiet xray || failed=true
  fi
  if [[ -f "${saved}/config.sha256" ]]; then
    cp -p "${saved}/config.sha256" "$(state::digest)" || failed=true
  else
    rm -f "$(state::digest)" || failed=true
  fi
  if [[ -f "${saved}/binary.sha256" ]]; then
    cp -p "${saved}/binary.sha256" "${binary_stamp}" || failed=true
  else
    rm -f "${binary_stamp}" || failed=true
  fi
  if [[ "${failed}" == true ]]; then
    core::log error "deployment rollback incomplete; recovery files retained" "$(printf '{"path":"%s"}' "${saved}")"
    return 1
  fi
  rm -rf "${saved}"
  core::log warn "deployment rolled back" '{}'
}

deploy_release() {
  local release_dir="${1}"
  core::log debug "deploy_release started" "$(printf '{"release_dir":"%s"}' "${release_dir}")"

  # Security: Validate directory path to prevent injection attacks
  # Reject: parent references (..), consecutive slashes (//), invalid characters
  # Note: Dots are allowed for hidden dirs (.config) and temp dirs (xrf.release.xxx)
  if [[ ! "${release_dir}" =~ ^/([a-zA-Z0-9._-]+/)*[a-zA-Z0-9._-]+$ ]] \
    || [[ "${release_dir}" == *".."* ]] \
    || [[ "${release_dir}" == *"//"* ]]; then
    core::log error "invalid directory path" "$(printf '{"path":"%s","reason":"path validation failed"}' "${release_dir//\"/\\\"}")"
    return "${ERR_INVALID_ARG}"
  fi

  if [[ ! -d "${release_dir}" ]]; then
    core::log error "directory does not exist" "$(printf '{"path":"%s"}' "${release_dir}")"
    return 1
  fi

  if ! config::validate_deep "${release_dir}"; then
    core::log error "deep configuration validation failed" "$(printf '{"confdir":"%s"}' "${release_dir}")"
    return 1
  fi

  if [[ -x "$(xray::bin)" ]]; then
    if ! config::validate_binary "${release_dir}"; then
      return 1
    fi
  fi
  local new_digest old_digest="" binary_digest="" old_binary_digest="" old_active=""
  local binary_stamp was_active=false saved
  binary_stamp="$(state::dir)/binary.sha256"
  new_digest="$(digest_confdir "${release_dir}")" || return 1
  [[ -f "$(state::digest)" ]] && old_digest="$(cat "$(state::digest)")"
  [[ -L "$(xray::active)" ]] && old_active="$(readlink -f "$(xray::active)")"
  if [[ -x "$(xray::bin)" ]]; then
    binary_digest="$(sha256sum "$(xray::bin)" | awk '{print $1}')" || return 1
  fi
  [[ -f "${binary_stamp}" ]] && old_binary_digest="$(cat "${binary_stamp}")"
  if command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet xray; then
    was_active=true
  fi
  if [[ -n "${old_active}" && "${old_digest}" == "${new_digest}" &&
    "$(digest_confdir "$(xray::active)")" == "${new_digest}" &&
    -n "${binary_digest}" && "${old_binary_digest}" == "${binary_digest}" ]]; then
    core::log info "configuration and deployed binary unchanged" '{}'
    return 0
  fi
  # Keep the established state parent mode; only this recovery snapshot is private.
  if [[ ! -d "$(state::dir)" ]]; then
    io::ensure_dir "$(state::dir)" 0755 || return 1
  fi
  saved="$(mktemp -d "$(state::dir)/deploy.XXXXXX")" || return 1
  chmod 0700 "${saved}" || return 1
  if [[ -L "$(xray::active)" ]]; then
    cp -a "$(xray::active)" "${saved}/active" || return 1
  fi
  if [[ -f "$(state::digest)" ]]; then
    cp -p "$(state::digest)" "${saved}/config.sha256" || return 1
  fi
  if [[ -f "${binary_stamp}" ]]; then
    cp -p "${binary_stamp}" "${saved}/binary.sha256" || return 1
  fi
  io::ensure_dir "$(xray::confbase)" 0755 || return 1
  io::ensure_dir "$(xray::releases)" 0755 || return 1
  ln -sfn "${release_dir}" "$(xray::active).new" || return 1
  mv -Tf "$(xray::active).new" "$(xray::active)" || {
    deploy_restore "${saved}" "${was_active}" "${binary_stamp}" || true
    return 1
  }
  if [[ "${was_active}" == true ]]; then
    if ! systemctl restart xray || ! systemctl is-active --quiet xray; then
      core::log error "restart failed; restoring previous active configuration" '{}'
      deploy_restore "${saved}" "${was_active}" "${binary_stamp}" || return 1
      return 1
    fi
  fi
  if ! printf '%s\n' "${new_digest}" | io::atomic_write "$(state::digest)" 0644; then
    deploy_restore "${saved}" "${was_active}" "${binary_stamp}" || return 1
    return 1
  fi
  if [[ "${was_active}" == true ]]; then
    if ! printf '%s\n' "${binary_digest}" | io::atomic_write "${binary_stamp}" 0644; then
      deploy_restore "${saved}" "${was_active}" "${binary_stamp}" || return 1
      return 1
    fi
  fi
  rm -rf "${saved}"
  core::log info "deployed" "$(printf '{"active":"%s"}' "$(xray::active)")"
}

deploy_with_lock() {
  local topology="${1}"
  local release_dir
  release_dir="$(render_release "${topology}")" || return 1
  deploy_release "${release_dir}"
}

main() {
  core::init "${@}"
  local topology="reality-only"
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --topology)
        topology="${2}"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  # Security: Validate topology parameter
  case "${topology}" in
    "reality-only") ;;
    *)
      core::log fatal "invalid topology" "$(printf '{"topology":"%s","valid_options":"reality-only"}' "${topology}")"
      ;;
  esac
  core::with_flock "$(state::lock)" deploy_with_lock "${topology}"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "${@}"
fi
