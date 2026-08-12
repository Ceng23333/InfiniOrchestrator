#!/usr/bin/env bash
# Poll GET /metrics during an active bench step; summarize on stop (HTTP only).
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

_period_enabled() {
  [[ "${BENCH_METRICS_PERIOD:-1}" == "1" ]]
}

_period_base_url() {
  echo "${BENCH_METRICS_URL:-${INFERENCE_SERVER_BASE_URL:-${BASE_URL:-}}}"
}

start_period_scrape() {
  local out_dir="${1:?out_dir required}"
  if [[ "${BENCH_SKIP_SERVER_METRICS:-0}" == "1" ]]; then
    echo "[scrape_server_metrics_period] skip (BENCH_SKIP_SERVER_METRICS=1)"
    return 0
  fi
  if ! _period_enabled; then
    return 0
  fi

  local base_url
  base_url="$(_period_base_url)"
  if [[ -z "${base_url}" ]]; then
    echo "[scrape_server_metrics_period] BENCH_METRICS_URL or INFERENCE_SERVER_BASE_URL required" >&2
    exit 1
  fi

  local poll_sec="${BENCH_METRICS_PERIOD_SEC:-10}"
  local raw_flag=()
  if [[ "${BENCH_METRICS_PERIOD_RAW:-0}" == "1" ]]; then
    raw_flag=(--write-raw-jsonl)
  fi

  mkdir -p "${out_dir}"
  cd "${BENCH_WAREHOUSE_REPO}"
  python3 -m server_client period-poll \
    --base-url "${base_url}" \
    --out-dir "${out_dir}" \
    --poll-interval-sec "${poll_sec}" \
    "${raw_flag[@]}" &
  echo $! > "${out_dir}/.metrics_period.pid"
  echo "[scrape_server_metrics_period] started pid=$(cat "${out_dir}/.metrics_period.pid") interval=${poll_sec}s"
}

stop_period_scrape() {
  local out_dir="${1:?out_dir required}"
  if [[ "${BENCH_SKIP_SERVER_METRICS:-0}" == "1" ]]; then
    return 0
  fi
  if ! _period_enabled; then
    return 0
  fi

  local pid_file="${out_dir}/.metrics_period.pid"
  if [[ ! -f "${pid_file}" ]]; then
    return 0
  fi

  local pid
  pid="$(cat "${pid_file}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
  rm -f "${pid_file}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:?start|stop}"
  out_dir="${2:?out_dir required}"
  case "${cmd}" in
    start) start_period_scrape "${out_dir}" ;;
    stop) stop_period_scrape "${out_dir}" ;;
    *) echo "usage: $0 start|stop <out_dir>" >&2; exit 1 ;;
  esac
fi
