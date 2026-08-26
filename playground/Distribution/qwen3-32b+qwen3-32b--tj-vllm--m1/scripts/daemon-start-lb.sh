#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${CASE_ID:-qwen3-32b+qwen3-32b--tj-vllm--m1}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
LB_BIN="${LB_BIN:-/private/zenghua/staging/InfiniOrchestrator/bin/infini-loadbalancer}"
ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://177.177.61.18:2379}"
DISCOVERY_PREFIX="${DISCOVERY_PREFIX:-/infini/orchestrator/qwen3-32b-tj-vllm-m1}"
LB_PORT="${LB_PORT:-8800}"
PID_FILE="${RUN_ROOT}/pids/load-balancer.pid"
LOG_FILE="${RUN_ROOT}/logs/load-balancer.log"

mkdir -p "${RUN_ROOT}/pids" "${RUN_ROOT}/logs"
if [[ -s "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "load balancer already running with PID $(cat "${PID_FILE}")"
  exit 0
fi
[[ -x "${LB_BIN}" ]] || { echo "missing executable LB_BIN=${LB_BIN}" >&2; exit 1; }

nohup env ETCD_ENDPOINTS="${ETCD_ENDPOINTS}" DISCOVERY_PREFIX="${DISCOVERY_PREFIX}" \
  "${LB_BIN}" --load-balancer-port "${LB_PORT}" \
  --etcd-endpoints "${ETCD_ENDPOINTS}" --discovery-prefix "${DISCOVERY_PREFIX}" \
  >"${LOG_FILE}" 2>&1 < /dev/null &
echo $! >"${PID_FILE}"
echo "started load-balancer pid=$(cat "${PID_FILE}") log=${LOG_FILE} case=${CASE_ID}"
