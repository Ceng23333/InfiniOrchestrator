#!/usr/bin/env bash
# Short LIMIT=1 quality gate for Standalone 9g --main and/or --refactor-dev.
# Exclusive GPU0 wraps; GPU1 Mars build container left alone.
# Product --refactor is never in the qualifier list (stays BLOCKED).
# Promote deploy-only driver (run_longbench_v2_worktree_9g_promote.sh) is unchanged.
#
# Usage:
#   ./scripts/run_longbench_v2_worktree_9g_qualify.sh                 # main then refactor-dev
#   ./scripts/run_longbench_v2_worktree_9g_qualify.sh main
#   ./scripts/run_longbench_v2_worktree_9g_qualify.sh refactor-dev
#   QUALIFIERS=main ./scripts/run_longbench_v2_worktree_9g_qualify.sh
#   QUALIFIERS='main refactor-dev' ./scripts/run_longbench_v2_worktree_9g_qualify.sh
#
# CLI args win over QUALIFIERS= env. LIMITS defaults to 1 (no LIMIT=0).
# RESTORE_BLOCKED_ON_FAIL=0 skips restoring BLOCKED_LAUNCH.md on FAIL (flash/graph try);
# L8 promote should leave default (restore on FAIL).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_env.sh
source "${SCRIPT_DIR}/worktree_env.sh"
# shellcheck source=worktree_9g_isolate.sh
source "${SCRIPT_DIR}/worktree_9g_isolate.sh"

STAND="${WORKTREE_9G_STAND}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"

# Snapshot caller env so per-leg exports do not leak across qualifiers.
_ORIG_CONFIG_IN_CONTAINER="${CONFIG_IN_CONTAINER:-}"
_ORIG_MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-}"
_ORIG_SOURCE_ROOT="${SOURCE_ROOT:-}"

# shellcheck disable=SC2206
LIMITS=(${LIMITS:-1})
RESTORE_BLOCKED_ON_FAIL="${RESTORE_BLOCKED_ON_FAIL:-1}"
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-short}"
export LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
export INFERENCE_METADATA_URL="${INFERENCE_METADATA_URL:-http://localhost:8101}"
export HOST_ID="${HOST_ID:-metax-152}"
export MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"
export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:8100}"
export TIMEOUT="${TIMEOUT:-1800}"

