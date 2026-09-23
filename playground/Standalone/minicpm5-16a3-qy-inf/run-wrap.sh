#!/usr/bin/env bash
# Run MiniCPM5.16a3 MoE InfiniLM on Denglin QY (dlrt). Live-mounts InfiniLM/InfiniCore.
# TP=1 only until Denglin NCCL allreduce is fixed. Weights ~28 GiB → short KV budget.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ID="$(basename "${SCRIPT_DIR}")"
SUPPORT_ROOT="${SUPPORT_ROOT:-/home/qinyiqun/workspace/minicpm5-2b-support}"
MODEL_DIR="${MODEL_DIR:-/home/qinyiqun/models/minicpm5.16a3.v0314}"
# Same bytelevel tokenizer vLLM LongBench used (overlay the weight-dir LlamaTokenizerFast files).
IO_ROOT="${IO_ROOT:-/home/qinyiqun/workspace/InfiniOrchestrator}"
TOKENIZER_BYTELEVEL="${TOKENIZER_BYTELEVEL:-${IO_ROOT}/playground/Standalone/minicpm5-x203-vllm/vllm_minicpm5/tokenizer_bytelevel}"

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

CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-16a3-qy-inf}"
API_PORT="${API_PORT:-18182}"
DENGLIN_DEVICES="${DENGLIN_DEVICES:-0}"
RUNTIME="${RUNTIME:-dlrt}"
# 28 GiB weights on ~32 GiB KS38 — keep cache short; graph off until decode is stable.
MAX_CACHE_LEN="${MAX_CACHE_LEN:-8192}"
MAX_NEW_TOKENS="${MAX_NEW_TOKENS:-1024}"
ENABLE_GRAPH="${ENABLE_GRAPH:-0}"
ENABLE_PAGED_ATTN="${ENABLE_PAGED_ATTN:-1}"
ATTN="${ATTN:-flash-attn}"
NUM_BLOCKS="${NUM_BLOCKS:-32}"
BLOCK_SIZE="${BLOCK_SIZE:-256}"
IGNORE_EOS="${IGNORE_EOS:-0}"
HOST_WS="${HOST_WS:-/home/qinyiqun/workspace}"
HOST_WS_CTN="${HOST_WS_CTN:-/host_ws}"
MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-/home/qinyiqun/.cache/modelscope}"
INFINI_LM_SRC="${INFINI_LM_SRC:-${SUPPORT_ROOT}/worktrees/InfiniTensorWorktree-v20260922-16a3/InfiniLM}"
INFINI_CORE_SRC="${INFINI_CORE_SRC:-${SUPPORT_ROOT}/worktrees/InfiniTensorWorktree-v20260922-16a3/InfiniCore}"
INFINI_CORE_INSTALL="${INFINI_CORE_INSTALL:-${SUPPORT_ROOT}/worktrees/InfiniCore-v20260920-install}"

GRAPH_ARGS=()
if [[ "${ENABLE_GRAPH}" == "1" || "${ENABLE_GRAPH}" == "true" || "${ENABLE_GRAPH}" == "yes" ]]; then
  GRAPH_ARGS+=(--enable-graph)
fi
PAGED_ARGS=()
if [[ "${ENABLE_PAGED_ATTN}" == "1" || "${ENABLE_PAGED_ATTN}" == "true" || "${ENABLE_PAGED_ATTN}" == "yes" ]]; then
  PAGED_ARGS+=(--enable-paged-attn --num-blocks="${NUM_BLOCKS}" --block-size="${BLOCK_SIZE}")
  if [[ "${ATTN}" == "default" ]]; then
    ATTN="paged-attn"
  fi
fi
if [[ "${ATTN}" != "default" ]]; then
  PAGED_ARGS+=(--attn="${ATTN}")
fi
IGNORE_EOS_ARGS=()
if [[ "${IGNORE_EOS}" == "1" || "${IGNORE_EOS}" == "true" || "${IGNORE_EOS}" == "yes" ]]; then
  IGNORE_EOS_ARGS+=(--ignore-eos)
fi

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "error: missing model at ${MODEL_DIR}" >&2
  exit 1
fi
if [[ ! -f "${TOKENIZER_BYTELEVEL}/tokenizer.json" || ! -f "${TOKENIZER_BYTELEVEL}/tokenizer_config.json" ]]; then
  echo "error: bytelevel tokenizer missing under ${TOKENIZER_BYTELEVEL}" >&2
  exit 1
fi
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "error: image not found: ${IMAGE_TAG}" >&2
  echo "  build via ${SUPPORT_ROOT}/image/build-unify-image.sh" >&2
  exit 1
fi
if [[ ! -d "${INFINI_LM_SRC}/python/infinilm" ]]; then
  echo "error: InfiniLM source missing: ${INFINI_LM_SRC}" >&2
  exit 1
