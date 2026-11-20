#!/usr/bin/env bash
# Shared helpers for PROFILER_MODE=attach_serve (in-CTN only).
# Sourced by kits/{dlpti,mctracer,hctracer}/run_promotion_loop_step.sh.
#
# Env:
#   ATTACH_PID          optional explicit serve PID
#   CLIENT_WINDOW_CMD   optional command run during attach window
#   ATTACH_CHATS        default chat burst count (8)
#   ATTACH_MAX_TOKENS   default 128
#   MODEL               chat model name
#   API_PORT_CANDIDATES space-separated in-CTN ports to try (default: 8000 8200)
#   ATTACH_READY_SECS   seconds to wait after attach start (default 3; dual uses 8 on metax/mars)
#   ATTACH_STOP_SECS    seconds to wait after stop signal (default 5)
#   MIN_ATTACH_BYTES    chrome attach size floor under NON_SMOKE_GATE (default 65536)

# Avoid SIGPIPE (141) from find|grep/head under pipefail in attach helpers.
# Also ignore SIGPIPE: printf to a closed tracer FIFO otherwise kills bash with 141
# even under `set +e` (builtin SIGPIPE terminates the shell).
_attach_soft() { set +e; set +o pipefail; trap '' PIPE; }
_attach_hard() { set -e; set -o pipefail; trap - PIPE; }

_pid_is_sleep() {
	local pid="$1" cmd=""
	cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
	[[ "${cmd}" == sleep* || "${cmd}" == *"sleep infinity"* ]]
}

_pid_alive() {
	local pid="$1"
	[[ "${pid}" =~ ^[0-9]+$ ]] || return 1
	kill -0 "${pid}" 2>/dev/null
}

_pid_looks_like_serve() {
	local pid="$1" cmd=""
	cmd="$(ps -p "${pid}" -o args= 2>/dev/null || true)"
	[[ -n "${cmd}" ]] || return 1
	# Reject sleep placeholders and profiler helpers.
	if _pid_is_sleep "${pid}"; then
		return 1
	fi
	if [[ "${cmd}" == *attach_common* || "${cmd}" == *run_promotion_loop_step* || "${cmd}" == *dlpti_tools* ]]; then
		return 1
	fi
	[[ "${cmd}" == *inference_server.py* \
		|| "${cmd}" == *VLLM::Worker_TP* \
		|| "${cmd}" == *VLLM::EngineCore* \
		|| "${cmd}" == *vllm.entrypoints* \
		|| "${cmd}" == *api_server* \
		|| "${cmd}" == *vllm* ]]
}

resolve_serve_pid() {
	local pid=""
	_attach_soft
	# Honor ATTACH_PID only when it is alive and looks like a serve process.
	# Dual-host SSH pgrep can leak host PIDs that do not exist in the CTN NS.
	if [[ -n "${ATTACH_PID:-}" && "${ATTACH_PID}" =~ ^[0-9]+$ ]]; then
		if _pid_alive "${ATTACH_PID}" && _pid_looks_like_serve "${ATTACH_PID}"; then
			echo "${ATTACH_PID}"
			_attach_hard
			return 0
		fi
		echo "[attach] WARN ATTACH_PID=${ATTACH_PID} dead/non-serve in this NS; re-resolving" >&2
	fi
	# Prefer GPU workers first — mcTracer/hcTracer need vendor port files on the
	# device process (API/EngineCore alone often fail with "Can not open port file").
	# Use ps|awk so pgrep -f cannot match this resolver's cmdline.
	pid="$(ps -eo pid,args 2>/dev/null | awk '/VLLM::Worker_TP0/ && $0 !~ /awk/ { print $1; exit }')"
	if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
		pid="$(ps -eo pid,args 2>/dev/null | awk '/VLLM::EngineCore/ && $0 !~ /awk/ { print $1; exit }')"
	fi
	if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
		pid="$(ps -eo pid,args 2>/dev/null | awk '/inference_server\.py/ && $0 !~ /awk/ { print $1; exit }')"
	fi
	if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
		pid="$(ps -eo pid,args 2>/dev/null | awk '/vllm\.entrypoints/ && $0 !~ /awk/ { print $1; exit }')"
	fi
	if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
		pid="$(ps -eo pid,etime,args 2>/dev/null | awk '
			/python/ && !/attach_common|run_promotion_loop_step|dlpti_tools|mcTracer|hcTracer/ && $0 !~ /sleep infinity/ {
				print $1; exit
			}')"
	fi
	if [[ "${pid}" =~ ^[0-9]+$ ]] && _pid_is_sleep "${pid}"; then
		pid=""
	fi
	_attach_hard
	if [[ ! "${pid}" =~ ^[0-9]+$ ]] || ! _pid_alive "${pid}"; then
		echo "[attach] error: could not resolve serve PID (got='${pid}')" >&2
		return 1
	fi
	echo "${pid}"
}

