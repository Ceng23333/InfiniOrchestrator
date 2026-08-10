#!/usr/bin/env bash
# C-Eval val limit=1 against deployed orchestrator router (no standalone serve_infinilm).
#
# Usage:
#   ROUTER_URL=http://localhost:8800 MODELS=9g_8b_thinking ./bench/run_deploy_ceval.sh
#   ROUTER_URL=http://localhost:8800 MODELS=Qwen3-32B MAX_GEN_TOKS=1024 ./bench/run_deploy_ceval.sh
#
# Env (override as needed):
#   ROUTER_URL, MODELS, TIMEOUT, MAX_GEN_TOKS, OUT_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../" && pwd)"

if [[ -f "${CASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env" && set +a
fi

# Offline CEval pins (pre-populate bench/ceval_cache/ on a networked host)
CEVAL_CACHE_ROOT="${CEVAL_CACHE_ROOT:-${CASE_DIR}/bench/ceval_cache}"
if [[ -d "${CEVAL_CACHE_ROOT}/hf" ]]; then
  export HF_HOME="${HF_HOME:-${CEVAL_CACHE_ROOT}/hf}"
  export HF_DATASETS_CACHE="${HF_DATASETS_CACHE:-${CEVAL_CACHE_ROOT}/hf/datasets}"
fi
if [[ -d "${CEVAL_CACHE_ROOT}/lm_eval" ]]; then
  export LM_EVAL="${LM_EVAL:-${CEVAL_CACHE_ROOT}/lm_eval}"
fi
if [[ -d "${CEVAL_CACHE_ROOT}/repo" ]]; then
  export CEVAL_REPO="${CEVAL_REPO:-${CEVAL_CACHE_ROOT}/repo}"
fi

ROUTER_URL="${ROUTER_URL:-http://localhost:${ROUTER_PORT:-8800}}"
MODELS="${MODELS:-}"
TIMEOUT="${TIMEOUT:-600}"
CEVAL_SKIP_BASELINE="${CEVAL_SKIP_BASELINE:-1}"
CEVAL_SKIP_SERVER_START="${CEVAL_SKIP_SERVER_START:-1}"
CEVAL_ENABLE_THINKING="${CEVAL_ENABLE_THINKING:-0}"

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
esac

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/bench_results/deploy_ceval_${MODELS}_limit1_${TS}}"

echo "=========================================="
echo "Deploy C-Eval limit1 (router)"
echo "=========================================="
echo "Router:       ${ROUTER_URL}"
echo "Model:        ${MODELS}"
echo "Timeout:      ${TIMEOUT}s"
echo "Max gen toks: ${MAX_GEN_TOKS}"
echo "OUT_DIR:      ${OUT_DIR}"
echo "CEVAL_CACHE:  ${CEVAL_CACHE_ROOT}"
echo "HF_HOME:      ${HF_HOME:-<unset>}"
echo "LM_EVAL:      ${LM_EVAL:-<unset>}"
echo ""

cd "${REPO_ROOT}"
CEVAL_SKIP_SERVER_START="${CEVAL_SKIP_SERVER_START}" \
CEVAL_SKIP_BASELINE="${CEVAL_SKIP_BASELINE}" \
CEVAL_ENABLE_THINKING="${CEVAL_ENABLE_THINKING}" \
HF_HOME="${HF_HOME:-}" \
HF_DATASETS_CACHE="${HF_DATASETS_CACHE:-}" \
LM_EVAL="${LM_EVAL:-}" \
CEVAL_REPO="${CEVAL_REPO:-}" \
ROUTER_URL="${ROUTER_URL}" \
MODELS="${MODELS}" \
TIMEOUT="${TIMEOUT}" \
MAX_GEN_TOKS="${MAX_GEN_TOKS}" \
OUT_DIR="${OUT_DIR}" \
  ./benchmarks/ceval_native_piecewise_chunk512.sh

echo ""
echo "Deploy C-Eval complete: ${OUT_DIR}"
