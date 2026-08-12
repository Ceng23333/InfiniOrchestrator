#!/usr/bin/env bash
# Run bench-warehouse harness against an already-running inference server (client-only).
#
# bench-warehouse never manages server lifecycle. Only GET /metadata links rows to server_id.
#
# Usage:
#   export BENCH_WAREHOUSE_REPO=/path/to/bench-warehouse
#   export HARDWARE_PROFILE_REPO=/path/to/hardware-profile
#   Harness lives in InfiniOrchestrator/harness
#   export BENCH_TARGET_URL=http://10.0.0.5:18161
#   export BENCH_TOOL_ROOT=/path/to/deployment_202606
#   export MODEL=9g_8b_thinking
#   export TOKENIZER_DIR=/data/models/9g_8b_thinking_llama
#   ./harness/run_bench_client.sh all

set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${HARNESS_ROOT}/scenarios/benchmark/run.sh" "$@"
