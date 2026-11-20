#!/usr/bin/env bash
# Denglin DLPTI helper (in-CTN).
# PROFILER_MODE=smoke (default): sdk vectorAdd under dlpti_tools capture.
# PROFILER_MODE=attach_serve: capture server + inject into serve PID around CLIENT_WINDOW.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR required}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${KIT_DIR}/.." && pwd)"
# shellcheck source=../attach_common.sh
source "${PARENT}/attach_common.sh"
MODEL="${MODEL:-Qwen3-8B}"
ROLE="${ROLE:-candidate}"
PROFILER_MODE="${PROFILER_MODE:-smoke}"
ENGINE="${ENGINE:-}"
if [[ -z "${ENGINE}" ]]; then
  if [[ "${ROLE}" == "baseline" ]]; then ENGINE=vllm; else ENGINE=infinilm; fi
fi
MIN_ATTACH_ACTIVITIES="${MIN_ATTACH_ACTIVITIES:-200}"
DLPTI_PARSE="${DLPTI_PARSE:-light}"
INJECT_SO="${INJECT_SO:-/usr/local/dlgpu/sdk/lib/libdlpti_injection.so}"

OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
RAW_DIR="${OUT_DIR}/raw"
mkdir -p "${RAW_DIR}"

# Activate Denglin SDK if present (env.sh references $1; must not run under set -u)
if [[ -f /usr/local/dlgpu/sdk/env.sh ]]; then
  set +u
  # shellcheck disable=SC1091
  source /usr/local/dlgpu/sdk/env.sh
  set -u
fi

DLPTI_BIN="${DLPTI_BIN:-}"
if [[ -z "${DLPTI_BIN}" ]]; then
  for c in /usr/local/dlgpu/sdk/bin/dlpti_tools "$(command -v dlpti_tools 2>/dev/null || true)"; do
    if [[ -n "${c}" && -x "${c}" ]]; then
      DLPTI_BIN="${c}"
      break
    fi
  done
fi

resolve_sample() {
  if [[ -n "${DLPTI_SAMPLE_CMD:-}" ]]; then
    echo "${DLPTI_SAMPLE_CMD}"
    return 0
  fi
  local src=/usr/local/dlgpu/sdk/samples/cuda/vectorAdd
  local bin="${src}/build/vector_add"
  if [[ ! -x "${bin}" ]]; then
    if [[ -f "${src}/CMakeLists.txt" ]]; then
      echo "[dlpti-kit] building vector_add under ${src}/build" >&2
      mkdir -p "${src}/build"
      (
        cd "${src}/build"
        cmake .. >/tmp/dlpti_vectoradd_cmake.log 2>&1
        make -j"$(nproc 2>/dev/null || echo 2)" >>/tmp/dlpti_vectoradd_cmake.log 2>&1
      ) || true
    fi
  fi
  if [[ -x "${bin}" ]]; then
    echo "${bin}"
    return 0
  fi
  echo "/bin/true"
}

