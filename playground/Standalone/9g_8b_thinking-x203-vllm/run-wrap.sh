#!/usr/bin/env bash
# Run wrap container: infini-entrypoint → stock vLLM for 9g_8b_thinking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${IO_ROOT}/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
IMAGE_TAG="${IMAGE_TAG:-vllm-mars-entrypoint:0.20.0-hpcc.ai3.7.0.102-9g}"

CONTAINER_NAME="${CONTAINER_NAME:-9g-vllm-x203}"
MODELS_DIR="${MODELS_DIR:-/root/zenghua/models}"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/master-9g_8b_thinking-vllm.toml}"
# In-container path (workspace bind-mount)
CONFIG_IN_CONTAINER="/workspace/InfiniOrchestrator/playground/Standalone/9g_8b_thinking-x203-vllm/config/master-9g_8b_thinking-vllm.toml"

# Ensure allowlist slug path exists for --served-model-name
if [[ ! -e "${MODELS_DIR}/9g_8b_thinking" ]]; then
  if [[ -d "${MODELS_DIR}/9g_8b_thinking_llama" ]]; then
    ln -sfn 9g_8b_thinking_llama "${MODELS_DIR}/9g_8b_thinking"
    echo "Created symlink ${MODELS_DIR}/9g_8b_thinking -> 9g_8b_thinking_llama"
  else
    echo "error: missing ${MODELS_DIR}/9g_8b_thinking (or 9g_8b_thinking_llama)" >&2
    exit 1
  fi
fi

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "Image ${IMAGE_TAG} missing; building..."
  "${SCRIPT_DIR}/build-wrap-image.sh"
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

# Avoid GPU contention with stock devcontainer if it holds devices; leave it running
# unless STOP_DEV_CONTAINER=1.
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
  -v "${MODELS_DIR}:/models:ro" \
  -v "${MODELS_DIR}:${MODELS_DIR}:ro" \
  -v "${WORKSPACE_ROOT}:/workspace:rw" \
  -v "${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:rw" \
  -e "ENTRYPOINT_CONFIGS=${CONFIG_IN_CONTAINER}" \
  --entrypoint /bin/bash \
  "${IMAGE_TAG}" \
  -lc 'exec infini-entrypoint --config-file "${ENTRYPOINT_CONFIGS}"'

echo "Waiting for /v1/models ..."
IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_NAME}")"
URL="http://${IP}:18180"
for i in $(seq 1 120); do
  if curl -sf --connect-timeout 2 --noproxy "*" "${URL}/v1/models" >/dev/null 2>&1; then
    echo "Ready: ${URL}/v1/models"
    curl -s --noproxy "*" "${URL}/v1/models" | head -c 2000
    echo ""
    echo "CONTAINER_NAME=${CONTAINER_NAME}"
    echo "BENCH_TARGET_URL=${URL}"
    echo "DEV_CONTAINER_NAME=${CONTAINER_NAME}"
    echo "DEV_PORT=18180"
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
