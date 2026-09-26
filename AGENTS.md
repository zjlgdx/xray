# Technical Reference

Detailed patterns and conventions for xray-fusion development.

## Scope

- Applies to the entire repository rooted at this `AGENTS.md`.
- If a deeper directory contains another `AGENTS.md`, the deeper file takes precedence for that subtree.
- This file is operational guidance for coding agents and should stay aligned with `CONTRIBUTING.md`.

## Execution Rules

### Always

- Prefer targeted changes and keep diffs minimal.
- Use structured logging via `core::log`; do not add new plain `echo` logging in library/runtime paths.
- Update tests and docs when behavior changes (especially `tests/README.md`, `CONTRIBUTING.md`, and relevant service docs).
- Run verification commands relevant to the changed area before claiming completion.
- Start new tasks from `origin/main` in a new git worktree and a `codex/*` branch unless the user explicitly asks to continue on the current branch.
- Treat host shell workflows as the baseline. `thin-devbox-shell` is an optional execution layer, not a required prerequisite.

### Never

- Do not add `trap ... EXIT` patterns in utility/library functions.
- Do not bypass shellcheck/shfmt conventions for shell files.
- Do not enable Docker proxy fallback in GitHub CI; local-only fallback is allowed (see Testing section).
- Do not assume `devbox` is available or that Docker can be called from inside a `devbox` container.

## Change-Triggered Verification

Run these checks based on what you changed:

- `lib/**`, `modules/**`, `commands/**`, `services/**`, `bin/**`:
  `make fmt && make lint && make test-unit`
- `.github/workflows/**`, `.github/dependabot.yml`:
  `bats -t tests/unit/test_github_metadata.bats`
- `scripts/e2e/install-lifecycle-smoke.sh`:
  `bash -n scripts/e2e/install-lifecycle-smoke.sh`
- `tests/**`:
  run the specific changed bats file(s), then `make test-unit`

Before opening a PR, prefer running full test suite when feasible:

```bash
make test
```

## Development Modes

- Supported modes:
  - Host shell on Linux/macOS
  - Windows via WSL Linux filesystem
