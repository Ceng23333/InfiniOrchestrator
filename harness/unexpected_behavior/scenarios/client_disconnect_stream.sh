#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "[client_disconnect_stream] BASE_URL=${BASE_URL} MODEL=${MODEL}"
python3 "${SIM_CLIENT}" \
  --base-url "${BASE_URL}" \
  --model "${MODEL}" \
  --prompt "Tell me a long story." \
  --max-tokens 128 \
  disconnect-stream \
  --delay-ms "${DISCONNECT_DELAY_MS:-150}"

sleep "${POST_FAULT_WAIT_SEC}"

if ! worker_health_ok; then
  echo "[client_disconnect_stream] FAIL: worker /health not OK" >&2
  exit 1
fi
assert_no_fatal_step_loop
echo "[client_disconnect_stream] PASS"