stamp_meta() {
  python3 - "${OUT_DIR}" "${ENGINE}" "${ROLE}" "${PROFILER_MODE}" <<'PY'
import json, sys
from pathlib import Path
out, engine, role, mode = sys.argv[1:5]
for name in ("compare.json", "host_signals.json"):
    p = Path(out) / name
    if not p.is_file():
        continue
    doc = json.loads(p.read_text(encoding="utf-8"))
    doc["engine"] = engine
    doc["role"] = role
    doc["profiler_mode"] = mode
    if mode == "attach_serve":
        doc["source"] = "dlpti matched_attach_serve"
    p.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

run_parse() {
  if [[ "${DLPTI_PARSE}" == "heavy" || "${NON_SMOKE_GATE:-0}" == "1" ]]; then
    echo "[dlpti-kit] parse=heavy (DLPTI_PARSE=${DLPTI_PARSE} NON_SMOKE_GATE=${NON_SMOKE_GATE:-0})" >&2
    python3 "${KIT_DIR}/parse_dlpti_heavy.py" --out-dir "${OUT_DIR}" --model "${MODEL}" --role "${ROLE}"
  else
    python3 "${KIT_DIR}/parse_dlpti_light.py" --out-dir "${OUT_DIR}" --model "${MODEL}" --role "${ROLE}"
  fi
  stamp_meta
}

ensure_gdb() {
  if command -v gdb >/dev/null 2>&1; then
    return 0
  fi
  echo "[dlpti-kit] gdb missing; attempting apt-get install gdb" >&2
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/tmp/dlpti_gdb_apt.log 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gdb >/tmp/dlpti_gdb_apt.log 2>&1 || true
  fi
  if command -v gdb >/dev/null 2>&1; then
    return 0
  fi
  echo "[dlpti-kit] gdb missing after install attempt" >&2
  return 1
}

preflight_attach() {
  local ok=1
  if [[ -z "${DLPTI_BIN}" || ! -x "${DLPTI_BIN}" ]]; then
    echo "[dlpti-kit] ERROR preflight: dlpti_tools missing inside CTN" >&2
    ok=0
  fi
  if [[ ! -f "${INJECT_SO}" ]]; then
    echo "[dlpti-kit] ERROR preflight: injection library missing: ${INJECT_SO}" >&2
    ok=0
  fi
  if ! ensure_gdb; then
    echo "[dlpti-kit] ERROR preflight: gdb unavailable" >&2
    ok=0
  fi
  if [[ "${ok}" -ne 1 ]]; then
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      return 1
    fi
    echo "[dlpti-kit] WARN preflight incomplete (NON_SMOKE_GATE off)" >&2
    return 1
  fi
  echo "[dlpti-kit] preflight ok: DLPTI_BIN=${DLPTI_BIN} so=${INJECT_SO} gdb=$(command -v gdb)" >&2
  return 0
}

export_activity_count() {
  local EXPORT_JSON="$1"
  python3 - "${EXPORT_JSON}" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    print(0)
    raise SystemExit(0)
try:
    doc = json.loads(p.read_text(encoding="utf-8"))
except Exception:
    print(0)
    raise SystemExit(0)
acts = doc.get("activities") if isinstance(doc, dict) else None
print(len(acts) if isinstance(acts, list) else 0)
PY
}

inject_log_failed() {
  local log="${1:-/tmp/dlpti_inject.log}"
  [[ -f "${log}" ]] || return 1
  # ptrace denial, attach failure, or null dlopen handle
  if grep -qiE \
    'ptrace:|Operation not permitted|Could not attach|Cannot attach|No such process|Permission denied|dlopen.*failed|failed to.*dlopen' \
    "${log}"
  then
    return 0
  fi
  # gdb printed a null void* from dlopen
  if grep -qE '\$[0-9]+ = \(void \*\) 0x0\b' "${log}"; then
    return 0
  fi
  return 1
}

export_db() {
  local DB="$1"
  local EXPORT_JSON="$2"
  if [[ -f "${DB}" ]]; then
    set +e
    "${DLPTI_BIN}" export --format json --output "${EXPORT_JSON}" "${DB}"
    local erc=$?
    set -e
    echo "[dlpti-kit] export exit=${erc}" >&2
  fi
}

stop_capture_server() {
  local SERVER_PID="${1:-}"
  [[ -n "${SERVER_PID}" ]] || return 0
  if kill -0 "${SERVER_PID}" 2>/dev/null; then
    kill -INT "${SERVER_PID}" 2>/dev/null || true
    local i
    for i in $(seq 1 "${ATTACH_STOP_SECS:-8}"); do
      if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        break
      fi
      sleep 1
    done
    kill -KILL "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}

run_smoke() {
  local SAMPLE DB EXPORT_JSON
  SAMPLE="$(resolve_sample)"
  DB="${RAW_DIR}/capture.db"
  EXPORT_JSON="${RAW_DIR}/export.json"
  echo "[dlpti-kit] SMOKE DLPTI_BIN=${DLPTI_BIN} sample=${SAMPLE}" >&2
  set +e
  "${DLPTI_BIN}" capture --data-file "${DB}" -- "${SAMPLE}"
  local rc=$?
  set -e
  echo "[dlpti-kit] capture exit=${rc}" >&2
  export_db "${DB}" "${EXPORT_JSON}"
}

_libc_deleted_under_pid() {
  local pid="$1"
  grep -q 'libc\.so\.6 (deleted)' "/proc/${pid}/maps" 2>/dev/null
}

inject_dlpti_into_pid() {
  local pid="$1" sock="$2"
  if [[ ! -f "${INJECT_SO}" ]]; then
    echo "[dlpti-kit] injection library missing: ${INJECT_SO}" >&2
    return 1
  fi
  if ! ensure_gdb; then
    echo "[dlpti-kit] gdb missing; cannot inject into pid=${pid}" >&2
    return 1
  fi
  if _libc_deleted_under_pid "${pid}"; then
    echo "[dlpti-kit] ERROR pid=${pid} has libc.so.6 (deleted) — apt upgraded libc under live serve; restart CTN (install gdb in wrap before exec)" >&2
    return 1
  fi
  # Injection .so reads DLPTI_LAUNCHER_URL (not DLPTI_SERVER).
  set +e
  gdb -p "${pid}" -batch -nx \
    -ex "set pagination off" \
    -ex "set auto-load safe-path /" \
    -ex "set scheduler-locking on" \
    -ex "set unwindonsignal on" \
    -ex "call (int)setenv(\"DLPTI_LAUNCHER_URL\", \"${sock}\", 1)" \
    -ex "print (void*)dlopen(\"${INJECT_SO}\", 1)" \
    -ex "set scheduler-locking off" \
    >/tmp/dlpti_inject.log 2>&1
  local irc=$?
  set -e
  echo "[dlpti-kit] gdb inject exit=${irc} pid=${pid}" >&2
  sed -n '1,60p' /tmp/dlpti_inject.log >&2 || true
  # Success: non-null dlopen handle, even if gdb exit!=0 from thread warnings.
  if grep -qE '\$[0-9]+ = \(void \*\) 0x[1-9a-fA-F]' /tmp/dlpti_inject.log; then
    if grep -q libdlpti_injection "/proc/${pid}/maps" 2>/dev/null; then
      echo "[dlpti-kit] inject ok pid=${pid} (maps+handle)" >&2
    else
      echo "[dlpti-kit] inject ok pid=${pid} (handle)" >&2
    fi
    return 0
  fi
  if inject_log_failed /tmp/dlpti_inject.log; then
    echo "[dlpti-kit] ERROR inject log shows ptrace/dlopen failure for pid=${pid}" >&2
    return 1
  fi
  if [[ ${irc} -ne 0 ]]; then
    return "${irc}"
  fi
  echo "[dlpti-kit] ERROR inject produced no dlopen handle for pid=${pid}" >&2
  return 1
}

# vLLM: GPU work lives in Worker_TP processes. InfiniLM: single inference_server.
resolve_inject_pids() {
  local primary="$1"
  local pids=()
  local p
  while IFS= read -r p; do
    [[ "${p}" =~ ^[0-9]+$ ]] || continue
    pids+=("${p}")
  done < <(pgrep -f 'VLLM::Worker_TP' 2>/dev/null || true)
  if [[ ${#pids[@]} -eq 0 ]]; then
    pids=("${primary}")
  fi
  printf '%s\n' "${pids[@]}"
}

run_attach_serve() {
  local pid DB EXPORT_JSON SOCK SERVER_PID note act_count
  if ! preflight_attach; then
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[dlpti-kit] ERROR attach preflight failed under NON_SMOKE_GATE" >&2
      return 1
    fi
    return 1
  fi

  pid="$(resolve_serve_pid)" || return 1
  DB="${RAW_DIR}/capture.db"
  EXPORT_JSON="${RAW_DIR}/export.json"
  SOCK="ipc:///tmp/io_dlpti_attach_$$.sock"
  rm -f /tmp/io_dlpti_attach_$$.sock 2>/dev/null || true
  echo "[dlpti-kit] ATTACH_SERVE pid=${pid} sock=${SOCK} engine=${ENGINE}" >&2
  note="matched attach_serve via capture server + inject"

  # Prefer bind-only server mode (no sleep target). Fall back to sleep if required.
  set +e
  "${DLPTI_BIN}" capture --data-file "${DB}" --bind "${SOCK}" \
    >/tmp/dlpti_server.log 2>&1 &
  SERVER_PID=$!
  set -e
  sleep "${ATTACH_READY_SECS:-3}"
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "[dlpti-kit] bind-only server exited; retry with sleep target:" >&2
    sed -n '1,40p' /tmp/dlpti_server.log >&2 || true
    set +e
    "${DLPTI_BIN}" capture --data-file "${DB}" --bind "${SOCK}" -- sleep 900 \
      >/tmp/dlpti_server.log 2>&1 &
    SERVER_PID=$!
    set -e
    sleep "${ATTACH_READY_SECS:-3}"
  fi
  if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "[dlpti-kit] capture server exited early:" >&2
    sed -n '1,60p' /tmp/dlpti_server.log >&2 || true
    return 1
  fi
  echo "[dlpti-kit] capture server pid=${SERVER_PID}" >&2

  local inj_rc=0 inj_ok=0 inj_pid
  local -a inject_pids=()
  mapfile -t inject_pids < <(resolve_inject_pids "${pid}")
  echo "[dlpti-kit] inject targets: ${inject_pids[*]:-none}" >&2
  for inj_pid in "${inject_pids[@]}"; do
    set +e
    inject_dlpti_into_pid "${inj_pid}" "${SOCK}"
    local one_rc=$?
    set -e
    if [[ ${one_rc} -eq 0 ]]; then
      inj_ok=1
    else
      inj_rc="${one_rc}"
      echo "[dlpti-kit] WARN inject failed for pid=${inj_pid} rc=${one_rc}" >&2
    fi
  done
  if [[ ${inj_ok} -eq 0 ]]; then
    note="attach_serve inject failed; capture-range window around client (best-effort)"
    echo "[dlpti-kit] WARN all injects failed (last_rc=${inj_rc})" >&2
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[dlpti-kit] ERROR inject failed under NON_SMOKE_GATE — abort (no client window)" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" \
        "attach_serve inject failed; non_smoke_gate_fail"
      stop_capture_server "${SERVER_PID}"
      return 1
    fi
    echo "[dlpti-kit] WARN continuing client window under live server (NON_SMOKE_GATE off)" >&2
  else
    inj_rc=0
    note="matched attach_serve via capture server + inject (pids=${inject_pids[*]})"
  fi

  write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" "${note}"

  # Allow injection hooks to finish handshake before workload.
  sleep "${ATTACH_SETTLE_SECS:-2}"
  echo "[dlpti-kit] server log (post-inject):" >&2
  sed -n '1,40p' /tmp/dlpti_server.log >&2 || true

  set +e
  run_client_window
  local client_rc=$?
  set -e
  echo "[dlpti-kit] client_rc=${client_rc}" >&2

  # Brief settle so agents flush before SIGINT finalize.
  sleep "${ATTACH_SETTLE_SECS:-2}"
  stop_capture_server "${SERVER_PID}"
  sleep 1
  echo "[dlpti-kit] server log (post-stop):" >&2
  sed -n '1,80p' /tmp/dlpti_server.log >&2 || true
  ls -la "${DB}" "${RAW_DIR}" >&2 || true
  export_db "${DB}" "${EXPORT_JSON}"

  act_count="$(export_activity_count "${EXPORT_JSON}")"
  echo "[dlpti-kit] activity_count=${act_count} min=${MIN_ATTACH_ACTIVITIES}" >&2

  # Empty / missing activities
  if [[ ! -f "${EXPORT_JSON}" || "${act_count}" -le 0 ]]; then
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[dlpti-kit] ERROR attach export empty; NON_SMOKE_GATE — fail" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" \
        "attach_inject_empty; non_smoke_gate_fail"
      return 1
    fi
    if [[ "${LIGHT_DROP_RAW:-1}" == "0" ]]; then
      echo "[dlpti-kit] WARN attach export empty; keeping raw (no smoke fallback)" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" \
        "attach_inject_empty; kept_raw_no_smoke"
      return 0
    fi
    echo "[dlpti-kit] WARN attach export empty; fallback smoke during client window" >&2
    write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" \
      "attach_inject_empty; fallback smoke during client window"
    local SAMPLE
    SAMPLE="$(resolve_sample)"
    rm -f "${DB}" "${EXPORT_JSON}" 2>/dev/null || true
    set +e
    (
      "${DLPTI_BIN}" capture --data-file "${DB}" -- "${SAMPLE}"
    ) &
    local smoke_pid=$!
    run_client_window
    wait "${smoke_pid}" 2>/dev/null || true
    set -e
    export_db "${DB}" "${EXPORT_JSON}"
    return 0
  fi

  # Tiny / smoke-like captures under the hard gate
  if [[ "${act_count}" -lt "${MIN_ATTACH_ACTIVITIES}" ]]; then
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[dlpti-kit] ERROR activity_count=${act_count} < MIN_ATTACH_ACTIVITIES=${MIN_ATTACH_ACTIVITIES}; NON_SMOKE_GATE — fail" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" \
        "attach_too_few_activities (${act_count}<${MIN_ATTACH_ACTIVITIES}); non_smoke_gate_fail"
      return 1
    fi
    echo "[dlpti-kit] WARN activity_count=${act_count} < MIN_ATTACH_ACTIVITIES=${MIN_ATTACH_ACTIVITIES} (gate soft)" >&2
  fi

  if [[ ${inj_rc} -eq 0 ]]; then
    write_attach_provenance "${OUT_DIR}/attach_provenance.json" "dlpti" "${pid}" \
      "matched attach_serve via capture server + inject (activities=${act_count})"
  fi
  return 0
}

if [[ -z "${DLPTI_BIN}" || ! -x "${DLPTI_BIN}" ]]; then
  echo "[dlpti-kit] dlpti_tools missing inside CTN" >&2
  if [[ "${PROFILER_MODE}" == "attach_serve" && "${NON_SMOKE_GATE:-0}" == "1" ]]; then
    echo "[dlpti-kit] ERROR missing dlpti_tools under NON_SMOKE_GATE" >&2
    exit 1
  fi
  run_parse || true
  exit 0
fi

attach_rc=0
case "${PROFILER_MODE}" in
  attach_serve)
    set +e
    run_attach_serve
    attach_rc=$?
    set -e
    ;;
  *)
    run_smoke
    ;;
esac

set +e
run_parse
parse_rc=$?
set -e

if [[ "${attach_rc}" -ne 0 ]]; then
  echo "[dlpti-kit] ERROR attach_serve failed rc=${attach_rc}" >&2
  exit "${attach_rc}"
fi
if [[ "${parse_rc}" -ne 0 ]]; then
  echo "[dlpti-kit] ERROR parse failed rc=${parse_rc}" >&2
  exit "${parse_rc}"
fi
exit 0
