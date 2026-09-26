#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/lib/defaults.sh"
. "${HERE}/lib/args.sh"
. "${HERE}/lib/uuid.sh"
. "${HERE}/lib/templates.sh"
. "${HERE}/lib/preview.sh"
. "${HERE}/lib/sni_validator.sh"
. "${HERE}/lib/health_check.sh"
. "${HERE}/lib/plugins.sh"
. "${HERE}/lib/backup.sh"
. "${HERE}/lib/x25519.sh"
. "${HERE}/modules/state.sh"
. "${HERE}/modules/net/sysctl.sh"
. "${HERE}/services/xray/common.sh"

usage() {
  cat << EOF
Usage: xrf install [options]

EOF
  args::show_help

  cat << EOF

Xray Configuration Variables:
  XRAY_SNIFFING=false|true
  # reality-only
  XRAY_PORT=443 XRAY_UUID=<uuid> XRAY_SNI=www.apple.com[,alt] XRAY_REALITY_DEST=www.apple.com XRAY_PRIVATE_KEY=<X25519> XRAY_SHORT_ID=<hex>
  # vision-reality
  XRAY_VISION_PORT=8443 XRAY_REALITY_PORT=443 XRAY_FALLBACK_PORT=8080 XRAY_UUID_VISION=<uuid> XRAY_UUID_REALITY=<uuid> XRAY_CERT_DIR=/usr/local/etc/xray/certs XRAY_PRIVATE_KEY=<X25519> XRAY_SHORT_ID=<hex>
  # Optional VLESS Encryption (advanced)
  XRAY_VLESS_ENCRYPTION_ENABLED=false XRAY_VLESS_DECRYPTION=<value> XRAY_VLESS_ENCRYPTION=<value>
EOF
}

