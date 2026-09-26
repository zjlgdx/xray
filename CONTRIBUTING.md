# Contributing to xray-fusion

Thank you for your interest in contributing to xray-fusion! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Documentation](#documentation)

---

## Code of Conduct

- **Be respectful**: Treat all contributors with respect
- **Be constructive**: Provide helpful feedback
- **Be professional**: Keep discussions focused on technical merits
- **Be patient**: Remember that everyone is learning

---

## Getting Started

### Prerequisites

- Bash 4.0+ (for strict mode and modern features)
- ShellCheck for static analysis
- shfmt for code formatting
- bats-core for testing
- kcov for real shell coverage (Linux may also require `libbinutils libdw1 libelf1`)
- A readable `/dev/fd` (required by bats-core process substitution)

### Development Environment Setup

Develop from a Git checkout. The online installer deploys only `bin/`, `commands/`,
`lib/`, `modules/`, `services/`, `packaging/`, `uninstall.sh`, and `LICENSE`; it
preserves executable modes from the verified checkout. Tests, docs, CI helpers,
and the online installer itself are not part of the installed runtime. Changes
that add a runtime directory must update this explicit payload and its tests.

```bash
# Clone the repository
git clone https://github.com/zjlgdx/xray.git
cd xray

# Install development dependencies
# Ubuntu/Debian
sudo apt-get install shellcheck shfmt bats jq kcov libbinutils libdw1 libelf1

# macOS
brew install shellcheck shfmt bats-core jq kcov

# Verify tools are installed
shellcheck --version
shfmt -version
bats --version
kcov --version
test -r /dev/fd/0 || sudo ln -sf /proc/self/fd /dev/fd
```

### Running Tests

```bash
# Run all tests
make test

# Run only unit tests
make test-unit

# Run only integration tests
make test-integration

# Run linting
make lint

# Format code
make fmt
```

For backup retention changes, use fixed archive modification times and custom
prefixes whose alphabetical order differs from time order. For health JSON,
parse stdout with `jq -e` and include multiple compatibility warnings; do not
mix stderr diagnostics into the report. Deep config validation reuses one syntax
pass and merged value; public layer validators must remain independently usable.
Exercise the installed `active` directory symlink as well as ordinary directories.
Compatibility checks over configuration must inspect JSON fields; reserve text
warning extraction for actual Xray output so loglevel/tag text cannot trigger
unrelated diagnostics.

If `make test-unit` fails before running any tests with a `/dev/fd/...` error, your
environment is missing the file-descriptor filesystem that bats-core expects.
On Linux, restore it with `sudo ln -sf /proc/self/fd /dev/fd`.

---

## Development Workflow

### Environment Options

Use the host shell as the baseline workflow for this repository. Supported
setups include:

- Linux or macOS local shell
- Windows via WSL
- Optional [`thin-devbox-shell`](https://github.com/xrf9268-hue/thin-devbox-shell)
  as a reproducible shell layer

`thin-devbox-shell` is optional. Do not assume it is always present, and do not
assume Docker can be called from inside the shared shell container. For Docker
lifecycle and online-install validation, prefer fresh host Docker containers.
Repository-local workflow docs in this repository remain authoritative even when
you choose the shared shell for command execution.

### 1. Create a Feature Branch

```bash
# Start from origin/main in a new worktree when another task is already active
git fetch origin
git worktree add -b codex/your-task-name ../xray-your-task-name origin/main
cd ../xray-your-task-name
```

### 2. Make Changes

Follow the [Coding Standards](#coding-standards) section below.

### 3. Test Your Changes

```bash
# Lint your changes
make lint

# Format your code
make fmt

# Run tests
make test

# Test a manual install only inside a disposable Linux container or VM;
# the installer also manages a service user and systemd unit.
XRAY_SNI=your-tested-target.example bin/xrf install --yes
```

### 4. Commit Your Changes

Follow the [Commit Guidelines](#commit-guidelines) section below.

### 5. Push and Create PR

```bash
git push origin codex/your-task-name
```

Then create a pull request on GitHub.

After each push or PR update, monitor GitHub Actions for the pushed commit until
required checks finish. If a required check fails, fix the issue, rerun
relevant local validation, and push again until the checks pass.

---

## Coding Standards

### File Organization

- `bin/`: CLI entrypoints
- `commands/`: High-level workflows (install, status, uninstall)
- `lib/`: Core utilities (core.sh, args.sh, validators.sh, backup.sh, errors.sh, defaults.sh)
- `modules/`: Reusable helpers (io.sh, state.sh, user/*, net/network.sh)
- `services/xray/`: Xray-specific logic
- `scripts/`: Lifecycle smoke and CI scripts
- `tests/`: Unit and integration tests

### Bash Style Guide

#### File Header

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${HERE}/lib/core.sh"
```

#### Naming Conventions

- **Functions**: `namespace::function` (e.g., `core::log`, `io::atomic_write`)
- **Variables**: lowercase `local` variables, UPPER_SNAKE for exported/env vars
- **Files**: kebab-case for new standalone scripts

#### Indentation

- **2 spaces** (no tabs)
- Use shfmt to format: `shfmt -i 2 -ci -sr -bn -ln=bash -w file.sh`

#### Function Documentation

All public functions must include ShellDoc-style comments:

```bash
##
# Brief one-line description
#
# Detailed description explaining what the function does,
# why it exists, and any important notes.
#
# Arguments:
#   $1 - Parameter name (type, required/optional, description)
#   $2 - Parameter name (type, optional, default: value)
#
# Returns:
#   0 - Success description
#   1 - Error description
#
# Security:
#   Security considerations (CWE references if applicable)
#
# Example:
#   function_name arg1 arg2
##
function_name() {
  local arg1="${1}"
  local arg2="${2:-default}"
  # implementation
}
```

**See**: AGENTS.md "Function Documentation" section

#### Logging Standards

```bash
# Always use core::log, never echo for logs
core::log info "Operation completed" '{"duration_ms":123}'
core::log error "Failed to read file" "$(printf '{"file":"%s"}' "${path}")"

# All logs go to stderr
core::log debug "Debug information" "$(printf '{"var":"%s"}' "${value}")"
```

**Log Levels**:
- `debug`: Debug information (filtered unless `XRF_DEBUG=true`)
- `info`: Informational messages
- `warn`: Warnings
- `error`: Recoverable errors
- `critical`: Severe errors (logged, execution continues)
- `fatal`: Unrecoverable errors (logs and exits immediately)

#### Error Handling

```bash
# Use standardized error codes from lib/errors.sh
. "${HERE}/lib/errors.sh"

# Return error codes
validators::port "${port}" || return "${ERR_INVALID_ARG}"

# Use fatal log level for unrecoverable failures (exits immediately)
core::log fatal "XRAY_PRIVATE_KEY required"
```

#### Avoid Common Pitfalls

**✅ Good**:
```bash
# Use full path in HERE document
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Atomic file operations
echo "content" | io::atomic_write "/etc/app/config" "0640"

# Proper variable quoting
local file_path="${1}"
[[ -f "${file_path}" ]] && echo "File exists"

# Logging to stderr
core::log error "Failed" "$(printf '{"code":%d}' "${code}")"
```

**❌ Bad**:
```bash
# Using echo for logs
echo "[ERROR] Failed"  # Pollutes stdout, inconsistent format

# Using traps in utility functions
io::atomic_write() {
  local tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' EXIT  # Breaks in pipelines!
  # ...
}

# Direct temp file creation without security
tmp="/tmp/predictable-name"  # CWE-59: Predictable name

# Missing error handling
cp file1 file2  # What if it fails?
```

**See**: AGENTS.md "Shell Patterns" section

---

## Testing

### Unit Tests

Unit tests use bats-core framework.

#### Creating Unit Tests

```bash
# tests/unit/test_mymodule.bats
#!/usr/bin/env bats
# Unit tests for mymodule

load ../test_helper

setup() {
  setup_test_env
  source "${HERE}/lib/mymodule.sh"
}

@test "mymodule::function - success case" {
  run mymodule::function "valid_input"
  [ "$status" -eq 0 ]
  [ "$output" = "expected_output" ]
}

@test "mymodule::function - handles empty input" {
  run mymodule::function ""
  [ "$status" -eq 1 ]
}
```

#### Running Unit Tests

```bash
# Run all unit tests
make test-unit

# Run specific test file
bats tests/unit/test_validators.bats

# Run with verbose output
bats -t tests/unit/test_validators.bats
```

### Integration Tests

Integration tests verify end-to-end workflows.

```bash
# tests/integration/test_workflow.bats
#!/usr/bin/env bats
# Integration test for workflow

load test_helper

setup() {
  setup_integration_env
}

teardown() {
  cleanup_integration_env
}

@test "workflow - completes successfully" {
  run env XRAY_SNI=your-tested-target.example bin/xrf install
  [ "$status" -eq 0 ]
  # Verify results...
}
```

### Test Coverage

Coverage is measured using real shell execution with `kcov` in CI.

- Unit coverage is gating and enforced by `.github/coverage/unit-threshold.txt` (ratchet baseline).
- Integration coverage is collected and published as non-gating report artifacts.
- CI summary for coverage is published in `.github/workflows/test.yml` run results.

Local commands:

```bash
make coverage-unit-real
make coverage-real
```

If host `kcov` is unstable, run coverage in a fresh Linux container using the
CI coverage job as the reference. `tests/README.md` records the evidence limits.

Practical notes:

- Treat `coverage.json` as authoritative when `kcov` exits non-zero with bats.
- Ensure build deps include `make` and `libssl-dev` (required by CMake build of `kcov`).
- If apt registry errors occur (for example transient HTTP 5xx), retry and/or switch mirror.
- For local Docker-based coverage, `docker.950288.xyz` can be used as a fallback image source; GitHub CI does not use this mirror.

---

## Commit Guidelines

### Commit Message Format

Follow Conventional Commits specification:

```
<type>(<scope>): <subject>

<body>

<footer>
```

#### Types

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `perf`: Performance improvements
- `test`: Adding or updating tests
- `chore`: Build process or auxiliary tool changes

#### Examples

```bash
# Good commit messages
git commit -m "feat(validators): add IPv6 private address validation"
git commit -m "fix(backup): retain recovery material after rollback failure"
git commit -m "docs: add ShellDoc documentation to core functions"
git commit -m "test(xray): cover REALITY release validation"

# With body
git commit -m "feat: add fatal/critical log levels

- fatal: logs and exits immediately (exit 1)
- critical: logs severe error but continues execution
- Converted 5 error+exit patterns to fatal level

Related to: Phase 3 Task 3.2"
```

### Commit Best Practices

- **Atomic commits**: One logical change per commit
- **Clear subject**: Describe what and why, not how
- **Imperative mood**: "Add feature" not "Added feature"
- **Reference issues**: Include issue numbers when applicable
- **Keep subject under 72 characters**

---

## Pull Request Process

### Before Submitting

1. **Ensure tests pass**: `make test`
2. **Lint your code**: `make lint`
3. **Format your code**: `make fmt`
4. **Update documentation**: Current user/developer guides, and `docs/adr/` for new decisions
5. **Add tests**: For new features or bug fixes

### PR Template

```markdown
## Summary
Brief description of changes and motivation.

## Changes
- List of specific changes
- Use bullet points

## Testing
How to validate these changes:
\`\`\`bash
# Specific commands to test
XRAY_SNI=your-tested-target.example bin/xrf install
\`\`\`

## Screenshots/Logs
(If applicable)

## Checklist
- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] Lint passes (`make lint`)
- [ ] Format applied (`make fmt`)
- [ ] Tests pass (`make test`)
- [ ] Supported current managed layout and failure paths are documented

## Related Issues
Closes #123
```

### PR Review Process

1. **Automated checks**: CI/CD must pass (lint, format, test)
2. **Code review**: At least one maintainer approval required
3. **Testing**: Reviewer should test changes if possible
4. **Documentation**: Verify docs are updated appropriately

### Addressing Review Comments

```bash
# Make requested changes
git add .
git commit -m "address review comments: fix validation logic"

# Push updated branch
git push origin feature/your-feature-name
```

---

## Documentation

### What to Document

#### Code Documentation
- All public functions (ShellDoc-style)
- Complex algorithms
- Security considerations (with CWE references)
- Non-obvious behavior

#### Project Documentation
- **AGENTS.md**: Development guidelines, coding standards
- **CLAUDE.md**: Project quick reference
- **README.md**: User-facing documentation
- **CHANGELOG.md**: Version history (Keep a Changelog format)
- **TROUBLESHOOTING.md**: Common issues and solutions

### Architecture Decision Records (ADRs)

When making significant architectural decisions, add a record under `docs/adr/`:

```markdown
### ADR-XXX: Decision Title (YYYY-MM-DD)

**Problem**: Brief description of the problem

**Decision**: What was decided

**Rationale**:
- Why this decision was made
- What alternatives were considered
- What trade-offs were accepted

**Impact**:
- How this affects the system
- What changes are required

**References**:
- Links to RFCs, docs, GitHub discussions
```

Earlier ADRs are historical where they describe removed topologies or plugins.

---

## Development Principles

**From AGENTS.md**:

- **System debugging, no guessing**: Use logs to analyze issues based on actual phenomena
- **Use project logging framework**: Consistently use `core::log`, never `echo` for logs
- **Consult official docs first**: Avoid deprecated or outdated implementations
- **Keep code clean**: No unnecessary backward compatibility; delete incomplete/deprecated code
- **Scriptable everything**: Ensure all operations are parameterized via scripts

---

## Questions or Help?

- **Documentation**: Check AGENTS.md, CLAUDE.md, README.md
- **Issues**: Search existing issues before creating new ones
- **Discussions**: Use GitHub Discussions for questions
- **IRC/Chat**: (If applicable)

---

## License

By contributing to xray-fusion, you agree that your contributions will be licensed under the same license as the project.

---

### Upgrade and deployment changes

Exercise `tests/unit/test_upgrade.bats` and `tests/unit/test_deploy_transaction.bats`
when changing installation or deployment. Cover candidate validation, restart and
metadata-write failures, old-binary restoration, active-symlink restoration, preserved
credentials/log settings and a binary change with an unchanged configuration. Tests
must call production functions rather than duplicate their implementations. Keep an
explicit distinction between mocked lifecycle tests and actual client compatibility.

For `--version latest`, install, upgrade and lifecycle smoke use the shared resolver
in `services/xray/install_utils.sh`. It selects the newest published, non-draft
GitHub release by `published_at`, including prereleases. Keep pagination and failure
tests in `tests/unit/test_install_utils.bats`; do not replace it with GitHub's
stable-only `/releases/latest` endpoint.
