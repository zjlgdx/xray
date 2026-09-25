#!/usr/bin/env bash
# Binary-only upgrade. Configuration and client credentials are never regenerated.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/modules/io.sh"
. "${HERE}/modules/state.sh"
. "${HERE}/services/xray/common.sh"

xray::stage_upgrade() {
  local stage="${1}" version="${2}"
  XRF_PREFIX="${stage}" bash "${HERE}/services/xray/install.sh" --version "${version}"
}

xray::replace_binary() {
  local source="${1}" target="${2}" temporary
  temporary="$(mktemp "${target}.XXXXXX")" || return 1
  if ! cp "${source}" "${temporary}" || ! chmod 0755 "${temporary}" || ! mv -f "${temporary}" "${target}"; then
    rm -f "${temporary}"
    return 1
  fi
}

xray::verify_running_binary() {
  local expected pid actual
  expected="$(sha256sum "$(xray::bin)" | awk '{print $1}')" || return 1
  systemctl is-active --quiet xray || return 1
  pid="$(systemctl show xray --property MainPID --value)" || return 1
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
  actual="$(sha256sum "/proc/${pid}/exe" | awk '{print $1}')" || return 1
  [[ "${expected}" == "${actual}" ]] || return 1
  sleep 1
  systemctl is-active --quiet xray && [[ "${pid}" == "$(systemctl show xray --property MainPID --value)" ]]
}

xray::rollback_upgrade() {
  local backup="${1}" metadata_failed=false
  core::log warn "restoring previous binary and state" "$(printf '{"backup":"%s"}' "${backup}")"
  if ! xray::replace_binary "${backup}/xray" "$(xray::bin)"; then
    core::log error "binary rollback failed; manual recovery required" '{}'
    return 1
  fi
  cp -p "${backup}/state.json" "$(state::path)" || metadata_failed=true
  if [[ -f "${backup}/binary.sha256" ]]; then
    cp -p "${backup}/binary.sha256" "$(state::dir)/binary.sha256" || metadata_failed=true
  else
    rm -f "$(state::dir)/binary.sha256" || metadata_failed=true
  fi
  if ! systemctl restart xray || ! xray::verify_running_binary; then
    core::log error "service rollback failed; manual recovery required" '{}'
    return 1
  fi
  if [[ "${metadata_failed}" == true ]]; then
    core::log error "old service restored but metadata rollback failed; restore from backup" '{}'
    return 1
  fi
  core::log warn "upgrade rolled back" '{}'
}

xray::upgrade() {
  local version="${1}" backup candidate new_version state
  if [[ ! -x "$(xray::bin)" || ! -d "$(xray::active)" || ! -f "$(state::path)" ]]; then
    core::log error "upgrade requires an existing installation and state" '{}'
    return 1
  fi
  if ! systemctl is-active --quiet xray; then
    core::log error "upgrade requires a running service; diagnose it before upgrading" '{}'
    return 1
  fi
  jq -e 'type == "object"' "$(state::path)" > /dev/null || return 1
  io::ensure_dir "$(state::dir)/upgrades" 0700 || return 1
  backup="$(mktemp -d "$(state::dir)/upgrades/upgrade.XXXXXX")" || return 1
  # Keep credentials private, and retain the candidate/old binary for manual recovery.
  chmod 0700 "${backup}" || return 1
  cp -p "$(xray::bin)" "${backup}/xray" || return 1
  cp -p "$(state::path)" "${backup}/state.json" || return 1
  cp -RLp "$(xray::active)" "${backup}/config" || return 1
  if [[ -f "$(state::dir)/binary.sha256" ]]; then
    cp -p "$(state::dir)/binary.sha256" "${backup}/binary.sha256" || return 1
  fi
  core::log info "upgrade backup created" "$(printf '{"backup":"%s"}' "${backup}")"
  if ! xray::stage_upgrade "${backup}/stage" "${version}"; then
    core::log error "candidate installation failed; running service unchanged" '{}'
    return 1
  fi
  candidate="${backup}/stage/bin/xray"
  new_version="$(xray::installed_version "${candidate}")"
  if [[ "${new_version}" == unknown ]] || { [[ "${version}" != latest ]] && [[ "${new_version}" != "v${version#v}" ]]; }; then
    core::log error "candidate version does not match requested version" '{}'
    return 1
  fi
  if ! "${candidate}" run -test -confdir "$(xray::active)" -format json; then
    core::log error "candidate rejected current config; running service unchanged" '{}'
    return 1
  fi
  state="$(jq --arg version "${new_version}" '.version = $version' "${backup}/state.json")" || return 1
  xray::replace_binary "${candidate}" "$(xray::bin)" || return 1
  if ! systemctl restart xray || ! xray::verify_running_binary; then
    xray::rollback_upgrade "${backup}" || return 1
    return 1
  fi
  if ! state::save "${state}" || ! sha256sum "$(xray::bin)" | awk '{print $1}' | io::atomic_write "$(state::dir)/binary.sha256" 0644; then
    xray::rollback_upgrade "${backup}" || return 1
    return 1
  fi
  core::log info "binary upgrade complete; verify your client connection" "$(printf '{"version":"%s","backup":"%s"}' "${new_version}" "${backup}")"
}

main() {
  core::init "$@"
  local version=""
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --version)
        version="${2:-}"
        [[ $# -ge 2 ]] || return 2
        shift 2
        ;;
      --debug | --json) shift ;;
      --help)
        printf '%s\n' 'Usage: xrf upgrade --version <vX.Y.Z|latest> (latest selects a non-prerelease)'
        return 0
        ;;
      *)
        core::log error "unknown upgrade argument" '{}'
        return 2
        ;;
    esac
  done
  if [[ "${version}" != latest && ! "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    core::log error "specify --version vX.Y.Z or --version latest (stable)" '{}'
    return 2
  fi
  core::with_flock "$(state::lock)" xray::upgrade "${version}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
