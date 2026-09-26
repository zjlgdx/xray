#!/usr/bin/env bash
# Error code definitions for xray-fusion
# Provides consistent error handling across all scripts
# NOTE: This file is sourced. Strict mode is set by the calling script or core::init()

# Source guard: prevent double-sourcing (also prevents readonly redefinition errors)
[[ -n "${_XRF_ERRORS_LOADED:-}" ]] && return 0
readonly _XRF_ERRORS_LOADED=1

# shellcheck disable=SC2034  # Consumed by services/xray/configure.sh
readonly ERR_INVALID_ARG=2 # Invalid argument
