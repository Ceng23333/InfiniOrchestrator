#!/usr/bin/env bash
# Three-host Observe→Parse promotion recipe (promo-facts-1).
# Normative: docs/design/performance-promotion-e2e.md
#
# Usage:
#   ROLE=baseline|candidate HOST_ROLE=qy|metax|mars \
#     INFINI_TENSOR_WORKTREE=/path/to/ITW \
#     ./scripts/run_unified_promo_recipe.sh
#
# Optional:
#   SUITE_DIR=... BASE_URL_VLLM=... BASE_URL_INFINILM=... MODEL=...
#   RUN_WALL=1|0  SKIP_PROFILER=0|1  FORCE_PROFILER=0|1
#   CASE_PATH_BASELINE=... CASE_PATH_CANDIDATE=...
#
# Exits before AI Promote. Validates $SUITE_DIR/facts as promo-facts-1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=worktree_env.sh
source "${SCRIPT_DIR}/worktree_env.sh"

ROLE="${ROLE:-baseline}"
HOST_ROLE="${HOST_ROLE:-${DEVICE_TRACK:-}}"
TS="${TS:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_WALL="${RUN_WALL:-1}"
SKIP_PROFILER="${SKIP_PROFILER:-0}"
FORCE_PROFILER="${FORCE_PROFILER:-0}"

case "${HOST_ROLE}" in
  qy|metax|mars) ;;
  denglin_qy)
    echo "error: DEVICE_TRACK denglin_qy renamed to qy" >&2
    exit 2
    ;;
  metax_qy)
    echo "error: DEVICE_TRACK metax_qy renamed to metax" >&2
    exit 2
    ;;
  *)
    echo "error: set HOST_ROLE or DEVICE_TRACK to qy|metax|mars (got: '${HOST_ROLE}')" >&2
    exit 2
    ;;
esac

export DEVICE_TRACK="${HOST_ROLE}"
export HOST_ID="${HOST_ID:-${PROMO_HOST:-${HOST_ROLE}}}"

case "${DEVICE_TRACK}" in
  qy)
    export VENDOR_PROFILER="${VENDOR_PROFILER:-dlpti}"
    : "${DLPTI_ROOT:=}"
    ;;
  metax)
    export VENDOR_PROFILER="${VENDOR_PROFILER:-mctracer}"
    : "${MCTRACER_ROOT:=}"
    ;;
  mars)
    # Prefer hcTracer when HCTRACER_ROOT is set; otherwise wall-only.
    if [[ -n "${HCTRACER_ROOT:-}" ]]; then
      export VENDOR_PROFILER="${VENDOR_PROFILER:-hctracer}"
    else
      export VENDOR_PROFILER="${VENDOR_PROFILER:-none}"
      if [[ "${FORCE_PROFILER}" == "1" ]]; then
        echo "error: FORCE_PROFILER=1 on mars requires HCTRACER_ROOT" >&2
        exit 2
      fi
      SKIP_PROFILER=1
    fi
    ;;
esac

if [[ -z "${INFINI_TENSOR_WORKTREE:-}" || ! -d "${INFINI_TENSOR_WORKTREE}" ]]; then
  echo "error: INFINI_TENSOR_WORKTREE must point at the ITW under test" >&2
  exit 2
fi

PIN_LABEL="${PIN_LABEL:-}"
if [[ -z "${PIN_LABEL}" ]]; then
  if [[ -f "${INFINI_TENSOR_WORKTREE}/MANIFEST" ]]; then
    # shellcheck disable=SC1090
    PIN_LABEL="$(grep -E '^(SNAPSHOT_TAG|RELEASE_TAG|ITW_SHA)=' "${INFINI_TENSOR_WORKTREE}/MANIFEST" | head -n1 | cut -d= -f2-)"
  fi
  PIN_LABEL="${PIN_LABEL:-$(git -C "${INFINI_TENSOR_WORKTREE}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
