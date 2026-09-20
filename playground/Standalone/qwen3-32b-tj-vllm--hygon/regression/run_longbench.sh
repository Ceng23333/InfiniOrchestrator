#!/usr/bin/env bash
# LongBench-v2 against the Standalone Hygon vLLM daemon (direct API).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

export CASE_ID="${CASE_ID:-qwen3-32b-tj-vllm--hygon}"
export CASE_PATH="${CASE_PATH:-${CASE_DIR}/case.toml}"
export MODEL="${MODEL:-Qwen3-32B}"
export TOKENIZER_DIR="${TOKENIZER_DIR:-/private/zenghua/Qwen3-32B}"
export BENCH_BACKEND="${BENCH_BACKEND:-vllm}"
export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:18180}"
export ROUTER_URL="${ROUTER_URL:-${BENCH_TARGET_URL}}"
export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${BENCH_TARGET_URL}}"
export LONGBENCH_PRESET="${LONGBENCH_PRESET:-short_easy_cot}"
export LIMIT="${LIMIT:-0}"
export HOST_ID="${HOST_ID:-tj-io-node00}"
export PLATFORM="${PLATFORM:-hpcc}"
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${CASE_DIR}/../../../../hardware-profile" && pwd)}"
unset BENCH_SKIP_SERVER_METRICS 2>/dev/null || true

HARNESS="${IO_ROOT}/harness/scenarios/benchmark/cases/longbench_v2/scripts/run.sh"
if [[ ! -f "${HARNESS}" ]]; then
  echo "error: missing ${HARNESS}" >&2
  exit 1
fi

echo "=========================================="
echo "LongBench-v2 Standalone: MODEL=${MODEL} CASE_ID=${CASE_ID}"
echo "  BENCH_TARGET_URL=${BENCH_TARGET_URL}"
echo "  LONGBENCH_PRESET=${LONGBENCH_PRESET}"
echo "  CASE_PATH=${CASE_PATH}"
echo "  LIMIT=${LIMIT}"
echo "=========================================="
MODEL="${MODEL}" bash "${HARNESS}"
