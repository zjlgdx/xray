#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/services/xray/common.sh"
. "${HERE}/modules/state.sh"

_rm() {
  local p="${1}"
  if [[ ! -e "${p}" && ! -L "${p}" ]]; then
    return 0
  fi

  core::log debug "removing" "$(printf '{"path":"%s"}' "$(core::json_escape "${p}")")"
  rm -rf "${p}"
}

uninstall_locked() {
  # Uninstall Xray
  "${HERE}/services/xray/systemd-unit.sh" remove || return 1
  _rm "$(xray::prefix)/bin/xray" || return 1
  _rm "$(xray::confbase)" || return 1
  core::log info "uninstallation complete" "{}"
}

main() {
  core::init "${@}"
  core::with_flock "$(state::lock)" uninstall_locked
}
main "${@}"
