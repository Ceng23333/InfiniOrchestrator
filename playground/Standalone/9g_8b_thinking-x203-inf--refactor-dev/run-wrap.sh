#!/usr/bin/env bash
# Standalone InfiniLM wrap: Mars --refactor-dev IMAGE_TAG + infini-entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
QUALIFIER="${CASE_ID##*--}"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/image/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/image/.image_tag")"
fi
# Default furthest-green infer: Mars ablation step-1 (eager paged).
CONFIG_IN_CONTAINER="${CONFIG_IN_CONTAINER:-/config/ablation/master-step1.toml}"
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "error: IMAGE_TAG unset and ${SCRIPT_DIR}/image/.image_tag missing" >&2
  echo "  run ${SCRIPT_DIR}/image/build-image.sh first" >&2
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-9g-inf-${QUALIFIER}}"
MODELS_DIR="${MODELS_DIR:-/root/zenghua/models}"
API_PORT="${API_PORT:-8100}"
BABYSITTER_PORT="${BABYSITTER_PORT:-8101}"
HPCC_VISIBLE_DEVICES="${HPCC_VISIBLE_DEVICES:-0}"

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
# Exclusive GPU0 :8100/:8101 only when using default ports (qualify gates).
if [[ "${API_PORT}" == "8100" && "${BABYSITTER_PORT}" == "8101" ]]; then
  for other in main refactor deploy; do
    docker rm -f "9g-inf-${other}" >/dev/null 2>&1 || true
  done
  for _i in $(seq 1 30); do
    if ! ss -lptn 2>/dev/null | grep -Eq ':8100|:8101'; then
      break
    fi
    sleep 1
  done
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
  -p "${API_PORT}:8100" \
  -p "${BABYSITTER_PORT}:8101" \
  -v "${MODELS_DIR}/9g_8b_thinking:/models/9g_8b_thinking:ro" \
  -v "${SCRIPT_DIR}/config:/config:ro" \
  -e "LAUNCH_COMPONENTS=entrypoint" \
  -e "ENTRYPOINT_CONFIGS=${CONFIG_IN_CONTAINER}" \
  -e "BABYSITTER_CONFIGS=${CONFIG_IN_CONTAINER}" \
  -e "HPCC_PATH=/opt/hpcc" \
  -e "HPCC_VISIBLE_DEVICES=${HPCC_VISIBLE_DEVICES}" \
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
