#!/usr/bin/env bash
# Throughput harness against an already-running endpoint (client-only).
#
# Usage:
#   BENCH_TARGET_URL=http://host:port MODEL=9g_8b_thinking ./harness/deploy/run_deploy_throughput.sh

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
MODEL="${MODEL:-}"

if [[ -z "${MODEL}" ]]; then
  echo "Error: MODEL is required (9g_8b_thinking | Qwen3-32B | minicpm5)" >&2
  exit 1
fi

case "${MODEL}" in
  9g_8b_thinking)
    TOKENIZER_DIR="${TOKENIZER_DIR:-${MODEL1_DIR:-}}"
    INPUT_LEN_MIN="${INPUT_LEN_MIN:-8192}"
    INPUT_LEN_MAX="${INPUT_LEN_MAX:-8192}"
    OUTPUT_LEN="${OUTPUT_LEN:-256}"
  ;;
  Qwen3-32B)
    TOKENIZER_DIR="${TOKENIZER_DIR:-${QWEN3_32B_DIR:-}}"
    INPUT_LEN_MIN="${INPUT_LEN_MIN:-8192}"
    INPUT_LEN_MAX="${INPUT_LEN_MAX:-40960}"
    OUTPUT_LEN="${OUTPUT_LEN:-512}"
  ;;
  minicpm5|minicpm5.16a3.v0314)
    TOKENIZER_DIR="${TOKENIZER_DIR:-${MINICPM5_TOKENIZER_DIR:-}}"
    INPUT_LEN_MIN="${INPUT_LEN_MIN:-512}"
    # Cap dynamic IN at 40960 (below max_position_embeddings=131072).
    INPUT_LEN_MAX="${INPUT_LEN_MAX:-40960}"
    OUTPUT_LEN="${OUTPUT_LEN:-128}"
    # Default sweep for remasure cells; set WORKLOAD_MODE=dynamic for warehouse dynamic.
    WORKLOAD_MODE="${WORKLOAD_MODE:-sweep}"
  ;;
  *)
    echo "Error: unsupported MODEL=${MODEL}" >&2
    exit 1
  ;;
esac

# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/resolve_tokenizer.sh"
TOKENIZER_DIR="$(resolve_tokenizer_dir "${MODEL}" "${TOKENIZER_DIR}")"

if [[ -z "${TOKENIZER_DIR}" || ! -d "${TOKENIZER_DIR}" ]]; then
  echo "Error: tokenizer dir missing for ${MODEL}: ${TOKENIZER_DIR}" >&2
  exit 1
fi

NUM_PROMPTS="${NUM_PROMPTS:-20}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-4}"
REQUEST_RATE="${REQUEST_RATE:-inf}"
ROUTER_READY_TIMEOUT_SEC="${ROUTER_READY_TIMEOUT_SEC:-3600}"
ROUTER_POLL_INTERVAL_SEC="${ROUTER_POLL_INTERVAL_SEC:-10}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-${BENCH_RESULTS_ROOT}/random-fixed-length_${MODEL}_${TS}}"
mkdir -p "${OUT_DIR}"
export OUT_DIR

STEP_STARTED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "=========================================="
echo "Deploy throughput (client)"
echo "=========================================="
echo "Endpoint:        ${ROUTER_URL}"
echo "Model:           ${MODEL}"
echo "Tokenizer:       ${TOKENIZER_DIR}"
echo "Input len:       ${INPUT_LEN_MIN}-${INPUT_LEN_MAX}"
echo "Output len:      ${OUTPUT_LEN}"
echo "Num prompts:     ${NUM_PROMPTS}"
echo "Max concurrency: ${MAX_CONCURRENCY}"
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

LABEL="deploy_tp_${MODEL}"
LOG_FILE="${OUT_DIR}/bench_console.log"
export VLLM_BENCH_READY_CHECK_TIMEOUT_SEC=0

_TRUST_RC_FLAG=""
_WORKLOAD_MODE="${WORKLOAD_MODE:-dynamic}"
_INPUT_LENS_ARGS=()
case "${MODEL}" in
  minicpm5|minicpm5.16a3.v0314)
    _TRUST_RC_FLAG="--trust-remote-code"
    _WORKLOAD_MODE="${WORKLOAD_MODE:-sweep}"
    if [[ "${_WORKLOAD_MODE}" == "sweep" ]]; then
      if [[ "${INPUT_LEN_MIN}" == "${INPUT_LEN_MAX}" ]]; then
        _INPUT_LENS_ARGS=(--input-lens "${INPUT_LEN_MIN}")
      else
        _INPUT_LENS_ARGS=(--input-lens "${INPUT_LEN_MIN},${INPUT_LEN_MAX}")
      fi
    fi
    ;;
