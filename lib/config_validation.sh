#!/usr/bin/env bash
# Multi-layer Xray configuration validation helpers.

[[ -n "${_XRF_CONFIG_VALIDATION_LOADED:-}" ]] && return 0
readonly _XRF_CONFIG_VALIDATION_LOADED=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
. "${HERE}/lib/core.sh"
# shellcheck source=lib/validators.sh
. "${HERE}/lib/validators.sh"
# shellcheck source=services/xray/common.sh
. "${HERE}/services/xray/common.sh"

config::_json_files() {
  local confdir="${1:?confdir required}"
  find "${confdir}" -maxdepth 1 -type f -name "*.json" | sort
}

config::_merge() {
  local confdir="${1:?confdir required}"
  local -a files=()
  while IFS= read -r file; do
    files+=("${file}")
  done < <(config::_json_files "${confdir}")
  if [[ "${#files[@]}" -eq 0 ]]; then
    return 1
  fi
  jq -s 'reduce .[] as $item ({}; . * $item)' "${files[@]}"
}

##
# Validate JSON syntax layer.
##
config::validate_json_syntax() {
  local confdir="${1:-}"
  if [[ -z "${confdir}" ]]; then
    core::log error "missing configuration directory" '{"layer":"json-syntax"}'
    return 1
  fi
  if [[ ! -d "${confdir}" ]]; then
    core::log error "configuration directory not found" "$(printf '{"layer":"json-syntax","confdir":"%s"}' "${confdir}")"
    return 1
  fi

  local -a files=()
  while IFS= read -r file; do
    files+=("${file}")
  done < <(config::_json_files "${confdir}")

  if [[ "${#files[@]}" -eq 0 ]]; then
    core::log error "no json configuration files found" "$(printf '{"layer":"json-syntax","confdir":"%s"}' "${confdir}")"
    return 1
  fi

  local file
  for file in "${files[@]}"; do
    if [[ ! -r "${file}" ]]; then
      core::log error "configuration file is not readable" "$(printf '{"layer":"json-syntax","file":"%s"}' "${file}")"
      return 1
    fi
    if ! jq empty "${file}" > /dev/null 2>&1; then
      core::log error "invalid json syntax detected" "$(printf '{"layer":"json-syntax","file":"%s"}' "${file}")"
      return 1
    fi
  done
  return 0
}

##
# Validate schema layer.
##
config::validate_schema() {
  local confdir="${1:-}"
  config::validate_json_syntax "${confdir}" || return 1

  local merged
  if ! merged="$(config::_merge "${confdir}")"; then
    core::log error "failed to merge json configuration" '{"layer":"schema"}'
    return 1
  fi

  config::_validate_schema_merged "${merged}"
}

# Internal layer check over an already parsed and merged configuration.
config::_validate_schema_merged() {
  local merged="${1:?merged configuration required}"

  if ! jq -e '.inbounds | type == "array"' <<< "${merged}" > /dev/null 2>&1; then
    core::log error "schema validation failed: inbounds must be an array" '{"layer":"schema"}'
    return 1
  fi
  if ! jq -e '.outbounds | type == "array"' <<< "${merged}" > /dev/null 2>&1; then
    core::log error "schema validation failed: outbounds must be an array" '{"layer":"schema"}'
    return 1
  fi

  if ! jq -e '.inbounds | all((.protocol? | type=="string") and (.tag? | type=="string"))' <<< "${merged}" > /dev/null 2>&1; then
    core::log error "schema validation failed: inbound protocol/tag missing or invalid type" '{"layer":"schema"}'
    return 1
  fi

  local port
  while IFS= read -r port; do
    [[ -n "${port}" ]] || continue
    if ! validators::port "${port}"; then
      core::log error "schema validation failed: invalid inbound port" "$(printf '{"layer":"schema","port":"%s"}' "${port}")"
      return 1
    fi
  done < <(jq -r '.inbounds[]?.port // empty' <<< "${merged}")

  if ! jq -e '.outbounds | all(.protocol? | type=="string")' <<< "${merged}" > /dev/null 2>&1; then
    core::log error "schema validation failed: outbound protocol missing or invalid type" '{"layer":"schema"}'
    return 1
  fi

  return 0
}

