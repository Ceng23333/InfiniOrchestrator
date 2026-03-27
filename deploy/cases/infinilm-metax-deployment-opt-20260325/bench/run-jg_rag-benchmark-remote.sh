#!/usr/bin/env bash
# Run jg_rag benchmark via remote router.
# - Generates dataset if missing
# - Waits router readiness + model availability
# - Runs vLLM benchmark and writes JSON results into this case's `results/`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BENCH_DIR="${SCRIPT_DIR}"
RESULTS_DIR="${CASE_DIR}/results"

# Repo root (bench/ lives under InfiniOrchestrator/deploy/cases/<case>/bench)
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../" && pwd)"

# Router endpoint
ROUTER_HOST="${1:-${ROUTER_HOST:-172.22.163.151}}"
ROUTER_PORT="${ROUTER_PORT:-8000}"
ROUTER_URL="http://${ROUTER_HOST}:${ROUTER_PORT}"

# Model and benchmark params
MODEL="${MODEL:-Qwen3-32B}"
LABEL="${LABEL:-jg_rag-baseline}"
REQUEST_RATE="${REQUEST_RATE:-1.0}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-4}"

# Patched vLLM fork (bench/runner machine)
VLLM_DIR="${VLLM_DIR:-/home/zenghua/workspace/infinilm-svc-refactor/vllm}"

# Required: tokenizer path on runner machine
TOKENIZER_DIR="${TOKENIZER_DIR:-${QWEN3_32B_DIR:-}}"

# Dataset (auto-generate if missing)
DATASET_FILE="${DATASET_FILE:-${BENCH_DIR}/jg_rag_benchmark.jsonl}"
DATASET_FORCE_REGEN="${DATASET_FORCE_REGEN:-0}"
# Default generator params produce 10*4=40 records. For 4x larger dataset, use 40*4=160.
DATASET_NUM_CONVERSATIONS="${DATASET_NUM_CONVERSATIONS:-}"
DATASET_MESSAGES_PER_CONV="${DATASET_MESSAGES_PER_CONV:-}"

# Router readiness polling
ROUTER_READY_TIMEOUT_SEC="${ROUTER_READY_TIMEOUT_SEC:-3600}" # 60 minutes
ROUTER_POLL_INTERVAL_SEC="${ROUTER_POLL_INTERVAL_SEC:-10}"

usage() {
  echo "Usage:"
  echo "  $0 [ROUTER_HOST]"
  echo ""
  echo "Required env:"
  echo "  QWEN3_32B_DIR (or TOKENIZER_DIR) - tokenizer/model directory"
  echo ""
  echo "Optional env:"
  echo "  ROUTER_PORT (default: 8000)"
  echo "  MODEL (default: Qwen3-32B)"
  echo "  LABEL (default: jg_rag-baseline)"
  echo "  REQUEST_RATE (default: 1.0)"
  echo "  MAX_CONCURRENCY (default: 4)"
  echo "  VLLM_DIR (default: /home/zenghua/workspace/infinilm-svc-refactor/vllm)"
  echo "  DATASET_FILE (default: bench/jg_rag_benchmark.jsonl)"
  echo "  DATASET_FORCE_REGEN (default: 0) - set to 1 to regenerate dataset"
  echo "  DATASET_NUM_CONVERSATIONS - passed to generator --num-conversations"
  echo "  DATASET_MESSAGES_PER_CONV - passed to generator --messages-per-conv"
  echo "  ROUTER_READY_TIMEOUT_SEC (default: 3600)"
  echo "  ROUTER_POLL_INTERVAL_SEC (default: 10)"
  echo ""
}

DATASET_GENERATOR="${REPO_ROOT}/InfiniLM-SVC/deployment/cases/infinilm-metax-deployment-opt/bench/gen-jg_rag-benchmark.py"
CACHE_VAL_DIR="${REPO_ROOT}/InfiniLM-SVC/deployment/cases/cache-type-routing-validation"
RUN_BENCHMARK_PY="${CACHE_VAL_DIR}/run_benchmark.py"

if [ -z "${TOKENIZER_DIR}" ] || [ ! -d "${TOKENIZER_DIR}" ]; then
  echo "Error: QWEN3_32B_DIR (or TOKENIZER_DIR) must be a valid directory"
  usage
  exit 1
fi

if [ ! -f "${DATASET_GENERATOR}" ]; then
  echo "Error: dataset generator not found: ${DATASET_GENERATOR}"
  exit 1
fi

if [ ! -d "${VLLM_DIR}" ]; then
  echo "Error: VLLM_DIR does not exist: ${VLLM_DIR}"
  exit 1
fi

if [ ! -f "${VLLM_DIR}/vllm/benchmarks/serve.py" ]; then
  echo "Error: vLLM benchmarks not found at ${VLLM_DIR}/vllm/benchmarks/serve.py"
  exit 1
fi

if [ ! -f "${RUN_BENCHMARK_PY}" ]; then
  echo "Error: run_benchmark.py not found: ${RUN_BENCHMARK_PY}"
  exit 1
fi

mkdir -p "${BENCH_DIR}" "${RESULTS_DIR}"

