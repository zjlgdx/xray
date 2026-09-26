#!/usr/bin/env bats
# Real backup restore orchestration with sandboxed Xray and systemctl boundaries.
# shellcheck disable=SC1091,SC2329
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/backup.sh"
  export XRF_VAR="${TEST_TMPDIR}/var"
  export XRF_SVC_STATE="${TEST_TMPDIR}/service.state"
  export XRF_SVC_CALLS="${TEST_TMPDIR}/service.calls"
  export XRF_SVC_FAIL="${TEST_TMPDIR}/service.fail"
  local release="${XRF_ETC}/xray/releases/20260926000000"
  mkdir -p "${release}" "${XRF_PREFIX}/bin" "${TEST_TMPDIR}/mockbin"
  ln -s "${release}" "${XRF_ETC}/xray/active"
  printf '{"valid":true,"marker":"archived"}\n' >"${release}/config.json"
  cat >"${XRF_PREFIX}/bin/xray" <<'SCRIPT'
#!/usr/bin/env bash
[[ "${1:-}" == -test && "${2:-}" == -confdir ]] || exit 1
jq -e '.valid == true' "${3}/config.json" > /dev/null
SCRIPT
  chmod +x "${XRF_PREFIX}/bin/xray"
  mkdir -p "$(state::dir)"
  printf '{"name":"reality-only","credential":"archived"}\n' >"$(state::path)"
  printf 'archived-digest\n' >"$(state::digest)"
  cat >"${TEST_TMPDIR}/mockbin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$XRF_SVC_CALLS"
case "$1" in
  show)
    [[ "${2:-}" == --property=ActiveState ]] || exit 1
    state="$(cat "$XRF_SVC_STATE")"
    [[ "$state" != unknown ]] || exit 1
    printf '%s\n' "$state" ;;
  is-active) [[ "$(cat "$XRF_SVC_STATE")" == active ]] ;;
  stop)
    [[ "$(cat "$XRF_SVC_FAIL" 2>/dev/null)" == stop ]] && exit 1
    printf 'inactive\n' > "$XRF_SVC_STATE" ;;
  start)
    if [[ "$(cat "$XRF_SVC_FAIL" 2>/dev/null)" == start-once ]]; then
      printf 'none\n' > "$XRF_SVC_FAIL"
      exit 1
    fi
    printf 'active\n' > "$XRF_SVC_STATE" ;;
  *) exit 1 ;;
esac
SCRIPT
  chmod +x "${TEST_TMPDIR}/mockbin/systemctl"
  export PATH="${TEST_TMPDIR}/mockbin:${PATH}"
  printf 'active\n' >"${XRF_SVC_STATE}"
  backup::create candidate >/dev/null
  BACKUP_NAME="$(basename "$(find "$(backup::dir)" -name 'candidate-*.tar.gz' | head -1)" .tar.gz)"
  export BACKUP_NAME
  printf '{"valid":true,"marker":"current"}\n' >"${release}/config.json"
  printf '{"name":"reality-only","credential":"current"}\n' >"$(state::path)"
  printf 'current-digest\n' >"$(state::digest)"
  : >"${XRF_SVC_CALLS}"
}

teardown() { cleanup_test_env; }

assert_current() {
  jq -e '.marker == "current"' "$(xray::active)/config.json" >/dev/null
  jq -e '.credential == "current"' "$(state::path)" >/dev/null
  [[ "$(cat "$(state::digest)")" == current-digest ]]
  [[ "$(cat "${XRF_SVC_STATE}")" == active ]]
}

rewrite_candidate_archive() {
  local extracted="${TEST_TMPDIR}/tamper"
  mkdir -p "${extracted}"
  tar -xzf "$(backup::dir)/${BACKUP_NAME}.tar.gz" -C "${extracted}"
  "$@" "${extracted}"
  tar -czf "$(backup::dir)/${BACKUP_NAME}.tar.gz" -C "${extracted}" .
  local hash
  hash="$(sha256sum "$(backup::dir)/${BACKUP_NAME}.tar.gz" | awk '{print $1}')"
  jq --arg hash "${hash}" '.hash = $hash' "$(backup::dir)/${BACKUP_NAME}.metadata.json" >"${TEST_TMPDIR}/metadata"
  mv "${TEST_TMPDIR}/metadata" "$(backup::dir)/${BACKUP_NAME}.metadata.json"
}

