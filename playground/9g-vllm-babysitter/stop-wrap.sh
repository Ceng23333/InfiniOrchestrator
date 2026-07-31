#!/usr/bin/env bash
# Stop the wrap container.
set -euo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-9g-vllm-babysitter}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
echo "Stopped ${CONTAINER_NAME}"
