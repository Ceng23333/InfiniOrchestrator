#!/usr/bin/env bash
# Post-compose EvalScope mixed 4096 regression (issue #2 repro).
#
# Prereq: docker-compose stack up with Qwen worker overrides for mixed batching:
#   --max-batch-size 20
#   INFINI_MAX_NUM_BATCHED_TOKENS=4096
#   INFINI_NATIVE_CG_CAPTURE_BUCKETS=4096
#   INFINI_DECODE_CG_BATCHES=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20
#   INFINI_SCHEDULE_NO_MIXED=0
#   INFINI_PREFILL_CHUNKED=1
#
# Use 4096-bucket AOT cache seed, e.g. from:
#   ../qwen3-32b+xiyan--x203-inf-disagg--opt20260817/cache/piecewise_inductor
#
# Usage:
#   ./regression/run_evalscope_mixed_4096.sh
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

if [[ -f "${CASE_DIR}/docker-compose/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${CASE_DIR}/docker-compose/.env"
  set +a
fi

export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:${ROUTER_PORT:-8800}}"
export ROUTER_URL="${ROUTER_URL:-${BENCH_TARGET_URL}}"
export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${ROUTER_URL}}"
export CASE_ID="${CASE_ID:-qwen3-32b+9g--x203-inf--opt20260811}"
export CASE_PATH="${CASE_PATH:-${CASE_DIR}/case.toml}"
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${CASE_DIR}/../../../../hardware-profile" && pwd)}"
export MODEL="${MODEL:-Qwen3-32B}"
export BENCH_BACKEND="${BENCH_BACKEND:-infinilm}"
unset BENCH_SKIP_SERVER_METRICS 2>/dev/null || true

if [[ -z "${BENCH_CTN_URL:-}" ]]; then
  if [[ "${BENCH_TARGET_URL}" =~ ^https?://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$ ]]; then
    _port="${BASH_REMATCH[3]:-${ROUTER_PORT:-8800}}"
    BENCH_CTN_URL="http://172.17.0.1:${_port}"
  fi
fi
export BENCH_CTN_URL="${BENCH_CTN_URL:-}"

export INFERENCE_METADATA_URL="${INFERENCE_METADATA_URL:-http://localhost:${WORKER_QWEN_BABYSITTER_PORT:-8201}}"

HARNESS="${IO_ROOT}/harness/scenarios/benchmark/cases/evalscope_mixed_4096/scripts/run.sh"
if [[ ! -f "${HARNESS}" ]]; then
  echo "error: missing ${HARNESS}" >&2
  exit 1
fi

echo "=========================================="
echo "EvalScope mixed 4096 regression"
echo "  BENCH_TARGET_URL=${BENCH_TARGET_URL}"
echo "  BENCH_CTN_URL=${BENCH_CTN_URL}"
echo "  INFERENCE_METADATA_URL=${INFERENCE_METADATA_URL}"
echo "  MODEL=${MODEL}"
echo "=========================================="

MODEL="${MODEL}" bash "${HARNESS}"
