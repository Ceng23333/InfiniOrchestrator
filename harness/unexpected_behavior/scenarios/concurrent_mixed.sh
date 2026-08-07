#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "[concurrent_mixed] BASE_URL=${BASE_URL} MODEL=${MODEL}"

pids=()
for _i in 1 2; do
  python3 "${SIM_CLIENT}" \
    --base-url "${BASE_URL}" \
    --model "${MODEL}" \
    --prompt "Concurrent stream cancel ${_i}" \
    --max-tokens 96 \
    cancel-stream \
    --delay-ms 250 &
  pids+=($!)
done

for _i in 1 2; do
  python3 "${SIM_CLIENT}" \
    --base-url "${BASE_URL}" \
    --model "${MODEL}" \
    --prompt "Concurrent happy ${_i}" \
    --max-tokens 8 \
    happy &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "${pid}" || true
done

sleep "${POST_FAULT_WAIT_SEC}"

if ! worker_health_ok; then
  echo "[concurrent_mixed] FAIL: worker /health not OK" >&2
  exit 1
fi
assert_no_fatal_step_loop
echo "[concurrent_mixed] PASS"