if [ "${DATASET_FORCE_REGEN}" = "1" ] && [ -f "${DATASET_FILE}" ]; then
  echo "Forcing dataset regeneration: removing ${DATASET_FILE}"
  rm -f "${DATASET_FILE}"
fi

if [ ! -f "${DATASET_FILE}" ]; then
  echo "Dataset not found: ${DATASET_FILE}"
  echo "Generating dataset with:"
  gen_args=(--output "${DATASET_FILE}")
  if [ -n "${DATASET_NUM_CONVERSATIONS}" ]; then
    gen_args+=(--num-conversations "${DATASET_NUM_CONVERSATIONS}")
  fi
  if [ -n "${DATASET_MESSAGES_PER_CONV}" ]; then
    gen_args+=(--messages-per-conv "${DATASET_MESSAGES_PER_CONV}")
  fi
  echo "  python ${DATASET_GENERATOR} ${gen_args[*]}"
  python "${DATASET_GENERATOR}" "${gen_args[@]}"
fi

if [ ! -f "${DATASET_FILE}" ]; then
  echo "Error: dataset still missing after generation: ${DATASET_FILE}"
  exit 1
fi

NUM_REQUESTS="$(wc -l < "${DATASET_FILE}")"
if [ "${NUM_REQUESTS}" -le 0 ] 2>/dev/null; then
  echo "Error: dataset appears empty: ${DATASET_FILE}"
  exit 1
fi

echo "=========================================="
echo "jg_rag Benchmark (remote router)"
echo "=========================================="
echo "Router URL:         ${ROUTER_URL}"
echo "Model:              ${MODEL}"
echo "Tokenizer:          ${TOKENIZER_DIR}"
echo "Dataset:            ${DATASET_FILE}"
echo "Total Requests:    ${NUM_REQUESTS}"
echo "Request Rate:      ${REQUEST_RATE} req/s"
echo "Max Concurrency:   ${MAX_CONCURRENCY}"
echo "Result Label:      ${LABEL}"
echo ""

echo "Checking router health at ${ROUTER_URL}/health ..."
if ! curl -s -f --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/health" > /dev/null 2>&1; then
  echo "Error: Router is not accessible at ${ROUTER_URL}"
  exit 1
fi
echo "Router is reachable."

echo "Waiting for router to report model '${MODEL}' via ${ROUTER_URL}/v1/models ..."
deadline=$((SECONDS + ROUTER_READY_TIMEOUT_SEC))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/v1/models" 2>/dev/null || true)"
  if echo "${models_json}" | grep -q "${MODEL}"; then
    echo "Router model '${MODEL}' is available."
    break
  fi

  echo "  Not ready yet (sleep ${ROUTER_POLL_INTERVAL_SEC}s)..."
  sleep "${ROUTER_POLL_INTERVAL_SEC}"
done

if ! echo "${models_json:-}" | grep -q "${MODEL}"; then
  echo "Error: Timed out after ${ROUTER_READY_TIMEOUT_SEC}s waiting for model '${MODEL}'"
  echo "Last /v1/models response (truncated):"
  echo "${models_json:-}" | head -c 2000 || true
  exit 1
fi

export PYTHONPATH="${VLLM_DIR}:${PYTHONPATH:-}"
export PYTHONWARNINGS="ignore::UserWarning"
export HF_HUB_OFFLINE=1

if command -v conda &> /dev/null; then
  eval "$(conda shell.bash hook)"
  conda activate "vllm-bench" 2>/dev/null || true
fi

cd "${VLLM_DIR}"

LOG_FILE="${BENCH_DIR}/bench-jg_rag-${LABEL}-remote-router.log"
echo "Running benchmark (log: ${LOG_FILE})..."
python -u -W ignore::UserWarning "${RUN_BENCHMARK_PY}" "${VLLM_DIR}" \
  --backend openai-chat \
  --host "${ROUTER_HOST}" \
  --port "${ROUTER_PORT}" \
  --endpoint /v1/chat/completions \
  --model "${MODEL}" \
  --tokenizer "${TOKENIZER_DIR}" \
  --dataset-name custom \
  --dataset-path "${DATASET_FILE}" \
  --request-rate "${REQUEST_RATE}" \
  --num-prompts "${NUM_REQUESTS}" \
  --max-concurrency "${MAX_CONCURRENCY}" \
  --label "${LABEL}" \
  --save-result \
  --result-dir "${RESULTS_DIR}" \
  --ready-check-timeout-sec 0 \
  2>&1 | tee "${LOG_FILE}"

CODE="${PIPESTATUS[0]}"
if [ "${CODE}" -ne 0 ]; then
  echo "Benchmark failed (exit code ${CODE})"
  exit "${CODE}"
fi

# Some vLLM forks may write results under the repo root (cwd). Copy if needed.
for f in "${VLLM_DIR}"/${LABEL}-*.json; do
  if [ -f "${f}" ] && [ ! -f "${RESULTS_DIR}/$(basename "${f}")" ]; then
    cp -v "${f}" "${RESULTS_DIR}/"
  fi
done 2>/dev/null || true

echo ""
echo "=========================================="
echo "Benchmark Complete"
echo "Results dir: ${RESULTS_DIR}"
echo "JSON files:"
ls -la "${RESULTS_DIR}"/${LABEL}-*.json 2>/dev/null || true

