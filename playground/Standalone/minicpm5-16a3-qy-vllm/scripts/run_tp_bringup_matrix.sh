#!/usr/bin/env bash
# Sweep TENSOR_PARALLEL_SIZE=1,2,4 for minicpm5-16a3-qy-vllm and verify /v1/models.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_WRAP="${CASE_DIR}/run-wrap.sh"
STOP_WRAP="${CASE_DIR}/stop-wrap.sh"
DOCKER="${DOCKER:-sudo docker}"

API_PORT="${API_PORT:-18181}"
# TP=4 is unsupported: num_key_value_heads=2 (GQA) cannot shard across 4 ranks.
TPS="${TPS:-1 2}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_ROOT="${OUT_ROOT:-${CASE_DIR}/logs/tp_bringup_${TS}}"
mkdir -p "${OUT_ROOT}"

echo "OUT_ROOT=${OUT_ROOT}"
echo "TPS=${TPS} API_PORT=${API_PORT}"

for tp in ${TPS}; do
  echo "=========================================="
  echo "TP=${tp} bring-up $(date -Is)"
  echo "=========================================="
  "${STOP_WRAP}" || true
  TENSOR_PARALLEL_SIZE="${tp}" \
    API_PORT="${API_PORT}" \
    "${RUN_WRAP}" | tee "${OUT_ROOT}/bringup_tp${tp}.log"

  ${DOCKER} exec minicpm5-16a3-qy-vllm bash -lc \
    "curl -sf --max-time 10 http://127.0.0.1:${API_PORT}/v1/models" \
    | tee "${OUT_ROOT}/models_tp${tp}.json" >/dev/null
  echo "OK TP=${tp} /v1/models"
done

echo "DONE OUT_ROOT=${OUT_ROOT}"
echo "Leaving last TP server running (TP=${TPS##* }). Stop with: ${STOP_WRAP}"
