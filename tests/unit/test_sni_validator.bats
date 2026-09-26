#!/usr/bin/env bats
# Actual diagnostic probe arguments and classification.
load ../test_helper

setup() {
  setup_test_env
  export XRF_PROBE_CALLS="${TEST_TMPDIR}/probe.calls"
  mkdir -p "${TEST_TMPDIR}/bin"
  cat > "${TEST_TMPDIR}/bin/timeout" <<'SCRIPT'
#!/usr/bin/env bash
shift
"$@"
SCRIPT
  cat > "${TEST_TMPDIR}/bin/openssl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >> "$XRF_PROBE_CALLS"
printf '%s\n' "${MOCK_TLS_VERSION:-Protocol: TLSv1.3}"
SCRIPT
  cat > "${TEST_TMPDIR}/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$XRF_PROBE_CALLS"
case "$*" in
  *http_version*) printf '%s' "${MOCK_HTTP_VERSION:-2}" ;;
  *redirect_url*) printf '%s' "${MOCK_REDIRECT_URL:-}" ;;
esac
SCRIPT
  chmod +x "${TEST_TMPDIR}/bin/"*
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export XRF_JSON=false
  source "${PROJECT_ROOT}/lib/sni_validator.sh"
}

teardown() { cleanup_test_env; }

@test "SNI diagnostic uses the same target host:port and SNI for TLS HTTP2 and redirects" {
  run sni::validate sni.example.com 8443 target.example.com
  [ "$status" -eq 0 ]
  grep -F -- '-connect target.example.com:8443 -servername sni.example.com -alpn h2 -tls1_3' "${XRF_PROBE_CALLS}"
  [ "$(grep -Fc -- '--connect-to sni.example.com:8443:target.example.com:8443' "${XRF_PROBE_CALLS}")" -eq 2 ]
  [ "$(grep -Fc -- 'https://sni.example.com:8443/' "${XRF_PROBE_CALLS}")" -eq 2 ]
}

@test "SNI diagnostic rejects TLS below 1.3" {
  export MOCK_TLS_VERSION='Protocol: TLSv1.2'
  run sni::validate sni.example.com 443 target.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *'TLS 1.3: false'* ]]
}

@test "SNI diagnostic rejects missing HTTP2" {
  export MOCK_HTTP_VERSION=1.1
  run sni::validate sni.example.com 443 target.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *'HTTP/2: false'* ]]
}

@test "SNI diagnostic rejects even a same-host redirect" {
  export MOCK_REDIRECT_URL='https://sni.example.com/login'
  run sni::validate sni.example.com 443 target.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *'no redirect: false'* ]]
}

@test "SNI diagnostic rejects malformed host and port before network calls" {
  run sni::validate 'bad host' 443 target.example.com
  [ "$status" -ne 0 ]
  [ ! -e "${XRF_PROBE_CALLS}" ]
  run sni::validate sni.example.com 65536 target.example.com
  [ "$status" -ne 0 ]
  [ ! -e "${XRF_PROBE_CALLS}" ]
}

@test "SNI diagnostic JSON reports target and failed result" {
  export XRF_JSON=true MOCK_HTTP_VERSION=1.1
  run sni::validate sni.example.com 443 target.example.com
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | sed -n '/^{/,/^}/p' | jq -e '.target.host == "target.example.com" and .target.port == 443 and .checks.http2 == false and .passed == false'
}
