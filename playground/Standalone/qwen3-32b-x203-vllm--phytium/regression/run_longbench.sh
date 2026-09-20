#!/usr/bin/env bash
# LongBench-v2 against the Standalone vLLM wrap (direct API, no router).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

export CASE_ID="${CASE_ID:-qwen3-32b-x203-vllm--phytium}"
export CASE_PATH="${CASE_PATH:-${CASE_DIR}/case.toml}"
export MODEL="${MODEL:-Qwen3-32B}"
export TOKENIZER_DIR="${TOKENIZER_DIR:-/root/zenghua/models/Qwen3-32B}"
export BENCH_BACKEND="${BENCH_BACKEND:-vllm}"
export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:18180}"
export ROUTER_URL="${ROUTER_URL:-${BENCH_TARGET_URL}}"
export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${BENCH_TARGET_URL}}"
export LONGBENCH_PRESET="${LONGBENCH_PRESET:-short_easy_cot}"
export LIMIT="${LIMIT:-0}"
export HOST_ID="${HOST_ID:-metax-9}"
export PLATFORM="${PLATFORM:-hpcc}"
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${CASE_DIR}/../../../../hardware-profile" && pwd)}"
unset BENCH_SKIP_SERVER_METRICS 2>/dev/null || true

if [[ -z "${BENCH_CTN_URL:-}" ]]; then
  if [[ "${BENCH_TARGET_URL}" =~ ^https?://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$ ]]; then
    _port="${BASH_REMATCH[3]:-18180}"
    BENCH_CTN_URL="http://172.17.0.1:${_port}"
  fi
fi
export BENCH_CTN_URL="${BENCH_CTN_URL:-}"

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
