#!/usr/bin/env bash
# EvalScope perf harness: 20-way parallel 4096-token prompts (mixed batch gate).
#
# Usage:
#   ROUTER_URL=http://host:8800 MODEL=Qwen3-32B \
#     ./harness/scenarios/benchmark/cases/evalscope_mixed_4096/scripts/run.sh
#
# Server-side overrides for issue #2 repro (not default playground TOML):
#   max-batch-size=20, INFINI_MAX_NUM_BATCHED_TOKENS=4096,
#   INFINI_NATIVE_CG_CAPTURE_BUCKETS=4096, INFINI_SCHEDULE_NO_MIXED=0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARNESS_ROOT="$(cd "${CASE_ROOT}/../../../.." && pwd)"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/client_env.sh"
# shellcheck disable=SC1091
source "${CASE_ROOT}/config/default.env"

_bench_client_resolve_urls || exit 1
_bench_client_resolve_paths || exit 1

ROUTER_URL="${ROUTER_URL:-${BASE_URL}}"
MODEL="${MODEL:-}"

if [[ -z "${MODEL}" ]]; then
  echo "Error: MODEL is required (Qwen3-32B)" >&2
  exit 1
fi

case "${MODEL}" in
  Qwen3-32B)
    TOKENIZER_DIR="${TOKENIZER_DIR:-${QWEN3_32B_DIR:-}}"
    ;;
  *)
    echo "Error: unsupported MODEL=${MODEL} (expected Qwen3-32B)" >&2
    exit 1
    ;;
esac

# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/resolve_tokenizer.sh"
TOKENIZER_DIR="$(resolve_tokenizer_dir "${MODEL}" "${TOKENIZER_DIR}")"

if [[ -n "${BENCH_CTN_URL:-}" && -n "${CONTAINER_TOKENIZER_DIR:-}" ]]; then
  TOKENIZER_DIR="${CONTAINER_TOKENIZER_DIR}"
elif [[ -n "${BENCH_CTN_URL:-}" ]]; then
  case "${MODEL}" in
    Qwen3-32B) TOKENIZER_DIR="/models/Qwen3-32B" ;;
  esac
fi

if [[ -z "${TOKENIZER_DIR}" ]]; then
  echo "Error: tokenizer dir missing for ${MODEL}" >&2
  exit 1
fi
if [[ -z "${BENCH_CTN_URL:-}" && ! -d "${TOKENIZER_DIR}" ]]; then
  echo "Error: tokenizer dir missing for ${MODEL}: ${TOKENIZER_DIR}" >&2
  exit 1
fi

CHAT_URL="${CHAT_URL:-${ROUTER_URL%/}${EVALSCOPE_ENDPOINT}}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${BENCH_RESULTS_ROOT}/evalscope_mixed_4096_${MODEL}_${TS}}"
mkdir -p "${OUT_DIR}"
export OUT_DIR

STEP_STARTED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "=========================================="
echo "EvalScope mixed 4096 perf (client)"
echo "=========================================="
echo "Endpoint:        ${CHAT_URL}"
echo "Model:           ${MODEL}"
echo "Tokenizer:       ${TOKENIZER_DIR}"
echo "Parallel:        ${PARALLEL}"
echo "Number:          ${NUMBER}"
echo "Prompt len:      ${MIN_PROMPT_LENGTH}-${MAX_PROMPT_LENGTH}"
echo "Output tokens:   ${MIN_TOKENS}-${MAX_TOKENS}"
echo "OUT_DIR:         ${OUT_DIR}"
echo ""

if ! curl -s -f --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/health" >/dev/null 2>&1 \
  && ! curl -s -f --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/v1/models" >/dev/null 2>&1; then
  echo "Error: endpoint not reachable at ${ROUTER_URL}/health or /v1/models" >&2
  exit 1
fi

echo "Waiting for model '${MODEL}' on ${ROUTER_URL}/models (or /v1/models) ..."
deadline=$((SECONDS + ROUTER_READY_TIMEOUT_SEC))
models_json=""
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/models" 2>/dev/null || true)"
  if [[ -z "${models_json}" ]] || ! echo "${models_json}" | grep -q '"id"'; then
    models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/v1/models" 2>/dev/null || true)"
  fi
  if echo "${models_json}" | grep -qE "\"id\"[[:space:]]*:[[:space:]]*\"${MODEL}\""; then
    echo "Model '${MODEL}' is available."
    break
  fi
  echo "  Not ready (sleep ${ROUTER_POLL_INTERVAL_SEC}s)..."
  sleep "${ROUTER_POLL_INTERVAL_SEC}"
done

if ! echo "${models_json:-}" | grep -qE "\"id\"[[:space:]]*:[[:space:]]*\"${MODEL}\""; then
  echo "Error: timed out waiting for model '${MODEL}'" >&2
  exit 1
