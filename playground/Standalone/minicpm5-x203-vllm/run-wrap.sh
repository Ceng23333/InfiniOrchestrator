#!/usr/bin/env bash
# Run wrap container: infini-entrypoint → stock vLLM + minicpm5 plugin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${IO_ROOT}/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
IMAGE_TAG="${IMAGE_TAG:-vllm-mars-entrypoint:0.20.0-hpcc.ai3.7.0.102-minicpm5}"

CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-x203-vllm}"
MODELS_DIR="${MODELS_DIR:-/root/zenghua/models}"
CONFIG_IN_CONTAINER="/workspace/InfiniOrchestrator/playground/Standalone/minicpm5-x203-vllm/config/master-minicpm5-vllm.toml"

if [[ ! -e "${MODELS_DIR}/minicpm5" ]]; then
  if [[ -d "${MODELS_DIR}/minicpm5.16a3.v0314" ]]; then
    ln -sfn minicpm5.16a3.v0314 "${MODELS_DIR}/minicpm5"
    echo "Created symlink ${MODELS_DIR}/minicpm5 -> minicpm5.16a3.v0314"
  else
    echo "error: missing ${MODELS_DIR}/minicpm5 (or minicpm5.16a3.v0314)" >&2
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

# Free GPU/port from sibling wrap containers
docker rm -f 9g-vllm-entrypoint >/dev/null 2>&1 || true
if [[ "${STOP_DEV_CONTAINER:-0}" == "1" ]]; then
  docker stop infinilm-dev-hpcc37 >/dev/null 2>&1 || true
fi

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG}..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
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
  -e "VLLM_TUNED_CONFIG_FOLDER=/opt/vllm_minicpm5/moe_configs" \
  --entrypoint /bin/bash \
  "${IMAGE_TAG}" \
  -lc 'exec infini-entrypoint --config-file "${ENTRYPOINT_CONFIGS}"'

echo "Waiting for /v1/models ..."
URL="http://127.0.0.1:18180"
# MoE load can take a while
for i in $(seq 1 180); do
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
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -100 >&2
    exit 1
  fi
  sleep 5
done

echo "error: timeout waiting for ${URL}/v1/models" >&2
docker logs "${CONTAINER_NAME}" 2>&1 | tail -120 >&2
exit 1
