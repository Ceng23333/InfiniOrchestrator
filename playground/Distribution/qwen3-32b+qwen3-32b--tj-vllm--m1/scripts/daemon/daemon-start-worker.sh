#!/usr/bin/env bash
set -euo pipefail

WORKER_ID="${1:?usage: daemon-start-worker.sh worker-a|worker-b}"
case "${WORKER_ID}" in
  worker-a) CONFIG_NAME="worker-a.toml" ;;
  worker-b) CONFIG_NAME="worker-b.toml" ;;
  *) echo "unknown worker: ${WORKER_ID}" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="${CASE_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
CASE_ID="${CASE_ID:-qwen3-32b+qwen3-32b--tj-vllm--m1}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
ENTRYPOINT_BIN="${ENTRYPOINT_BIN:-/private/zenghua/staging/InfiniOrchestrator/bin/infini-entrypoint}"
PID_FILE="${RUN_ROOT}/pids/${WORKER_ID}.pid"
LOG_FILE="${RUN_ROOT}/logs/${WORKER_ID}.log"
CONFIG_FILE="${CONFIG_FILE:-${CASE_DIR}/config/${CONFIG_NAME}}"

mkdir -p "${RUN_ROOT}/pids" "${RUN_ROOT}/logs"
if [[ -s "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "${WORKER_ID} already running with PID $(cat "${PID_FILE}")"
  exit 0
fi
[[ -x "${ENTRYPOINT_BIN}" ]] || { echo "missing executable ENTRYPOINT_BIN=${ENTRYPOINT_BIN}" >&2; exit 1; }
[[ -f "${CONFIG_FILE}" ]] || { echo "missing CONFIG_FILE=${CONFIG_FILE}" >&2; exit 1; }

nohup "${ENTRYPOINT_BIN}" --config-file "${CONFIG_FILE}" \
  >"${LOG_FILE}" 2>&1 < /dev/null &
echo $! >"${PID_FILE}"
echo "started ${WORKER_ID} pid=$(cat "${PID_FILE}") log=${LOG_FILE} case=${CASE_ID}"