esac

_backend="$(echo "${BENCH_BACKEND:-infinilm}" | tr '[:upper:]' '[:lower:]')"
_common_tail=(
  --endpoint /v1/chat/completions
  --backend openai-chat
  --model "${MODEL}"
  --tokenizer "${TOKENIZER_DIR}"
  ${_TRUST_RC_FLAG}
  --num-prompts "${NUM_PROMPTS}"
  --output-len "${OUTPUT_LEN}"
  --request-rate "${REQUEST_RATE}"
  --max-concurrency "${MAX_CONCURRENCY}"
  --csv-out "${OUT_DIR}/${LABEL}_throughput.csv"
  --result-dir "${OUT_DIR}/${LABEL}"
  --extra-metadata "stack=deploy_router,model=${MODEL}"
)
if [[ "${_WORKLOAD_MODE}" == "sweep" ]]; then
  _mode_args=(--workload-mode sweep "${_INPUT_LENS_ARGS[@]}")
else
  _mode_args=(
    --workload-mode dynamic
    --input-len-min "${INPUT_LEN_MIN}"
    --input-len-max "${INPUT_LEN_MAX}"
    --dynamic-seed
  )
fi

if [[ "${_backend}" == "vllm" || "${_backend}" == "openai" ]]; then
  DEV_CONTAINER="${DEV_CONTAINER_NAME:-infinilm-dev-hpcc37}"
  _bench_url="http://127.0.0.1:${DEV_PORT:-18180}"
  echo "[deploy-throughput] BENCH_BACKEND=${_backend} mode=${_WORKLOAD_MODE}: harness inside ${DEV_CONTAINER} url=${_bench_url}"
  # shellcheck disable=SC2086
  docker exec \
    -e VLLM_BENCH_READY_CHECK_TIMEOUT_SEC=0 \
    -e PYTHONUNBUFFERED=1 \
    "${DEV_CONTAINER}" \
    bash -lc "source /opt/conda/etc/profile.d/conda.sh && conda activate base && \
      python3 '${MONOREPO}/benchmarks/vllm_harness_sweep.py' \
        --label '${LABEL}' \
        --base-url '${_bench_url}' \
        --endpoint /v1/chat/completions \
        --backend openai-chat \
        --model '${MODEL}' \
        --tokenizer '${TOKENIZER_DIR}' \
        ${_TRUST_RC_FLAG} \
        --workload-mode '${_WORKLOAD_MODE}' \
        $(if [[ "${_WORKLOAD_MODE}" == sweep ]]; then
            if [[ "${INPUT_LEN_MIN}" == "${INPUT_LEN_MAX}" ]]; then
              echo --input-lens "${INPUT_LEN_MIN}"
            else
              echo --input-lens "${INPUT_LEN_MIN},${INPUT_LEN_MAX}"
            fi
          else
            echo --input-len-min "${INPUT_LEN_MIN}" --input-len-max "${INPUT_LEN_MAX}" --dynamic-seed
          fi) \
        --num-prompts '${NUM_PROMPTS}' \
        --output-len '${OUTPUT_LEN}' \
        --request-rate '${REQUEST_RATE}' \
        --max-concurrency '${MAX_CONCURRENCY}' \
        --csv-out '${OUT_DIR}/${LABEL}_throughput.csv' \
        --result-dir '${OUT_DIR}/${LABEL}' \
        --extra-metadata 'stack=deploy_router,model=${MODEL}'" \
    2>&1 | tee "${LOG_FILE}"
else
  # shellcheck source=/dev/null
  source "${MONOREPO}/scripts/vllm_bench_env.sh"
  # shellcheck disable=SC2086
  "${VLLM_BENCH_PYTHON}" "${MONOREPO}/benchmarks/vllm_harness_sweep.py" \
    --label "${LABEL}" \
    --base-url "${ROUTER_URL}" \
    "${_mode_args[@]}" \
    "${_common_tail[@]}" \
    2>&1 | tee "${LOG_FILE}"
fi

STEP_FINISHED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

bash "${HARNESS_ROOT}/lib/scrape_server_metrics_period.sh" stop "${SERVER_DIR}" || true
bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" after "${SERVER_DIR}" || true

echo ""
echo "Deploy throughput complete: ${OUT_DIR}"

BENCH_ID="random-fixed-length__${MODEL}"
export BASE_URL="${ROUTER_URL}"
export MODEL
bash "${HARNESS_ROOT}/lib/emit_bench.sh" "${BENCH_ID}" "${OUT_DIR}" "${STEP_STARTED}" "${STEP_FINISHED}" || {
  echo "[deploy-throughput] WARN: emit failed for ${BENCH_ID}" >&2
}
