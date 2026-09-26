#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/lib/defaults.sh"
. "${HERE}/lib/args.sh"
. "${HERE}/lib/uuid.sh"
. "${HERE}/lib/preview.sh"
. "${HERE}/lib/health_check.sh"
. "${HERE}/lib/x25519.sh"
. "${HERE}/modules/state.sh"
. "${HERE}/services/xray/common.sh"

usage() {
  printf 'Usage: xrf install [options]\n\n'
  args::show_help
  cat << 'HELP'
Xray Configuration Variables:
  XRAY_PORT=443 XRAY_UUID=<uuid> XRAY_SNI=<required host[,host]>
  XRAY_REALITY_DEST=<optional host:port> XRAY_PRIVATE_KEY=<X25519> XRAY_SHORT_ID=<hex>
HELP
}

# This command only installs into an empty Xray location. Remove artifacts it
# owns on failure; existing state and backups left by uninstall are untouched.
install::cleanup_fresh() {
  local state_existed="${1}" old_state="${2}" failed=false
  local unit_file="${XRF_SYSTEMD_DIR:-/etc/systemd/system}/xray.service"
  if [[ -e "${unit_file}" ]]; then
    systemctl disable --now xray.service || failed=true
    rm -f "${unit_file}" || failed=true
    systemctl daemon-reload || failed=true
  fi
  rm -f "$(xray::bin)" "$(state::digest)" "$(state::dir)/binary.sha256" || failed=true
  rm -rf "$(xray::confbase)" || failed=true
  if [[ "${state_existed}" == true ]]; then
    state::save "${old_state}" || failed=true
  else
    rm -f "$(state::path)" || failed=true
  fi
  if [[ "${failed}" == true ]]; then
    core::log error "fresh install cleanup incomplete; inspect remaining artifacts" '{}'
    return 1
  fi
}

install::credentials() {
  if [[ -n "${UUID_FROM_STRING:-}" ]]; then
    XRAY_UUID="$(uuid::from_string "${UUID_FROM_STRING}" "$(xray::bin)")" || return 1
  elif [[ -n "${UUID:-}" ]]; then
    XRAY_UUID="${UUID}"
  else
    XRAY_UUID="$(uuid::generate "$(xray::bin)")" || return 1
  fi
  validators::uuid "${XRAY_UUID}" || return 1

  XRAY_PORT="${XRAY_PORT:-${DEFAULT_XRAY_PORT}}"
  XRAY_SHORT_ID="${XRAY_SHORT_ID:-$(xray::generate_shortid)}"
  [[ -n "${XRAY_SHORT_ID}" ]] && validators::shortid "${XRAY_SHORT_ID}" || return 1

  if [[ -z "${XRAY_PRIVATE_KEY:-}" ]]; then
    local keypair
    keypair="$("$(xray::bin)" x25519)" || return 1
    XRAY_PRIVATE_KEY="$(x25519::parse_keys "${keypair}" | sed -n '1p')"
    XRAY_PUBLIC_KEY="$(x25519::parse_keys "${keypair}" | sed -n '2p')"
  else
    XRAY_PUBLIC_KEY="$(x25519::derive_public_key "$(xray::bin)" "${XRAY_PRIVATE_KEY}")" || return 1
  fi
  [[ -n "${XRAY_PRIVATE_KEY}" && -n "${XRAY_PUBLIC_KEY}" ]] || return 1
  [[ "$(x25519::derive_public_key "$(xray::bin)" "${XRAY_PRIVATE_KEY}")" == "${XRAY_PUBLIC_KEY}" ]] || return 1
  export XRAY_PORT XRAY_UUID XRAY_SNI XRAY_REALITY_DEST XRAY_SHORT_ID XRAY_PRIVATE_KEY XRAY_PUBLIC_KEY
  export XRAY_SNIFFING="${XRAY_SNIFFING:-${DEFAULT_XRAY_SNIFFING}}"
}

