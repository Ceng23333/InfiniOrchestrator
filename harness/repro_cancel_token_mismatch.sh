#!/usr/bin/env bash
# Thin wrapper: repro the cancel/disconnect sampled-token mismatch bug.
set -euo pipefail
SCENARIOS="${SCENARIOS:-cancel_mid_decode}"
export SCENARIOS
exec "$(dirname "$0")/run_unexpected_behavior_bench.sh" "$@"
