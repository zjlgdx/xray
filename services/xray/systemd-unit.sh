#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/modules/io.sh"
. "${HERE}/modules/user/user.sh"
. "${HERE}/modules/state.sh"
# shellcheck source=services/xray/common.sh
. "${HERE}/services/xray/common.sh"

systemd::escape_sed_replacement() {
  printf '%s' "${1}" | sed -e 's/[|&\\]/\\&/g'
}

systemd::render_xray_unit() {
  local xray_bin confbase active_confdir
  local xray_bin_esc confbase_esc active_confdir_esc
  xray_bin="$(xray::bin)"
  confbase="$(xray::confbase)"
  active_confdir="$(xray::active)"
  xray_bin_esc="$(systemd::escape_sed_replacement "${xray_bin}")"
  confbase_esc="$(systemd::escape_sed_replacement "${confbase}")"
  active_confdir_esc="$(systemd::escape_sed_replacement "${active_confdir}")"

  sed \
    -e "s|/usr/local/bin/xray|${xray_bin_esc}|g" \
    -e "s|/usr/local/etc/xray/active|${active_confdir_esc}|g" \
    -e "s|/usr/local/etc/xray|${confbase_esc}|g" \
    "${HERE}/packaging/systemd/xray.service"
}

install_unit() {
  core::init "${@}"
  core::log info "installing systemd unit" "{}"
  core::with_flock "$(state::lock)" install_unit_with_lock
}
systemd_unit_path() {
  local base="${XRF_SYSTEMD_DIR:-/etc/systemd/system}"
  echo "${base%/}/xray.service"
}
install_unit_with_lock() {
  user::ensure_system_user xray xray || return 1
  local unit_file
  unit_file="$(systemd_unit_path)"
  core::log info "preparing systemd unit directory" "$(printf '{"dir":"%s"}' "$(dirname "${unit_file}")")"
  io::ensure_dir "$(dirname "${unit_file}")" 0755 || return 1
  core::log info "writing systemd unit file" "$(printf '{"path":"%s"}' "${unit_file}")"
  if ! systemd::render_xray_unit | io::atomic_write "${unit_file}" 0644; then
    core::log error "failed to write systemd unit" "$(printf '{"path":"%s"}' "${unit_file}")"
    return 1
  fi
  core::log info "reloading systemd manager configuration" '{}'
  if ! systemctl daemon-reload; then
    core::log error "systemctl daemon-reload failed" '{}'
    rm -f "${unit_file}" 2> /dev/null || true
    return 1
  fi
  core::log info "enabling and starting xray service" "$(printf '{"unit":"%s"}' "xray.service")"
  if ! systemctl enable --now xray; then
    core::log error "systemctl enable --now failed" "$(printf '{"unit":"%s"}' "xray.service")"
    rollback_systemd_unit "${unit_file}"
    return 1
  fi
  core::log info "systemd unit installed" "$(printf '{"path":"%s"}' "${unit_file}")"
}
rollback_systemd_unit() {
  local unit_file="${1}"
  core::log warn "rolling back systemd unit installation" "$(printf '{"path":"%s"}' "${unit_file}")"
  if ! systemctl disable --now xray; then
    core::log warn "systemctl disable during rollback failed" "$(printf '{"unit":"%s"}' "xray.service")"
  fi
  rm -f "${unit_file}" 2> /dev/null || true
  if ! systemctl daemon-reload; then
    core::log warn "systemctl daemon-reload during rollback failed" '{}'
  fi
  if ! systemctl reset-failed xray.service 2> /dev/null; then
    core::log warn "systemctl reset-failed during rollback failed" '{}'
  fi
}
remove_unit() {
  core::init "${@}"
  local unit_file active_state unit_state was_active=false was_enabled=false
  unit_file="$(systemd_unit_path)"
  active_state="$(systemctl show --property=ActiveState --value xray.service)" || return 1
  unit_state="$(systemctl show --property=UnitFileState --value xray.service)" || return 1
  case "${active_state}" in
    active) was_active=true ;;
    inactive | failed) ;;
    *)
      core::log error "unknown xray service state" "$(printf '{"state":"%s"}' "${active_state}")"
      return 1
      ;;
  esac
  case "${unit_state}" in
    enabled | enabled-runtime) was_enabled=true ;;
    disabled | static | masked | indirect | not-found) ;;
    "") [[ ! -e "${unit_file}" ]] || return 1 ;;
    *)
      core::log error "unknown xray unit state" "$(printf '{"state":"%s"}' "${unit_state}")"
      return 1
      ;;
  esac
  if [[ "${was_active}" == true ]]; then
    systemctl stop xray || return 1
  fi
  if [[ "${was_enabled}" == true ]]; then
    systemctl disable xray || return 1
  fi
  rm -f "${unit_file}" || return 1
  systemctl daemon-reload || return 1
  systemctl reset-failed xray.service 2> /dev/null || true
  core::log info "systemd unit removed" "{}"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1-}" in install) install_unit "${@}" ;; remove) remove_unit "${@}" ;; *)
    echo "Usage: ${0} {install|remove}"
    exit 2
    ;;
  esac
fi
