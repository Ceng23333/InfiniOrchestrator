#!/usr/bin/env bash
# Run MiniCPM5-2B InfiniLM on Denglin QY (dlrt). Shares unify .image_tag with -vllm.
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

CONTAINER_NAME="${CONTAINER_NAME:-minicpm5-2b-qy-inf}"
API_PORT="${API_PORT:-18001}"
DENGLIN_DEVICES="${DENGLIN_DEVICES:-0}"
RUNTIME="${RUNTIME:-dlrt}"
# Match vLLM CoT context budget; default max-new-tokens must cover CoT phase (1024).
MAX_CACHE_LEN="${MAX_CACHE_LEN:-16384}"
MAX_NEW_TOKENS="${MAX_NEW_TOKENS:-2048}"
# CUDA graph: default off — MiniCPM5-2B+QY produced <|fim_prefix|> loops with --enable-graph.
ENABLE_GRAPH="${ENABLE_GRAPH:-0}"
HOST_WS="${HOST_WS:-/home/qinyiqun/workspace}"
HOST_WS_CTN="${HOST_WS_CTN:-/host_ws}"
MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-/home/qinyiqun/.cache/modelscope}"
# Live InfiniLM tree so QY chat_template_kwargs fix applies without image rebuild.
INFINI_LM_SRC="${INFINI_LM_SRC:-${SUPPORT_ROOT}/worktrees/InfiniTensorWorktree-v029/InfiniLM}"

GRAPH_ARGS=()
if [[ "${ENABLE_GRAPH}" == "1" || "${ENABLE_GRAPH}" == "true" || "${ENABLE_GRAPH}" == "yes" ]]; then
  GRAPH_ARGS+=(--enable-graph)
fi

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "error: missing model at ${MODEL_DIR}" >&2
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

echo "Stopping existing ${CONTAINER_NAME} (if any)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

echo "Starting ${CONTAINER_NAME} from ${IMAGE_TAG} (DENGLIN_DEVICES=${DENGLIN_DEVICES}, port=${API_PORT}, enable_graph=${ENABLE_GRAPH})..."
echo "Mounting live InfiniLM from ${INFINI_LM_SRC}"
# Build argv inside the container shell so --enable-graph is optional.
INF_CMD=(
  python3 /workspace/InfiniLM/python/infinilm/server/inference_server.py
  --device qy
  --model=/models/minicpm5-2b
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
if [[ ${#GRAPH_ARGS[@]} -gt 0 ]]; then
  INF_CMD+=("${GRAPH_ARGS[@]}")
fi
# shellcheck disable=SC2086
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
  -v "${MODEL_DIR}:/models/minicpm5-2b:ro" \
  -v "${HOST_WS}:${HOST_WS_CTN}:rw" \
  -v "${MODELSCOPE_CACHE}:${MODELSCOPE_CACHE}:ro" \
  -v "${INFINI_LM_SRC}:/workspace/InfiniLM:ro" \
  "${IMAGE_TAG}" \
  -lc "source /usr/local/dlgpu/sdk/env.sh; export CUDA_HOME=/usr/local/dlgpu/sdk; exec $(printf '%q ' "${INF_CMD[@]}")"

URL="http://127.0.0.1:${API_PORT}"
echo "Waiting for ${URL}/health ..."
for i in $(seq 1 180); do
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
