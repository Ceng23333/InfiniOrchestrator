#!/usr/bin/env bash
# InfiniLM MiniCPM5-2B Layer-A: smoke→full for TP1/2/4 on v2026.11.06-qy-full-pd.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
HARNESS="${BENCH}/scripts/run_harness_in_inf_container.sh"
export ITW_TAG="${ITW_TAG:-v2026.11.06-qy-full-pd}"
export INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL:-1}"

run_one() {
  local cfg="$1"
  echo "===== Layer-A InfiniLM 2B: ${cfg} (ITW_TAG=${ITW_TAG}) ====="
  ITW_TAG="${ITW_TAG}" INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL}" \
    bash "${HARNESS}" "${BENCH}/${cfg}"
}

# Skip TP1 smoke+full if SKIP_TP1=1 (e.g. already completed in this campaign).
if [[ "${SKIP_TP1:-0}" != "1" ]]; then
  run_one config.minicpm5-2b.infinilm.smoke.json
  run_one config.minicpm5-2b.infinilm.tp1.json
fi
if [[ "${SKIP_TP2:-0}" != "1" ]]; then
  run_one config.minicpm5-2b.infinilm.smoke.tp2.json
  run_one config.minicpm5-2b.infinilm.tp2.json
fi
if [[ "${SKIP_TP4:-0}" != "1" ]]; then
  run_one config.minicpm5-2b.infinilm.smoke.tp4.json
  run_one config.minicpm5-2b.infinilm.tp4.json
fi

echo "Layer-A InfiniLM 2B complete. Results under ${BENCH}/result/"
