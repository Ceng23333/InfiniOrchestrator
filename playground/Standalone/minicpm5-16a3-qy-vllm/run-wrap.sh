#!/usr/bin/env bash
# Run MiniCPM5.16a3 MoE stock vLLM on Denglin QY (dlrt).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"

MODEL_DIR="${MODEL_DIR:-/home/qinyiqun/models/minicpm5.16a3.v0314}"

IMAGE_TAG="${IMAGE_TAG:-}"
if [[ -z "${IMAGE_TAG}" && -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi
IMAGE_TAG="${IMAGE_TAG:-dl-vllm-minicpm5-16a3-qy:v2026.09.21}"

CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-16a3-qy-vllm}"
API_PORT="${API_PORT:-18181}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-1}"
# Default device list for TP (0..N-1 on this 4×KS38 host).
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
# 16a3 MoE weights ~28 GiB on 32 GiB KS38. gpu_memory_utilization 0.85 leaves
# negative KV headroom after CUDA-graph profiling; 0.95 leaves ~1.6 GiB KV at 8k.
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.95}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
# Set ENFORCE_EAGER=1 to skip CUDA graphs if KV is still tight.
ENFORCE_EAGER="${ENFORCE_EAGER:-0}"
# Host workspace for LongBench client docker-exec.
HOST_WS="${HOST_WS:-/home/qinyiqun/workspace}"
HOST_WS_CTN="${HOST_WS_CTN:-/host_ws}"

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "error: missing model at ${MODEL_DIR}" >&2
  echo "  extract: tar -xf ~/models/minicpm5.16a3.v0314.tar -C ~/models" >&2
  exit 1
fi
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "Image ${IMAGE_TAG} missing; building..."
  "${SCRIPT_DIR}/build-wrap-image.sh"
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
fi

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

EAGER_ARGS=()
if [[ "${ENFORCE_EAGER}" == "1" ]]; then
  EAGER_ARGS+=(--enforce-eager)
fi

# Multi-GPU NCCL needs more than docker's default 64MiB /dev/shm.
# Denglin NCCL also expects /dev/dl-shmem (chardev); host exposes /dev/denglin-shm.
SHM_SIZE="${SHM_SIZE:-64g}"
DOCKER_EXTRA=(--shm-size="${SHM_SIZE}")
NCCL_ENV_ARGS=()
if [[ "${TENSOR_PARALLEL_SIZE}" -gt 1 ]]; then
  # Avoid host IPC namespace; denglin-shm is the real cross-process path.
  NCCL_ENV_ARGS+=(-e "NCCL_SHM_DISABLE=${NCCL_SHM_DISABLE:-1}")
  NCCL_ENV_ARGS+=(-e "NCCL_IB_DISABLE=${NCCL_IB_DISABLE:-1}")
fi

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG} (TP=${TENSOR_PARALLEL_SIZE}, DENGLIN_DEVICES=${DENGLIN_DEVICES}, port=${API_PORT}, max_model_len=${MAX_MODEL_LEN}, gpu_mem=${GPU_MEM_UTIL}, eager=${ENFORCE_EAGER}, shm=${SHM_SIZE})..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  --runtime "${RUNTIME}" \
  --hostname "${CONTAINER_NAME}" \
  --entrypoint /bin/bash \
  --workdir /workspace \
  "${DOCKER_EXTRA[@]}" \
  -p "${API_PORT}:${API_PORT}" \
  -e "HOME=/home/qinyiqun" \
  -e "DENGLIN_DEVICES=${DENGLIN_DEVICES}" \
  -e "TZ=Asia/Shanghai" \
  -e "LC_ALL=C.UTF-8" \
  -e "LANG=C.UTF-8" \
  -e "PATH=/usr/local/dlgpu/sdk/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e "LD_LIBRARY_PATH=/usr/local/dlgpu/sdk/lib" \
  -e "VLLM_TUNED_CONFIG_FOLDER=/opt/vllm_minicpm5/moe_configs" \
  -e "NCCL_DEBUG=${NCCL_DEBUG:-WARN}" \
  "${NCCL_ENV_ARGS[@]}" \
  -v "${MODEL_DIR}:/model:ro" \
  -v "${HOST_WS}:${HOST_WS_CTN}:rw" \
  "${IMAGE_TAG}" \
  -lc "ln -sfn /dev/denglin-shm /dev/dl-shmem; source /usr/local/dlgpu/sdk/env.sh; export CUDA_HOME=/usr/local/dlgpu/sdk; exec python3 -m vllm.entrypoints.openai.api_server --model /model --tokenizer /opt/vllm_minicpm5/tokenizer_bytelevel --served-model-name minicpm5.16a3.v0314 --chat-template /model/chat_template.jinja --host 0.0.0.0 --port ${API_PORT} --dtype bfloat16 --trust-remote-code --tensor-parallel-size ${TENSOR_PARALLEL_SIZE} --max-model-len ${MAX_MODEL_LEN} --max-num-seqs ${MAX_NUM_SEQS} --gpu-memory-utilization ${GPU_MEM_UTIL} --generation-config vllm ${EAGER_ARGS[*]}"

URL="http://127.0.0.1:${API_PORT}"
echo "Waiting for ${URL}/v1/models (MoE load can take several minutes)..."
for i in $(seq 1 360); do
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
