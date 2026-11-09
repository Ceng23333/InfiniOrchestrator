#!/usr/bin/env bash
# InfiniLM MiniCPM5.16a3 Layer-A: smoke→full for TP1/2 (no p4096; no TP4).
# TP1 dual-bank needs INFINI_PREFILL_FULL_CG_SKIP_PIECEWISE=1; TP2 keep-piecewise.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "${CASE_DIR}/../../../.." && pwd)"
BENCH="${BENCH:-${WS_ROOT}/llm_performace_benchmark}"
HARNESS="${BENCH}/scripts/run_harness_16a3_in_inf_container.sh"
export ITW_TAG="${ITW_TAG:-v2026.11.09-qy-moe-bf16-warpnk}"
export INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL:-1}"

run_one() {
  local cfg="$1"
  echo "===== Layer-A InfiniLM 16a3: ${cfg} (ITW_TAG=${ITW_TAG} SKIP_PIECEWISE=${INFINI_PREFILL_FULL_CG_SKIP_PIECEWISE:-}) ====="
  ITW_TAG="${ITW_TAG}" INFINI_VOCAB_PARALLEL="${INFINI_VOCAB_PARALLEL}" \
    INFINI_PREFILL_FULL_CG_SKIP_PIECEWISE="${INFINI_PREFILL_FULL_CG_SKIP_PIECEWISE:-}" \
    bash "${HARNESS}" "${BENCH}/${cfg}"
}

if [[ "${SKIP_TP1:-0}" != "1" ]]; then
  # Historical Layer-A: TP1 FULL-only (skip piecewise dual-bank OOM).
  export INFINI_PREFILL_FULL_CG_SKIP_PIECEWISE=1
  run_one config.minicpm5-16a3.infinilm.smoke.json
  run_one config.minicpm5-16a3.infinilm.tp1.json
fi
if [[ "${SKIP_TP2:-0}" != "1" ]]; then
  # TP2 keep-piecewise dual-bank (default campaign cell).
  unset INFINI_PREFILL_FULL_CG_SKIP_PIECEWISE
  run_one config.minicpm5-16a3.infinilm.smoke.tp2.json
  run_one config.minicpm5-16a3.infinilm.tp2.json
fi

echo "Layer-A InfiniLM 16a3 complete (p4096 skipped). Results under ${BENCH}/result/"
