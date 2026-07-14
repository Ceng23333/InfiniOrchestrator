#!/usr/bin/env bash
# Throughput harness against an already-running orchestrator router (no server restart).
#
# Usage:
#   MODEL=9g_8b_thinking ./bench/run_deploy_throughput.sh
#   MODEL=Qwen3-32B ./bench/run_deploy_throughput.sh
#
# Env:
#   ROUTER_HOST (default localhost)
#   ROUTER_PORT (from .env, default 8800)
#   MODEL (required: 9g_8b_thinking | Qwen3-32B)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../" && pwd)"

if [[ -f "${CASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env" && set +a
fi

ROUTER_HOST="${ROUTER_HOST:-localhost}"
ROUTER_PORT="${ROUTER_PORT:-8800}"
ROUTER_URL="http://${ROUTER_HOST}:${ROUTER_PORT}"
MODEL="${MODEL:-}"

if [[ -z "${MODEL}" ]]; then
  echo "Error: MODEL is required (9g_8b_thinking | Qwen3-32B)" >&2
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
  *)
    echo "Error: unsupported MODEL=${MODEL}" >&2
    exit 1
  ;;
esac

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
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/bench_results/deploy_throughput_${MODEL}_${TS}}"
mkdir -p "${OUT_DIR}"

echo "=========================================="
echo "Deploy throughput (router)"
echo "=========================================="
echo "Router:          ${ROUTER_URL}"
echo "Model:           ${MODEL}"
echo "Tokenizer:       ${TOKENIZER_DIR}"
echo "Input len:       ${INPUT_LEN_MIN}-${INPUT_LEN_MAX}"
echo "Output len:      ${OUTPUT_LEN}"
echo "Num prompts:     ${NUM_PROMPTS}"
echo "Max concurrency: ${MAX_CONCURRENCY}"
echo "OUT_DIR:         ${OUT_DIR}"
echo ""

if ! curl -s -f --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/health" >/dev/null 2>&1; then
  echo "Error: router not reachable at ${ROUTER_URL}/health" >&2
  exit 1
fi

echo "Waiting for model '${MODEL}' on ${ROUTER_URL}/v1/models ..."
deadline=$((SECONDS + ROUTER_READY_TIMEOUT_SEC))
models_json=""
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/v1/models" 2>/dev/null || true)"
  if ! echo "${models_json}" | grep -q "${MODEL}"; then
    models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/models" 2>/dev/null || true)"
  fi
  if echo "${models_json}" | grep -q "${MODEL}"; then
    echo "Model '${MODEL}' is available."
    break
  fi
  echo "  Not ready (sleep ${ROUTER_POLL_INTERVAL_SEC}s)..."
  sleep "${ROUTER_POLL_INTERVAL_SEC}"
done

if ! echo "${models_json:-}" | grep -q "${MODEL}"; then
  echo "Error: timed out waiting for model '${MODEL}'" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/vllm_bench_env.sh"

LABEL="deploy_tp_${MODEL}"
LOG_FILE="${OUT_DIR}/bench_console.log"

export VLLM_BENCH_READY_CHECK_TIMEOUT_SEC=0

"${VLLM_BENCH_PYTHON}" "${REPO_ROOT}/benchmarks/vllm_harness_sweep.py" \
  --workload-mode dynamic \
  --label "${LABEL}" \
  --base-url "${ROUTER_URL}" \
  --endpoint "/v1/chat/completions" \
  --backend openai-chat \
  --model "${MODEL}" \
  --tokenizer "${TOKENIZER_DIR}" \
  --input-len-min "${INPUT_LEN_MIN}" \
  --input-len-max "${INPUT_LEN_MAX}" \
  --num-prompts "${NUM_PROMPTS}" \
  --output-len "${OUTPUT_LEN}" \
  --request-rate "${REQUEST_RATE}" \
  --max-concurrency "${MAX_CONCURRENCY}" \
  --dynamic-seed \
  --csv-out "${OUT_DIR}/${LABEL}_throughput.csv" \
  --result-dir "${OUT_DIR}/${LABEL}" \
  --extra-metadata "stack=deploy_router,model=${MODEL}" \
  2>&1 | tee "${LOG_FILE}"

echo ""
echo "Deploy throughput complete: ${OUT_DIR}"
