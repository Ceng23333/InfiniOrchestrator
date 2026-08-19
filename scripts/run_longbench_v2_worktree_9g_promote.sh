#!/usr/bin/env bash
# Deploy-only LongBench-v2 promote ladder: short LIMIT steps (default 1 → 8).
# One wrap start; keep warm between LIMIT steps. Promote only if wrap+LongBench
# rc=0 and quality gate passes (majority non-empty preds + lb_em present).
# Does not rewrite the archival ABC driver (run_longbench_v2_worktree_9g.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_env.sh
source "${SCRIPT_DIR}/worktree_env.sh"

STAND="${IO_ROOT}/playground/Standalone"
CASE_DIR="${STAND}/9g_8b_thinking-x203-inf--deploy"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT_DIR:-${IO_ROOT}/../bench_results/worktree_9g_promote_${TS}}"
mkdir -p "${OUT}"

# Default ladder: short LIMIT=1 then LIMIT=8 (no LIMIT=0).
# shellcheck disable=SC2206
LIMITS=(${LIMITS:-1 8})
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short}"
export LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
export INFERENCE_METADATA_URL="${INFERENCE_METADATA_URL:-http://localhost:8101}"
export HOST_ID="${HOST_ID:-metax-152}"
export MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"
export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:8100}"

summary="${OUT}/CAMPAIGN.md"
{
  echo "# 9g worktree LongBench-v2 promote ladder (deploy-only)"
  echo
  echo "- started: ${TS}"
  echo "- qualifier: **deploy only** (main/refactor omitted)"
  echo "- LIMITS=${LIMITS[*]} (no LIMIT=0)"
  echo "- LONGBENCH_LENGTH=${LONGBENCH_LENGTH}"
  echo "- LONGBENCH_DIFFICULTY=${LONGBENCH_DIFFICULTY}"
  echo "- MAX_CONCURRENCY=${MAX_CONCURRENCY}"
  echo "- INFERENCE_METADATA_URL=${INFERENCE_METADATA_URL}"
  echo "- HOST_ID=${HOST_ID}"
  echo "- BENCH_TARGET_URL=${BENCH_TARGET_URL}"
  echo "- promote: advance only if wrap+LongBench rc=0 and quality gate passes"
  echo "- wrap: warm between LIMIT steps; stop on failure or after last step"
  echo
} > "${summary}"

quality_ok() {
  python3 - "$1" <<'PY'
import json, sys
from pathlib import Path

p = Path(sys.argv[1])
sj, pj = p / "longbench_summary.json", p / "longbench_preds.jsonl"
if not sj.exists() or not pj.exists():
    print("quality missing files")
    sys.exit(1)
s = json.loads(sj.read_text())
if "lb_em" not in s:
    print("quality lb_em missing")
    sys.exit(1)
rows = [json.loads(l) for l in pj.read_text().splitlines() if l.strip()]
empty = sum(1 for r in rows if not (r.get("pred") or "").strip())
e2e = sorted(float(r.get("e2e_ms") or 0) for r in rows)
med = e2e[len(e2e) // 2] if e2e else 0
# Majority non-empty preds; reject all-empty-pred "PASS".
ok = len(rows) > 0 and empty < max(1, len(rows) // 2)
if med < 1.0 and empty >= len(rows) * 0.8:
    ok = False
print(f"quality n={len(rows)} empty_pred={empty} lb_em={s.get('lb_em')} e2e_p50={med} ok={ok}")
sys.exit(0 if ok else 1)
PY
}

latest_lb_dir() {
  ls -dt "${BENCH_WAREHOUSE_REPO}/bench_results/longbench_v2_9g_8b_thinking_"* 2>/dev/null | head -1
}

stop_all_9g_wraps() {
  for other in main refactor deploy; do
    CONTAINER_NAME="9g-inf-${other}" \
      "${STAND}/9g_8b_thinking-x203-inf--${other}/stop-wrap.sh" >/dev/null 2>&1 || true
  done
  docker rm -f 9g-inf-main 9g-inf-refactor 9g-inf-deploy \
    9g-vllm-x203 infiniorch-worker-9g-8100-20260811 >/dev/null 2>&1 || true
}

cleanup_and_exit() {
  local rc="$1"
  stop_all_9g_wraps
  echo | tee -a "${summary}"
  echo "artifacts: ${OUT}" | tee -a "${summary}"
  if [[ -x "${BENCH_WAREHOUSE_REPO}/bin/bench-sync" ]]; then
    echo "========== bench-sync push ==========" | tee -a "${summary}"
    set +e
    "${BENCH_WAREHOUSE_REPO}/bin/bench-sync" push --message "worktree 9g promote ${TS}" 2>&1 \
      | tee -a "${OUT}/bench-sync.log"
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
  exit "${rc}"
}

if [[ ! -d "${CASE_DIR}" ]]; then
  echo "missing case ${CASE_DIR}" | tee -a "${summary}"
  exit 1
fi

wrap_log="${OUT}/deploy_wrap.log"
echo "========== wrap start deploy ==========" | tee -a "${summary}"
stop_all_9g_wraps

INFERENCE_SERVER_ID="$(cat /proc/sys/kernel/random/uuid)"
export INFERENCE_SERVER_ID

set +e
"${CASE_DIR}/run-wrap.sh" > "${wrap_log}" 2>&1
wrap_rc=$?
set -e
if [[ ${wrap_rc} -ne 0 ]]; then
  echo "wrap failed deploy rc=${wrap_rc} (see ${wrap_log})" | tee -a "${summary}"
  cleanup_and_exit "${wrap_rc}"
fi
echo "wrap ready INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID}" | tee -a "${summary}"

for lim in "${LIMITS[@]}"; do
  step_log="${OUT}/deploy_L${lim}.log"
  echo "========== deploy short LIMIT=${lim} ==========" | tee -a "${summary}"
  export LIMIT="${lim}"

  set +e
  "${CASE_DIR}/regression/run_longbench.sh" > "${step_log}" 2>&1
  lb_rc=$?
  set -e

  lb_dir="$(latest_lb_dir)"
  echo "longbench deploy LIMIT=${lim} rc=${lb_rc} INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID}" \
    | tee -a "${summary}"
  echo "OUT_DIR=${lb_dir}" | tee -a "${summary}"

  if [[ ${lb_rc} -ne 0 ]]; then
    echo "FAIL LIMIT=${lim}: longbench rc=${lb_rc} (see ${step_log})" | tee -a "${summary}"
    cleanup_and_exit "${lb_rc}"
  fi

  set +e
  quality_ok "${lb_dir}" | tee -a "${summary}"
  q_rc=${PIPESTATUS[0]}
  set -e
  if [[ ${q_rc} -ne 0 ]]; then
    echo "FAIL LIMIT=${lim}: quality gate (no promote)" | tee -a "${summary}"
    cleanup_and_exit 1
  fi
  echo "PASS LIMIT=${lim}" | tee -a "${summary}"
done

echo "CAMPAIGN done (all LIMIT steps passed)" | tee -a "${summary}"
cleanup_and_exit 0
