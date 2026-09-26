SHELL := /usr/bin/env bash
# Source files for linting (includes .bats for shellcheck)
# ShellCheck can handle bats files - see tests/.shellcheckrc for bats-specific config
SRC_LINT := $(shell git ls-files '*.sh' 'bin/*' 'commands/*' 'lib/*' 'modules/**/*' 'services/**/*' 'scripts/**/*.sh' 'tests/**/*.sh' 'tests/**/*.bats' 2>/dev/null)

# Source files for formatting (excludes .bats - shfmt doesn't support @test syntax)
# See: https://github.com/mvdan/sh/issues/291
SRC_FMT  := $(shell git ls-files '*.sh' 'bin/*' 'commands/*' 'lib/*' 'modules/**/*' 'services/**/*' 'scripts/**/*.sh' 'tests/**/*.sh' 2>/dev/null)
COVERAGE_DIR ?= artifacts/coverage

.PHONY: lint fmt test check-bats-runtime test-unit test-integration coverage-check-tools coverage-unit-real coverage-integration-real coverage-real

lint:
	@files=(); \
	for f in $(SRC_LINT); do \
	  [ -e "$$f" ] && files+=("$$f"); \
	done; \
	[ "$${#files[@]}" -gt 0 ] || { echo "No shell files found for lint"; exit 0; }; \
	shellcheck -S error -S warning -x "$${files[@]}"

fmt:
	@command -v shfmt >/dev/null 2>&1 || { echo "shfmt not found; see https://github.com/mvdan/sh"; exit 2; }
	@files=(); \
	for f in $(SRC_FMT); do \
	  [ -e "$$f" ] && files+=("$$f"); \
	done; \
	[ "$${#files[@]}" -gt 0 ] || { echo "No shell files found for formatting"; exit 0; }; \
	shfmt -i 2 -ci -sr -bn -ln=bash -w "$${files[@]}"
	@echo "Formatted with shfmt"

test: test-unit test-integration

check-bats-runtime:
	@bash scripts/ci/check-bats-runtime.sh

test-unit: check-bats-runtime
	@command -v bats >/dev/null 2>&1 || { echo "bats not found; see https://github.com/bats-core/bats-core"; exit 2; }
	@bats tests/unit/*.bats

test-integration: check-bats-runtime
	@command -v bats >/dev/null 2>&1 || { echo "bats not found; see https://github.com/bats-core/bats-core"; exit 2; }
	@bats tests/integration/*.bats

coverage-check-tools: check-bats-runtime
	@command -v bats >/dev/null 2>&1 || { echo "bats not found; see https://github.com/bats-core/bats-core"; exit 2; }
	@command -v jq >/dev/null 2>&1 || { echo "jq not found; install jq to run coverage tests."; exit 2; }
	@command -v kcov >/dev/null 2>&1 || { echo "kcov not found; see https://github.com/SimonKagstrom/kcov"; exit 2; }
	@kcov --version >/dev/null 2>&1 || { echo "kcov is not runnable; missing runtime libraries (Ubuntu example: sudo apt-get install libbinutils libdw1 libelf1)."; exit 2; }

coverage-unit-real: coverage-check-tools
	@mkdir -p "$(COVERAGE_DIR)/unit"
	@kcov --bash-method=DEBUG --exclude-path=/tmp --include-path="$(CURDIR)" "$(COVERAGE_DIR)/unit" bats tests/unit/*.bats
	@json_file="$$(find "$(COVERAGE_DIR)/unit" -name coverage.json | head -n1)"; \
	[ -n "$$json_file" ] || { echo "coverage.json not found in $(COVERAGE_DIR)/unit"; exit 1; }; \
	percent="$$(grep -Eo '"percent_covered":[[:space:]]*[0-9]+(\.[0-9]+)?' "$$json_file" | head -n1 | sed -E 's/.*:[[:space:]]*//')"; \
	echo "Unit coverage: $${percent:-unknown}%"; \
	echo "Unit coverage report: $(COVERAGE_DIR)/unit"

coverage-integration-real: coverage-check-tools
	@mkdir -p "$(COVERAGE_DIR)/integration"
	@status=0; \
	kcov --bash-method=DEBUG --exclude-path=/tmp --include-path="$(CURDIR)" "$(COVERAGE_DIR)/integration" bats tests/integration/*.bats || status=$$?; \
	if [ "$$status" -ne 0 ]; then \
	  echo "Integration coverage run failed (non-gating)."; \
	  exit 0; \
	fi; \
	json_file="$$(find "$(COVERAGE_DIR)/integration" -name coverage.json | head -n1)"; \
	if [ -n "$$json_file" ]; then \
	  percent="$$(grep -Eo '"percent_covered":[[:space:]]*[0-9]+(\.[0-9]+)?' "$$json_file" | head -n1 | sed -E 's/.*:[[:space:]]*//')"; \
	  echo "Integration coverage: $${percent:-unknown}%"; \
	else \
	  echo "Integration coverage report was not generated."; \
	fi; \
	echo "Integration coverage report: $(COVERAGE_DIR)/integration"

coverage-real: coverage-unit-real coverage-integration-real
	@echo "Coverage artifacts: $(COVERAGE_DIR)"

help:
	@echo "Available targets:"
	@echo "  lint             - Run ShellCheck on all shell scripts"
	@echo "  fmt              - Format all shell scripts with shfmt"
	@echo "  test             - Run all tests (unit + integration)"
	@echo "  test-unit        - Run unit tests"
	@echo "  test-integration - Run integration tests"
	@echo "  coverage-unit-real        - Run unit tests with real kcov coverage"
	@echo "  coverage-integration-real - Run integration tests with real kcov coverage (non-gating)"
	@echo "  coverage-real             - Run unit+integration real kcov coverage"
	@echo "  help             - Show this help message"