_http_ok() {
	local url="$1"
	if command -v curl >/dev/null 2>&1; then
		curl -sf --noproxy '*' --max-time 2 "${url}" >/dev/null 2>&1
		return $?
	fi
	python3 - "${url}" <<'PY'
import sys, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=2) as r:
        sys.exit(0 if r.status < 400 else 1)
except Exception:
    sys.exit(1)
PY
}

detect_serve_url() {
	local p
	for p in ${API_PORT_CANDIDATES:-8000 8200}; do
		if _http_ok "http://127.0.0.1:${p}/v1/models"; then
			echo "http://127.0.0.1:${p}"
			return 0
		fi
	done
	echo "http://127.0.0.1:8000"
}

_chat_once() {
	local url="$1" model="$2" max_tok="$3" i="$4" out="$5"
	local payload
	payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"matched-attach decode window ${i}\"}],\"max_tokens\":${max_tok},\"temperature\":0,\"stream\":false,\"ignore_eos\":true}"
	if command -v curl >/dev/null 2>&1; then
		curl -sf --noproxy '*' --max-time 300 \
			-H 'Content-Type: application/json' \
			-d "${payload}" \
			"${url}/v1/chat/completions" >"${out}"
		return $?
	fi
	python3 - "${url}/v1/chat/completions" "${payload}" "${out}" <<'PY'
import sys, urllib.request
url, payload, out = sys.argv[1:4]
req = urllib.request.Request(
    url, data=payload.encode(), headers={"Content-Type": "application/json"}, method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        open(out, "wb").write(r.read())
    sys.exit(0)
except Exception as exc:
    print(f"[attach] python chat failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

default_client_window() {
	local url model chats max_tok i
	url="$(detect_serve_url)"
	model="${MODEL:-Qwen3-8B}"
	chats="${ATTACH_CHATS:-8}"
	max_tok="${ATTACH_MAX_TOKENS:-128}"
	echo "[attach] client window url=${url} chats=${chats} max_tokens=${max_tok}" >&2
	_attach_soft
	for i in $(seq 1 "${chats}"); do
		_chat_once "${url}" "${model}" "${max_tok}" "${i}" "/tmp/io_attach_chat_${i}.json" \
			|| echo "[attach] warn: chat ${i} failed" >&2
	done
	# Stay soft — callers own pipefail; _attach_hard here leaked SIGPIPE 141 into kits.
}

run_client_window() {
	if [[ -n "${CLIENT_WINDOW_CMD:-}" ]]; then
		echo "[attach] CLIENT_WINDOW_CMD=${CLIENT_WINDOW_CMD}" >&2
		bash -lc "${CLIENT_WINDOW_CMD}"
		return $?
	fi
	default_client_window
}

# Start a chrome-trace style tracer in attach mode; writes Ctrl+T to stop.
# Usage: start_chrome_tracer_attach <bin> <extra-args...> -- <pid>
# Sets: ATTACH_TRACER_PID ATTACH_TRACER_MASTER ATTACH_TRACER_FIFO
start_chrome_tracer_attach() {
	local bin="$1"; shift
	local pid=""
	local args=()
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--" ]]; then
			shift
			pid="${1:-}"
			break
		fi
		args+=("$1")
		shift
	done
	: "${pid:?start_chrome_tracer_attach requires -- <pid>}"

	ATTACH_TRACER_FIFO="$(mktemp -u /tmp/io_tracer_fifo.XXXXXX)"
	mkfifo "${ATTACH_TRACER_FIFO}"

	mkdir -p "${OUT_DIR}/raw"
	local tracer_log="${OUT_DIR}/raw/attach_tracer.log"
	# Start reader FIRST — opening a FIFO for write blocks until a reader exists.
	# Capture tracer stdout/stderr so early-exit diagnosis is not a misleading "port file".
	(
		cd "${OUT_DIR}"
		"${bin}" "${args[@]}" --attach "${pid}" <"${ATTACH_TRACER_FIFO}" >"${tracer_log}" 2>&1
	) &
	ATTACH_TRACER_PID=$!
	# Keep FIFO open for Ctrl+T writes from this shell.
	exec {ATTACH_TRACER_MASTER}>"${ATTACH_TRACER_FIFO}"
	echo "[attach] tracer pid=${ATTACH_TRACER_PID} target=${pid} fifo=${ATTACH_TRACER_FIFO} log=${tracer_log}" >&2
	sleep "${ATTACH_READY_SECS:-3}"
	if ! kill -0 "${ATTACH_TRACER_PID}" 2>/dev/null; then
		echo "[attach] error: tracer process exited before client window" >&2
		if [[ -f "${tracer_log}" ]]; then
			echo "[attach] --- attach_tracer.log (tail) ---" >&2
			tail -n 80 "${tracer_log}" >&2 || true
			echo "[attach] --- end attach_tracer.log ---" >&2
		fi
		return 1
	fi
	return 0
}

stop_chrome_tracer_attach() {
	local wait_secs="${ATTACH_STOP_SECS:-8}"
	_attach_soft
	if [[ -n "${ATTACH_TRACER_MASTER:-}" ]]; then
		# Ctrl+T (0x14) ends a single attach session per vendor help.
		printf '\024' >&"${ATTACH_TRACER_MASTER}" 2>/dev/null || true
		sleep 2
		printf 'q\n' >&"${ATTACH_TRACER_MASTER}" 2>/dev/null || true
	fi
	if [[ -n "${ATTACH_TRACER_PID:-}" ]]; then
		local i
		for i in $(seq 1 "${wait_secs}"); do
			if ! kill -0 "${ATTACH_TRACER_PID}" 2>/dev/null; then
				break
			fi
			sleep 1
		done
		if kill -0 "${ATTACH_TRACER_PID}" 2>/dev/null; then
			echo "[attach] soft-stop timed out after ${wait_secs}s; sending INT" >&2
			kill -INT "${ATTACH_TRACER_PID}" 2>/dev/null || true
			for i in $(seq 1 30); do
				if ! kill -0 "${ATTACH_TRACER_PID}" 2>/dev/null; then
					break
				fi
				sleep 1
			done
			if kill -0 "${ATTACH_TRACER_PID}" 2>/dev/null; then
				echo "[attach] INT timed out; SIGKILL (JSON may need truncate-repair)" >&2
				kill -KILL "${ATTACH_TRACER_PID}" 2>/dev/null || true
			fi
		fi
		wait "${ATTACH_TRACER_PID}" 2>/dev/null || true
	fi
	if [[ -n "${ATTACH_TRACER_MASTER:-}" ]]; then
		exec {ATTACH_TRACER_MASTER}>&- 2>/dev/null || true
	fi
	rm -f "${ATTACH_TRACER_FIFO:-}" 2>/dev/null || true
	unset ATTACH_TRACER_PID ATTACH_TRACER_MASTER ATTACH_TRACER_FIFO
	# Stay soft — never re-enable pipefail here (tracer wait often returns 141/SIGPIPE).
	return 0
}

write_attach_provenance() {
	local out="$1"
	local vendor="$2"
	local pid="$3"
	local extra="${4:-}"
	python3 - "${out}" "${vendor}" "${pid}" "${extra}" <<'PY'
import json, sys
from pathlib import Path
out, vendor, pid, extra = sys.argv[1:5]
path = Path(out)
doc = {
  "mode": "attach_serve",
  "vendor_profiler": vendor,
  "attach_pid": int(pid) if str(pid).isdigit() else pid,
  "note": extra or None,
}
path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
print(f"[attach] wrote {path}", flush=True)
PY
}
