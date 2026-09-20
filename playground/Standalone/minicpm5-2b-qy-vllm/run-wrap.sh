#!/usr/bin/env bash
# Run MiniCPM5-2B stock vLLM on Denglin QY (dlrt). Shares unify .image_tag with -inf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
SUPPORT_ROOT="${SUPPORT_ROOT:-/home/qinyiqun/workspace/minicpm5-2b-support}"
MODEL_DIR="${MODEL_DIR:-${SUPPORT_ROOT}/model}"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
if [[ -z "${IMAGE_TAG}" && -f "${SUPPORT_ROOT}/image/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SUPPORT_ROOT}/image/.image_tag")"
fi
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "error: IMAGE_TAG unset and .image_tag missing" >&2
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-2b-qy-vllm}"
API_PORT="${API_PORT:-18000}"
DENGLIN_DEVICES="${DENGLIN_DEVICES:-0}"
RUNTIME="${RUNTIME:-dlrt}"
# Raise above 8192 so CoT (≤1024 gen) can keep MAX_INPUT≈noCoT without truncating evidence.
MAX_MODEL_LEN="${MAX_MODEL_LEN:-16384}"
# Host workspace for LongBench client docker-exec (keeps baked /workspace InfiniLM intact).
HOST_WS="${HOST_WS:-/home/qinyiqun/workspace}"
HOST_WS_CTN="${HOST_WS_CTN:-/host_ws}"
# model/ is a symlink into ModelScope cache; mount cache so host tokenizer paths resolve in-container.
MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-/home/qinyiqun/.cache/modelscope}"

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "error: missing model at ${MODEL_DIR}" >&2
  exit 1
fi
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "error: image not found: ${IMAGE_TAG}" >&2
  echo "  build via ${SUPPORT_ROOT}/image/build-unify-image.sh" >&2
  exit 1
fi

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG} (DENGLIN_DEVICES=${DENGLIN_DEVICES}, port=${API_PORT})..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --runtime "${RUNTIME}" \
  --hostname "${CONTAINER_NAME}" \
  --entrypoint /bin/bash \
  --workdir /workspace \
  -p "${API_PORT}:${API_PORT}" \
  -e "HOME=/home/qinyiqun" \
  -e "DENGLIN_DEVICES=${DENGLIN_DEVICES}" \
  -e "TZ=Asia/Shanghai" \
  -e "LC_ALL=C.UTF-8" \
  -e "LANG=C.UTF-8" \
  -e "PATH=/usr/local/dlgpu/sdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e "LD_LIBRARY_PATH=/usr/local/dlgpu/sdk/lib" \
  -v "${MODEL_DIR}:/model:ro" \
  -v "${HOST_WS}:${HOST_WS_CTN}:rw" \
  -v "${MODELSCOPE_CACHE}:${MODELSCOPE_CACHE}:ro" \
  "${IMAGE_TAG}" \
  -lc "source /usr/local/dlgpu/sdk/env.sh; export CUDA_HOME=/usr/local/dlgpu/sdk; exec python3 -m vllm.entrypoints.openai.api_server --model /model --served-model-name minicpm5-2b --chat-template /model/chat_template.jinja --host 0.0.0.0 --port ${API_PORT} --max-model-len ${MAX_MODEL_LEN} --max-num-seqs 1 --generation-config vllm"

URL="http://127.0.0.1:${API_PORT}"
echo "Waiting for ${URL}/v1/models ..."
for i in $(seq 1 180); do
  if docker exec "${CONTAINER_NAME}" bash -lc "curl -sf --connect-timeout 2 http://127.0.0.1:${API_PORT}/v1/models >/dev/null"; then
    echo "Ready: ${URL}/v1/models"
    docker exec "${CONTAINER_NAME}" bash -lc "curl -s http://127.0.0.1:${API_PORT}/v1/models" | head -c 2000
    echo ""
    echo "CONTAINER_NAME=${CONTAINER_NAME}"
    echo "BENCH_TARGET_URL=${URL}"
    echo "DEV_CONTAINER_NAME=${CONTAINER_NAME}"
    echo "CONTAINER_REPO=${HOST_WS_CTN}"
    echo "MONOREPO_WORK=${HOST_WS}"
    echo "CASE_ID=${CASE_ID}"
    echo "CASE_PATH=${SCRIPT_DIR}/case.toml"
    echo "IMAGE_TAG=${IMAGE_TAG}"
    exit 0
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "error: container exited" >&2
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -120 >&2
    exit 1
  fi
  sleep 5
done

echo "error: timeout waiting for ${URL}/v1/models" >&2
docker logs "${CONTAINER_NAME}" 2>&1 | tail -120 >&2
exit 1