DEFAULT_QUALIFIERS=(main refactor-dev)
if [[ $# -gt 0 ]]; then
  QUALIFIERS=("$@")
elif [[ -n "${QUALIFIERS:-}" ]]; then
  # Space- or comma-separated: QUALIFIERS=main  or  QUALIFIERS=main,refactor-dev
  # shellcheck disable=SC2206
  QUALIFIERS=(${QUALIFIERS//,/ })
else
  QUALIFIERS=("${DEFAULT_QUALIFIERS[@]}")
fi

if [[ ${#QUALIFIERS[@]} -eq 0 ]]; then
  echo "error: empty QUALIFIERS (allowed: main, refactor-dev)" >&2
  exit 1
fi
for lim in "${LIMITS[@]}"; do
  if [[ "${lim}" == "0" ]]; then
    echo "error: LIMIT=0 is out of qualify scope (use LIMITS=1)" >&2
    exit 1
  fi
done

# Allowlist: product --refactor and --deploy stay out of this driver.
for q in "${QUALIFIERS[@]}"; do
  case "${q}" in
    main|refactor-dev) ;;
    refactor)
      echo "error: product --refactor is out of qualify scope (still BLOCKED); use refactor-dev" >&2
      exit 1
      ;;
    *)
      echo "error: unknown qualifier '${q}' (allowed: main, refactor-dev)" >&2
      exit 1
      ;;
  esac
done

OUT="${OUT_DIR:-${IO_ROOT}/../bench_results/worktree_9g_qualify_${TS}}"
mkdir -p "${OUT}"

summary="${OUT}/CAMPAIGN.md"
_limits_title="$(IFS=,; echo "${LIMITS[*]}")"
{
  echo "# 9g worktree LongBench-v2 qualify (LIMITS=${_limits_title})"
  echo
  echo "- started: ${TS}"
  echo "- QUALIFIERS=${QUALIFIERS[*]}"
  echo "- LIMITS=${LIMITS[*]} (no LIMIT=0)"
  echo "- LONGBENCH_LENGTH=${LONGBENCH_LENGTH}"
  echo "- LONGBENCH_DIFFICULTY=${LONGBENCH_DIFFICULTY}"
  echo "- MAX_CONCURRENCY=${MAX_CONCURRENCY}"
  echo "- INFERENCE_METADATA_URL=${INFERENCE_METADATA_URL}"
  echo "- HOST_ID=${HOST_ID}"
  echo "- BENCH_TARGET_URL=${BENCH_TARGET_URL}"
  echo "- RESTORE_BLOCKED_ON_FAIL=${RESTORE_BLOCKED_ON_FAIL}"
  if [[ -n "${_ORIG_CONFIG_IN_CONTAINER}" ]]; then
    echo "- CONFIG_IN_CONTAINER=${_ORIG_CONFIG_IN_CONTAINER}"
  fi
  echo "- isolation: GPU0 exclusive wraps; stop wrap between legs; GPU1 ${WORKTREE_9G_GPU1_MARS_CTN} left for Mars build"
  echo "- product --refactor: not in list (BLOCKED / mutate-forbidden)"
  for q in "${QUALIFIERS[@]}"; do
    echo "- SOURCE_ROOT ${q}: $(worktree_9g_source_root_for "${q}")"
  done
  echo
} > "${summary}"

# Same quality rule as run_longbench_v2_worktree_9g_promote.sh.
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
  # Prefer campaign OUT when harness wrote preds there (OUT_DIR=qualify OUT).
  if [[ -f "${OUT}/longbench_summary.json" && -f "${OUT}/longbench_preds.jsonl" ]]; then
    echo "${OUT}"
    return 0
  fi
  ls -dt "${BENCH_WAREHOUSE_REPO}/bench_results/longbench_v2_9g_8b_thinking_"* 2>/dev/null | head -1
}

wrap_faulted() {
  local ctn="$1"
  docker logs "${ctn}" 2>&1 | grep -Eq \
    'wait_status\(139\)|SIGSEGV|xnack|atu address translation|hcGraphExecDestroy|hcGraphDestroy|INFINIRT_MEMCPY|Internal Error \(.*runtime\.cc'
}

tiny_chat_ok() {
  local url="$1" out_json="$2"
  set +e
  curl -sS -m 180 -X POST "${url}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"9g_8b_thinking","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":16,"temperature":0}' \
    > "${out_json}"
  local curl_rc=$?
  set -e
  if [[ ${curl_rc} -ne 0 ]]; then
    echo "tiny-chat curl rc=${curl_rc}"
    return 1
  fi
  python3 - "${out_json}" <<'PY'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
ch = (d.get("choices") or [{}])[0]
content = ((ch.get("message") or {}).get("content") or "").strip()
if not content:
    print("FAIL empty", d)
    sys.exit(1)
print("OK", repr(content[:120]))
sys.exit(0)
PY
}

# Archive active BLOCKED_LAUNCH.md → .stale-*; clear for gate. Caller restores on FAIL.
archive_blocked_launch() {
  local case_dir="$1"
  local blocked="${case_dir}/BLOCKED_LAUNCH.md"
  if [[ -f "${blocked}" ]]; then
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mv "${blocked}" "${case_dir}/BLOCKED_LAUNCH.md.stale-qualify-${stamp}"
    echo "archived ${blocked} → BLOCKED_LAUNCH.md.stale-qualify-${stamp}"
  fi
}

restore_blocked_launch() {
  local case_dir="$1"
  local reason="$2"
  if [[ "${RESTORE_BLOCKED_ON_FAIL}" == "0" ]]; then
    echo "skip restore BLOCKED_LAUNCH.md (RESTORE_BLOCKED_ON_FAIL=0) (${reason})"
    return 0
  fi
  local blocked="${case_dir}/BLOCKED_LAUNCH.md"
  if [[ -f "${blocked}" ]]; then
    return 0
  fi
  local latest
  latest="$(ls -t "${case_dir}"/BLOCKED_LAUNCH.md.stale-* 2>/dev/null | head -1 || true)"
  if [[ -n "${latest}" ]]; then
    cp -a "${latest}" "${blocked}"
    echo "restored BLOCKED_LAUNCH.md from $(basename "${latest}") (${reason})"
  else
    cat > "${blocked}" <<EOF
# BLOCKED_LAUNCH --$(basename "${case_dir}" | sed 's/.*--//')

Qualify gate failed (${reason}) at ${TS}.
See ${OUT}
EOF
    echo "wrote new BLOCKED_LAUNCH.md (${reason})"
  fi
}

restore_caller_env() {
  unset IMAGE_TAG RUNTIME_BASE_TAG FORCE_XMAKE_BUILD API_PORT BABYSITTER_PORT \
    CONTAINER_NAME CASE_ID CASE_PATH SOURCE_ROOT CONFIG_IN_CONTAINER MAX_INPUT_TOKENS \
    || true
  if [[ -n "${_ORIG_CONFIG_IN_CONTAINER}" ]]; then
    export CONFIG_IN_CONTAINER="${_ORIG_CONFIG_IN_CONTAINER}"
  fi
  if [[ -n "${_ORIG_MAX_INPUT_TOKENS}" ]]; then
    export MAX_INPUT_TOKENS="${_ORIG_MAX_INPUT_TOKENS}"
  fi
  if [[ -n "${_ORIG_SOURCE_ROOT}" ]]; then
    export SOURCE_ROOT="${_ORIG_SOURCE_ROOT}"
  fi
}

# GPU0 exclusive: stop this wrap and any sibling (incl. 9g-inf-refactor). GPU1 Mars ctn untouched.
stop_leg_wraps() {
  local case_dir="$1" ctn="$2"
  if [[ -x "${case_dir}/stop-wrap.sh" ]]; then
    CONTAINER_NAME="${ctn}" "${case_dir}/stop-wrap.sh" >/dev/null 2>&1 || true
  fi
  worktree_9g_stop_gpu0_wraps
  echo "stopped wrap ${ctn} (GPU0 exclusive; siblings incl. 9g-inf-refactor)" | tee -a "${summary}"
}

cleanup_and_exit() {
  local rc="$1"
  restore_caller_env
  worktree_9g_stop_gpu0_wraps
  echo | tee -a "${summary}"
  echo "artifacts: ${OUT}" | tee -a "${summary}"
  if [[ -x "${BENCH_WAREHOUSE_REPO}/bin/bench-sync" ]]; then
    echo "========== bench-sync push ==========" | tee -a "${summary}"
    set +e
    "${BENCH_WAREHOUSE_REPO}/bin/bench-sync" push --message "worktree 9g qualify ${TS}" 2>&1 \
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

run_qualifier() {
  local q="$1"
  local case_dir="${STAND}/9g_8b_thinking-x203-inf--${q}"
  local ctn="9g-inf-${q}"
  local wrap_log="${OUT}/${q}_wrap.log"
  local src_root

  echo "========== qualify ${q} ==========" | tee -a "${summary}"
  if [[ ! -d "${case_dir}" ]]; then
    echo "missing case ${case_dir}" | tee -a "${summary}"
    return 1
  fi
  worktree_9g_assert_not_mutating_product_refactor "${case_dir}" || return 1
  src_root="$(worktree_9g_source_root_for "${q}")" || return 1
  echo "SOURCE_ROOT=${src_root}" | tee -a "${summary}"

  archive_blocked_launch "${case_dir}" | tee -a "${summary}"

  echo "force-free GPU0 before ${q}" | tee -a "${summary}"
  worktree_9g_force_free_gpu0

  restore_caller_env
  export SOURCE_ROOT="${src_root}"
  # main / refactor-dev wraps default to ablation step-1; env override still wins.
  if [[ "${q}" == "main" ]]; then
    export CONFIG_IN_CONTAINER="${CONFIG_IN_CONTAINER:-/config/ablation/master-step1.toml}"
  elif [[ "${q}" == "refactor-dev" ]]; then
    export CONFIG_IN_CONTAINER="${CONFIG_IN_CONTAINER:-/config/ablation/master-step1.toml}"
    # 43k Mars eager prefill hung GPU-idle; LIMIT=1 gate middle-truncates unless caller overrides.
    export MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-2048}"
    echo "MAX_INPUT_TOKENS=${MAX_INPUT_TOKENS} (refactor-dev LIMIT=1 default)" | tee -a "${summary}"
  fi

  INFERENCE_SERVER_ID="$(cat /proc/sys/kernel/random/uuid)"
  export INFERENCE_SERVER_ID

  set +e
  "${case_dir}/run-wrap.sh" > "${wrap_log}" 2>&1
  local wrap_rc=$?
  set -e
  if [[ ${wrap_rc} -ne 0 ]]; then
    echo "FAIL ${q}: wrap rc=${wrap_rc} (see ${wrap_log})" | tee -a "${summary}"
    stop_leg_wraps "${case_dir}" "${ctn}"
    restore_blocked_launch "${case_dir}" "wrap rc=${wrap_rc}" | tee -a "${summary}"
    return "${wrap_rc}"
  fi
  echo "wrap ready ${ctn} INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID}" | tee -a "${summary}"
  docker inspect "${ctn}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -E 'ENTRYPOINT_CONFIGS|BABYSITTER_CONFIGS' | tee -a "${summary}" || true

  echo "tiny-chat ${q}..." | tee -a "${summary}"
  set +e
  tiny_chat_ok "http://127.0.0.1:8100" "${OUT}/${q}_tiny_chat.json" | tee -a "${summary}"
  local chat_rc=${PIPESTATUS[0]}
  set -e
  if wrap_faulted "${ctn}" || [[ ${chat_rc} -ne 0 ]]; then
    echo "FAIL ${q}: tiny-chat/wrap fault" | tee -a "${summary}"
    docker logs "${ctn}" 2>&1 | tail -80 > "${OUT}/${q}_docker_tail.log" || true
    stop_leg_wraps "${case_dir}" "${ctn}"
    restore_blocked_launch "${case_dir}" "tiny-chat/wrap fault" | tee -a "${summary}"
    return 1
  fi
  echo "tiny-chat OK ${q}" | tee -a "${summary}"

  local lim step_log lb_dir lb_rc q_rc
  for lim in "${LIMITS[@]}"; do
    step_log="${OUT}/${q}_L${lim}.log"
    echo "========== ${q} short LIMIT=${lim} ==========" | tee -a "${summary}"
    export LIMIT="${lim}"
    set +e
    "${case_dir}/regression/run_longbench.sh" > "${step_log}" 2>&1
    lb_rc=$?
    set -e
    lb_dir="$(latest_lb_dir)"
    echo "longbench ${q} LIMIT=${lim} rc=${lb_rc} INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID}" \
      | tee -a "${summary}"
    echo "OUT_DIR=${lb_dir}" | tee -a "${summary}"

    if wrap_faulted "${ctn}"; then
      echo "FAIL ${q} LIMIT=${lim}: wrap fault during longbench" | tee -a "${summary}"
      stop_leg_wraps "${case_dir}" "${ctn}"
      restore_blocked_launch "${case_dir}" "wrap fault LIMIT=${lim}" | tee -a "${summary}"
      return 1
    fi
    if [[ ${lb_rc} -ne 0 ]]; then
      echo "FAIL ${q} LIMIT=${lim}: longbench rc=${lb_rc}" | tee -a "${summary}"
      stop_leg_wraps "${case_dir}" "${ctn}"
      restore_blocked_launch "${case_dir}" "longbench rc=${lb_rc}" | tee -a "${summary}"
      return "${lb_rc}"
    fi
    if [[ -z "${lb_dir}" ]]; then
      echo "FAIL ${q} LIMIT=${lim}: no longbench output dir" | tee -a "${summary}"
      stop_leg_wraps "${case_dir}" "${ctn}"
      restore_blocked_launch "${case_dir}" "missing longbench dir LIMIT=${lim}" | tee -a "${summary}"
      return 1
    fi
    set +e
    quality_ok "${lb_dir}" | tee -a "${summary}"
    q_rc=${PIPESTATUS[0]}
    set -e
    if [[ ${q_rc} -ne 0 ]]; then
      echo "FAIL ${q} LIMIT=${lim}: quality gate" | tee -a "${summary}"
      stop_leg_wraps "${case_dir}" "${ctn}"
      restore_blocked_launch "${case_dir}" "quality gate LIMIT=${lim}" | tee -a "${summary}"
      return 1
    fi
    echo "PASS ${q} LIMIT=${lim}" | tee -a "${summary}"
  done

  stop_leg_wraps "${case_dir}" "${ctn}"
  # PASS: leave BLOCKED_LAUNCH absent.
  if [[ -f "${case_dir}/BLOCKED_LAUNCH.md" ]]; then
    rm -f "${case_dir}/BLOCKED_LAUNCH.md"
  fi
  echo "PASS ${q}: BLOCKED_LAUNCH cleared" | tee -a "${summary}"
  restore_caller_env
  return 0
}

echo "========== force-free GPU0 (kickoff) ==========" | tee -a "${summary}"
worktree_9g_force_free_gpu0

fail=0
for q in "${QUALIFIERS[@]}"; do
  if ! run_qualifier "${q}"; then
    fail=1
    # On main FAIL do not continue to refactor-dev (plan Phase A).
    if [[ "${q}" == "main" ]]; then
      echo "main FAIL: stopping qualify (no refactor-dev leg)" | tee -a "${summary}"
      break
    fi
  fi
done

if [[ ${fail} -eq 0 ]]; then
  echo "CAMPAIGN done (all qualifiers passed)" | tee -a "${summary}"
else
  echo "CAMPAIGN failed" | tee -a "${summary}"
fi
cleanup_and_exit "${fail}"
