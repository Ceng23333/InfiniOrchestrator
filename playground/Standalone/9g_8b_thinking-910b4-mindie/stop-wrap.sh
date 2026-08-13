#!/usr/bin/env bash
set -euo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-mindie-9g-8b-entrypoint-visible23-preserveenv-20260812-ascend}"
if [[ "${CONTAINER_NAME}" != mindie-9g-8b* ]]; then
  echo "Refusing to manage '${CONTAINER_NAME}': name must start with mindie-9g-8b" >&2
  exit 1
fi
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
echo "Stopped ${CONTAINER_NAME}"