archive_release_link_to_live() {
  local extracted="$1"
  rm -rf "${extracted}/xray/releases/20260926000000"
  ln -s "${XRF_ETC}/xray/releases/20260926000000" "${extracted}/xray/releases/20260926000000"
}

archive_releases_parent_link_to_live() {
  local extracted="$1"
  rm -rf "${extracted}/xray/releases"
  ln -s "${XRF_ETC}/xray/releases" "${extracted}/xray/releases"
}

archive_json_link_to_live() {
  local extracted="$1"
  rm -f "${extracted}/xray/releases/20260926000000/config.json"
  ln -s "${XRF_ETC}/xray/releases/20260926000000/config.json" "${extracted}/xray/releases/20260926000000/config.json"
}

archive_xray_parent_link_to_live() {
  local extracted="$1"
  rm -rf "${extracted}/xray"
  ln -s "${XRF_ETC}/xray" "${extracted}/xray"
}

@test "restore rejects archived release symlink to live tree before touching stopped service" {
  printf 'inactive\n' >"${XRF_SVC_STATE}"
  rewrite_candidate_archive archive_release_link_to_live
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  jq -e '.marker == "current"' "$(xray::active)/config.json" >/dev/null
  [ "$(cat "${XRF_SVC_STATE}")" = inactive ]
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore rejects archived releases parent symlink to live tree" {
  rewrite_candidate_archive archive_releases_parent_link_to_live
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore rejects archived config JSON symlink to live tree" {
  rewrite_candidate_archive archive_json_link_to_live
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore rejects archived xray parent symlink to live tree" {
  rewrite_candidate_archive archive_xray_parent_link_to_live
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore refuses missing current digest before stopping for its safety backup" {
  rm -f "$(state::digest)"
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  jq -e '.marker == "current"' "$(xray::active)/config.json" >/dev/null
  [ ! -e "$(state::digest)" ]
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore fails closed when service state query fails" {
  printf 'unknown\n' >"${XRF_SVC_STATE}"
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  jq -e '.marker == "current"' "$(xray::active)/config.json" >/dev/null
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore validates the archived release rather than the live active symlink" {
  local extracted="${TEST_TMPDIR}/tamper"
  mkdir -p "${extracted}"
  tar -xzf "$(backup::dir)/${BACKUP_NAME}.tar.gz" -C "${extracted}"
  printf '{"valid":false,"marker":"bad"}\n' >"${extracted}/xray/releases/20260926000000/config.json"
  tar -czf "$(backup::dir)/${BACKUP_NAME}.tar.gz" -C "${extracted}" .
  local hash
  hash="$(sha256sum "$(backup::dir)/${BACKUP_NAME}.tar.gz" | awk '{print $1}')"
  jq --arg hash "${hash}" '.hash = $hash' "$(backup::dir)/${BACKUP_NAME}.metadata.json" >"${TEST_TMPDIR}/metadata"
  mv "${TEST_TMPDIR}/metadata" "$(backup::dir)/${BACKUP_NAME}.metadata.json"

  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore aborts before stopping when pre-restore backup fails" {
  backup::_create_locked() { return 1; }
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore stop failure keeps current configuration and active service" {
  printf 'stop\n' >"${XRF_SVC_FAIL}"
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
}

@test "restore cannot change live files while the shared lock is held" {
  local lock
  lock="$(state::lock)"
  mkdir -p "$(dirname "${lock}")"
  if command -v flock >/dev/null 2>&1; then
    bash -c 'exec 200>> "$1"; flock -x 200; touch "$2"; sleep 3' _ "${lock}" "${TEST_TMPDIR}/held" &
    local holder=$!
    while [[ ! -f "${TEST_TMPDIR}/held" ]]; do sleep 0.01; done
  else
    mkdir "${lock}.d"
  fi

  XRF_FLOCK_TIMEOUT_SEC=1 run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]

  if [[ -n "${holder:-}" ]]; then
    kill "${holder}" 2>/dev/null || true
    wait "${holder}" 2>/dev/null || true
  else
    rmdir "${lock}.d"
  fi
}

