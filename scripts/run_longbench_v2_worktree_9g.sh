#!/usr/bin/env bash
# Sequential LongBench-v2 campaign: Standalone 9g --main → --refactor → --deploy.
# Official 0-shot slice: LONGBENCH_LENGTH=short,medium LIMIT=0 (pool 395/503).
# Stops/starts wrap containers between legs. Skips a qualifier when BLOCKED_LAUNCH.md exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_env.sh
source "${SCRIPT_DIR}/worktree_env.sh"

STAND="${IO_ROOT}/playground/Standalone"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT_DIR:-${IO_ROOT}/../bench_results/worktree_9g_${TS}}"
mkdir -p "${OUT}"

# Official 0-shot short+medium (LIMIT=0 = full filtered pool, ~395 items).
LIMIT="${LIMIT:-0}"
export LIMIT
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short,medium}"
export LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
export INFERENCE_METADATA_URL="${INFERENCE_METADATA_URL:-http://localhost:8101}"
export HOST_ID="${HOST_ID:-metax-152}"

QUALIFIERS=(main refactor deploy)
if [[ $# -gt 0 ]]; then
  QUALIFIERS=("$@")
fi

summary="${OUT}/CAMPAIGN.md"
{
  echo "# 9g worktree LongBench-v2 campaign"
  echo
  echo "- started: ${TS}"
  echo "- LIMIT=${LIMIT} (0 = full filtered pool)"
  echo "- LONGBENCH_LENGTH=${LONGBENCH_LENGTH}"
  echo "- LONGBENCH_DIFFICULTY=${LONGBENCH_DIFFICULTY}"
  echo "- INFERENCE_METADATA_URL=${INFERENCE_METADATA_URL}"
  echo "- HOST_ID=${HOST_ID}"
  echo
} > "${summary}"

run_leg() {
  local q="$1"
  local case_dir="${STAND}/9g_8b_thinking-x203-inf--${q}"
  local log="${OUT}/${q}.log"
  echo "========== ${q} ==========" | tee -a "${summary}"
  if [[ ! -d "${case_dir}" ]]; then
    echo "missing case ${case_dir}" | tee -a "${summary}"
    return 1
  fi
  if [[ -f "${case_dir}/BLOCKED_LAUNCH.md" ]]; then
    echo "skip ${q}: BLOCKED_LAUNCH.md" | tee -a "${summary}"
    return 0
  fi

  # Exclusive GPU 0: stop sibling wraps.
  for other in main refactor deploy; do
    CONTAINER_NAME="9g-inf-${other}" "${STAND}/9g_8b_thinking-x203-inf--${other}/stop-wrap.sh" >/dev/null 2>&1 || true
  done
  docker rm -f 9g-vllm-x203 infiniorch-worker-9g-8100-20260811 >/dev/null 2>&1 || true

  INFERENCE_SERVER_ID="$(cat /proc/sys/kernel/random/uuid)"
  export INFERENCE_SERVER_ID

  set +e
  "${case_dir}/run-wrap.sh" > "${log}" 2>&1
  local rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    echo "launch failed ${q} rc=${rc} (see ${log})" | tee -a "${summary}"
    if [[ "${q}" == "refactor" ]]; then
      cat > "${case_dir}/BLOCKED_LAUNCH.md" <<EOF
# BLOCKED_LAUNCH --refactor

MetaX 9g wrap failed (rc=${rc}) at ${TS}.
See campaign log: ${log}

Campaign continues with --main and --deploy.
EOF
      echo "wrote BLOCKED_LAUNCH.md; continuing" | tee -a "${summary}"
      return 0
    fi
    return ${rc}
  fi

  set +e
  "${case_dir}/regression/run_longbench.sh" >> "${log}" 2>&1
  rc=$?
  set -e
  "${case_dir}/stop-wrap.sh" >/dev/null 2>&1 || true
  echo "longbench ${q} rc=${rc} INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID}" | tee -a "${summary}"
  if [[ ${rc} -ne 0 && "${q}" != "refactor" ]]; then
    return ${rc}
  fi
  return 0
}

fail=0
for q in "${QUALIFIERS[@]}"; do
  if ! run_leg "${q}"; then
    fail=1
  fi
done

echo | tee -a "${summary}"
echo "artifacts: ${OUT}" | tee -a "${summary}"

# Warehouse: harness already emits per-step; sync + compact after the campaign.
if [[ -x "${BENCH_WAREHOUSE_REPO}/bin/bench-sync" ]]; then
  echo "========== bench-sync push ==========" | tee -a "${summary}"
  set +e
  "${BENCH_WAREHOUSE_REPO}/bin/bench-sync" push --message "worktree 9g campaign ${TS}" 2>&1 | tee -a "${OUT}/bench-sync.log"
  sync_rc=${PIPESTATUS[0]}
  set -e
  echo "bench-sync rc=${sync_rc}" | tee -a "${summary}"
fi
if [[ -d "${BENCH_WAREHOUSE_REPO}" ]]; then
  echo "========== compact ==========" | tee -a "${summary}"
  TODAY="$(date -u +%Y-%m-%d)"
  set +e
  (
    cd "${BENCH_WAREHOUSE_REPO}"
    python3 -m bench_warehouse.compact --date "${TODAY}"
  ) 2>&1 | tee -a "${OUT}/compact.log"
  compact_rc=${PIPESTATUS[0]}
  set -e
  echo "compact rc=${compact_rc} date=${TODAY}" | tee -a "${summary}"
fi

exit ${fail}
