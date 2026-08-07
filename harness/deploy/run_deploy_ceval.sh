#!/usr/bin/env bash
# C-Eval val limit=1 against an already-running endpoint (client-only).
#
# Usage:
#   BENCH_TARGET_URL=http://host:port MODELS=9g_8b_thinking ./harness/deploy/run_deploy_ceval.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/client_env.sh"

_bench_client_resolve_urls || exit 1
_bench_client_resolve_paths || exit 1

MONOREPO="${BENCH_TOOL_ROOT}"
if [[ -z "${MONOREPO}" || ! -d "${MONOREPO}" ]]; then
  echo "Error: BENCH_TOOL_ROOT must point at repo with benchmarks/ on the client host" >&2
  exit 1
fi

ROUTER_URL="${ROUTER_URL:-${BASE_URL}}"
MODELS="${MODELS:-}"
TIMEOUT="${TIMEOUT:-600}"
CEVAL_SKIP_BASELINE="${CEVAL_SKIP_BASELINE:-1}"
CEVAL_SKIP_SERVER_START=1

if [[ -z "${MODELS}" ]]; then
  echo "Error: MODELS is required (9g_8b_thinking | Qwen3-32B)" >&2
  exit 1
fi

case "${MODELS}" in
  9g_8b_thinking)
    MAX_GEN_TOKS="${MAX_GEN_TOKS:-256}"
  ;;
  Qwen3-32B)
    MAX_GEN_TOKS="${MAX_GEN_TOKS:-1024}"
  ;;
  minicpm5|minicpm5.16a3.v0314)
    MAX_GEN_TOKS="${MAX_GEN_TOKS:-256}"
  ;;
esac

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${BENCH_RESULTS_ROOT}/deploy_ceval_${MODELS}_limit1_${TS}}"
mkdir -p "${OUT_DIR}"
export OUT_DIR

STEP_STARTED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "=========================================="
echo "Deploy C-Eval limit1 (client)"
echo "=========================================="
echo "Endpoint:     ${ROUTER_URL}"
echo "Model:        ${MODELS}"
echo "Timeout:      ${TIMEOUT}s"
echo "Max gen toks: ${MAX_GEN_TOKS}"
echo "OUT_DIR:      ${OUT_DIR}"
echo ""

if [[ -z "${INFERENCE_SERVER_ID:-}" ]]; then
  # shellcheck disable=SC1091
  source "${HARNESS_ROOT}/lib/server_preflight.sh"
  server_preflight "${INFERENCE_SERVER_BASE_URL:-${ROUTER_URL}}" "${OUT_DIR}"
fi

SERVER_DIR="${OUT_DIR}/server"
mkdir -p "${SERVER_DIR}"
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" before "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" start "${SERVER_DIR}" || true

cd "${MONOREPO}"
CEVAL_SKIP_SERVER_START="${CEVAL_SKIP_SERVER_START}" \
CEVAL_SKIP_BASELINE="${CEVAL_SKIP_BASELINE}" \
ROUTER_URL="${ROUTER_URL}" \
MODELS="${MODELS}" \
TIMEOUT="${TIMEOUT}" \
MAX_GEN_TOKS="${MAX_GEN_TOKS}" \
OUT_DIR="${OUT_DIR}" \
  ./benchmarks/ceval_native_piecewise_chunk512.sh

STEP_FINISHED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" stop "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" after "${SERVER_DIR}" || true

echo ""
echo "Deploy C-Eval complete: ${OUT_DIR}"

BENCH_ID="deploy_ceval__${MODELS}"
export BASE_URL="${ROUTER_URL}"
export MODEL="${MODELS}"
bash "${HARNESS_ROOT}/lib/emit_bench.sh" "${BENCH_ID}" "${OUT_DIR}" "${STEP_STARTED}" "${STEP_FINISHED}" || {
  echo "[deploy-ceval] WARN: emit failed for ${BENCH_ID}" >&2
}
