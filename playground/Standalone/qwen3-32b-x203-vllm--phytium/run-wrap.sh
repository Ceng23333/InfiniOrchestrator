#!/usr/bin/env bash
# Run wrap container: infini-entrypoint → stock vLLM for Qwen3-32B TP=4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${IO_ROOT}/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
IMAGE_TAG="${IMAGE_TAG:-vllm-mars-entrypoint:0.20.0-hpcc.ai3.7.0.102-9g}"

CONTAINER_NAME="${CONTAINER_NAME:-qwen-vllm-phytium}"
MODELS_DIR="${MODELS_DIR:-/root/zenghua/models}"
API_PORT="${API_PORT:-18180}"
CONFIG_IN_CONTAINER="/workspace/InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-vllm--phytium/config/master-qwen3-32b-vllm.toml"

if [[ ! -d "${MODELS_DIR}/Qwen3-32B" ]]; then
  echo "error: missing ${MODELS_DIR}/Qwen3-32B" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "Image ${IMAGE_TAG} missing; building..."
  "${SCRIPT_DIR}/build-wrap-image.sh"
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

if [[ "${STOP_DEV_CONTAINER:-0}" == "1" ]]; then
  docker stop infinilm-dev-hpcc37 >/dev/null 2>&1 || true
fi

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG}..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --privileged \
  --ipc=shareable \
  --shm-size=100g \
  --security-opt=apparmor=unconfined \
  --security-opt=label=disable \
  --device=/dev/dri:/dev/dri \
  --device=/dev/htcd:/dev/htcd \
  -p "${API_PORT}:18180" \
  -v "${MODELS_DIR}:/models:ro" \
  -v "${MODELS_DIR}:${MODELS_DIR}:ro" \
  -v "${WORKSPACE_ROOT}:/workspace:rw" \
  -v "${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:rw" \
  -e "ENTRYPOINT_CONFIGS=${CONFIG_IN_CONTAINER}" \
  --entrypoint /bin/bash \
  "${IMAGE_TAG}" \
  -lc 'exec infini-entrypoint --config-file "${ENTRYPOINT_CONFIGS}"'

echo "Waiting for http://127.0.0.1:${API_PORT}/v1/models ..."
URL="http://127.0.0.1:${API_PORT}"
for i in $(seq 1 180); do
  if curl -sf --connect-timeout 2 --noproxy "*" "${URL}/v1/models" >/dev/null 2>&1; then
    echo "Ready: ${URL}/v1/models"
    curl -s --noproxy "*" "${URL}/v1/models" | head -c 2000
    echo ""
    echo "CONTAINER_NAME=${CONTAINER_NAME}"
    echo "BENCH_TARGET_URL=${URL}"
    echo "CASE_ID=${CASE_ID}"
    echo "CASE_PATH=${SCRIPT_DIR}/case.toml"
    echo "DEV_PORT=${API_PORT}"
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "error: container exited" >&2
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -80 >&2
    exit 1
  fi
  sleep 5
done

echo "error: timeout waiting for ${URL}/v1/models" >&2
docker logs "${CONTAINER_NAME}" 2>&1 | tail -100 >&2
exit 1