@test "backup creation reads state under the shared configuration lock" {
  local lock
  lock="$(state::lock)"
  mkdir -p "$(dirname "${lock}")"
  if command -v flock >/dev/null 2>&1; then
    bash -c 'exec 200>> "$1"; flock -x 200; touch "$2"; sleep 3' _ "${lock}" "${TEST_TMPDIR}/held" &
    local holder=$!
    while [[ ! -f "${TEST_TMPDIR}/held" ]]; do sleep 0.01; done
  else
    mkdir "${lock}.d"
  fi

  XRF_FLOCK_TIMEOUT_SEC=1 run backup::create blocked
  [ "$status" -ne 0 ]
  [ -z "$(find "$(backup::dir)" -name 'blocked-*.tar.gz' -print -quit)" ]

  if [[ -n "${holder:-}" ]]; then
    kill "${holder}" 2>/dev/null || true
    wait "${holder}" 2>/dev/null || true
  else
    rmdir "${lock}.d"
  fi
}

@test "restore rolls back config copy failure" {
  cp() {
    if [[ "$*" == *'/candidate/xray '* ]]; then return 1; fi
    command cp "$@"
  }
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
}

@test "restore rolls back state write failure" {
  state::save() { return 1; }
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
}

@test "restore rolls back digest write failure" {
  cp() {
    if [[ "$*" == *'/candidate/config.sha256 '* ]]; then return 1; fi
    command cp "$@"
  }
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
}

@test "restore rolls back start failure and restarts old service" {
  printf 'start-once\n' >"${XRF_SVC_FAIL}"
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  assert_current
}

@test "restore refuses absent old state and digest before stopping" {
  rm -f "$(state::path)" "$(state::digest)"
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  jq -e '.marker == "current"' "$(xray::active)/config.json" >/dev/null
  [ ! -e "$(state::path)" ]
  [ ! -e "$(state::digest)" ]
  [[ "$(cat "${XRF_SVC_STATE}")" == active ]]
  run grep -q '^stop ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}

@test "restore retains private recovery material if rollback fails" {
  state::save() { return 1; }
  mv() {
    if [[ "${1:-}" == */old ]]; then return 1; fi
    command mv "$@"
  }
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -ne 0 ]
  [[ "$output" == *'recovery retained'* ]]
  local recovery
  recovery="$(find "${XRF_ETC}" -maxdepth 1 -name '.xray-restore.*' -type d | head -1)"
  [ -d "${recovery}" ]
  [ "$(stat -c '%a' "${recovery}" 2>/dev/null || stat -f '%Lp' "${recovery}")" = 700 ]
  [ -d "${recovery}/old" ]
  [ -f "${recovery}/state.json" ]
}

@test "restore succeeds for a previously active service and private credentials" {
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -eq 0 ]
  jq -e '.marker == "archived"' "$(xray::active)/config.json" >/dev/null
  jq -e '.credential == "archived"' "$(state::path)" >/dev/null
  [[ "$(cat "$(state::digest)")" == archived-digest ]]
  [[ "$(cat "${XRF_SVC_STATE}")" == active ]]
  [ "$(stat -c '%a' "$(backup::dir)" 2>/dev/null || stat -f '%Lp' "$(backup::dir)")" = 700 ]
  [ "$(stat -c '%a' "$(state::path)" 2>/dev/null || stat -f '%Lp' "$(state::path)")" = 600 ]
}

@test "restore leaves a previously stopped service stopped" {
  printf 'inactive\n' >"${XRF_SVC_STATE}"
  run backup::restore "${BACKUP_NAME}"
  [ "$status" -eq 0 ]
  [[ "$(cat "${XRF_SVC_STATE}")" == inactive ]]
  run grep -q '^start ' "${XRF_SVC_CALLS}"
  [ "$status" -eq 1 ]
}
