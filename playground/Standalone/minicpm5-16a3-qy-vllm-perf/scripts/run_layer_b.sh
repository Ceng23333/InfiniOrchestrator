#!/usr/bin/env bash
# vLLM MiniCPM5.16a3 Layer-B longbench-task: smoke then full for TP1/2.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
HARNESS="${BENCH}/scripts/run_harness_16a3_in_vllm_container.sh"
CONFIG="${CONFIG:-${BENCH}/config.minicpm5-16a3.json}"
TPS="${TPS:-1 2}"

for tp in ${TPS}; do
  echo "===== Layer-B vLLM 16a3 smoke tp=${tp} ====="
  bash "${HARNESS}" "${CONFIG}" --longbench-task --limit 3 --tp "${tp}"
  echo "===== Layer-B vLLM 16a3 full tp=${tp} ====="
  bash "${HARNESS}" "${CONFIG}" --longbench-task --limit 0 --tp "${tp}"
done

echo "Layer-B vLLM 16a3 complete. Results under ${BENCH}/result/longbench_task_*"