install::normalize_target() {
  local normalized
  normalized="$({
    . "${HERE}/services/xray/configure.sh"
    local server_names sni target
    server_names="$(json_array_from_csv "${XRAY_SNI}" XRAY_SNI)" || exit 1
    [[ "$(jq 'length' <<< "${server_names}")" -gt 0 ]] || exit 1
    sni="$(jq -r 'join(",")' <<< "${server_names}")" || exit 1
    target="$(ensure_reality_dest "${XRAY_REALITY_DEST:-}" "${sni%%,*}")" || exit 1
    jq -n --arg sni "${sni}" --arg target "${target}" '{sni:$sni,target:$target}'
  })" || return 1
  XRAY_SNI="$(jq -r .sni <<< "${normalized}")" || return 1
  XRAY_REALITY_DEST="$(jq -r .target <<< "${normalized}")" || return 1
  export XRAY_SNI XRAY_REALITY_DEST
}

install::run_fresh() {
  "${HERE}/services/xray/install.sh" --version "${VERSION}" || return 1
  . "${HERE}/services/xray/configure.sh"
  install::credentials || return 1
  (deploy_with_lock reality-only) || return 1
  (
    . "${HERE}/services/xray/systemd-unit.sh"
    install_unit_with_lock
  ) || return 1
  if ! systemctl is-active --quiet xray.service; then
    core::log error "new Xray service is not active" '{}'
    return 1
  fi

  local version now state
  version="$(xray::installed_version)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state="$(jq -n --arg ver "${version}" --arg ts "${now}" \
    --argjson port "${XRAY_PORT}" --arg uuid "${XRAY_UUID}" --arg sni "${XRAY_SNI}" \
    --arg sid "${XRAY_SHORT_ID}" --arg pbk "${XRAY_PUBLIC_KEY}" \
    --arg fp "${XRAY_FINGERPRINT:-chrome}" \
    '{name:"reality-only",version:$ver,installed_at:$ts,xray:{port:$port,uuid:$uuid,reality_sni:$sni,short_id:$sid,reality_public_key:$pbk,fingerprint:$fp}}')" || return 1
  state::save "${state}" || return 1
  "${HERE}/services/xray/client-links.sh" || core::log warn "connection link unavailable; run xrf links after resolving server IP" '{}'
  if ! health::run; then
    core::log warn "health check failed" '{"suggestion":"run xrf health to diagnose issues"}'
  fi
  if ! systemctl is-active --quiet xray.service; then
    core::log error "new Xray service stopped during installation" '{}'
    return 1
  fi
  core::log info "Install complete" "$(printf '{"topology":"reality-only","version":"%s"}' "${version}")"
}

install::guard_empty() {
  # A state file alone remains after uninstall. All live artifacts require
  # the upgrade path or manual recovery, never a destructive fresh install.
  if [[ -e "$(xray::confbase)" || -L "$(xray::confbase)" || -e "$(xray::bin)" || -L "$(xray::bin)" || -e "${XRF_SYSTEMD_DIR:-/etc/systemd/system}/xray.service" ]]; then
    core::log error "existing Xray artifacts found; use xrf upgrade for a complete installation or recover partial artifacts first" '{}'
    return 1
  fi
}

install::run_locked() {
  install::guard_empty || return 1
  local state_existed=false old_state=""
  if [[ -f "$(state::path)" ]]; then
    state_existed=true
    old_state="$(cat "$(state::path)")" || return 1
  fi
  if ! install::run_fresh; then
    core::log error "fresh install failed" '{}'
    install::cleanup_fresh "${state_existed}" "${old_state}" || return 1
    return 1
  fi
}

main() {
  core::init "${@}"
  args::init
  local rc=0
  args::parse "$@" || rc=$?
  if [[ ${rc} -eq 10 ]]; then
    usage
    return 0
  fi
  if [[ ${rc} -ne 0 ]]; then
    usage
    return 1
  fi
  install::guard_empty || return 1
  if [[ -z "${XRAY_SNI:-}" ]]; then
    core::log error "XRAY_SNI is required for a fresh install" '{}'
    return 1
  fi
  args::export_vars
  install::normalize_target || return 1
  preview::show
  if preview::is_dry_run; then return 0; fi
  if ! preview::confirm; then return 1; fi
  core::with_flock "$(state::lock)" install::run_locked
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
