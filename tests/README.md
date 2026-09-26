# Xray-Fusion Test Suite

This directory contains the test suite for the xray-fusion project.

## Directory Structure

```
tests/
├── README.md           # This file
├── test_helper.bash    # Common test helper functions
├── unit/               # Unit tests
│   ├── test_args_validation.bats
│   └── test_core_functions.bats
├── integration/        # Integration tests (TODO)
└── helpers/            # Test helper scripts (TODO)
```

## Test Framework

Using [bats-core](https://github.com/bats-core/bats-core) - a testing framework designed for Bash.

### Install bats-core

```bash
# Ubuntu/Debian
sudo apt-get install bats

# macOS
brew install bats-core

# Manual installation
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

For real shell coverage commands (`make coverage-unit-real`), install `kcov` too.
On Ubuntu, if `kcov` reports missing shared libs, install `libbinutils libdw1 libelf1`.
`bats-core` also requires a readable `/dev/fd/0`; on minimal Linux containers,
restore it with `sudo ln -sf /proc/self/fd /dev/fd` before running `make test-unit`.

## Running Tests

```bash
# Run all tests
bats tests/**/*.bats

# Run unit tests only
bats tests/unit/*.bats

# Run specific test file
bats tests/unit/test_args_validation.bats

# Verbose output
bats -t tests/unit/*.bats

# Run in parallel
bats -j 4 tests/unit/*.bats

# Fail fast if the bats runtime is incomplete
make check-bats-runtime

# Workspace-backed Docker lifecycle smoke test
bash scripts/e2e/install-lifecycle-smoke.sh

# Raw GitHub online installer lifecycle smoke test (requires pushed branch)
XRF_SMOKE_MODE=online \
XRF_SMOKE_BRANCH=<branch> \
XRF_SMOKE_INSTALL_URL="https://raw.githubusercontent.com/xrf9268-hue/xray/<branch>/install.sh" \
XRF_SMOKE_UNINSTALL_URL="https://raw.githubusercontent.com/xrf9268-hue/xray/<branch>/uninstall.sh" \
bash scripts/e2e/install-lifecycle-smoke.sh
```

## Writing Tests

### Basic Structure

```bash
#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "describe your test" {
  run your_command args
  [ "$status" -eq 0 ]
  [[ "$output" == *"expected"* ]]
}
```

### Available Helper Functions

- `setup_test_env`: Create isolated test environment
- `cleanup_test_env`: Clean up test environment
- `assert_file_exists <file>`: Assert file exists
- `assert_dir_exists <dir>`: Assert directory exists
- `assert_equals <expected> <actual>`: Assert equality
- `assert_contains <haystack> <needle>`: Assert contains
- `assert_command_success <cmd> [args]`: Assert command succeeds
- `assert_command_fails <cmd> [args]`: Assert command fails

## Current Test Coverage

### Unit Tests

- ✅ **lib/args.sh**: Parameter validation (19 tests)
  - topology validation
  - domain validation (including internal domain blocking)
  - version validation
  - configuration cross-validation

- ✅ **lib/core.sh**: Core functionality (7 tests)
  - timestamp generation
  - log output (text/JSON)
  - debug log filtering
  - retry mechanism

- ✅ **lib/plugins.sh**: Plugin system (21 tests)
  - plugin directory management
  - plugin ID validation (security checks)
  - plugin enable/disable
  - plugin loading and metadata
  - event emission and hook invocation

- ✅ **modules/io.sh**: IO operations (20 tests)
  - directory creation and permissions
  - writability checks
  - atomic file writes
  - file installation

- ✅ **services/xray/common.sh**: Xray paths (15 tests)
  - path functions (prefix, etc, confbase, releases, active, bin)
  - environment variable overrides
  - path hierarchy consistency

### Test Statistics

- **Test files**: 5
- **Test cases**: 82
- **Code coverage**:
  - Collected with real shell execution via `kcov` (not estimated from test counts)
  - Unit coverage is gating in CI (`.github/coverage/unit-threshold.txt`)
  - Integration coverage is reported as non-gating artifacts

### TODO

- [ ] **services/xray/configure.sh**: Configuration generation tests
- [ ] **modules/web/caddy.sh**: Caddy management tests
- [ ] **integration**: Complete installation flow tests

## CI/CD Integration

Tests run automatically in GitHub Actions (see `.github/workflows/test.yml`).

Coverage commands:

```bash
make coverage-unit-real
make coverage-real
```

### Local Docker Coverage (Host Fallback)

If host `kcov` is unstable (for example, "Can't start/attach to bats" on macOS),
run coverage in an Ubuntu container with the same strategy as CI.

```bash
BASE_IMAGE="ubuntu:24.04"
if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
  docker pull "${BASE_IMAGE}" >/dev/null 2>&1 || BASE_IMAGE="docker.950288.xyz/library/ubuntu:24.04"
  docker pull "${BASE_IMAGE}" >/dev/null
fi

docker run --rm -v "$PWD":/workspace -w /workspace "${BASE_IMAGE}" bash -lc '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Optional: switch to a local mirror when upstream apt is unstable.
# sed -i "s|http://ports.ubuntu.com/ubuntu-ports/|http://<mirror>/ubuntu-ports/|g" /etc/apt/sources.list.d/ubuntu.sources

apt-get update -o Acquire::Retries=3
apt-get install -y --no-install-recommends \
  ca-certificates curl tar python3 jq cmake g++ make pkg-config \
  libdw-dev libelf-dev libiberty-dev libcurl4-openssl-dev libssl-dev \
  zlib1g-dev binutils-dev git

BATS_VERSION=v1.13.0
tmpdir="$(mktemp -d)"
curl -fsSL "https://github.com/bats-core/bats-core/archive/refs/tags/${BATS_VERSION}.tar.gz" | tar -xz -C "${tmpdir}"
"${tmpdir}/bats-core-${BATS_VERSION#v}/install.sh" /usr/local
rm -rf "${tmpdir}"

KCOV_VERSION=v42
tmpdir="$(mktemp -d)"
curl -fsSL "https://github.com/SimonKagstrom/kcov/archive/refs/tags/${KCOV_VERSION}.tar.gz" | tar -xz -C "${tmpdir}"
cd "${tmpdir}/kcov-${KCOV_VERSION#v}"
mkdir build && cd build
cmake -DCMAKE_INSTALL_PREFIX=/usr/local ..
make -j"$(nproc)"
make install

cd /workspace
kcov --bash-dont-parse-binary-dir \
  --include-path="/workspace/lib,/workspace/commands,/workspace/modules,/workspace/services,/workspace/plugins,/workspace/bin" \
  --exclude-path=/tmp \
  artifacts/coverage/docker-unit \
  bats tests/unit/*.bats || true
'
```

Notes for image source:

- Local runs may fall back to `docker.950288.xyz/library/ubuntu:24.04` when Docker Hub is unavailable.
- GitHub CI (`.github/workflows/test.yml`) does not use this proxy mirror.

Notes:

- `kcov` may exit non-zero with bats because of `DEBUG` trap conflicts; parse `coverage.json` and use it as the source of truth.
- In this report format, per-file entries use `.file` (not `.filename`).
- Typical output path: `artifacts/coverage/docker-unit/**/coverage.json`.

## Best Practices

1. **Isolation**: Each test uses independent temporary directories
2. **Idempotency**: Tests can be run repeatedly
3. **Speed**: Unit tests should be fast (< 1 second)
4. **Clarity**: Test names should describe expected behavior
5. **Coverage**: Prioritize testing critical paths and edge cases

## Debugging Tests

```bash
# Print each command (verbose mode)
bats -t tests/unit/test_args_validation.bats

# Run only specific test
bats tests/unit/test_args_validation.bats --filter "accepts valid domain"

# Stop on failure
bats --no-parallelize-across-files tests/unit/*.bats
```

### Upgrade/deployment regression coverage

- `unit/test_upgrade.bats`: production upgrade transaction with isolated candidate and
  service doubles; validates preservation, version selection, download/config failures,
  restart/process verification failures, metadata rollback, and fresh-install guard.
- `unit/test_deploy_transaction.bats`: production renderer/deployer; checks log preservation,
  explicit overrides, binary-aware restarts, validation failures and configuration rollback.

These tests never operate the host service or contact a VPS. They do not establish
Shadowrocket compatibility or external network reliability.
