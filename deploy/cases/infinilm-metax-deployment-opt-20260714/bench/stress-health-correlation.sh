#!/usr/bin/env bash
# Phase 2: run load (jg_rag bench, curl burst, or custom) while logging /health responses.
# Use this to correlate "completions stuck / ultra-slow" with HTTP 200 on inference and babysitter.
#
# Typical (worker reachable on localhost inside host/container):
#   HEALTH_ENDPOINTS="http://127.0.0.1:8100/health http://127.0.0.1:8101/health" \
#     ./stress-health-correlation.sh -- ./run-jg_rag-benchmark-remote.sh 192.168.163.151
#
# Router-only (LAN cannot see worker ports):
#   HEALTH_ENDPOINTS="http://192.168.163.151:8000/health" \
#     ./stress-health-correlation.sh -- ./run-jg_rag-benchmark-remote.sh 192.168.163.151
#
# Lightweight parallel chat (no vLLM bench deps):
#   ./stress-health-correlation.sh curl-burst --base-url http://127.0.0.1:8100 --model Qwen3-32B

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${CASE_DIR}/results"

INTERVAL_SEC="${HEALTH_POLL_INTERVAL_SEC:-2}"
LOG_FILE="${LOG_FILE:-}"
HEALTH_URLS=()

usage() {
  sed -n '1,80p' "$0" | sed -n '/^# /s/^# //p' | head -40
  echo ""
  echo "Usage:"
  echo "  $0 [--interval SEC] [--log FILE] [--health-endpoint URL]... -- <command> [args...]"
  echo "  $0 curl-burst --base-url URL --model MODEL [options]"
  echo ""
  echo "Env:"
  echo "  HEALTH_ENDPOINTS     Space-separated /health URLs (alternative to --health-endpoint)"
  echo "  HEALTH_POLL_INTERVAL_SEC  Poll period (default: 2)"
  echo "  LOG_FILE             Health log path (default: results/phase2-health-<UTC>.log)"
  echo ""
}

poll_loop() {
  local log="$1"
  while true; do
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    for url in "${HEALTH_URLS[@]}"; do
      # One line per endpoint: timestamp, URL, http_code or ERR, time_total
      local out code t
      out="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
        --connect-timeout 2 --max-time 5 --noproxy '*' "${url}" 2>&1)" || true
      if [[ "${out}" =~ ^[0-9]{3}\  ]]; then
        code="${out%% *}"
        t="${out#* }"
        printf '%s\t%s\t%s\t%s\n' "${ts}" "${url}" "${code}" "${t}" >> "${log}"
      else
        printf '%s\t%s\tERR\t%s\n' "${ts}" "${url}" "${out//$'\n'/ }" >> "${log}"
      fi
    done
    sleep "${INTERVAL_SEC}"
  done
}

# Sets global poller_pid. Do not call via $(...) — a subshell waits for background jobs on exit and would block.
start_poller() {
  local log="$1"
  mkdir -p "$(dirname "${log}")"
  {
    echo "# phase2 health correlation log"
    echo "# started $(date -u +"%Y-%m-%dT%H:%M:%SZ") interval=${INTERVAL_SEC}s"
    echo "# fields: iso_timestamp	url	http_code_or_ERR	time_total_seconds"
  } >> "${log}"
  poll_loop "${log}" &
  poller_pid=$!
}

