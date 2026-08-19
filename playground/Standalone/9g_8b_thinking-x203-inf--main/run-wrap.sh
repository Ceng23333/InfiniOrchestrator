#!/usr/bin/env bash
# Standalone InfiniLM wrap: product IMAGE_TAG + infini-entrypoint for 9g_8b_thinking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
QUALIFIER="${CASE_ID##*--}"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/image/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/image/.image_tag")"
fi
CONFIG_IN_CONTAINER="${CONFIG_IN_CONTAINER:-/config/master-9g_8b_thinking.toml}"
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "error: IMAGE_TAG unset and ${SCRIPT_DIR}/image/.image_tag missing" >&2
  echo "  run ${SCRIPT_DIR}/image/build-image.sh first (not for --deploy)" >&2
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-9g-inf-${QUALIFIER}}"
MODELS_DIR="${MODELS_DIR:-/root/zenghua/models}"
API_PORT="${API_PORT:-8100}"
BABYSITTER_PORT="${BABYSITTER_PORT:-8101}"

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
  echo "error: image not found: ${IMAGE_TAG}" >&2
  exit 1
fi

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

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
  -p "${API_PORT}:8100" \
  -p "${BABYSITTER_PORT}:8101" \
  -v "${MODELS_DIR}/9g_8b_thinking:/models/9g_8b_thinking:ro" \
  -v "${SCRIPT_DIR}/config:/config:ro" \
  -e "LAUNCH_COMPONENTS=entrypoint" \
  -e "ENTRYPOINT_CONFIGS=${CONFIG_IN_CONTAINER}" \
  -e "BABYSITTER_CONFIGS=${CONFIG_IN_CONTAINER}" \
  "${IMAGE_TAG}"

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
