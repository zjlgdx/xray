#!/usr/bin/env bash
# Explicit network diagnostic for the configured REALITY target and SNI.
[[ -n "${_XRF_SNI_VALIDATOR_LOADED:-}" ]] && return 0
readonly _XRF_SNI_VALIDATOR_LOADED=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
. "${HERE}/lib/core.sh"
# shellcheck source=lib/validators.sh
. "${HERE}/lib/validators.sh"

sni::check_tls13() {
  local sni="${1}" port="${2}" host="${3}"
  local output
  if ! output="$(timeout 10 openssl s_client -connect "${host}:${port}" -servername "${sni}" -alpn h2 -tls1_3 < /dev/null 2>&1)"; then
    core::log warn "TLS connection failed" "$(printf '{"target":"%s:%s"}' "${host}" "${port}")"
    return 1
  fi
  [[ "${output}" == *TLSv1.3* ]] || {
    core::log warn "TLS 1.3 not supported" '{}'
    return 1
  }
}

sni::check_http2() {
  local sni="${1}" port="${2}" host="${3}" version
  if ! version="$(timeout 10 curl -I -sS --http2 --max-time 10 \
    --connect-to "${sni}:${port}:${host}:${port}" \
    -w '%{http_version}' -o /dev/null "https://${sni}:${port}/")"; then
    core::log warn "HTTP/2 probe failed" '{}'
    return 1
  fi
  [[ "${version}" == 2 ]] || {
    core::log warn "HTTP/2 not supported" "$(printf '{"version":"%s"}' "${version}")"
    return 1
  }
}

sni::check_redirect() {
  local sni="${1}" port="${2}" host="${3}" redirect
  if ! redirect="$(timeout 10 curl -I -sS --max-time 10 \
    --connect-to "${sni}:${port}:${host}:${port}" \
    -w '%{redirect_url}' -o /dev/null "https://${sni}:${port}/")"; then
    core::log warn "redirect probe failed" '{}'
    return 1
  fi
  [[ -z "${redirect}" ]] || {
    core::log warn "target redirects" "$(printf '{"url":"%s"}' "$(core::json_escape "${redirect}")")"
    return 1
  }
}

sni::validate() {
  local sni="${1:-}" port="${2:-443}"
  local host="${3:-${sni}}"
  if ! validators::hostname "${sni}" || ! validators::hostname "${host}" || ! validators::port "${port}"; then
    core::log error "invalid SNI or target host:port" '{}'
    return 1
  fi
  core::log info "testing REALITY target" "$(printf '{"sni":"%s","target":"%s:%s"}' "${sni}" "${host}" "${port}")"

  local tls13_ok=false http2_ok=false redirect_ok=false passed=false
  sni::check_tls13 "${sni}" "${port}" "${host}" && tls13_ok=true
  sni::check_http2 "${sni}" "${port}" "${host}" && http2_ok=true
  sni::check_redirect "${sni}" "${port}" "${host}" && redirect_ok=true
  if [[ "${tls13_ok}" == true && "${http2_ok}" == true && "${redirect_ok}" == true ]]; then
    passed=true
  fi

  if [[ "${XRF_JSON:-false}" == true ]]; then
    jq -n --arg domain "${sni}" --arg host "${host}" --argjson port "${port}" \
      --argjson tls13 "${tls13_ok}" --argjson http2 "${http2_ok}" \
      --argjson no_redirect "${redirect_ok}" --argjson passed "${passed}" \
      '{domain:$domain,target:{host:$host,port:$port},checks:{tls13:$tls13,http2:$http2,no_redirect:$no_redirect},passed:$passed}'
  else
    printf 'SNI: %s, target: %s:%s\n' "${sni}" "${host}" "${port}"
    printf 'TLS 1.3: %s; HTTP/2: %s; no redirect: %s\n' "${tls13_ok}" "${http2_ok}" "${redirect_ok}"
  fi
  [[ "${passed}" == true ]]
}
