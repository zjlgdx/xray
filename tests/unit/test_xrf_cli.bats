#!/usr/bin/env bats
# Exercise the real CLI dispatcher with isolated command executables.

load ../test_helper

setup() {
  setup_test_env
  local tree="${TEST_TMPDIR}/tree"
  mkdir -p "${tree}/bin" "${tree}/lib" "${tree}/commands" "${tree}/services/xray"
  cp "${PROJECT_ROOT}/bin/xrf" "${tree}/bin/xrf"
  printf ':\n' > "${tree}/lib/core.sh"
  local name
  for name in install status uninstall logs backup check test-sni health; do
    printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "%s" "$*"\n' "${name}" > "${tree}/commands/${name}.sh"
    chmod +x "${tree}/commands/${name}.sh"
  done
  for name in upgrade client-links; do
    printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "%s" "$*"\n' "${name}" > "${tree}/services/xray/${name}.sh"
    chmod +x "${tree}/services/xray/${name}.sh"
  done
  export TEST_CLI="${tree}/bin/xrf"
}

teardown() { cleanup_test_env; }

@test "xrf dispatches every retained command through the real entrypoint" {
  local command expected
  for command in install upgrade status uninstall links logs backup check test-sni health; do
    expected="${command}"
    [[ "${command}" == links ]] && expected=client-links
    run "${TEST_CLI}" "${command}" --example argument
    [ "$status" -eq 0 ]
    [ "$output" = "${expected}|--example argument" ]
  done
}

@test "xrf help lists retained command rows and omits retired entrypoints" {
  run "${TEST_CLI}" help
  [ "$status" -eq 0 ]
  for command in install upgrade status uninstall links logs backup check test-sni health; do
    [[ "$output" =~ (^|$'\n')'  '${command}' '[^$'\n']+ ]]
  done
  for command in export templates plugin; do
    [[ ! "$output" =~ (^|$'\n')'  '${command}' '[^$'\n']+ ]]
  done
}

@test "xrf rejects retired commands with exit 2" {
  local command
  for command in export templates plugin; do
    run "${TEST_CLI}" "${command}"
    [ "$status" -eq 2 ]
  done
}

@test "xrf rejects unknown command and empty invocation shows help" {
  run "${TEST_CLI}" something-else
  [ "$status" -eq 2 ]
  run "${TEST_CLI}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: xrf <command>"* ]]
}
