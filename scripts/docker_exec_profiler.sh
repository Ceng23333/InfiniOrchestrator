#!/usr/bin/env bash
# Run an IO promo kit helper INSIDE PROFILER_CONTAINER, then pull lightweight outs.
#
# Required env:
#   PROFILER_CONTAINER  — docker CTN name (active serve CTN)
#   OUT_DIR             — host path for profile/<run_id>
#   PROFILER_KIT_DIR    — host path to kits/{dlpti|mctracer|hctracer}
#
# Optional:
#   DOCKER_BIN=docker|sudo -n docker
#   MODEL ROLE VENDOR_PROFILER HCTRACER_BIN MCTRACER_BIN DLPTI_BIN
#   PROFILER_MODE=smoke|attach_serve  ATTACH_PID  CLIENT_WINDOW_CMD  ENGINE
#   ATTACH_CHATS ATTACH_MAX_TOKENS API_PORT_CANDIDATES
set -euo pipefail

: "${PROFILER_CONTAINER:?PROFILER_CONTAINER required}"
: "${OUT_DIR:?OUT_DIR required}"
: "${PROFILER_KIT_DIR:?PROFILER_KIT_DIR required}"

DOCKER_BIN="${DOCKER_BIN:-docker}"
# Allow "sudo -n docker" as a single string
docker_cli() {
  # shellcheck disable=SC2086
  ${DOCKER_BIN} "$@"
}

CTN="${PROFILER_CONTAINER}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
KIT_DIR="$(cd "${PROFILER_KIT_DIR}" && pwd)"
KIT_NAME="$(basename "${KIT_DIR}")"
PARENT_KIT="$(cd "${KIT_DIR}/.." && pwd)"
CTN_WORK="/tmp/io_profiler_${KIT_NAME}_$$"
MODEL="${MODEL:-Qwen3-8B}"
ROLE="${ROLE:-candidate}"
PROFILER_MODE="${PROFILER_MODE:-smoke}"
ENGINE="${ENGINE:-}"
if [[ -z "${ENGINE}" ]]; then
  if [[ "${ROLE}" == "baseline" ]]; then ENGINE=vllm; else ENGINE=infinilm; fi
fi

mkdir -p "${OUT_DIR}/raw"

echo "[docker-exec-profiler] ctn=${CTN} kit=${KIT_DIR} out=${OUT_DIR} mode=${PROFILER_MODE} engine=${ENGINE}" >&2

# Ensure CTN is running
if ! docker_cli ps --format '{{.Names}}' | grep -qx "${CTN}"; then
  echo "[docker-exec-profiler] error: container ${CTN} not running" >&2
  exit 42
fi

docker_cli exec "${CTN}" bash -lc "rm -rf '${CTN_WORK}' && mkdir -p '${CTN_WORK}/raw' '${CTN_WORK}/kit'"

# Copy kit (+ shared chrome_trace_{light,heavy}.py / attach_common.sh parent files when present)
docker_cli cp "${KIT_DIR}/." "${CTN}:${CTN_WORK}/kit/"
docker_cli exec "${CTN}" bash -lc "mkdir -p '${CTN_WORK}/kit_parent' '${CTN_WORK}/kits/${KIT_NAME}'"
if [[ -f "${PARENT_KIT}/chrome_trace_light.py" ]]; then
  docker_cli cp "${PARENT_KIT}/chrome_trace_light.py" "${CTN}:${CTN_WORK}/kit_parent/chrome_trace_light.py"
fi
if [[ -f "${PARENT_KIT}/chrome_trace_heavy.py" ]]; then
  docker_cli cp "${PARENT_KIT}/chrome_trace_heavy.py" "${CTN}:${CTN_WORK}/kit_parent/chrome_trace_heavy.py"
fi
if [[ -f "${PARENT_KIT}/attach_common.sh" ]]; then
  docker_cli cp "${PARENT_KIT}/attach_common.sh" "${CTN}:${CTN_WORK}/kit_parent/attach_common.sh"
fi
# Layout: kits/<name>/ + kits/{chrome_trace_*.py,attach_common.sh} so ../ works
docker_cli exec "${CTN}" bash -lc "
  cp -a '${CTN_WORK}/kit/.' '${CTN_WORK}/kits/${KIT_NAME}/'
  if [[ -f '${CTN_WORK}/kit_parent/chrome_trace_light.py' ]]; then
    cp -a '${CTN_WORK}/kit_parent/chrome_trace_light.py' '${CTN_WORK}/kits/chrome_trace_light.py'
  fi
  if [[ -f '${CTN_WORK}/kit_parent/chrome_trace_heavy.py' ]]; then
    cp -a '${CTN_WORK}/kit_parent/chrome_trace_heavy.py' '${CTN_WORK}/kits/chrome_trace_heavy.py'
  fi
  if [[ -f '${CTN_WORK}/kit_parent/attach_common.sh' ]]; then
    cp -a '${CTN_WORK}/kit_parent/attach_common.sh' '${CTN_WORK}/kits/attach_common.sh'
  fi
