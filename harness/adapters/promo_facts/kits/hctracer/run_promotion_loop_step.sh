#!/usr/bin/env bash
# Mars hcTracer helper (in-CTN).
# PROFILER_MODE=smoke (default): vectorAdd under hcTracer.
# PROFILER_MODE=attach_serve: hcTracer --attach <serve_pid> around CLIENT_WINDOW.
set -euo pipefail

: "${OUT_DIR:?OUT_DIR required}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT="$(cd "${KIT_DIR}/.." && pwd)"
# shellcheck source=../attach_common.sh
source "${PARENT}/attach_common.sh"
HCTRACER_BIN="${HCTRACER_BIN:-/opt/hpcc/bin/hcTracer}"
MODEL="${MODEL:-Qwen3-8B}"
ROLE="${ROLE:-candidate}"
PROFILER_MODE="${PROFILER_MODE:-smoke}"
ENGINE="${ENGINE:-}"
if [[ -z "${ENGINE}" ]]; then
  if [[ "${ROLE}" == "baseline" ]]; then ENGINE=vllm; else ENGINE=infinilm; fi
fi

resolve_sample() {
  if [[ -n "${HCTRACER_SAMPLE_CMD:-}" ]]; then
    echo "${HCTRACER_SAMPLE_CMD}"
    return 0
  fi
  local candidates=(
    /opt/hpcc/samples/0_Introduction/vectorAdd/vectorAdd
    /opt/hpcc/samples/0_Introduction/vectorAdd/vectorAdd.exe
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "${c}" ]]; then
      echo "${c}"
      return 0
    fi
  done
  local src=/opt/hpcc/samples/0_Introduction/vectorAdd
  if [[ -f "${src}/Makefile" ]]; then
    echo "[hctracer-kit] building vectorAdd under ${src}" >&2
    if make -C "${src}" -j"$(nproc 2>/dev/null || echo 2)" >/tmp/hctracer_vectoradd_build.log 2>&1; then
      if [[ -x "${src}/vectorAdd" ]]; then
        echo "${src}/vectorAdd"
        return 0
      fi
    else
      echo "[hctracer-kit] vectorAdd build failed; falling back" >&2
    fi
  fi
  echo "/bin/true"
}

OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
RAW_DIR="${OUT_DIR}/raw"
mkdir -p "${RAW_DIR}"

run_parse() {
  if [[ "${NON_SMOKE_GATE:-0}" == "1" || "${DLPTI_PARSE:-light}" == "heavy" ]]; then
    if [[ -f "${PARENT}/chrome_trace_heavy.py" ]]; then
      echo "[hctracer-kit] parse=heavy (NON_SMOKE_GATE=${NON_SMOKE_GATE:-0} DLPTI_PARSE=${DLPTI_PARSE:-light})" >&2
      python3 "${PARENT}/chrome_trace_heavy.py" \
        --out-dir "${OUT_DIR}" \
        --vendor hctracer \
        --model "${MODEL}" \
        --role "${ROLE}"
      return $?
    fi
  fi
  if [[ -f "${PARENT}/chrome_trace_light.py" ]]; then
    python3 "${PARENT}/chrome_trace_light.py" \
      --out-dir "${OUT_DIR}" \
      --vendor hctracer \
      --model "${MODEL}" \
      --role "${ROLE}"
  else
    python3 "${KIT_DIR}/parse_hctracer_light.py" --out-dir "${OUT_DIR}"
  fi
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
        doc["source"] = "hctracer matched_attach_serve"
    p.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
PY
}

if [[ ! -x "${HCTRACER_BIN}" ]]; then
  echo "[hctracer-kit] missing binary ${HCTRACER_BIN}" >&2
  run_parse
  stamp_meta
  exit 0
fi

run_smoke() {
  local SAMPLE_CMD
  SAMPLE_CMD="$(resolve_sample)"
  echo "[hctracer-kit] SMOKE HCTRACER_BIN=${HCTRACER_BIN} sample=${SAMPLE_CMD}" >&2
  set +e
  (
    cd "${OUT_DIR}"
    "${HCTRACER_BIN}" --hctx --odname raw --name tracer_out "${SAMPLE_CMD}"
  )
  local rc=$?
  set -e
  echo "[hctracer-kit] hcTracer exit=${rc}" >&2
}

collect_tracer_outs() {
  mkdir -p "${RAW_DIR}"
  set +e
  set +o pipefail
  trap '' PIPE
  find "${OUT_DIR}" -maxdepth 3 -type f -name 'tracer_out*.json' \
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
  local pid start_rc client_rc bytes SAMPLE_CMD smoke_pid min_bytes
  set +e
  set +o pipefail
  trap '' PIPE
  pid="$(resolve_serve_pid)" || {
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[hctracer-kit] ERROR serve PID unresolved under NON_SMOKE_GATE" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "0" \
        "attach_failed; serve PID unresolved"
    fi
    return 1
  }
  echo "[hctracer-kit] ATTACH_SERVE BIN=${HCTRACER_BIN} pid=${pid} engine=${ENGINE}" >&2
  write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "${pid}" "matched attach_serve"
  start_chrome_tracer_attach "${HCTRACER_BIN}" --hctx --odname raw --name tracer_out -- "${pid}"
  start_rc=$?
  if [[ ${start_rc} -ne 0 ]]; then
    if [[ "${LIGHT_DROP_RAW:-1}" == "0" || "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[hctracer-kit] ERROR attach start failed (tracer exited early); NON_SMOKE_GATE — no smoke fallback" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "${pid}" \
        "attach_failed; tracer_exited_early; no_smoke"
      # Under gate: do not run a client window that could mark soft success.
      collect_tracer_outs
      return 1
    fi
    echo "[hctracer-kit] WARN attach start failed; fallback smoke during client window" >&2
    write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "${pid}" \
      "attach_failed; fallback smoke during client window"
    SAMPLE_CMD="$(resolve_sample)"
    (
      cd "${OUT_DIR}"
      "${HCTRACER_BIN}" --hctx --odname raw --name tracer_out "${SAMPLE_CMD}"
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
  echo "[hctracer-kit] client_rc=${client_rc}" >&2
  collect_tracer_outs
  bytes="$(attach_bytes_total)"
  min_bytes=4096
  if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
    min_bytes="${MIN_ATTACH_BYTES:-65536}"
  fi
  if [[ "${bytes:-0}" -lt "${min_bytes}" ]]; then
    if [[ "${NON_SMOKE_GATE:-0}" == "1" ]]; then
      echo "[hctracer-kit] ERROR attach tracer small (${bytes}B < ${min_bytes}); NON_SMOKE_GATE — fail" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "${pid}" \
        "attach_small_capture; bytes=${bytes}; min=${min_bytes}"
      return 1
    fi
    if [[ "${LIGHT_DROP_RAW:-1}" == "0" ]]; then
      echo "[hctracer-kit] WARN attach tracer small (${bytes}B); keeping raw (no smoke fallback)" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "${pid}" \
        "attach_small_capture; kept_raw_no_smoke"
    else
      echo "[hctracer-kit] WARN attach tracer small (${bytes}B); smoke fallback" >&2
      write_attach_provenance "${OUT_DIR}/attach_provenance.json" "hctracer" "${pid}" \
        "attach_small_capture; fallback smoke"
      run_smoke
      collect_tracer_outs
    fi
  fi
  return 0
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
  echo "[hctracer-kit] propagating attach failure under NON_SMOKE_GATE (ec=${kit_rc})" >&2
  exit "${kit_rc}"
fi
exit 0
