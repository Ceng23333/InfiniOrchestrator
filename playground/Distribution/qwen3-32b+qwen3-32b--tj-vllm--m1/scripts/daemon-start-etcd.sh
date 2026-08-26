#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${CASE_ID:-qwen3-32b+qwen3-32b--tj-vllm--m1}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
ETCD_BIN="${ETCD_BIN:-/usr/local/bin/etcd}"
ETCD_NAME="${ETCD_NAME:-tj-m1-etcd}"
ETCD_CLIENT_PORT="${ETCD_CLIENT_PORT:-2379}"
ETCD_PEER_PORT="${ETCD_PEER_PORT:-2380}"
ETCD_ADVERTISE_HOST="${ETCD_ADVERTISE_HOST:-177.177.61.18}"
PID_FILE="${RUN_ROOT}/pids/etcd.pid"
LOG_FILE="${RUN_ROOT}/logs/etcd.log"

mkdir -p "${RUN_ROOT}/pids" "${RUN_ROOT}/logs" "${RUN_ROOT}/etcd-data"
if [[ -s "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "etcd already running with PID $(cat "${PID_FILE}")"
  exit 0
fi
command -v "${ETCD_BIN}" >/dev/null 2>&1 || { echo "missing ETCD_BIN=${ETCD_BIN}" >&2; exit 1; }

nohup "${ETCD_BIN}" \
  --name "${ETCD_NAME}" \
  --data-dir "${RUN_ROOT}/etcd-data" \
  --listen-client-urls "http://0.0.0.0:${ETCD_CLIENT_PORT}" \
  --advertise-client-urls "http://${ETCD_ADVERTISE_HOST}:${ETCD_CLIENT_PORT}" \
  --listen-peer-urls "http://0.0.0.0:${ETCD_PEER_PORT}" \
  --initial-advertise-peer-urls "http://${ETCD_ADVERTISE_HOST}:${ETCD_PEER_PORT}" \
  --initial-cluster "${ETCD_NAME}=http://${ETCD_ADVERTISE_HOST}:${ETCD_PEER_PORT}" \
  --initial-cluster-state new \
  --initial-cluster-token "${CASE_ID}" \
  >"${LOG_FILE}" 2>&1 < /dev/null &
echo $! >"${PID_FILE}"
echo "started etcd pid=$(cat "${PID_FILE}") log=${LOG_FILE} case=${CASE_ID}"