- Optional [`thin-devbox-shell`](https://github.com/xrf9268-hue/thin-devbox-shell) for a reproducible shell layer
- Keep the project workflow environment-agnostic. Repository docs and prompts must still work when `devbox` is not used.
- Run Docker lifecycle and online-install validation from fresh host Docker containers. Do not reuse prior test containers or assume Docker-in-Docker support.

## Key APIs

### Core Utilities (`lib/core.sh`)

```bash
# Structured logging - ALWAYS use, never echo
core::log info "message" '{"key":"value"}'
core::log error "failed" "$(printf '{"file":"%s"}' "${path}")"

# File locking
core::with_flock /var/lock/mylock.lock my_command arg1 arg2

# Retry with exponential backoff
core::retry 3 curl -fsSL "${url}"
```

### I/O Utilities (`modules/io.sh`)

```bash
# Atomic file write (same-partition, prevents race conditions)
echo "content" | io::atomic_write /path/to/file 0644

# Directory creation with sudo fallback
io::ensure_dir /path/to/dir 0755
```

### Validators (`lib/validators.sh`)

```bash
# RFC-compliant domain validation (rejects private/reserved)
validators::domain "example.com" || exit 1
```

### Xray Utilities (`services/xray/common.sh`)

```bash
# Generate a 16-character hexadecimal shortId
shortid=$(xray::generate_shortid)
```

## Shell Patterns

### Source Guards (Required for Libraries)

```bash
# Prevent "readonly variable" errors on multiple source
[[ -n "${_XRF_MYLIB_LOADED:-}" ]] && return 0
readonly _XRF_MYLIB_LOADED=1

readonly MY_CONSTANT="value"
```

### Module Dependencies

```bash
# ALWAYS source dependencies explicitly
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/defaults.sh
. "${HERE}/lib/defaults.sh"
# shellcheck source=lib/core.sh
. "${HERE}/lib/core.sh"
```

### No Traps in Utility Functions

```bash
# EXIT traps in functions break pipelines and test frameworks
# Use explicit cleanup instead:
my_function() {
  local tmp="$(mktemp)"
  if ! some_operation > "${tmp}"; then
    rm -f "${tmp}" 2>/dev/null || true
    return 1
  fi
  mv "${tmp}" "${dest}" || { rm -f "${tmp}"; return 1; }
}
```

### Atomic File Operations

```bash
# Create temp in same dir for atomic mv
tmp="$(mktemp -p "${dstdir}" .atomic.XXXXXX.tmp)"
cat > "${tmp}" && mv -f "${tmp}" "${dst}"
```

### External Tool Parsing

```bash
# Normalize before matching - upstream formats change silently
label="${line%%:*}"
normalized="${label,,}"                # lowercase
normalized="${normalized//[[:space:]]/}"  # remove whitespace
if [[ "${normalized}" == *keyword* ]]; then
  # matched
fi
```

## Testing

```bash
# Run all checks
make fmt && make lint && make test-unit

# Run specific test file
bats -t tests/unit/test_core_functions.bats

# Run a manual install only inside a disposable Linux container or VM;
# the installer also manages a service user and systemd unit.
XRAY_SNI=your-tested-target.example bin/xrf install --yes

# Local e2e smoke test (Docker)
scripts/e2e/install-lifecycle-smoke.sh
```

- Local e2e Docker test may fallback to `docker.950288.xyz/library/ubuntu:24.04` when `ubuntu:24.04` pull fails.
- GitHub CI must stay on official source only (`GITHUB_ACTIONS=true` path disables proxy fallback).
- Optional overrides:
  - `XRF_SMOKE_BASE_IMAGE` (default: `ubuntu:24.04`)
  - `XRF_SMOKE_FALLBACK_IMAGE` (default: `docker.950288.xyz/library/ubuntu:24.04`)

## Xray Configuration

### Managed Inbound

- One VLESS + REALITY inbound on port 443 by default, using raw transport and
  the `xtls-rprx-vision` flow. There is no separate TLS/Vision inbound.
- `XRAY_SNI` is required with no built-in default; `XRAY_REALITY_DEST` defaults
  to `<XRAY_SNI>:443`. `xrf test-sni` is an explicit network diagnostic.
- The current `latest` release resolver includes published prereleases. The
  version verified during this change was v26.9.9; do not hard-code it as latest.
- Xray stdout/stderr goes to journald. No managed file-log, logrotate, Caddy,
  certificate, plugin, template, firewall, or sysctl path remains.
- State contains full connection credentials: directory mode 0700 and state file
  mode 0600. Client links require authorized access, normally `sudo xrf links`.
- Fresh install rejects managed artifacts; binary changes use `xrf upgrade`.
  Backup/restore accepts the current managed release layout only.

### Key Concepts
- REALITY does not require domain ownership (SNI is for camouflage)
- Test the actual client through the VPS after an upgrade; configuration tests
  and mocked systemctl lifecycle checks do not prove interoperability.
- `shortIds` is a server pool; client URIs carry the selected shortId.

## Function Documentation

```bash
##
# Brief description
#
# Arguments:
#   $1 - name (type, required)
#   $2 - value (type, optional, default: X)
#
# Returns:
#   0 - success
#   1 - error
##
my_function() {
  # implementation
}
```

## Commit Guidelines

- Use Conventional Commits: `<type>(<scope>): <subject>`
- Keep subject imperative and concise (prefer <72 chars)
- Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
- Before commit, run at minimum:

```bash
make fmt && make lint && make test-unit
```

## Push and CI

- After every push or PR update, monitor GitHub Actions for the pushed commit until all required checks complete.
- If any required check fails, investigate the failure, make the necessary fix, rerun relevant local validation, and push follow-up commits until the required checks pass.
- After every push or PR update, also review new PR reviews, review comments, and bot suggestions for the pushed commit.
- Treat actionable review findings as required follow-up work: validate whether they still apply on `HEAD`, fix or respond with evidence, rerun relevant local validation, and push follow-up commits until there is no unresolved blocking review feedback.
- Do not stop at reporting CI failures unless the user explicitly asks to pause.

## Common Pitfalls

| Problem | Solution |
|---------|----------|
| `readonly variable` error | Add source guard |
| Variable undefined in SC2154 | Source the defining module |
| `exec >> lock` fails | Fix ownership AND permissions |
| Network download fails | Use `core::retry` |
| Parse error after tool upgrade | Normalize labels before matching |
| Trap "unbound variable" | Don't use traps in utility functions |
| kcov exits non-zero with bats | DEBUG trap conflict; capture exit code, check `coverage.json` instead |
| Prebuilt binary crashes in CI | Build from source and cache; prebuilt binaries assume specific shared libs |
| Python f-string `SyntaxError` | No backslashes in f-string expressions before 3.12; use `%`-formatting |
