#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${CASE_ID:-qwen3-32b+qwen3-32b--tj-vllm--m1}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
if [[ "$#" -eq 0 ]]; then
  set -- etcd load-balancer worker-a worker-b
fi

stop_tree() {
  local pid="$1"
  local child
  while read -r child; do
    [[ -n "${child}" ]] && stop_tree "${child}"
  done < <(pgrep -P "${pid}" 2>/dev/null || true)
  kill "${pid}" 2>/dev/null || true
}

for name in "$@"; do
  pid_file="${RUN_ROOT}/pids/${name}.pid"
  if [[ -s "${pid_file}" ]]; then
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" 2>/dev/null; then
      process_group="$(ps -o pgid= -p "${pid}" | tr -d ' ')"
      own_group="$(ps -o pgid= -p "$$" | tr -d ' ')"
      if [[ "${process_group}" =~ ^[0-9]+$ && "${process_group}" != "1" && "${process_group}" != "${own_group}" ]]; then
        kill -TERM -- "-${process_group}" 2>/dev/null || true
      else
        stop_tree "${pid}"
      fi
      for _ in $(seq 1 20); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
      done
      if [[ "${process_group}" =~ ^[0-9]+$ && "${process_group}" != "1" && "${process_group}" != "${own_group}" ]]; then
        kill -KILL -- "-${process_group}" 2>/dev/null || true
      else
        kill -KILL "${pid}" 2>/dev/null || true
      fi
    fi
    rm -f "${pid_file}"
    echo "stopped ${name} pid=${pid} case=${CASE_ID}"
  fi
done
