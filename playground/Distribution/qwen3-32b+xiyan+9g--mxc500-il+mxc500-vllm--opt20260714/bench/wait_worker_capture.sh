#!/usr/bin/env bash
# Poll babysitter logs until C++ CG capture completes (or timeout).
set -euo pipefail

usage() {
  echo "Usage: $0 <container_name> [label] [timeout_sec]"
  echo "Example: $0 infiniorch-worker-master-qwen-paged-8200-20260714 Qwen 7200"
  exit 1
}

[[ $# -ge 1 ]] || usage

CONTAINER="$1"
LABEL="${2:-${CONTAINER}}"
TIMEOUT="${3:-7200}"

deadline=$((SECONDS + TIMEOUT))
while [[ "${SECONDS}" -lt "${deadline}" ]]; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "waiting ${LABEL} (container not running yet)..."
    sleep 30
    continue
  fi
  logs="$(docker exec "${CONTAINER}" bash -lc \
    'f=$(ls -t /app/logs/babysitter_*.log 2>/dev/null | head -1); tail -200 "$f" 2>/dev/null' \
    2>/dev/null || docker logs "${CONTAINER}" 2>&1 | tail -200)"
  if echo "${logs}" | grep -q "C++ capture complete"; then
    echo "READY ${LABEL}"
    exit 0
  fi
  echo "waiting ${LABEL}..."
  sleep 30
done

echo "TIMEOUT ${LABEL} after ${TIMEOUT}s" >&2
docker logs "${CONTAINER}" 2>&1 | tail -80 >&2 || true
exit 1
