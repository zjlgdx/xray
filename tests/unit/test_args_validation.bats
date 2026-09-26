#!/usr/bin/env bats
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/args.sh"
  args::init
}
teardown() { cleanup_test_env; }

@test "default install version is latest" {
  [ "$VERSION" = latest ]
}

@test "retired topology is rejected" {
  run args::parse --topology reality-only
  [ "$status" -ne 0 ]
}

@test "retired domain template plugin and encryption arguments are rejected" {
  for flag in --domain --template --plugins --enable-vless-encryption --vless-decryption --vless-encryption; do
    run args::parse "$flag" value
    [ "$status" -ne 0 ]
  done
}

@test "version parser retains latest and explicit releases" {
  run args::parse --version latest
  [ "$status" -eq 0 ]
  run args::parse --version v26.9.9
  [ "$status" -eq 0 ]
  run args::parse --version nonsense
  [ "$status" -ne 0 ]
}

@test "UUID alternatives cannot both be selected" {
  run args::parse --uuid 11111111-2222-4333-8444-555555555555 --uuid-from-string seed
  [ "$status" -ne 0 ]
}

@test "fingerprint and install control flags still parse" {
  args::parse --fingerprint safari --dry-run --yes
  [ "$FINGERPRINT" = safari ]
  [ "$XRF_DRY_RUN" = true ]
  [ "$XRF_YES" = true ]
}
