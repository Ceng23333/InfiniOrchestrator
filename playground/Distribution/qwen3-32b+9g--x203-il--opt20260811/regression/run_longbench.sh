#!/usr/bin/env bash
# Post-compose LongBench-v2 regression against the running InfiniOrchestrator router.
# Wraps InfiniOrchestrator/harness/deploy/run_deploy_longbench_v2.sh (official 0-shot).
#
# Prereq: docker-compose stack up + ./docker-compose/validate.sh localhost
#
# Usage:
#   ./regression/run_longbench.sh
#   LIMIT=8 ./regression/run_longbench.sh          # quick gate
#   MODEL=9g_8b_thinking ./regression/run_longbench.sh
#   MODELS="Qwen3-32B 9g_8b_thinking" ./regression/run_longbench.sh
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

export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:${ROUTER_PORT:-8000}}"
export ROUTER_URL="${ROUTER_URL:-${BENCH_TARGET_URL}}"
export CASE_ID="${CASE_ID:-qwen3-32b+9g--x203-il--opt20260811}"
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short,medium}"
export LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
export ENABLE_THINKING="${ENABLE_THINKING:-0}"
export LIMIT="${LIMIT:-0}"
export BENCH_BACKEND="${BENCH_BACKEND:-infinilm}"

# Harness runs the client inside DEV_CONTAINER; multi-network docker inspect can
# concatenate gateways. Prefer an explicit in-container URL to the host-published router.
if [[ -z "${BENCH_CTN_URL:-}" ]]; then
  if [[ "${BENCH_TARGET_URL}" =~ ^https?://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$ ]]; then
    _port="${BASH_REMATCH[3]:-${ROUTER_PORT:-8000}}"
    BENCH_CTN_URL="http://172.17.0.1:${_port}"
  fi
fi
export BENCH_CTN_URL="${BENCH_CTN_URL:-}"

HARNESS="${IO_ROOT}/harness/deploy/run_deploy_longbench_v2.sh"
if [[ ! -f "${HARNESS}" ]]; then
  echo "error: missing ${HARNESS}" >&2
  exit 1
fi

run_one() {
  local model="$1"
  echo "=========================================="
  echo "LongBench-v2 regression: MODEL=${model}"
  echo "  BENCH_TARGET_URL=${BENCH_TARGET_URL}"
  echo "  CASE_ID=${CASE_ID} LIMIT=${LIMIT} ENABLE_THINKING=${ENABLE_THINKING}"
  echo "=========================================="
  MODEL="${model}" bash "${HARNESS}"
}

if [[ -n "${MODELS:-}" ]]; then
  # shellcheck disable=SC2086
  for m in ${MODELS}; do
    run_one "${m}"
  done
else
  run_one "${MODEL:-Qwen3-32B}"
fi
