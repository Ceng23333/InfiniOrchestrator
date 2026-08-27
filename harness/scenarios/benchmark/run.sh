#!/usr/bin/env bash
# Benchmark scene dispatcher (client-only against a running inference server).
#
# Usage (via harness/run_bench_client.sh or directly):
#   ./scenarios/benchmark/run.sh longbench|ceval|throughput|unexpected|all

set -euo pipefail

SCENE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "${SCENE_ROOT}/../.." && pwd)"
CASES_ROOT="${SCENE_ROOT}/cases"

BENCH="${1:-all}"
shift 2>/dev/null || true

if [[ "${BENCH}" == "-h" || "${BENCH}" == "--help" ]]; then
  echo "Benchmark scene dispatcher (client-only)."
  echo "Usage: run_bench_client.sh unexpected|throughput|ceval|longbench|evalscope-mixed-4096|all"
  exit 0
fi

# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/client_env.sh"

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
  "${CASES_ROOT}/unexpected_behavior/scripts/run.sh" "$@"
}

run_throughput() {
  local model="${MODEL:-}"
  [[ -n "${model}" ]] || { echo "[bench_client] MODEL required for throughput" >&2; return 1; }
  export MODEL="${model}"
  export ROUTER_URL
  export OUT_DIR="${SUITE_DIR}/random-fixed-length"
  mkdir -p "${OUT_DIR}"
  cp -f "${SUITE_DIR}/metadata.json" "${OUT_DIR}/metadata.json" 2>/dev/null || true
  "${CASES_ROOT}/random_fixed_length/scripts/run.sh"
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
    "${CASES_ROOT}/ceval/scripts/run.sh"
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
  "${CASES_ROOT}/longbench_v2/scripts/run.sh"
}

run_evalscope_mixed_4096() {
  local model="${MODEL:-}"
  [[ -n "${model}" ]] || { echo "[bench_client] MODEL required for evalscope-mixed-4096" >&2; return 1; }
  export MODEL="${model}"
  export ROUTER_URL
  export OUT_DIR="${SUITE_DIR}/evalscope-mixed-4096"
  mkdir -p "${OUT_DIR}"
  cp -f "${SUITE_DIR}/metadata.json" "${OUT_DIR}/metadata.json" 2>/dev/null || true
  "${CASES_ROOT}/evalscope_mixed_4096/scripts/run.sh"
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
  evalscope-mixed-4096|evalscope|es4096)
    run_evalscope_mixed_4096
    ;;
  all)
    run_unexpected
    run_throughput
    run_ceval
    ;;
  *)
    echo "Unknown bench: ${BENCH} (expected unexpected|throughput|ceval|longbench|evalscope-mixed-4096|all)" >&2
    exit 2
    ;;
esac

echo "[bench_client] suite complete: ${SUITE_DIR} server_id=${INFERENCE_SERVER_ID}"
