#!/usr/bin/env bats
load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/preview.sh"
  export VERSION=latest XRF_JSON=false XRF_YES=false XRF_DRY_RUN=false XRAY_SNI=sni.example.com
}
teardown() { cleanup_test_env; }

@test "preview shows REALITY topology, version, port and explicit target" {
  run preview::show
  [ "$status" -eq 0 ]
  [[ "$output" == *'Topology: reality-only'* ]]
  [[ "$output" == *'Xray: latest'* ]]
  [[ "$output" == *'Port: 443 (REALITY)'* ]]
  [[ "$output" == *'SNI: sni.example.com'* ]]
  [[ "$output" == *'Target: sni.example.com:443'* ]]
  [[ "$output" != *'Vision'* && "$output" != *'Caddy'* && "$output" != *'Plugins'* ]]
}

@test "JSON preview uses one REALITY port" {
  export XRF_JSON=true XRAY_PORT=8443
  run preview::show
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.preview == {topology:"reality-only",version:"latest",port:8443,sni:"sni.example.com",target:"sni.example.com:443"}'
}

@test "confirmation and dry-run controls remain available" {
  export XRF_YES=true XRF_DRY_RUN=true
  run preview::confirm
  [ "$status" -eq 0 ]
  run preview::is_dry_run
  [ "$status" -eq 0 ]
}
