#!/usr/bin/env bash
# vLLM MiniCPM5-2B Layer-B longbench-task: smoke then full for TP1/2/4.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
HARNESS="${BENCH}/scripts/run_harness_in_vllm_container.sh"
CONFIG="${CONFIG:-${BENCH}/config.minicpm5-2b.json}"
TPS="${TPS:-1 2 4}"

for tp in ${TPS}; do
  echo "===== Layer-B vLLM 2B smoke tp=${tp} ====="
  bash "${HARNESS}" "${CONFIG}" --longbench-task --limit 3 --tp "${tp}"
  echo "===== Layer-B vLLM 2B full tp=${tp} ====="
  bash "${HARNESS}" "${CONFIG}" --longbench-task --limit 0 --tp "${tp}"
done

echo "Layer-B vLLM 2B complete. Results under ${BENCH}/result/longbench_task_*"
