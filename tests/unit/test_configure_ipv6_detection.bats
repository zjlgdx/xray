#!/usr/bin/env bats
# Unit tests for IPv6 dual-stack auto-detection in services/xray/configure.sh
# shellcheck disable=SC2154

load ../test_helper

setup() {
  setup_test_env

  export XRF_PLUGINS="${TEST_TMPDIR}/plugins"
  mkdir -p "${XRF_PLUGINS}/available" "${XRF_PLUGINS}/enabled"

  export PATH="${TEST_TMPDIR}/mockbin:${PATH}"
  mkdir -p "${TEST_TMPDIR}/mockbin"

  cat > "${TEST_TMPDIR}/mockbin/mv" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-Tf" ]]; then
  shift
  exec /bin/mv -f "$@"
fi
exec /bin/mv "$@"
SCRIPT
  chmod +x "${TEST_TMPDIR}/mockbin/mv"

  export XRAY_UUID="11111111-1111-4111-8111-111111111111"
  export XRAY_SHORT_ID="abcd1234"
  export XRAY_PRIVATE_KEY="test-private-key"
  export XRAY_SNI="www.microsoft.com"
  export XRAY_REALITY_DEST="www.microsoft.com:443"
}

teardown() {
  cleanup_test_env
}

write_mock_ip() {
  local mode="${1:?mode required}"
  local ip_mock="${TEST_TMPDIR}/mockbin/ip"

  case "${mode}" in
    global)
      cat > "${ip_mock}" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-6" && "${2:-}" == "addr" && "${3:-}" == "show" ]]; then
  cat <<'OUT'
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet6 2001:db8::100/64 scope global dynamic
OUT
  exit 0
fi
exit 1
SCRIPT
      ;;
    loopback)
      cat > "${ip_mock}" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-6" && "${2:-}" == "addr" && "${3:-}" == "show" ]]; then
  cat <<'OUT'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
    inet6 ::1/128 scope host
OUT
  exit 0
fi
exit 1
SCRIPT
      ;;
    *)
      echo "unknown mode: ${mode}" >&2
      return 1
      ;;
  esac

  chmod +x "${ip_mock}"
}

@test "configure uses IPv4-only strategy when IPv6 unsupported" {
  export XRF_IPV6_IF_INET6_PATH="${TEST_TMPDIR}/proc/net/if_inet6"
  write_mock_ip "loopback"

  run "${PROJECT_ROOT}/services/xray/configure.sh" --topology reality-only
  [ "${status}" -eq 0 ]

  run jq -r '.inbounds[0].listen' "${XRF_ETC}/xray/active/05_inbounds.json"
  [ "${status}" -eq 0 ]
  [ "${output}" = "0.0.0.0" ]

  run jq -r '.dns.queryStrategy' "${XRF_ETC}/xray/active/07_dns.json"
  [ "${status}" -eq 0 ]
  [ "${output}" = "UseIPv4" ]
}

@test "configure uses dual-stack strategy when global IPv6 is available" {
  mkdir -p "${TEST_TMPDIR}/proc/net"
  : > "${TEST_TMPDIR}/proc/net/if_inet6"
  export XRF_IPV6_IF_INET6_PATH="${TEST_TMPDIR}/proc/net/if_inet6"
  write_mock_ip "global"

  run "${PROJECT_ROOT}/services/xray/configure.sh" --topology reality-only
  [ "${status}" -eq 0 ]

  run jq -r '.inbounds[0].listen' "${XRF_ETC}/xray/active/05_inbounds.json"
  [ "${status}" -eq 0 ]
  [ "${output}" = "::" ]

  run jq -r '.dns.queryStrategy' "${XRF_ETC}/xray/active/07_dns.json"
  [ "${status}" -eq 0 ]
  [ "${output}" = "UseIP" ]
}
