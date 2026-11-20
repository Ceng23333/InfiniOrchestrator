#!/usr/bin/env bash
# MetaX mcTracer helper (in-CTN).
# PROFILER_MODE=smoke (default): vectorAdd under mcTracer.
# PROFILER_MODE=attach_serve: mcTracer --attach <serve_pid> around CLIENT_WINDOW.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR required}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${KIT_DIR}/.." && pwd)"
# shellcheck source=../attach_common.sh
source "${PARENT}/attach_common.sh"
MCTRACER_BIN="${MCTRACER_BIN:-}"
MODEL="${MODEL:-Qwen3-8B}"
ROLE="${ROLE:-candidate}"
PROFILER_MODE="${PROFILER_MODE:-smoke}"
ENGINE="${ENGINE:-}"
if [[ -z "${ENGINE}" ]]; then
  if [[ "${ROLE}" == "baseline" ]]; then ENGINE=vllm; else ENGINE=infinilm; fi
fi

resolve_bin() {
  if [[ -n "${MCTRACER_BIN}" && -x "${MCTRACER_BIN}" ]]; then
    echo "${MCTRACER_BIN}"
    return 0
  fi
  local c
  for c in /opt/maca/bin/mcTracer /opt/maca-*/bin/mcTracer; do
    # shellcheck disable=SC2086
    for p in $c; do
      if [[ -x "${p}" ]]; then
        echo "${p}"
        return 0
      fi
    done
  done
  if command -v mcTracer >/dev/null 2>&1; then
    command -v mcTracer
    return 0
  fi
  return 1
}

resolve_sample() {
  if [[ -n "${MCTRACER_SAMPLE_CMD:-}" ]]; then
    echo "${MCTRACER_SAMPLE_CMD}"
    return 0
  fi
  local src c
  for src in \
    /opt/maca/samples/0_Introduction/vectorAdd \
    /opt/maca-3.8.2/samples/0_Introduction/vectorAdd
  do
    c="${src}/vectorAdd"
    if [[ ! -x "${c}" && -f "${src}/Makefile" ]]; then
      make -C "${src}" -j"$(nproc 2>/dev/null || echo 2)" >/tmp/mctracer_vectoradd_build.log 2>&1 || true
    fi
    if [[ -x "${c}" ]]; then
      echo "${c}"
      return 0
    fi
  done
  echo "/bin/true"
}

OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
RAW_DIR="${OUT_DIR}/raw"
mkdir -p "${RAW_DIR}"

BIN="$(resolve_bin)" || {
  echo "[mctracer-kit] mcTracer binary missing inside CTN" >&2
  python3 "${PARENT}/chrome_trace_light.py" --out-dir "${OUT_DIR}" --vendor mctracer --model "${MODEL}" --role "${ROLE}"
  exit 0
}

run_smoke() {
  local SAMPLE
  SAMPLE="$(resolve_sample)"
  echo "[mctracer-kit] SMOKE BIN=${BIN} sample=${SAMPLE} OUT_DIR=${OUT_DIR}" >&2
  set +e
  (
    cd "${OUT_DIR}"
    "${BIN}" --mctx --odname raw --name tracer_out "${SAMPLE}"
  )
  local rc=$?
  set -e
  echo "[mctracer-kit] mcTracer exit=${rc}" >&2
}

collect_tracer_outs() {
  mkdir -p "${RAW_DIR}"
  # Avoid find|grep under pipefail (SIGPIPE → exit 141). Stay soft afterward.
  set +e
  set +o pipefail
  trap '' PIPE
  find "${OUT_DIR}" -maxdepth 3 -type f \( -name 'tracer_out*.json' -o -name 'tracer_out*.json.gz' \) \
    ! -path "${RAW_DIR}/*" -exec mv -f {} "${RAW_DIR}/" \; 2>/dev/null
  local n
  n="$(find "${OUT_DIR}/raw" -type f -name 'tracer_out*.json' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${n:-0}" -eq 0 ]]; then
    find "${OUT_DIR}" -type f -name 'tracer_out*.json' -exec cp -f {} "${RAW_DIR}/" \; 2>/dev/null
  fi
}

attach_bytes_total() {
  local bytes=0 _f _sz
  while IFS= read -r _f; do
    [[ -f "${_f}" ]] || continue
    _sz=$(wc -c <"${_f}" 2>/dev/null | tr -d ' ' || echo 0)
    bytes=$((bytes + ${_sz:-0}))
  done < <(find "${RAW_DIR}" -type f -name 'tracer_out*.json' 2>/dev/null)
  echo "${bytes}"
}