fi

if [[ -z "${INFERENCE_SERVER_ID:-}" ]]; then
  # shellcheck disable=SC1091
  source "${HARNESS_ROOT}/lib/server_preflight.sh"
  server_preflight "${INFERENCE_SERVER_BASE_URL:-${ROUTER_URL}}" "${OUT_DIR}"
fi

SERVER_DIR="${OUT_DIR}/server"
mkdir -p "${SERVER_DIR}"
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" before "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" start "${SERVER_DIR}" || true

LOG_FILE="${OUT_DIR}/evalscope_console.log"
LABEL="evalscope_mixed_4096_${MODEL}"

_run_evalscope_local() {
  "${EVALSCOPE_BIN}" perf \
    --parallel "${PARALLEL}" \
    --number "${NUMBER}" \
    --model "${MODEL}" \
    --url "${CHAT_URL}" \
    --api "${EVALSCOPE_API}" \
    --dataset random \
    --max-tokens "${MAX_TOKENS}" \
    --min-tokens "${MIN_TOKENS}" \
    --min-prompt-length "${MIN_PROMPT_LENGTH}" \
    --max-prompt-length "${MAX_PROMPT_LENGTH}" \
    --tokenizer-path "${TOKENIZER_DIR}" \
    --extra-args "${EVALSCOPE_EXTRA_ARGS}" \
    --outputs-dir "${OUT_DIR}/${LABEL}" \
    "$@"
}

_run_evalscope_in_container() {
  local dev_ctn="$1"
  local bench_url="$2"
  docker exec \
    -e PYTHONUNBUFFERED=1 \
    "${dev_ctn}" \
    bash -lc "source /opt/conda/etc/profile.d/conda.sh && conda activate base && \
      ${EVALSCOPE_BIN} perf \
        --parallel '${PARALLEL}' \
        --number '${NUMBER}' \
        --model '${MODEL}' \
        --url '${bench_url}' \
        --api '${EVALSCOPE_API}' \
        --dataset random \
        --max-tokens '${MAX_TOKENS}' \
        --min-tokens '${MIN_TOKENS}' \
        --min-prompt-length '${MIN_PROMPT_LENGTH}' \
        --max-prompt-length '${MAX_PROMPT_LENGTH}' \
        --tokenizer-path '${TOKENIZER_DIR}' \
        --extra-args '${EVALSCOPE_EXTRA_ARGS}' \
        --outputs-dir '${OUT_DIR}/${LABEL}'"
}

if [[ -n "${BENCH_CTN_URL:-}" ]]; then
  DEV_CONTAINER="${DEV_CONTAINER_NAME}"
  echo "[evalscope] running inside ${DEV_CONTAINER} url=${BENCH_CTN_URL}${EVALSCOPE_ENDPOINT}"
  _run_evalscope_in_container "${DEV_CONTAINER}" "${BENCH_CTN_URL}${EVALSCOPE_ENDPOINT}" \
    2>&1 | tee "${LOG_FILE}"
elif command -v "${EVALSCOPE_BIN}" >/dev/null 2>&1; then
  echo "[evalscope] running locally url=${CHAT_URL}"
  _run_evalscope_local 2>&1 | tee "${LOG_FILE}"
else
  DEV_CONTAINER="${DEV_CONTAINER_NAME}"
  if docker ps --format '{{.Names}}' | grep -qx "${DEV_CONTAINER}"; then
    _bench_url="${BENCH_CTN_URL:-http://172.17.0.1:${ROUTER_PORT:-8800}}"
    echo "[evalscope] ${EVALSCOPE_BIN} not on PATH; using ${DEV_CONTAINER} url=${_bench_url}${EVALSCOPE_ENDPOINT}"
    _run_evalscope_in_container "${DEV_CONTAINER}" "${_bench_url}${EVALSCOPE_ENDPOINT}" \
      2>&1 | tee "${LOG_FILE}"
  else
    echo "Error: ${EVALSCOPE_BIN} not found and container ${DEV_CONTAINER} not running" >&2
    exit 1
  fi
fi

STEP_FINISHED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" stop "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" after "${SERVER_DIR}" || true

echo ""
echo "EvalScope mixed 4096 complete: ${OUT_DIR}"

BENCH_ID="evalscope-mixed-4096__${MODEL}"
export BASE_URL="${ROUTER_URL}"
export MODEL
bash "${HARNESS_ROOT}/lib/emit_bench.sh" "${BENCH_ID}" "${OUT_DIR}" "${STEP_STARTED}" "${STEP_FINISHED}" || {
  echo "[evalscope] WARN: emit failed for ${BENCH_ID}" >&2
}