run_curl_burst() {
  local base_url="" model="" parallel=8 requests=40 max_tokens=64 max_time=120
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-url) base_url="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --parallel) parallel="$2"; shift 2 ;;
      --requests) requests="$2"; shift 2 ;;
      --max-tokens) max_tokens="$2"; shift 2 ;;
      --max-time) max_time="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown curl-burst option: $1" >&2; exit 1 ;;
    esac
  done
  if [[ -z "${base_url}" || -z "${model}" ]]; then
    echo "curl-burst requires --base-url and --model" >&2
    exit 1
  fi
  local ep="${base_url%/}/v1/chat/completions"
  local payload
  payload="$(printf '{"model":"%s","messages":[{"role":"user","content":"phase2 stress ping"}],"max_tokens":%s}' "${model}" "${max_tokens}")"

  echo "curl-burst: ${requests} requests, parallelism ${parallel}, POST ${ep}"
  local i=0
  while [[ "${i}" -lt "${requests}" ]]; do
    i=$((i + 1))
    (
      curl -sS -X POST "${ep}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        --max-time "${max_time}" \
        --noproxy "*" \
        -o /dev/null -w "req=${i} http=%{http_code} time=%{time_total}s\n" || echo "req=${i} curl_err"
    ) &
    while [[ "$(jobs -rp | wc -l)" -ge "${parallel}" ]]; do
      wait -n 2>/dev/null || wait
    done
  done
  wait
  echo "curl-burst: done"
}

# --- main: curl-burst subcommand ---
if [[ "${1:-}" == "curl-burst" ]]; then
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval) INTERVAL_SEC="$2"; shift 2 ;;
      --log) LOG_FILE="$2"; shift 2 ;;
      --health-endpoint) HEALTH_URLS+=("$2"); shift 2 ;;
      *) break ;;
    esac
  done
  if [[ ${#HEALTH_URLS[@]} -eq 0 && -n "${HEALTH_ENDPOINTS:-}" ]]; then
    read -r -a HEALTH_URLS <<< "${HEALTH_ENDPOINTS}"
  fi
  if [[ ${#HEALTH_URLS[@]} -eq 0 ]]; then
    echo "Warning: no health endpoints (set HEALTH_ENDPOINTS or use --health-endpoint). Load will run without polling." >&2
  fi
  if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${RESULTS_DIR}/phase2-health-$(date -u +%Y%m%d-%H%M%SZ).log"
  fi
  poller_pid=""
  if [[ ${#HEALTH_URLS[@]} -gt 0 ]]; then
    start_poller "${LOG_FILE}"
    echo "Health log: ${LOG_FILE} (polling ${#HEALTH_URLS[@]} URL(s))"
  fi
  trap 'if [[ -n "${poller_pid:-}" ]]; then kill "${poller_pid}" 2>/dev/null || true; wait "${poller_pid}" 2>/dev/null || true; fi' EXIT
  run_curl_burst "$@"
  exit 0
fi

# --- main: -- command mode ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL_SEC="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --health-endpoint) HEALTH_URLS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *)
      if [[ "$1" == -* ]]; then
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
      fi
      break
      ;;
  esac
done

if [[ ${#HEALTH_URLS[@]} -eq 0 && -n "${HEALTH_ENDPOINTS:-}" ]]; then
  read -r -a HEALTH_URLS <<< "${HEALTH_ENDPOINTS}"
fi

if [[ $# -lt 1 ]]; then
  echo "Error: missing command after options (use -- before the stress command)" >&2
  usage >&2
  exit 1
fi

if [[ -z "${LOG_FILE}" ]]; then
  LOG_FILE="${RESULTS_DIR}/phase2-health-$(date -u +%Y%m%d-%H%M%SZ).log"
fi

poller_pid=""
if [[ ${#HEALTH_URLS[@]} -gt 0 ]]; then
  start_poller "${LOG_FILE}"
  echo "Health log: ${LOG_FILE} (polling ${#HEALTH_URLS[@]} URL(s))"
else
  echo "Warning: no health endpoints — set HEALTH_ENDPOINTS or pass --health-endpoint one or more times." >&2
  echo "         Stress will run without /health correlation logs." >&2
fi

trap 'if [[ -n "${poller_pid:-}" ]]; then kill "${poller_pid}" 2>/dev/null || true; wait "${poller_pid}" 2>/dev/null || true; fi' EXIT

set +e
"$@"
code=$?
set -e
exit "${code}"