"
CTN_KIT="${CTN_WORK}/kits/${KIT_NAME}"

# Preflight: tool presence inside CTN
set +e
docker_cli exec "${CTN}" bash -lc "
set +e
case '${KIT_NAME}' in
  dlpti)
    set +u
    source /usr/local/dlgpu/sdk/env.sh 2>/dev/null || true
    set -u
    if [[ ! -x /usr/local/dlgpu/sdk/bin/dlpti_tools ]] && ! command -v dlpti_tools >/dev/null 2>&1; then
      echo MISSING_DLPTI_TOOLS
      exit 43
    fi
    ;;
  mctracer)
    if [[ ! -x /opt/maca/bin/mcTracer ]] && ! command -v mcTracer >/dev/null 2>&1; then
      echo MISSING_MCTRACER
      exit 43
    fi
    ;;
  hctracer)
    if [[ ! -x /opt/hpcc/bin/hcTracer ]]; then
      echo MISSING_HCTRACER
      exit 43
    fi
    ;;
esac
echo PREFLIGHT_OK
"
pre_ec=$?
set -e
if [[ ${pre_ec} -eq 43 ]]; then
  echo "[docker-exec-profiler] SKIPPED: in-container tool missing for ${KIT_NAME}" >&2
  echo SKIPPED_MISSING_IN_CTN_TOOL > "${OUT_DIR}/COMPARE_SKIPPED.txt"
  exit 42
fi
if [[ ${pre_ec} -ne 0 ]]; then
  echo "[docker-exec-profiler] preflight failed ec=${pre_ec}" >&2
  exit "${pre_ec}"
fi

# Optionally resolve serve PID inside CTN when ATTACH_PID unset.
# Important: do NOT source Denglin env.sh here — it prints banners that pollute PID capture.
if [[ "${PROFILER_MODE}" == "attach_serve" && -z "${ATTACH_PID:-}" ]]; then
  set +e
  # Prefer Worker_TP0 (GPU) over EngineCore/API — chrome tracers need vendor port files.
  ATTACH_PID="$(
    docker_cli exec "${CTN}" bash -lc '
      set +e
      ps -eo pid,args 2>/dev/null | awk "/VLLM::Worker_TP0/ && \$0 !~ /awk/ { print \$1; exit }"
      ps -eo pid,args 2>/dev/null | awk "/VLLM::EngineCore/ && \$0 !~ /awk/ { print \$1; exit }"
      ps -eo pid,args 2>/dev/null | awk "/inference_server\\.py/ && \$0 !~ /awk/ { print \$1; exit }"
      ps -eo pid,args 2>/dev/null | awk "/vllm\\.entrypoints/ && \$0 !~ /awk/ { print \$1; exit }"
      true
    ' 2>/dev/null | tr -d "\r" | grep -E '^[0-9]+$' | head -n1
  )"
  set -e
  if [[ "${ATTACH_PID}" =~ ^[0-9]+$ ]]; then
    echo "[docker-exec-profiler] resolved ATTACH_PID=${ATTACH_PID}" >&2
  else
    ATTACH_PID=""
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[docker-exec-profiler] ERROR: ATTACH_PID unresolved under NON_SMOKE_GATE" >&2
      exit 1
    fi
    echo "[docker-exec-profiler] WARN: ATTACH_PID unresolved; kit will retry inside CTN" >&2
  fi
fi

# Run helper inside CTN
set +e
docker_cli exec \
  -e OUT_DIR="${CTN_WORK}/out" \
  -e MODEL="${MODEL}" \
  -e ROLE="${ROLE}" \
  -e ENGINE="${ENGINE}" \
  -e PROFILER_MODE="${PROFILER_MODE}" \
  -e ATTACH_PID="${ATTACH_PID:-}" \
  -e CLIENT_WINDOW_CMD="${CLIENT_WINDOW_CMD:-}" \
  -e ATTACH_CHATS="${ATTACH_CHATS:-8}" \
  -e ATTACH_MAX_TOKENS="${ATTACH_MAX_TOKENS:-128}" \
  -e API_PORT_CANDIDATES="${API_PORT_CANDIDATES:-8000 8200}" \
  -e LIGHT_DROP_RAW="${LIGHT_DROP_RAW:-1}" \
  -e NON_SMOKE_GATE="${NON_SMOKE_GATE:-0}" \
  -e DLPTI_PARSE="${DLPTI_PARSE:-light}" \
  -e MIN_ATTACH_ACTIVITIES="${MIN_ATTACH_ACTIVITIES:-200}" \
  -e MIN_ATTACH_BYTES="${MIN_ATTACH_BYTES:-65536}" \
  -e ATTACH_READY_SECS="${ATTACH_READY_SECS:-3}" \
  -e ATTACH_STOP_SECS="${ATTACH_STOP_SECS:-8}" \
  -e VENDOR_PROFILER="${VENDOR_PROFILER:-${KIT_NAME}}" \
  -e HCTRACER_BIN="${HCTRACER_BIN:-/opt/hpcc/bin/hcTracer}" \
  -e MCTRACER_BIN="${MCTRACER_BIN:-/opt/maca/bin/mcTracer}" \
  -e DLPTI_BIN="${DLPTI_BIN:-}" \
  "${CTN}" bash -lc "