##
# Validate business rules layer.
##
config::validate_business_rules() {
  local confdir="${1:-}"
  config::validate_json_syntax "${confdir}" || return 1

  local merged
  if ! merged="$(config::_merge "${confdir}")"; then
    core::log error "failed to merge json configuration" '{"layer":"business-rules"}'
    return 1
  fi

  config::_validate_business_rules_merged "${merged}"
}

# Internal layer check over an already parsed and merged configuration.
config::_validate_business_rules_merged() {
  local merged="${1:?merged configuration required}"

  local -A port_seen=()
  local port
  while IFS= read -r port; do
    [[ -n "${port}" ]] || continue
    if [[ -n "${port_seen[${port}]:-}" ]]; then
      core::log error "business rule violation: duplicate inbound port" "$(printf '{"layer":"business-rules","port":"%s"}' "${port}")"
      return 1
    fi
    port_seen["${port}"]=1
  done < <(jq -r '.inbounds[]?.port // empty' <<< "${merged}")

  local -A outbound_tag_seen=()
  local tag
  while IFS= read -r tag; do
    [[ -n "${tag}" ]] || continue
    if [[ -n "${outbound_tag_seen[${tag}]:-}" ]]; then
      core::log error "business rule violation: duplicate outbound tag" "$(printf '{"layer":"business-rules","tag":"%s"}' "${tag}")"
      return 1
    fi
    outbound_tag_seen["${tag}"]=1
  done < <(jq -r '.outbounds[]?.tag // empty' <<< "${merged}")

  local strategy
  strategy="$(jq -r '.routing.domainStrategy // empty' <<< "${merged}")"
  if [[ -n "${strategy}" ]]; then
    case "${strategy}" in
      AsIs | IPIfNonMatch | IPOnDemand) ;;
      *)
        core::log error "business rule violation: unsupported routing domainStrategy" "$(printf '{"layer":"business-rules","strategy":"%s"}' "${strategy}")"
        return 1
        ;;
    esac
  fi

  return 0
}

##
# Validate binary layer (xray -test).
##
config::validate_binary() {
  local confdir="${1:-}"
  local xray_bin
  xray_bin="$(xray::bin)"
  if [[ ! -x "${xray_bin}" ]]; then
    core::log error "xray binary not found or not executable" "$(printf '{"layer":"binary","path":"%s"}' "${xray_bin}")"
    return 1
  fi

  local test_output
  if ! test_output="$("${xray_bin}" -test -confdir "${confdir}" -format json 2>&1)"; then
    core::log error "xray binary validation failed" "$(printf '{"layer":"binary","confdir":"%s"}' "${confdir}")"
    [[ -n "${test_output}" ]] && printf '%s\n' "${test_output}" >&2
    return 1
  fi

  local compat_warning
  while IFS= read -r compat_warning; do
    [[ -n "${compat_warning}" ]] || continue
    core::log warn "${compat_warning}" "$(printf '{"layer":"binary","confdir":"%s"}' "${confdir}")"
  done < <(xray::extract_compat_warnings "${test_output}")

  return 0
}

##
# Run three-layer deep validation.
##
config::validate_deep() {
  local confdir="${1:-}"
  core::log debug "running deep config validation" "$(printf '{"confdir":"%s"}' "${confdir}")"
  config::validate_json_syntax "${confdir}" || return 1
  local merged
  if ! merged="$(config::_merge "${confdir}")"; then
    core::log error "failed to merge json configuration" '{"layer":"schema"}'
    return 1
  fi
  config::_validate_schema_merged "${merged}" || return 1
  config::_validate_business_rules_merged "${merged}" || return 1
  return 0
}
