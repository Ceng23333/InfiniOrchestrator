#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "[happy_single] BASE_URL=${BASE_URL} MODEL=${MODEL}"
python3 "${SIM_CLIENT}" \
  --base-url "${BASE_URL}" \
  --model "${MODEL}" \
  --prompt "Hello" \
  --max-tokens 16 \
  happy

sleep "${POST_FAULT_WAIT_SEC}"

if ! worker_health_ok; then
  echo "[happy_single] FAIL: worker /health not OK" >&2
  exit 1
fi
assert_no_fatal_step_loop
echo "[happy_single] PASS"
