#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/lib/validators.sh"
. "${HERE}/modules/state.sh"
. "${HERE}/modules/net/network.sh"

main() {
  core::init "$@"
  local path state uuid port sni sid pbk fp ip
  path="$(state::path)"
  if [[ ! -r "${path}" ]]; then
    core::log error "connection state is not readable; run xrf links with access to private state" '{}'
    return 1
  fi
  state="$(cat "${path}")" || return 1
  if ! jq -e '.name == "reality-only" and (.xray | type == "object")' <<< "${state}" > /dev/null; then
    core::log error "unsupported or invalid connection state" '{}'
    return 1
  fi
  uuid="$(jq -r '.xray.uuid // empty' <<< "${state}")"
  port="$(jq -r '.xray.port // empty' <<< "${state}")"
  sni="$(jq -r '.xray.reality_sni // empty' <<< "${state}")"
  sid="$(jq -r '.xray.short_id // empty' <<< "${state}")"
  pbk="$(jq -r '.xray.reality_public_key // empty' <<< "${state}")"
  fp="$(jq -r '.xray.fingerprint // "chrome"' <<< "${state}")"
  if [[ -z "${uuid}" || -z "${port}" || -z "${sni}" || -z "${sid}" || -z "${pbk}" ]] \
    || ! validators::uuid "${uuid}" || ! validators::port "${port}" || ! validators::shortid "${sid}"; then
    core::log error "connection credentials are incomplete or invalid" '{}'
    return 1
  fi
  sni="${sni%%,*}"
  if ! validators::hostname "${sni}" || ! validators::fingerprint "${fp}" || [[ ! "${pbk}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    core::log error "connection credentials are unsafe for a URI" '{}'
    return 1
  fi
  ip="${XRAY_SERVER_IP:-}"
  [[ -n "${ip}" ]] || ip="$(net::detect_public_ip)" || return 1
  if [[ -z "${ip}" ]]; then
    core::log error "cannot determine server IP" '{}'
    return 1
  fi
  if [[ ! "${ip}" =~ ^[0-9.]+$ && ! "${ip}" =~ ^[0-9a-fA-F:]+$ ]]; then
    core::log error "server IP is invalid for a URI" '{}'
    return 1
  fi
  [[ "${ip}" == *:* && "${ip}" != \[*\] ]] && ip="[${ip}]"
  printf '========== LINKS ==========\n'
  printf 'REALITY: vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&spx=%%2F#REALITY-%s\n' \
    "${uuid}" "${ip}" "${port}" "${sni}" "${fp}" "${pbk}" "${sid}" "${ip}"
  printf '==========================\n'
}
main "$@"