main() {
  core::init "${@}"

  # Initialize and parse arguments
  args::init
  local rc=0
  args::parse "$@" || rc=$?

  if [[ ${rc} -eq 10 ]]; then
    usage
    exit 0
  elif [[ ${rc} -ne 0 ]]; then
    usage
    exit 1
  fi

  # A state file alone remains after normal uninstall. Any installed artifact
  # means a fresh install could destroy recoverable configuration or binaries.
  if [[ -e "$(xray::confbase)" || -L "$(xray::confbase)" || -e "$(xray::bin)" || -L "$(xray::bin)" || -e "${XRF_SYSTEMD_DIR:-/etc/systemd/system}/xray.service" ]]; then
    core::log error "existing Xray artifacts found; use xrf upgrade for a complete installation or recover partial artifacts first" '{}'
    return 1
  fi
  plugins::ensure_dirs
  plugins::load_enabled

  # Export arguments as environment variables
  args::export_vars

  # Apply template if specified (template values used as defaults, can be overridden by CLI args)
  if [[ -n "${TEMPLATE}" ]]; then
    core::log info "applying template" "$(printf '{"template":"%s"}' "${TEMPLATE}")"

    # Validate template exists and is valid
    if ! templates::validate "${TEMPLATE}"; then
      core::log error "invalid template" "$(printf '{"template":"%s"}' "${TEMPLATE}")"
      exit 1
    fi

    # Export template variables (prefixed with TEMPLATE_*)
    templates::export "${TEMPLATE}"

    # Apply template defaults only if not explicitly set by CLI
    # Topology: use template only if user didn't provide --topology
    if [[ -z "${_TOPOLOGY_EXPLICIT}" && -n "${TEMPLATE_TOPOLOGY:-}" ]]; then
      TOPOLOGY="${TEMPLATE_TOPOLOGY}"
      core::log debug "topology from template" "$(printf '{"topology":"%s"}' "${TOPOLOGY}")"
    fi

    # Version: use template only if user didn't provide --version
    if [[ -z "${_VERSION_EXPLICIT}" && -n "${TEMPLATE_VERSION:-}" ]]; then
      VERSION="${TEMPLATE_VERSION}"
      core::log debug "version from template" "$(printf '{"version":"%s"}' "${VERSION}")"
    fi

    # Plugins: merge template plugins with CLI plugins
    if [[ -n "${TEMPLATE_PLUGINS:-}" ]]; then
      if [[ -z "${_PLUGINS_EXPLICIT}" ]]; then
        # No CLI plugins, use template plugins
        PLUGINS="${TEMPLATE_PLUGINS}"
        core::log debug "plugins from template" "$(printf '{"plugins":"%s"}' "${PLUGINS}")"
      else
        # Merge: CLI plugins take priority, add template plugins not already specified
        PLUGINS="${PLUGINS},${TEMPLATE_PLUGINS}"
        core::log debug "plugins merged" "$(printf '{"cli":"%s","template":"%s"}' "${PLUGINS%%,*}" "${TEMPLATE_PLUGINS}")"
      fi
    fi

    # Export Xray configuration from template (used later in configuration)
    local -a template_vars=(SNI REALITY_DEST SNIFFING PORT VISION_PORT REALITY_PORT)
    for var in "${template_vars[@]}"; do
      local tval="TEMPLATE_${var}" xval="XRAY_${var}"
      [[ -n "${!tval:-}" ]] && export "${xval}=${!tval}"
    done

    core::log info "template applied" "$(printf '{"template":"%s","topology":"%s"}' "${TEMPLATE}" "${TOPOLOGY}")"
  fi

  # Enable plugins if specified
  if [[ -n "${PLUGINS}" ]]; then
    core::log info "enabling plugins" "$(printf '{"plugins":"%s"}' "${PLUGINS}")"
    IFS=',' read -ra plugin_list <<< "${PLUGINS}"
    for plugin in "${plugin_list[@]}"; do
      # Bash parameter expansion for trimming (faster than echo | xargs)
      plugin="${plugin#"${plugin%%[![:space:]]*}"}" # trim leading whitespace
      plugin="${plugin%"${plugin##*[![:space:]]}"}" # trim trailing whitespace
      if [[ -n "${plugin}" ]]; then
        # Direct function call (faster than forking external script)
        plugins::enable "${plugin}"
      fi
    done
    # Reload enabled plugins after enabling new ones
    plugins::load_enabled
  fi

  # Show installation preview
  preview::show

  # Check for dry-run mode (exit after preview)
  if preview::is_dry_run; then
    core::log info "dry-run mode, skipping installation" "{}"
    exit 0
  fi

  # Request user confirmation (unless --yes flag)
  if ! preview::confirm; then
    core::log info "installation cancelled" "{}"
    exit 1
  fi

  # Auto-backup before installation (if existing installation found)
  local state_file
  state_file="$(state::path)"
  local existing_confdir
  existing_confdir="$(xray::confbase)"
  if [[ -f "${state_file}" && -d "${existing_confdir}" ]]; then
    core::log info "existing installation detected, creating automatic backup" "{}"
    local auto_backup_name
    auto_backup_name="pre-install-$(date +%Y%m%d-%H%M%S)"
    if backup::create "${auto_backup_name}" > /dev/null 2>&1; then
      core::log info "automatic backup created" "$(printf '{"name":"%s"}' "${auto_backup_name}")"
    else
      core::log warn "failed to create automatic backup" '{"suggestion":"continuing with installation"}'
      # Continue anyway - user confirmed installation
    fi
  elif [[ -f "${state_file}" ]]; then
    core::log info "state file exists but config directory is missing; skipping automatic backup" "$(printf '{"state":"%s","confdir":"%s"}' "${state_file}" "${existing_confdir}")"
  fi

  plugins::emit install_pre "topology=${TOPOLOGY}" "version=${VERSION}"
  "${HERE}/services/xray/install.sh" --version "${VERSION}"

  # Generate or use provided UUIDs
  local generated_uuid=""
  if [[ -n "${UUID_FROM_STRING:-}" ]]; then
    # Custom UUID from string (requires xray binary)
    core::log debug "generating UUID from custom string" "$(printf '{"input":"%s"}' "${UUID_FROM_STRING}")"
    generated_uuid="$(uuid::from_string "${UUID_FROM_STRING}" "$(xray::bin)")" || {
      core::log error "failed to generate UUID from string" "$(printf '{"input":"%s","suggestion":"ensure xray is installed"}' "${UUID_FROM_STRING}")"
      exit 1
    }
  elif [[ -n "${UUID:-}" ]]; then
    # User-provided UUID
    if ! uuid::validate "${UUID}"; then
      error_codes::invalid_uuid "${UUID}"
      exit 1
    fi
    generated_uuid="${UUID}"
  fi

  if [[ "${TOPOLOGY}" == "vision-reality" ]]; then
    core::log debug "configuring vision-reality topology" "$(printf '{"XRAY_DOMAIN":"%s"}' "${XRAY_DOMAIN:-unset}")"
    : "${XRAY_VISION_PORT:=${DEFAULT_XRAY_VISION_PORT}}"
    : "${XRAY_REALITY_PORT:=${DEFAULT_XRAY_REALITY_PORT}}"
    : "${XRAY_CERT_DIR:=${DEFAULT_XRAY_CERT_DIR}}"
    : "${XRAY_FALLBACK_PORT:=${DEFAULT_XRAY_FALLBACK_PORT}}"
    if [[ -z "${XRAY_UUID_VISION:-}" ]]; then
      XRAY_UUID_VISION="${generated_uuid:-$(uuid::generate "$(xray::bin)")}"
    fi
    if [[ -z "${XRAY_UUID_REALITY:-}" ]]; then
      XRAY_UUID_REALITY="$(uuid::generate "$(xray::bin)")"
    fi
  else
    : "${XRAY_PORT:=${DEFAULT_XRAY_PORT}}"
    if [[ -z "${XRAY_UUID:-}" ]]; then
      XRAY_UUID="${generated_uuid:-$(uuid::generate "$(xray::bin)")}"
    fi
  fi
  : "${XRAY_SNI:=${DEFAULT_XRAY_SNI}}"
  if [[ -z "${XRAY_REALITY_DEST:-}" ]]; then
    XRAY_REALITY_DEST="${XRAY_SNI%%,*}"
  fi
  if [[ "${XRAY_REALITY_DEST}" != *:* ]]; then
    XRAY_REALITY_DEST="${XRAY_REALITY_DEST}:443"
  fi

  # Validate SNI domain (optional check, warn if fails)
  # Extract domain from REALITY_DEST (remove port)
  local sni_domain="${XRAY_REALITY_DEST%:*}"
  core::log info "validating SNI domain" "$(printf '{"domain":"%s"}' "${sni_domain}")"

  # Run SNI validation silently (log results only)
  if ! sni::validate "${sni_domain}" > /dev/null 2>&1; then
    core::log warn "SNI validation failed" "$(printf '{"domain":"%s","suggestion":"REALITY may work but with reduced reliability"}' "${sni_domain}")"
  else
    core::log info "SNI validation passed" "$(printf '{"domain":"%s"}' "${sni_domain}")"
  fi

  # Warn about Apple/iCloud REALITY destinations (v26.3.27+: risk of IP blocking)
  case "${sni_domain,,}" in
    *icloud-content.com | *cdn-apple.com | *mzstatic.com | *icloud.com | *apple.com)
      core::log warn "Apple/iCloud REALITY dest may cause IP blocking (Xray v26.3.27+)" \
        "$(printf '{"domain":"%s","suggestion":"Use a non-Apple domain such as www.microsoft.com"}' "${sni_domain}")"
      ;;
  esac

  # Generate shortIds pool (3 shortIds for multi-client scenarios)
  # Batch generate if none provided; fill missing ones individually otherwise
  if [[ -z "${XRAY_SHORT_ID:-}${XRAY_SHORT_ID_2:-}${XRAY_SHORT_ID_3:-}" ]]; then
    mapfile -t shortids < <(xray::generate_shortids 3)
    XRAY_SHORT_ID="${shortids[0]}"
    XRAY_SHORT_ID_2="${shortids[1]}"
    XRAY_SHORT_ID_3="${shortids[2]}"
  else
    : "${XRAY_SHORT_ID:=$(xray::generate_shortid)}"
    : "${XRAY_SHORT_ID_2:=$(xray::generate_shortid)}"
    : "${XRAY_SHORT_ID_3:=$(xray::generate_shortid)}"
  fi

  # Validate all generated shortIds (hex format, even length, max 16 chars)
  # Use shared validator from lib/validators.sh
  for sid_var in XRAY_SHORT_ID XRAY_SHORT_ID_2 XRAY_SHORT_ID_3; do
    if [[ -n "${!sid_var:-}" ]] && ! validators::shortid "${!sid_var}"; then
      core::log error "invalid shortId format" "$(printf '{"var":"%s","value":"%s","requirements":"hex,even_length,max_16"}' "${sid_var}" "${!sid_var}")"
      exit 1
    fi
  done

  core::log debug "shortIds generated" "$(printf '{"primary":"%s","sid2":"%s","sid3":"%s"}' "${XRAY_SHORT_ID}" "${XRAY_SHORT_ID_2}" "${XRAY_SHORT_ID_3}")"

  # Generate private/public key pair if not provided
  if [[ -z "${XRAY_PRIVATE_KEY:-}" && -x "$(xray::bin)" ]]; then
    local keypair
    keypair="$("$(xray::bin)" x25519 2> /dev/null || true)"
    local -a parsed_keypair=()
    mapfile -t parsed_keypair < <(x25519::parse_keys "${keypair}")
    local private_key="${parsed_keypair[0]:-}"
    local public_key="${parsed_keypair[1]:-}"
    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
      core::log error "failed to parse x25519 keypair" '{"suggestion":"verify xray x25519 output"}'
      exit 1
    fi
    XRAY_PRIVATE_KEY="${private_key}"
    XRAY_PUBLIC_KEY="${public_key}"
  elif [[ -n "${XRAY_PRIVATE_KEY:-}" && -z "${XRAY_PUBLIC_KEY:-}" && -x "$(xray::bin)" ]]; then
    local derived_public
    if derived_public="$(x25519::derive_public_key "$(xray::bin)" "${XRAY_PRIVATE_KEY}")"; then
      XRAY_PUBLIC_KEY="${derived_public}"
    else
      core::log error "failed to derive public key from provided private key" '{"suggestion":"re-run: xray x25519"}'
      exit 1
    fi
  fi

  # Verify public key matches private key if both are provided
  if [[ -n "${XRAY_PRIVATE_KEY:-}" && -n "${XRAY_PUBLIC_KEY:-}" && -x "$(xray::bin)" ]]; then
    core::log debug "verifying public key matches private key" "{}"
    local verified_public
    if verified_public="$(x25519::derive_public_key "$(xray::bin)" "${XRAY_PRIVATE_KEY}" 2> /dev/null)"; then
      if [[ "${verified_public}" != "${XRAY_PUBLIC_KEY}" ]]; then
        core::log error "public key does not match private key" '{"suggestion":"regenerate keypair with: xray x25519"}'
        exit 1
      fi
      core::log debug "verified public key matches private key" "{}"
    else
      core::log warn "unable to verify public key (xray x25519 failed)" '{"continuing":"yes"}'
    fi
  fi

  # Optional VLESS encryption (Reality inbound only)
  export XRAY_VLESS_ENCRYPTION_ENABLED="${XRAY_VLESS_ENCRYPTION_ENABLED:-false}"
  if [[ "${XRAY_VLESS_ENCRYPTION_ENABLED}" == "true" ]]; then
    if [[ -z "${XRAY_VLESS_DECRYPTION:-}" || -z "${XRAY_VLESS_ENCRYPTION:-}" ]]; then
      local -a vless_pair=()
      if [[ ! -x "$(xray::bin)" ]]; then
        core::log error "xray binary required to auto-generate vless encryption pair" "{}"
        exit 1
      fi
      if ! mapfile -t vless_pair < <(xray::generate_vless_encryption_pair "$(xray::bin)"); then
        core::log error "failed to generate vless encryption pair" '{"hint":"xray vlessenc"}'
        exit 1
      fi
      : "${XRAY_VLESS_DECRYPTION:=${vless_pair[0]:-}}"
      : "${XRAY_VLESS_ENCRYPTION:=${vless_pair[1]:-}}"
    fi

    if ! validators::vless_crypto_value "${XRAY_VLESS_DECRYPTION:-}"; then
      core::log error "invalid XRAY_VLESS_DECRYPTION" "$(printf '{"value":"%s"}' "${XRAY_VLESS_DECRYPTION:-}")"
      exit 1
    fi
    if ! validators::vless_crypto_value "${XRAY_VLESS_ENCRYPTION:-}"; then
      core::log error "invalid XRAY_VLESS_ENCRYPTION" "$(printf '{"value":"%s"}' "${XRAY_VLESS_ENCRYPTION:-}")"
      exit 1
    fi
  else
    XRAY_VLESS_DECRYPTION="${XRAY_VLESS_DECRYPTION:-none}"
  fi

  export XRAY_SNIFFING="${XRAY_SNIFFING:-${DEFAULT_XRAY_SNIFFING}}"
  export XRAY_UUID XRAY_UUID_VISION XRAY_UUID_REALITY XRAY_SHORT_ID XRAY_SHORT_ID_2 XRAY_SHORT_ID_3 XRAY_SNI XRAY_REALITY_DEST \
    XRAY_PORT XRAY_VISION_PORT XRAY_REALITY_PORT XRAY_DOMAIN XRAY_CERT_DIR XRAY_FALLBACK_PORT \
    XRAY_PRIVATE_KEY XRAY_PUBLIC_KEY XRAY_VLESS_ENCRYPTION_ENABLED XRAY_VLESS_DECRYPTION XRAY_VLESS_ENCRYPTION

  plugins::emit install_post "topology=${TOPOLOGY}" "version=${VERSION}"
  "${HERE}/services/xray/configure.sh" --topology "${TOPOLOGY}"

  # Apply TCP sysctl tuning for proxy workloads (non-fatal: containers may lack sysctl access)
  net::apply_sysctl_tuning || core::log warn "sysctl tuning skipped" \
    "$(printf '{"suggestion":"run manually: sysctl -p %s"}' "${XRF_SYSCTL_CONF}")"

  # Install and start systemd service
  "${HERE}/services/xray/systemd-unit.sh" install

  local version
  version="$(xray::installed_version)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local state
  if [[ "${TOPOLOGY}" == "vision-reality" ]]; then
    state=$(jq -n --arg name "vision-reality" --arg ver "${version}" --arg ts "${now}" \
      --arg vport "${XRAY_VISION_PORT}" --arg rport "${XRAY_REALITY_PORT}" \
      --arg vuuid "${XRAY_UUID_VISION}" --arg ruuid "${XRAY_UUID_REALITY}" \
      --arg domain "${XRAY_DOMAIN}" --arg sni "${XRAY_SNI}" --arg sid "${XRAY_SHORT_ID:-}" --arg pbk "${XRAY_PUBLIC_KEY:-}" \
      --arg cert_dir "${XRAY_CERT_DIR}" \
      --arg fp "${XRAY_FINGERPRINT:-chrome}" \
      --arg vdec "${XRAY_VLESS_DECRYPTION:-}" --arg venc "${XRAY_VLESS_ENCRYPTION:-}" \
      '
      {name:$name,version:$ver,installed_at:$ts,xray:{vision_port:($vport|tonumber),reality_port:($rport|tonumber),uuid_vision:$vuuid,uuid_reality:$ruuid,domain:$domain,reality_sni:$sni,short_id:$sid,reality_public_key:$pbk,cert_dir:$cert_dir,fingerprint:$fp}}
      | if $vdec != "" and $vdec != "none" then .xray.vless_decryption = $vdec else . end
      | if $venc != "" and $venc != "none" then .xray.vless_encryption = $venc else . end
      ')
  else
    state=$(jq -n --arg name "reality-only" --arg ver "${version}" --arg ts "${now}" \
      --arg port "${XRAY_PORT}" --arg uuid "${XRAY_UUID}" --arg sni "${XRAY_SNI}" --arg sid "${XRAY_SHORT_ID:-}" --arg pbk "${XRAY_PUBLIC_KEY:-}" \
      --arg fp "${XRAY_FINGERPRINT:-chrome}" \
      --arg vdec "${XRAY_VLESS_DECRYPTION:-}" --arg venc "${XRAY_VLESS_ENCRYPTION:-}" \
      '
      {name:$name,version:$ver,installed_at:$ts,xray:{port:($port|tonumber),uuid:$uuid,reality_sni:$sni,short_id:$sid,reality_public_key:$pbk,fingerprint:$fp}}
      | if $vdec != "" and $vdec != "none" then .xray.vless_decryption = $vdec else . end
      | if $venc != "" and $venc != "none" then .xray.vless_encryption = $venc else . end
      ')
  fi
  state::save "${state}"

  "${HERE}/services/xray/client-links.sh" "${TOPOLOGY}"
  core::log info "Install complete" "$(printf '{"topology":"%s","version":"%s"}' "${TOPOLOGY}" "${version}")"

  # Run post-installation health check
  core::log info "running post-installation health check" "{}"
  printf '\n'
  if health::run; then
    core::log info "health check passed" "{}"
  else
    core::log warn "health check failed" '{"suggestion":"run xrf health to diagnose issues"}'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "${@}"
fi
