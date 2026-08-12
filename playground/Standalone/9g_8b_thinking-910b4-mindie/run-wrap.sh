#!/usr/bin/env bash
# Run wrap container: infini-entrypoint -> MindIE for 9g_8b_thinking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${IO_ROOT}/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
IMAGE_TAG="${IMAGE_TAG:-mindie-9g-8b-entrypoint:2.3.0-910b4-20260812}"

CONTAINER_NAME="${CONTAINER_NAME:-mindie-9g-8b-entrypoint-visible23-preserveenv-20260812-ascend}"
MODEL_HOST="${MODEL_HOST:-/data-aisoft/zenghua/models/9g_8b_thinking_llama}"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config/mindie-config.json}"
RUN_DAEMON_HOST="${RUN_DAEMON_HOST:-${SCRIPT_DIR}/image/run-daemon.sh}"
ENTRYPOINT_CONFIG_IN_CONTAINER="/workspace/InfiniOrchestrator/playground/Standalone/9g_8b_thinking-910b4-mindie/config/master-9g_8b_thinking-mindie.toml"
API_URL="${API_URL:-http://192.168.162.27:1135}"
WAIT_READY="${WAIT_READY:-0}"

if [[ "${CONTAINER_NAME}" != mindie-9g-8b* ]]; then
  echo "Refusing to manage '${CONTAINER_NAME}': name must start with mindie-9g-8b" >&2
  exit 1
fi
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "Image ${IMAGE_TAG} missing; building..."
  "${SCRIPT_DIR}/build-wrap-image.sh"
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
test -d "${MODEL_HOST}"
test -f "${CONFIG_FILE}"
test -f "${RUN_DAEMON_HOST}"

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG}..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --privileged \
  --net=host \
  --shm-size=16g \
  --user root \
  -e RUN_USER="${RUN_USER:-0}" \
  -e RUN_GROUP="${RUN_GROUP:-0}" \
  -e MINDIE_LOG_TO_STDOUT=1 \
  -e ENTRYPOINT_CONFIGS="${ENTRYPOINT_CONFIG_IN_CONTAINER}" \
  -w /home/mindie-run \
  --device=/dev/davinci2:rwm \
  --device=/dev/davinci3:rwm \
  --device=/dev/davinci_manager:rwm \
  --device=/dev/hisi_hdc:rwm \
  --device=/dev/devmm_svm:rwm \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v /usr/local/sbin:/usr/local/sbin:ro \
  -v "${MODEL_HOST}:/models/9g_8b_thinking_llama:ro" \
  -v "${CONFIG_FILE}:/mnt/mindie-config/config.json:ro" \
  -v "${RUN_DAEMON_HOST}:/mnt/mindie-run-daemon/run-daemon.sh:ro" \
  -v "${WORKSPACE_ROOT}:/workspace:rw" \
  -v "${WORKSPACE_ROOT}:${WORKSPACE_ROOT}:rw" \
  "${IMAGE_TAG}"

echo "CONTAINER_NAME=${CONTAINER_NAME}"
echo "BENCH_TARGET_URL=${API_URL}"
echo "CASE_ID=9g_8b_thinking-910b4-mindie"
echo "CASE_PATH=${SCRIPT_DIR}/case.toml"

if [[ "${WAIT_READY}" == "1" ]]; then
  echo "Waiting for ${API_URL}/v1/models ..."
  for i in $(seq 1 120); do
    if curl -sf --connect-timeout 2 --noproxy "*" "${API_URL}/v1/models" >/dev/null 2>&1; then
      echo "Ready: ${API_URL}/v1/models"
      curl -s --noproxy "*" "${API_URL}/v1/models" | head -c 2000
      echo ""
      exit 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
      echo "error: container exited" >&2
      docker logs "${CONTAINER_NAME}" 2>&1 | tail -100 >&2
      exit 1
    fi
    sleep 5
  done
  echo "error: timeout waiting for ${API_URL}/v1/models" >&2
  docker logs "${CONTAINER_NAME}" 2>&1 | tail -100 >&2
  exit 1
fi
