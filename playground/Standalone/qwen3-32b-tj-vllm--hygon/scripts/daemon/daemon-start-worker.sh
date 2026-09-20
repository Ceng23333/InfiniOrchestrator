#!/usr/bin/env bash
# Start single Standalone vLLM worker daemon on tj-io-node00.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="${CASE_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CASE_ID="${CASE_ID:-qwen3-32b-tj-vllm--hygon}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
ENTRYPOINT_BIN="${ENTRYPOINT_BIN:-/private/zenghua/staging/InfiniOrchestrator/phase2-m1/bin/infini-entrypoint}"
WORKER_ID="${WORKER_ID:-worker}"
PID_FILE="${RUN_ROOT}/pids/${WORKER_ID}.pid"
LOG_FILE="${RUN_ROOT}/logs/${WORKER_ID}.log"
CONFIG_FILE="${CONFIG_FILE:-${CASE_DIR}/config/master-qwen3-32b-vllm.toml}"

mkdir -p "${RUN_ROOT}/pids" "${RUN_ROOT}/logs"
if [[ -s "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "${WORKER_ID} already running with PID $(cat "${PID_FILE}")"
  exit 0
fi
[[ -x "${ENTRYPOINT_BIN}" ]] || { echo "missing executable ENTRYPOINT_BIN=${ENTRYPOINT_BIN}" >&2; exit 1; }
[[ -f "${CONFIG_FILE}" ]] || { echo "missing CONFIG_FILE=${CONFIG_FILE}" >&2; exit 1; }
[[ -d "/private/zenghua/Qwen3-32B" ]] || { echo "missing model /private/zenghua/Qwen3-32B" >&2; exit 1; }

# Prefer the case-local overlay if present; else staging overlay from PYTHONPATH in TOML.
if [[ -d "${CASE_DIR}/runtime-overlay" ]]; then
  export PYTHONPATH="${CASE_DIR}/runtime-overlay${PYTHONPATH:+:${PYTHONPATH}}"
fi

nohup "${ENTRYPOINT_BIN}" --config-file "${CONFIG_FILE}" \
  >"${LOG_FILE}" 2>&1 < /dev/null &
echo $! >"${PID_FILE}"
echo "started ${WORKER_ID} pid=$(cat "${PID_FILE}") log=${LOG_FILE} case=${CASE_ID}"
echo "BENCH_TARGET_URL=http://127.0.0.1:18180"
echo "CASE_PATH=${CASE_DIR}/case.toml"
