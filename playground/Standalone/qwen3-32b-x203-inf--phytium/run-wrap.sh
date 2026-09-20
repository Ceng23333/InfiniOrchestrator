#!/usr/bin/env bash
# Standalone InfiniLM wrap: product IMAGE_TAG + infini-entrypoint for Qwen3-32B TP=4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/image/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/image/.image_tag")"
fi
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "error: IMAGE_TAG unset and ${SCRIPT_DIR}/image/.image_tag missing" >&2
  echo "  pin product image: echo 'infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813' > image/.image_tag" >&2
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-qwen-inf-phytium}"
MODELS_DIR="${MODELS_DIR:-/root/zenghua/models}"
API_PORT="${API_PORT:-8200}"
BABYSITTER_PORT="${BABYSITTER_PORT:-8201}"
CONFIG_IN_CONTAINER="/config/master-qwen3-32b.toml"
CACHE_HOST="${CACHE_HOST:-${SCRIPT_DIR}/cache/piecewise_inductor}"

if [[ ! -d "${MODELS_DIR}/Qwen3-32B" ]]; then
  echo "error: missing ${MODELS_DIR}/Qwen3-32B" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "error: image not found: ${IMAGE_TAG}" >&2
  exit 1
fi

mkdir -p "${CACHE_HOST}"

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
  -p "${API_PORT}:8200" \
  -p "${BABYSITTER_PORT}:8201" \
  -v "${MODELS_DIR}/Qwen3-32B:/models/Qwen3-32B:ro" \
  -v "${SCRIPT_DIR}/config:/config:ro" \
  -v "${CACHE_HOST}:/workspace/piecewise_inductor_cache:rw" \
  -e "LAUNCH_COMPONENTS=entrypoint" \
  -e "ENTRYPOINT_CONFIGS=${CONFIG_IN_CONTAINER}" \
  -e "BABYSITTER_CONFIGS=${CONFIG_IN_CONTAINER}" \
  "${IMAGE_TAG}"

echo "Waiting for http://127.0.0.1:${API_PORT}/v1/models ..."
URL="http://127.0.0.1:${API_PORT}"
# Cold CG / piecewise compile for Qwen TP=4 can take 30+ min.
for i in $(seq 1 720); do
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