fi

export PIN_BASELINE="${PIN_BASELINE:-vllm-frozen}"
export PIN_CANDIDATE="${PIN_CANDIDATE:-${PIN_LABEL}}"
export ITW_TAG="${ITW_TAG:-${PIN_CANDIDATE}}"

SUITE_DIR="${SUITE_DIR:-${IO_ROOT}/../bench_results/unified_promo_${HOST_ID}_${ROLE}_${TS}}"
mkdir -p "${SUITE_DIR}"
export SUITE_DIR

echo "[unified-promo] ROLE=${ROLE} DEVICE_TRACK=${DEVICE_TRACK} HOST_ID=${HOST_ID}"
echo "[unified-promo] INFINI_TENSOR_WORKTREE=${INFINI_TENSOR_WORKTREE}"
echo "[unified-promo] PIN_CANDIDATE=${PIN_CANDIDATE}"
echo "[unified-promo] SUITE_DIR=${SUITE_DIR}"

LOOP_ARGS=(
  --suite-dir "${SUITE_DIR}"
  --device-track "${DEVICE_TRACK}"
)
if [[ "${RUN_WALL}" == "1" ]]; then
  LOOP_ARGS+=(--run-wall)
  [[ -n "${BASE_URL_VLLM:-}" ]] && LOOP_ARGS+=(--base-url-vllm "${BASE_URL_VLLM}")
  [[ -n "${BASE_URL_INFINILM:-}" ]] && LOOP_ARGS+=(--base-url-infinilm "${BASE_URL_INFINILM}")
  [[ -n "${MODEL:-}" ]] && LOOP_ARGS+=(--model "${MODEL}")
  [[ -n "${AIPERF_PROFILE:-}" ]] && LOOP_ARGS+=(--profile "${AIPERF_PROFILE}")
  [[ -n "${CASE_PATH_BASELINE:-}" ]] && LOOP_ARGS+=(--case-vllm "${CASE_PATH_BASELINE}")
  [[ -n "${CASE_PATH_CANDIDATE:-}" ]] && LOOP_ARGS+=(--case-infinilm "${CASE_PATH_CANDIDATE}")
else
  LOOP_ARGS+=(--reuse-wall)
fi
[[ "${SKIP_PROFILER}" == "1" ]] && LOOP_ARGS+=(--skip-profiler)
[[ "${FORCE_PROFILER}" == "1" ]] && LOOP_ARGS+=(--force-profiler)

"${HARNESS_ROOT}/bin/run-promotion-loop-step" "${LOOP_ARGS[@]}"

# Stamp worktree identity into campaign.json when present
FACTS_DIR="${SUITE_DIR}/facts"
if [[ -f "${FACTS_DIR}/campaign.json" ]]; then
  python3 - "${FACTS_DIR}/campaign.json" "${INFINI_TENSOR_WORKTREE}" "${PIN_CANDIDATE}" "${ROLE}" <<'PY'
import json, sys
path, wt, pin, role = sys.argv[1:5]
obj = json.loads(open(path, encoding="utf-8").read())
obj["worktree_candidate"] = wt
obj["pin_candidate"] = pin
obj["itw_tag_candidate"] = pin
if role == "baseline":
    obj.setdefault("pin_baseline", "vllm-frozen")
open(path, "w", encoding="utf-8").write(json.dumps(obj, indent=2) + "\n")
print(f"[unified-promo] stamped worktree into {path}")
PY
fi

"${HARNESS_ROOT}/bin/parse-promo-facts" validate "${FACTS_DIR}"
"${HARNESS_ROOT}/bin/parse-promo-facts" load-suite "${FACTS_DIR}" >/dev/null

echo "[unified-promo] STOP before Promote — backlog under ${SUITE_DIR}/profile/*/promotion_backlog.json"
echo "[unified-promo] SUITE_DIR=${SUITE_DIR}"
