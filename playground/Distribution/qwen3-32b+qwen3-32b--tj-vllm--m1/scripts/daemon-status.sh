#!/usr/bin/env bash
set -euo pipefail

CASE_ID="${CASE_ID:-qwen3-32b+qwen3-32b--tj-vllm--m1}"
RUN_ROOT="${RUN_ROOT:-/private/zenghua/runs/${CASE_ID}}"
for name in etcd load-balancer worker-a worker-b; do
  pid_file="${RUN_ROOT}/pids/${name}.pid"
  if [[ -s "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    echo "${name} PASS pid=$(cat "${pid_file}") log=${RUN_ROOT}/logs/${name}.log case=${CASE_ID}"
  else
    echo "${name} STOPPED pid_file=${pid_file} case=${CASE_ID}"
  fi
done
