#!/usr/bin/env bash
# LongBench-v2 against the Standalone InfiniLM wrap (direct API, no router).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

export CASE_ID="${CASE_ID:-9g_8b_thinking-x203-inf--deploy}"
export CASE_PATH="${CASE_PATH:-${CASE_DIR}/case.toml}"
export MODEL="${MODEL:-9g_8b_thinking}"
export TOKENIZER_DIR="${TOKENIZER_DIR:-/root/zenghua/models/9g_8b_thinking_llama}"
export BENCH_BACKEND="${BENCH_BACKEND:-infinilm}"
export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:8100}"
export ROUTER_URL="${ROUTER_URL:-${BENCH_TARGET_URL}}"
export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${BENCH_TARGET_URL}}"
export INFERENCE_METADATA_URL="${INFERENCE_METADATA_URL:-http://localhost:8101}"
export MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-65408}"
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short,medium}"
export LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
export ENABLE_THINKING="${ENABLE_THINKING:-0}"
export LIMIT="${LIMIT:-0}"
export HOST_ID="${HOST_ID:-metax-152}"
export PLATFORM="${PLATFORM:-hpcc}"
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${CASE_DIR}/../../../../hardware-profile" && pwd)}"
unset BENCH_SKIP_SERVER_METRICS 2>/dev/null || true

if [[ -z "${BENCH_CTN_URL:-}" ]]; then
  if [[ "${BENCH_TARGET_URL}" =~ ^https?://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$ ]]; then
    _port="${BASH_REMATCH[3]:-8100}"
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
echo "  CASE_PATH=${CASE_PATH}"
echo "  LIMIT=${LIMIT} MAX_INPUT_TOKENS=${MAX_INPUT_TOKENS}"
echo "=========================================="
MODEL="${MODEL}" bash "${HARNESS}"
