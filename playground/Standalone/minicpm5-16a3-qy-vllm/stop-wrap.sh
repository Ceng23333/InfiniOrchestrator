#!/usr/bin/env bash
set -euo pipefail
DOCKER="${DOCKER:-sudo docker}"
CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-16a3-qy-vllm}"
${DOCKER} rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
echo "Stopped ${CONTAINER_NAME}"
