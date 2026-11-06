#!/usr/bin/env bash
# InfiniLM MiniCPM5-2B Layer-B longbench-task: smoke limit=3 then full limit=0 for TP1/2/4.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
HARNESS="${BENCH}/scripts/run_harness_in_inf_container.sh"
CONFIG="${CONFIG:-${BENCH}/config.minicpm5-2b.infinilm.tp1.json}"
export ITW_TAG="${ITW_TAG:-v2026.11.06-qy-full-pd}"
export INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL:-1}"
TPS="${TPS:-1 2 4}"

for tp in ${TPS}; do
  echo "===== Layer-B InfiniLM 2B smoke tp=${tp} ====="
  ITW_TAG="${ITW_TAG}" INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL}" \
    bash "${HARNESS}" "${CONFIG}" --longbench-task --limit 3 --tp "${tp}"
  echo "===== Layer-B InfiniLM 2B full tp=${tp} ====="
  ITW_TAG="${ITW_TAG}" INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL}" \
    bash "${HARNESS}" "${CONFIG}" --longbench-task --limit 0 --tp "${tp}"
done

echo "Layer-B InfiniLM 2B complete. Results under ${BENCH}/result/longbench_task_*"
