#!/usr/bin/env bash
# InfiniLM MiniCPM5.16a3 Layer-A: smoke→full for TP1/2 (no p4096; no TP4).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
HARNESS="${BENCH}/scripts/run_harness_16a3_in_inf_container.sh"
export ITW_TAG="${ITW_TAG:-v2026.11.06-qy-full-pd}"
export INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL:-1}"

run_one() {
  local cfg="$1"
  echo "===== Layer-A InfiniLM 16a3: ${cfg} (ITW_TAG=${ITW_TAG}) ====="
  ITW_TAG="${ITW_TAG}" INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL}" \
    bash "${HARNESS}" "${BENCH}/${cfg}"
}

if [[ "${SKIP_TP1:-0}" != "1" ]]; then
  run_one config.minicpm5-16a3.infinilm.smoke.json
  run_one config.minicpm5-16a3.infinilm.tp1.json
fi
if [[ "${SKIP_TP2:-0}" != "1" ]]; then
  run_one config.minicpm5-16a3.infinilm.smoke.tp2.json
  run_one config.minicpm5-16a3.infinilm.tp2.json
fi

echo "Layer-A InfiniLM 16a3 complete (p4096 skipped). Results under ${BENCH}/result/"