set +e
set +o pipefail
mkdir -p '${CTN_WORK}/out/raw'
export OUT_DIR='${CTN_WORK}/out'
export MODEL='${MODEL}'
export ROLE='${ROLE}'
export ENGINE='${ENGINE}'
export PROFILER_MODE='${PROFILER_MODE}'
export ATTACH_PID='${ATTACH_PID:-}'
export CLIENT_WINDOW_CMD='${CLIENT_WINDOW_CMD:-}'
export ATTACH_CHATS='${ATTACH_CHATS:-8}'
export ATTACH_MAX_TOKENS='${ATTACH_MAX_TOKENS:-128}'
export API_PORT_CANDIDATES='${API_PORT_CANDIDATES:-8000 8200}'
export LIGHT_DROP_RAW='${LIGHT_DROP_RAW:-1}'
export NON_SMOKE_GATE='${NON_SMOKE_GATE:-0}'
export DLPTI_PARSE='${DLPTI_PARSE:-light}'
export MIN_ATTACH_ACTIVITIES='${MIN_ATTACH_ACTIVITIES:-200}'
export MIN_ATTACH_BYTES='${MIN_ATTACH_BYTES:-65536}'
export ATTACH_READY_SECS='${ATTACH_READY_SECS:-3}'
export ATTACH_STOP_SECS='${ATTACH_STOP_SECS:-8}'
bash '${CTN_KIT}/run_promotion_loop_step.sh'
ec=\$?
set +e
set +o pipefail
trap '' PIPE
# Under NON_SMOKE_GATE, kit failure must fail docker exec (no empty success).
if [[ '${NON_SMOKE_GATE:-0}' == '1' && \$ec -ne 0 ]]; then
  echo \"[docker-exec-profiler] kit failed under NON_SMOKE_GATE (ec=\$ec) — propagating\" >&2
  exit \$ec
fi
# If kit died mid-attach or produced empty totals, force smoke + light parse inside CTN.
need_smoke=0
if [[ ! -f '${CTN_WORK}/out/host_signals.json' && ! -f '${CTN_WORK}/out/compare.json' ]]; then
  need_smoke=1
elif python3 - '${CTN_WORK}/out/host_signals.json' <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
try:
    d=json.loads(p.read_text())
except Exception:
    raise SystemExit(1)
ft=d.get('family_totals_us') or {}
hs=d.get('host_signals') or []
ok=any(float(v or 0)>0 for v in ft.values()) or any(isinstance(x,dict) and x.get('ratio') is not None for x in hs)
raise SystemExit(0 if ok else 1)
PY
then
  :
else
  need_smoke=1
