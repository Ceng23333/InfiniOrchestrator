#!/usr/bin/env bash
# vLLM MiniCPM5.16a3 Layer-A: reused baseline (TP1/2 only; no TP4).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
BASELINE="${BENCH}/result/20261102_123008_9e595f73"

echo "Layer-A vLLM 16a3: REUSE baseline (TP1/2 × p512/2048/4096 o=1024)"
echo "  run_dir=${BASELINE}"
if [[ -f "${BASELINE}/summary.json" ]]; then
  echo "  summary.json: OK"
else
  echo "error: missing reused baseline ${BASELINE}/summary.json" >&2
  exit 1
fi
if [[ "${FORCE_RERUN_LAYER_A:-0}" == "1" ]]; then
  bash "${BENCH}/scripts/run_harness_16a3_in_vllm_container.sh" \
    "${BENCH}/config.minicpm5-16a3.json"
fi
