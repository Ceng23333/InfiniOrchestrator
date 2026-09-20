#!/usr/bin/env bash
set -euo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-2b-qy-vllm}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
echo "Stopped ${CONTAINER_NAME}"
