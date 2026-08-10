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
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/client_env.sh"

BENCH="${1:-all}"
shift 2>/dev/null || true

TS="$(date +%Y%m%d_%H%M%S)"
SUITE_DIR="${SUITE_DIR:-${BENCH_RESULTS_ROOT}/bench_client_${MODEL:-unknown}_${TS}}"
mkdir -p "${SUITE_DIR}"

export SUITE_STARTED_AT="${SUITE_STARTED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
export SUMMARY_DIR="${SUMMARY_DIR:-${SUITE_DIR}/unexpected_behavior}"

if [[ -z "${INFERENCE_SERVER_ID:-}" ]]; then
  bench_client_preflight "${SUITE_DIR}" || exit 1
else
  _bench_client_resolve_backend || exit 1
  _bench_client_resolve_urls || exit 1
  _bench_client_resolve_paths || exit 1
  export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${INFERENCE_SERVER_BASE_URL}}"
  echo "[bench_client] using INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID} backend=${BENCH_BACKEND:-infinilm}"
  if [[ ! -f "${SUITE_DIR}/metadata.json" && -f "${SUITE_DIR%/unexpected_behavior}/metadata.json" ]]; then
    cp -f "${SUITE_DIR%/unexpected_behavior}/metadata.json" "${SUITE_DIR}/metadata.json" 2>/dev/null || true
  fi
fi

run_unexpected() {
  export MODEL="${MODEL:-9g_8b_thinking}"
  export BASE_URL="${ROUTER_URL}"
  export SUMMARY_DIR="${SUITE_DIR}/unexpected_behavior"
  mkdir -p "${SUMMARY_DIR}"
  cp -f "${SUITE_DIR}/metadata.json" "${SUMMARY_DIR}/metadata.json" 2>/dev/null || true
  "${HARNESS_ROOT}/run_unexpected_behavior_bench.sh" "$@"
}

run_throughput() {
  local model="${MODEL:-}"
  [[ -n "${model}" ]] || { echo "[bench_client] MODEL required for throughput" >&2; return 1; }
  export MODEL="${model}"
  export ROUTER_URL
  export OUT_DIR="${SUITE_DIR}/random-fixed-length"
  mkdir -p "${OUT_DIR}"
  cp -f "${SUITE_DIR}/metadata.json" "${OUT_DIR}/metadata.json" 2>/dev/null || true
  "${HARNESS_ROOT}/deploy/run_deploy_throughput.sh"
}

run_ceval() {
  local model="${MODEL:-${MODELS:-}}"
  [[ -n "${model}" ]] || { echo "[bench_client] MODEL or MODELS required for ceval" >&2; return 1; }
  export MODELS="${model}"
  export ROUTER_URL
  export OUT_DIR="${SUITE_DIR}/ceval"
  mkdir -p "${OUT_DIR}"
  cp -f "${SUITE_DIR}/metadata.json" "${OUT_DIR}/metadata.json" 2>/dev/null || true
  CEVAL_SKIP_BASELINE="${CEVAL_SKIP_BASELINE:-1}" \
    "${HARNESS_ROOT}/deploy/run_deploy_ceval.sh"
}

run_longbench() {
  local model="${MODEL:-${MODELS:-}}"
  [[ -n "${model}" ]] || { echo "[bench_client] MODEL or MODELS required for longbench" >&2; return 1; }
  export MODEL="${model}"
  export MODELS="${model}"
  export ROUTER_URL
  export OUT_DIR="${SUITE_DIR}/longbench_v2"
  mkdir -p "${OUT_DIR}"
  cp -f "${SUITE_DIR}/metadata.json" "${OUT_DIR}/metadata.json" 2>/dev/null || true
  "${HARNESS_ROOT}/deploy/run_deploy_longbench_v2.sh"
}

case "${BENCH}" in
  unexpected|ub)
    run_unexpected "$@"
    ;;
  throughput|tp|random-fixed-length|rfl)
    run_throughput
    ;;
  ceval)
    run_ceval
    ;;
  longbench|lbv2)
    run_longbench
    ;;
  all)
    run_unexpected
    run_throughput
    run_ceval
    ;;
  -h|--help)
    sed -n '1,18p' "$0" | sed 's/^# //'
    exit 0
    ;;
  *)
    echo "Unknown bench: ${BENCH} (expected unexpected|throughput|ceval|longbench|all)" >&2
    exit 2
    ;;
esac

echo "[bench_client] suite complete: ${SUITE_DIR} server_id=${INFERENCE_SERVER_ID}"