fi
if [[ ! -f "${INFINI_LM_SRC}/python/infinilm/lib/_infinilm.cpython-312-x86_64-linux-gnu.so" ]]; then
  echo "error: rebuilt InfiniLM extension missing under ${INFINI_LM_SRC}/python/infinilm/lib" >&2
  exit 1
fi
if [[ ! -d "${INFINI_CORE_SRC}/python/infinicore" ]]; then
  echo "error: InfiniCore source missing: ${INFINI_CORE_SRC}" >&2
  exit 1
fi
if [[ ! -d "${INFINI_CORE_INSTALL}/lib" ]]; then
  echo "error: InfiniCore install libs missing: ${INFINI_CORE_INSTALL}/lib" >&2
  exit 1
fi

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG} (DENGLIN_DEVICES=${DENGLIN_DEVICES}, port=${API_PORT}, enable_graph=${ENABLE_GRAPH}, paged=${ENABLE_PAGED_ATTN}, attn=${ATTN}, ignore_eos=${IGNORE_EOS})..."
echo "Mounting live InfiniLM from ${INFINI_LM_SRC}"
echo "Mounting live InfiniCore from ${INFINI_CORE_SRC} (libs: ${INFINI_CORE_INSTALL})"
echo "Overlaying bytelevel tokenizer from ${TOKENIZER_BYTELEVEL}"
INF_CMD=(
  python3 /workspace/InfiniLM/python/infinilm/server/inference_server.py
  --device qy
  --model=/models/minicpm5-16a3
  --tp=1
  --host=0.0.0.0
  --port="${API_PORT}"
  --max-new-tokens="${MAX_NEW_TOKENS}"
  --max-batch-size=1
  --max-cache-len="${MAX_CACHE_LEN}"
  --temperature=0
  --top-p=1
  --top-k=1
)
if [[ ${#PAGED_ARGS[@]} -gt 0 ]]; then
  INF_CMD+=("${PAGED_ARGS[@]}")
fi
if [[ ${#GRAPH_ARGS[@]} -gt 0 ]]; then
  INF_CMD+=("${GRAPH_ARGS[@]}")
fi
if [[ ${#IGNORE_EOS_ARGS[@]} -gt 0 ]]; then
  INF_CMD+=("${IGNORE_EOS_ARGS[@]}")
fi

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
  -e "PYTHONPATH=/workspace/InfiniLM/python:/workspace/InfiniCore/python" \
  -e "LD_LIBRARY_PATH=/usr/local/dlgpu/sdk/lib:/opt/infinicore/lib:/usr/local/lib/python3.12/dist-packages/torch/lib" \
  -e "CUDA_LAUNCH_BLOCKING=${CUDA_LAUNCH_BLOCKING:-0}" \
  -v "${MODEL_DIR}:/models/minicpm5-16a3:ro" \
  -v "${TOKENIZER_BYTELEVEL}/tokenizer.json:/models/minicpm5-16a3/tokenizer.json:ro" \
  -v "${TOKENIZER_BYTELEVEL}/tokenizer_config.json:/models/minicpm5-16a3/tokenizer_config.json:ro" \
  -v "${HOST_WS}:${HOST_WS_CTN}:rw" \
  -v "${MODELSCOPE_CACHE}:${MODELSCOPE_CACHE}:ro" \
  -v "${INFINI_LM_SRC}:/workspace/InfiniLM:ro" \
  -v "${INFINI_CORE_SRC}:/workspace/InfiniCore:ro" \
  -v "${INFINI_CORE_INSTALL}/lib:/opt/infinicore/lib:ro" \
  "${IMAGE_TAG}" \
  -lc "source /usr/local/dlgpu/sdk/env.sh; export CUDA_HOME=/usr/local/dlgpu/sdk; exec $(printf '%q ' "${INF_CMD[@]}")"

URL="http://127.0.0.1:${API_PORT}"
echo "Waiting for ${URL}/health (MoE weight load can take several minutes)..."
for i in $(seq 1 360); do
  if docker exec "${CONTAINER_NAME}" bash -lc "curl -sf --connect-timeout 2 http://127.0.0.1:${API_PORT}/health >/dev/null || curl -sf --connect-timeout 2 http://127.0.0.1:${API_PORT}/v1/models >/dev/null"; then
    echo "Ready: ${URL}"
    docker exec "${CONTAINER_NAME}" bash -lc "curl -s http://127.0.0.1:${API_PORT}/v1/models" | head -c 2000 || true
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

echo "error: timeout waiting for ${URL}/health" >&2
docker logs "${CONTAINER_NAME}" 2>&1 | tail -120 >&2
exit 1