run_attach_serve() {
  local pid start_rc client_rc bytes SAMPLE smoke_pid min_bytes
  set +e
  set +o pipefail
  trap '' PIPE
  pid="$(resolve_serve_pid)" || {
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[mctracer-kit] ERROR serve PID unresolved under NON_SMOKE_GATE" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "0" \
        "attach_failed; serve PID unresolved"
    fi
    return 1
  }
  echo "[mctracer-kit] ATTACH_SERVE BIN=${BIN} pid=${pid} engine=${ENGINE} role=${ROLE}" >&2
  write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "${pid}" "matched attach_serve"
  # Prefer --ip form used in MetaX attach examples; fall back without it.
  start_chrome_tracer_attach "${BIN}" --ip 127.0.0.1 --mctx --odname raw --name tracer_out -- "${pid}"
  start_rc=$?
  if [[ ${start_rc} -ne 0 ]]; then
    echo "[mctracer-kit] attach with --ip failed; retry without --ip" >&2
    start_chrome_tracer_attach "${BIN}" --mctx --odname raw --name tracer_out -- "${pid}"
    start_rc=$?
  fi
  if [[ ${start_rc} -ne 0 ]]; then
    if [[ "${LIGHT_DROP_RAW:-1}" == "0" || "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[mctracer-kit] ERROR attach start failed (tracer exited early); NON_SMOKE_GATE — no smoke fallback" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "${pid}" \
        "attach_failed; tracer_exited_early; no_smoke"
      # Under gate: do not run a client window that could mark soft success.
      collect_tracer_outs
      return 1
    fi
    echo "[mctracer-kit] WARN attach start failed; fallback matched-window smoke under client" >&2
    write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "${pid}" \
      "attach_failed; fallback smoke during client window"
    SAMPLE="$(resolve_sample)"
    (
      cd "${OUT_DIR}"
      "${BIN}" --mctx --odname raw --name tracer_out "${SAMPLE}"
    ) &
    smoke_pid=$!
    run_client_window
    wait "${smoke_pid}" 2>/dev/null || true
    collect_tracer_outs
    return 0
  fi
  run_client_window
  client_rc=$?
  stop_chrome_tracer_attach || true
  echo "[mctracer-kit] client_rc=${client_rc}" >&2
  collect_tracer_outs
  bytes="$(attach_bytes_total)"
  min_bytes=4096
  if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
    min_bytes="${MIN_ATTACH_BYTES:-65536}"
  fi
  if [[ "${bytes:-0}" -lt "${min_bytes}" ]]; then
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[mctracer-kit] ERROR attach tracer small (${bytes}B < ${min_bytes}); NON_SMOKE_GATE — fail" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "${pid}" \
        "attach_small_capture; bytes=${bytes}; min=${min_bytes}"
      return 1
    fi
    if [[ "${LIGHT_DROP_RAW:-1}" == "0" ]]; then
      echo "[mctracer-kit] WARN attach tracer small (${bytes}B); keeping raw (no smoke fallback)" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "${pid}" \
        "attach_small_capture; kept_raw_no_smoke"
    else
      echo "[mctracer-kit] WARN attach tracer small (${bytes}B); smoke fallback" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "mctracer" "${pid}" \
        "attach_small_capture; fallback smoke"
      run_smoke
      collect_tracer_outs
    fi
  fi
  return 0
}

run_parse() {
  if [[ "${NON_SMOKE_GATE:-0}" == "1" || "${DLPTI_PARSE:-light}" == "heavy" ]]; then
    if [[ -f "${PARENT}/chrome_trace_heavy.py" ]]; then
      echo "[mctracer-kit] parse=heavy (NON_SMOKE_GATE=${NON_SMOKE_GATE:-0} DLPTI_PARSE=${DLPTI_PARSE:-light})" >&2
      python3 "${PARENT}/chrome_trace_heavy.py" \
        --out-dir "${OUT_DIR}" \
        --vendor mctracer \
        --model "${MODEL}" \
        --role "${ROLE}"
      return $?
    fi
  fi
  python3 "${PARENT}/chrome_trace_light.py" \
    --out-dir "${OUT_DIR}" \
    --vendor mctracer \
    --model "${MODEL}" \
    --role "${ROLE}"
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
        doc["source"] = "mctracer matched_attach_serve"
    p.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

kit_rc=0
set +e
set +o pipefail
case "${PROFILER_MODE}" in
  attach_serve) run_attach_serve; kit_rc=$? ;;
  *) run_smoke; kit_rc=0 ;;
esac

run_parse || true
stamp_meta || true

if [[ "${NON_SMOKE_GATE:-0}" == "1" && "${kit_rc}" -ne 0 ]]; then
  echo "[mctracer-kit] propagating attach failure under NON_SMOKE_GATE (ec=${kit_rc})" >&2
  exit "${kit_rc}"
fi
exit 0
