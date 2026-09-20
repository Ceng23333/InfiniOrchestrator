#!/usr/bin/env bash
# Start single Standalone InfiniLM worker daemon on tj-io-node00.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="${CASE_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CASE_ID="${CASE_ID:-qwen3-32b-tj-inf--hygon}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
ENTRYPOINT_BIN="${ENTRYPOINT_BIN:-/private/zenghua/staging/InfiniOrchestrator/phase2-m1/bin/infini-entrypoint}"
WORKER_ID="${WORKER_ID:-worker}"
PID_FILE="${RUN_ROOT}/pids/${WORKER_ID}.pid"
LOG_FILE="${RUN_ROOT}/logs/${WORKER_ID}.log"
CONFIG_FILE="${CONFIG_FILE:-${CASE_DIR}/config/master-qwen3-32b.toml}"
INFINILM_ROOT="${INFINILM_ROOT:-/private/zenghua/staging/InfiniLM}"

mkdir -p "${RUN_ROOT}/pids" "${RUN_ROOT}/logs" "${RUN_ROOT}/piecewise_inductor_cache"
if [[ -s "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "${WORKER_ID} already running with PID $(cat "${PID_FILE}")"
  exit 0
fi
[[ -x "${ENTRYPOINT_BIN}" ]] || { echo "missing executable ENTRYPOINT_BIN=${ENTRYPOINT_BIN}" >&2; exit 1; }
[[ -f "${CONFIG_FILE}" ]] || { echo "missing CONFIG_FILE=${CONFIG_FILE}" >&2; exit 1; }
[[ -d "/private/zenghua/Qwen3-32B" ]] || { echo "missing model /private/zenghua/Qwen3-32B" >&2; exit 1; }

if [[ ! -d "${INFINILM_ROOT}" ]]; then
  echo "error: InfiniLM tree missing at INFINILM_ROOT=${INFINILM_ROOT}" >&2
  echo "  Discovery on tj-io-node00 found no InfiniLM install; install a host-native" >&2
  echo "  InfiniLM+InfiniCore tree (or enable Docker and adapt to product image) first." >&2
  echo "  See ${CASE_DIR}/README.md" >&2
  exit 1
fi

nohup "${ENTRYPOINT_BIN}" --config-file "${CONFIG_FILE}" \
  >"${LOG_FILE}" 2>&1 < /dev/null &
echo $! >"${PID_FILE}"
echo "started ${WORKER_ID} pid=$(cat "${PID_FILE}") log=${LOG_FILE} case=${CASE_ID}"
echo "BENCH_TARGET_URL=http://127.0.0.1:8200"
echo "CASE_PATH=${CASE_DIR}/case.toml"
