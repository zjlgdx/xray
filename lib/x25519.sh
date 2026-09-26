#!/usr/bin/env bash
# X25519 key utilities shared across install and status workflows
# NOTE: This file is sourced. Strict mode is set by the calling script or core::init()

# Source guard: prevent double-sourcing
[[ -n "${_XRF_X25519_LOADED:-}" ]] && return 0
readonly _XRF_X25519_LOADED=1

x25519::trim() {
  local value="${1-}"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

x25519::sanitize_token() {
  local value="${1-}"
  value="${value//$'\r'/}"
  # Allow Base64 ("+/=") and Base64URL ("-_") alphabets so we can
  # parse outputs from newer Xray releases that switched to Base64URL
  # for x25519 keys. This maintains compatibility with older versions
  # while accepting the broader character set.
  value="$(printf '%s' "${value}" | tr -d -c 'A-Za-z0-9+/=_-')"
  printf '%s' "${value}"
}

x25519::parse_keys() {
  local output="${1}" line expect="" label value value_clean normalized
  local private="" public=""

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//$'\r'/}"
    [[ -z "${line//[[:space:]]/}" ]] && continue

    if [[ -n "${expect}" ]]; then
      value="$(x25519::trim "${line}")"
      value_clean="$(x25519::sanitize_token "${value}")"
      if [[ "${value_clean}" =~ ^[A-Za-z0-9+/=_-]{4,}$ ]]; then
        if [[ "${expect}" == "private" && -z "${private}" ]]; then
          private="${value}"
        elif [[ "${expect}" == "public" && -z "${public}" ]]; then
          public="${value}"
        fi
        expect=""
        continue
      fi
    fi

    [[ "${line}" != *:* ]] && continue

    label="${line%%:*}"
    value="${line#*:}"
    normalized="${label,,}"
    normalized="${normalized//[[:space:]]/}"
    normalized="${normalized//[^a-z]/}"
    value="$(x25519::trim "${value}")"
    value_clean="$(x25519::sanitize_token "${value}")"

    # Match PrivateKey or "Private key"
    if [[ "${normalized}" == *private*key* || "${normalized}" == "privatekey" ]]; then
      if [[ "${value_clean}" =~ ^[A-Za-z0-9+/=_-]{4,}$ && -z "${private}" ]]; then
        private="${value}"
        expect=""
        continue
      fi
      expect="private"
      continue
    fi

    # Match PublicKey, "Public key", or Password (new format)
    # In Xray v25.8.31+, the public key is labeled "Password"
    if [[ "${normalized}" == *public*key* || "${normalized}" == "publickey" || "${normalized}" == "password" ]]; then
      if [[ "${value_clean}" =~ ^[A-Za-z0-9+/=_-]{4,}$ && -z "${public}" ]]; then
        public="${value}"
        expect=""
        continue
      fi
      expect="public"
      continue
    fi
  done <<< "${output}"

  printf '%s\n%s\n' "${private}" "${public}"
}

x25519::derive_public_key() {
  local xray_bin="${1}" private_key="${2}" output public
  output="$("${xray_bin}" x25519 -i "${private_key}" 2> /dev/null)" || return 1
  public="$(x25519::parse_keys "${output}" | sed -n '2p')"
  [[ -n "${public}" ]] || return 1
  printf '%s\n' "${public}"
}
