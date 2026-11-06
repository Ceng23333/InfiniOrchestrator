#!/usr/bin/env bash
# vLLM MiniCPM5-2B Layer-A: reused baseline (no re-run per campaign plan 1B).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
BASELINE="${BENCH}/result/20261102_105946_87156c97"

echo "Layer-A vLLM 2B: REUSE baseline (TP1/2/4 × p512/2048/8192 o=1024)"
echo "  run_dir=${BASELINE}"
if [[ -f "${BASELINE}/summary.json" ]]; then
  echo "  summary.json: OK"
else
  echo "error: missing reused baseline ${BASELINE}/summary.json" >&2
  exit 1
fi
echo "Set FORCE_RERUN_LAYER_A=1 to re-run (not part of default campaign)."
if [[ "${FORCE_RERUN_LAYER_A:-0}" == "1" ]]; then
  bash "${BENCH}/scripts/run_harness_in_vllm_container.sh" \
    "${BENCH}/config.minicpm5-2b.json"
fi
