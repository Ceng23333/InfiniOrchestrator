#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "[cancel_mid_decode] BASE_URL=${BASE_URL} MODEL=${MODEL}"
if ! worker_health_ok; then
  echo "[cancel_mid_decode] FAIL: worker not healthy before scenario" >&2
  exit 1
fi

python3 "${SIM_CLIENT}" \
  --base-url "${BASE_URL}" \
  --model "${MODEL}" \
  --prompt "Write a detailed essay about distributed systems." \
  --max-tokens 128 \
  cancel-stream \
  --delay-ms "${CANCEL_DELAY_MS:-300}"

sleep "${POST_FAULT_WAIT_SEC}"

if ! worker_health_ok; then
  echo "[cancel_mid_decode] FAIL: worker /health not OK after cancel" >&2
  exit 1
fi
assert_no_fatal_step_loop
echo "[cancel_mid_decode] PASS"