fi
if [[ \$need_smoke -eq 1 ]]; then
  if [[ '${LIGHT_DROP_RAW:-1}' == '0' || '${NON_SMOKE_GATE:-0}' == '1' ]]; then
    echo \"[docker-exec-profiler] empty/missing summary (kit_ec=\$ec); NON_SMOKE_GATE — skip smoke fallback\" >&2
    # Still attempt heavy/light parse on whatever raw exists.
    if [[ -f '${CTN_WORK}/kits/${KIT_NAME}/parse_dlpti_heavy.py' ]]; then
      python3 '${CTN_WORK}/kits/${KIT_NAME}/parse_dlpti_heavy.py' \
        --out-dir '${CTN_WORK}/out' --model '${MODEL}' --role '${ROLE}' || true
    elif [[ -f '${CTN_WORK}/kits/chrome_trace_heavy.py' ]]; then
      python3 '${CTN_WORK}/kits/chrome_trace_heavy.py' \
        --out-dir '${CTN_WORK}/out' --vendor '${KIT_NAME}' --model '${MODEL}' --role '${ROLE}' || true
    elif [[ -f '${CTN_WORK}/kits/chrome_trace_light.py' ]]; then
      python3 '${CTN_WORK}/kits/chrome_trace_light.py' \
        --out-dir '${CTN_WORK}/out' --vendor '${KIT_NAME}' --model '${MODEL}' --role '${ROLE}' || true
    fi
    if [[ '${NON_SMOKE_GATE:-0}' == '1' ]]; then
      exit \${ec:-1}
    fi
  else
    echo \"[docker-exec-profiler] empty/missing summary (kit_ec=\$ec); in-CTN smoke+parse fallback\" >&2
    export OUT_DIR='${CTN_WORK}/out' MODEL='${MODEL}' ROLE='${ROLE}' ENGINE='${ENGINE}'
    export PROFILER_MODE=smoke
    bash '${CTN_KIT}/run_promotion_loop_step.sh' || true
    if [[ ! -f '${CTN_WORK}/out/host_signals.json' && -f '${CTN_WORK}/kits/chrome_trace_light.py' ]]; then
      python3 '${CTN_WORK}/kits/chrome_trace_light.py' \
        --out-dir '${CTN_WORK}/out' --vendor '${KIT_NAME}' --model '${MODEL}' --role '${ROLE}' || true
    fi
  fi
fi
# Prefer success if summaries now exist (soft path only).
if [[ -f '${CTN_WORK}/out/host_signals.json' || -f '${CTN_WORK}/out/compare.json' ]]; then
  exit 0
fi
exit \$ec
"
run_ec=$?
set -e
echo "[docker-exec-profiler] helper exit=${run_ec}" >&2

# Pull lightweight outs only (never leave raw trees as the continuous publish path)
mkdir -p "${OUT_DIR}"
docker_cli cp "${CTN}:${CTN_WORK}/out/." "${OUT_DIR}/" 2>/dev/null || true

# Host-side parse fallback if CTN helper died before writing summaries but raw remains.
if [[ ! -f "${OUT_DIR}/compare.json" && ! -f "${OUT_DIR}/host_signals.json" ]]; then
  if [[ -f "${PARENT_KIT}/chrome_trace_light.py" ]] && compgen -G "${OUT_DIR}/raw/tracer_out*.json" >/dev/null 2>&1; then
    echo "[docker-exec-profiler] host chrome_trace_light fallback on pulled raw" >&2
    set +e
    python3 "${PARENT_KIT}/chrome_trace_light.py" \
      --out-dir "${OUT_DIR}" \
      --vendor "${KIT_NAME}" \
      --model "${MODEL}" \
      --role "${ROLE}"
    set -e
  fi
fi

# Drop bulky raw capture from host OUT when LIGHT_DROP_RAW=1 (default)
if [[ "${LIGHT_DROP_RAW:-1}" == "1" ]]; then
  # Keep a tiny provenance marker; remove large db/json trees from host OUT/raw
  if [[ -d "${OUT_DIR}/raw" ]]; then
    set +e
    find "${OUT_DIR}/raw" -type f \( -name '*.db' -o -name 'tracer_out*.json' -o -name 'export.json' \) \
      -printf '%p %s\n' > "${OUT_DIR}/raw_provenance.txt" 2>/dev/null
    if [[ ! -s "${OUT_DIR}/raw_provenance.txt" ]]; then
      find "${OUT_DIR}/raw" -type f \( -name '*.db' -o -name 'tracer_out*.json' -o -name 'export.json' \) \
        -exec ls -la {} \; > "${OUT_DIR}/raw_provenance.txt" 2>/dev/null
    fi
    find "${OUT_DIR}/raw" -type f \( -name '*.db' -o -name 'tracer_out*.json' -o -name 'export.json' \) -delete 2>/dev/null
    set -e
  fi
fi

docker_cli exec "${CTN}" bash -lc "rm -rf '${CTN_WORK}'" >/dev/null 2>&1 || true

# Treat exit 141 (SIGPIPE from find|head under pipefail) as soft if summaries exist.
if [[ ! -f "${OUT_DIR}/compare.json" && ! -f "${OUT_DIR}/host_signals.json" ]]; then
  echo "[docker-exec-profiler] error: no lightweight summary produced (helper_ec=${run_ec})" >&2
  exit 2
fi
if [[ ${run_ec} -ne 0 && ${run_ec} -ne 141 ]]; then
  if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
    echo "[docker-exec-profiler] ERROR helper_ec=${run_ec} under NON_SMOKE_GATE — fail (ignore empty summary)" >&2
    exit "${run_ec}"
  fi
  echo "[docker-exec-profiler] warn: helper_ec=${run_ec} but summary present; continuing" >&2
fi
exit 0
