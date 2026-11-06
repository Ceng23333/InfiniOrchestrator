#!/usr/bin/env bash
# Run MiniCPM5-2B stock vLLM on Denglin QY (dlrt). Supports TENSOR_PARALLEL_SIZE=1,2,4.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
DOCKER="${DOCKER:-sudo docker}"
MODEL_DIR="${MODEL_DIR:-/home/admin01/models/MiniCPM5-2B}"
DEFAULT_IMAGE_TAG="dl-vllm-v0.21.0-docker-image:MR-4.1.2-202606032315-ubuntu22.04-x86_64-20260603"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
IMAGE_TAG="${IMAGE_TAG:-${DEFAULT_IMAGE_TAG}}"

CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-2b-qy-vllm}"
API_PORT="${API_PORT:-18000}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-1}"
# Default device list for TP (0..N-1 on this 4×ZL340 host).
if [[ -z "${DENGLIN_DEVICES:-}" ]]; then
  case "${TENSOR_PARALLEL_SIZE}" in
    1) DENGLIN_DEVICES="0" ;;
    2) DENGLIN_DEVICES="0,1" ;;
    4) DENGLIN_DEVICES="0,1,2,3" ;;
    *)
      echo "error: set DENGLIN_DEVICES explicitly for TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE}" >&2
      exit 1
      ;;
  esac
fi
RUNTIME="${RUNTIME:-dlrt}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-16384}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.9}"
HOST_WS="${HOST_WS:-/home/admin01/workspace_c610/nov_milestone}"
HOST_WS_CTN="${HOST_WS_CTN:-/host_ws}"

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "error: missing model at ${MODEL_DIR}" >&2
  exit 1
fi
if ! ${DOCKER} image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "error: image not found: ${IMAGE_TAG}" >&2
  exit 1
fi

# Persist resolved tag for sibling scripts / stop-wrap callers.
printf '%s\n' "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
${DOCKER} rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

SHM_SIZE="${SHM_SIZE:-64g}"
DOCKER_EXTRA=(--shm-size="${SHM_SIZE}")
NCCL_ENV_ARGS=()
if [[ "${TENSOR_PARALLEL_SIZE}" -gt 1 ]]; then
  NCCL_ENV_ARGS+=(-e "NCCL_SHM_DISABLE=${NCCL_SHM_DISABLE:-1}")
  NCCL_ENV_ARGS+=(-e "NCCL_IB_DISABLE=${NCCL_IB_DISABLE:-1}")
fi

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG} (TP=${TENSOR_PARALLEL_SIZE}, DENGLIN_DEVICES=${DENGLIN_DEVICES}, port=${API_PORT}, max_model_len=${MAX_MODEL_LEN})..."
${DOCKER} run -d \
  --name "${CONTAINER_NAME}" \
  --runtime "${RUNTIME}" \
  --hostname "${CONTAINER_NAME}" \
  --entrypoint /bin/bash \
  --workdir /workspace \
  "${DOCKER_EXTRA[@]}" \
  -p "${API_PORT}:${API_PORT}" \
  -e "HOME=/home/admin01" \
  -e "DL_DEVICES=all" \
  -e "DENGLIN_DEVICES=${DENGLIN_DEVICES}" \
  -e "TZ=Asia/Shanghai" \
  -e "LC_ALL=C.UTF-8" \
  -e "LANG=C.UTF-8" \
  -e "PATH=/usr/local/dlgpu/sdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e "LD_LIBRARY_PATH=/usr/local/dlgpu/sdk/lib" \
  -e "NCCL_DEBUG=${NCCL_DEBUG:-WARN}" \
  "${NCCL_ENV_ARGS[@]}" \
  -v "${MODEL_DIR}:/model:ro" \
  -v "${HOST_WS}:${HOST_WS_CTN}:rw" \
  "${IMAGE_TAG}" \
  -lc "if [[ -e /dev/denglin-shm ]]; then ln -sfn /dev/denglin-shm /dev/dl-shmem; elif [[ -e /dev/dlgpu-shm && ! -e /dev/dl-shmem ]]; then ln -sfn /dev/dlgpu-shm /dev/dl-shmem; fi; source /usr/local/dlgpu/sdk/env.sh; export CUDA_HOME=/usr/local/dlgpu/sdk; exec python3 -m vllm.entrypoints.openai.api_server --model /model --served-model-name minicpm5-2b --chat-template /model/chat_template.jinja --host 0.0.0.0 --port ${API_PORT} --tensor-parallel-size ${TENSOR_PARALLEL_SIZE} --max-model-len ${MAX_MODEL_LEN} --max-num-seqs ${MAX_NUM_SEQS} --gpu-memory-utilization ${GPU_MEM_UTIL} --generation-config vllm"

URL="http://127.0.0.1:${API_PORT}"
echo "Waiting for ${URL}/v1/models ..."
for i in $(seq 1 180); do
  if ${DOCKER} exec "${CONTAINER_NAME}" bash -lc "curl -sf --connect-timeout 2 http://127.0.0.1:${API_PORT}/v1/models >/dev/null"; then
    echo "Ready: ${URL}/v1/models"
    ${DOCKER} exec "${CONTAINER_NAME}" bash -lc "curl -s http://127.0.0.1:${API_PORT}/v1/models" | head -c 2000
    echo ""
    echo "CONTAINER_NAME=${CONTAINER_NAME}"
    echo "BENCH_TARGET_URL=${URL}"
    echo "DEV_CONTAINER_NAME=${CONTAINER_NAME}"
    echo "CONTAINER_REPO=${HOST_WS_CTN}"
    echo "MONOREPO_WORK=${HOST_WS}"
    echo "CASE_ID=${CASE_ID}"
    echo "CASE_PATH=${SCRIPT_DIR}/case.toml"
    echo "IMAGE_TAG=${IMAGE_TAG}"
    echo "TENSOR_PARALLEL_SIZE=${TENSOR_PARALLEL_SIZE}"
    echo "DENGLIN_DEVICES=${DENGLIN_DEVICES}"
    exit 0
  fi
  if ! ${DOCKER} ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "error: container exited" >&2
    ${DOCKER} logs "${CONTAINER_NAME}" 2>&1 | tail -120 >&2
    exit 1
  fi
  sleep 5
done

echo "error: timeout waiting for ${URL}/v1/models" >&2
${DOCKER} logs "${CONTAINER_NAME}" 2>&1 | tail -120 >&2
exit 1
