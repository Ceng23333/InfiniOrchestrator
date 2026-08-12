#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

echo "[curl_timeout_burst] BASE_URL=${BASE_URL} MODEL=${MODEL}"
payload="$(chat_payload "Quick ping" false)"

for _i in $(seq 1 "${CURL_BURST_COUNT:-8}"); do
  curl -sS -o /dev/null \
    --connect-timeout 1 \
    --max-time "${CURL_MAX_TIME:-0.05}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${BASE_URL}/v1/chat/completions" \
    2>/dev/null || true &
done
wait

sleep "${POST_FAULT_WAIT_SEC}"

if ! worker_health_ok; then
  echo "[curl_timeout_burst] FAIL: worker /health not OK" >&2
  exit 1
fi
assert_no_fatal_step_loop
echo "[curl_timeout_burst] PASS"
