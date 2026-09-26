#!/usr/bin/env bats
# Production test-sni CLI argument and exit behavior.
load ../test_helper

setup() {
  setup_test_env
  mkdir -p "${TEST_TMPDIR}/bin"
  export XRF_PROBE_CALLS="${TEST_TMPDIR}/probe.calls"
  cat > "${TEST_TMPDIR}/bin/timeout" <<'SCRIPT'
#!/usr/bin/env bash
shift
"$@"
SCRIPT
  cat > "${TEST_TMPDIR}/bin/openssl" <<'SCRIPT'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >> "$XRF_PROBE_CALLS"
printf 'Protocol: %s\n' "${MOCK_TLS_VERSION:-TLSv1.3}"
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
}

teardown() { cleanup_test_env; }

@test "test-sni help documents explicit target" {
  run "${PROJECT_ROOT}/commands/test-sni.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'--target <host:port>'* ]]
}

@test "test-sni requires SNI and rejects ambiguous or malformed target" {
  run "${PROJECT_ROOT}/commands/test-sni.sh"
  [ "$status" -ne 0 ]
  run "${PROJECT_ROOT}/commands/test-sni.sh" sni.example.com --target target.example.com:443 --port 443
  [ "$status" -ne 0 ]
  run "${PROJECT_ROOT}/commands/test-sni.sh" sni.example.com --target target.example.com:bad
  [ "$status" -ne 0 ]
  [ ! -e "${XRF_PROBE_CALLS}" ]
}

@test "test-sni sends explicit target and SNI through the production validator" {
  run "${PROJECT_ROOT}/commands/test-sni.sh" sni.example.com --target target.example.com:8443 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
  grep -F -- '-connect target.example.com:8443 -servername sni.example.com' "${XRF_PROBE_CALLS}"
  [ "$(grep -Fc -- '--connect-to sni.example.com:8443:target.example.com:8443' "${XRF_PROBE_CALLS}")" -eq 2 ]
}

@test "test-sni defaults target to SNI port 443" {
  run "${PROJECT_ROOT}/commands/test-sni.sh" sni.example.com --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"port": 443'* ]]
  grep -F -- '-connect sni.example.com:443 -servername sni.example.com' "${XRF_PROBE_CALLS}"
}

@test "test-sni propagates diagnostic failure in JSON" {
  export MOCK_REDIRECT_URL='https://sni.example.com/login'
  run "${PROJECT_ROOT}/commands/test-sni.sh" sni.example.com --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"passed": false'* ]]
}
