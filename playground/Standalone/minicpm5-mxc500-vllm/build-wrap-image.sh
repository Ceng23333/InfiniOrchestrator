#!/usr/bin/env bash
# Build wrap image: stock vllm-mars + infini-entrypoint + vllm_minicpm5 plugin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUST_DIR="${IO_ROOT}/rust"

BASE_IMAGE="${BASE_IMAGE:-vllm-mars-babysitter:0.20.0-hpcc.ai3.7.0.102-9g}"
# Fall back to stock mars if entrypoint wrap not present
STOCK_BASE="${STOCK_BASE:-mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64}"
IMAGE_TAG="${IMAGE_TAG:-vllm-mars-entrypoint:0.20.0-hpcc.ai3.7.0.102-minicpm5}"
BUILD_CONTAINER="${BUILD_CONTAINER:-vllm-mars-entrypoint-minicpm5-build}"
VLLM_MINICPM5_HOST="${VLLM_MINICPM5_HOST:-${SCRIPT_DIR}/vllm_minicpm5}"

echo "=========================================="
echo "Build wrap image (vLLM + entrypoint + minicpm5 plugin)"
echo "=========================================="

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "Base ${BASE_IMAGE} missing; using stock ${STOCK_BASE}"
  BASE_IMAGE="${STOCK_BASE}"
fi
if [[ ! -d "${VLLM_MINICPM5_HOST}" ]]; then
  echo "error: VLLM_MINICPM5_HOST missing: ${VLLM_MINICPM5_HOST}" >&2
  exit 1
fi

ENTRYPOINT_BIN="${RUST_DIR}/target/release/infini-entrypoint"
if [[ ! -x "${ENTRYPOINT_BIN}" ]]; then
  echo "error: need ${ENTRYPOINT_BIN} (cargo build --release --bin infini-entrypoint)" >&2
  exit 1
fi

docker rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
docker run -d \
  --network host \
  --name "${BUILD_CONTAINER}" \
  --entrypoint /bin/bash \
  "${BASE_IMAGE}" \
  -c "sleep infinity"

cleanup_on_fail() {
  local ec=$?
  if [[ ${ec} -ne 0 ]]; then
    echo "Build failed (exit ${ec}). Container kept: docker exec -it ${BUILD_CONTAINER} bash" >&2
  fi
}
trap cleanup_on_fail EXIT

# Always install/refresh InfiniEntrypoint binary from host release build
echo "Installing infini-entrypoint into build container..."
test -x "${ENTRYPOINT_BIN}"
docker exec "${BUILD_CONTAINER}" mkdir -p /usr/local/bin
docker cp "${ENTRYPOINT_BIN}" "${BUILD_CONTAINER}:/usr/local/bin/infini-entrypoint"
docker exec "${BUILD_CONTAINER}" chmod +x /usr/local/bin/infini-entrypoint
# Compat symlink for older scripts
docker exec "${BUILD_CONTAINER}" bash -lc 'ln -sfn /usr/local/bin/infini-entrypoint /usr/local/bin/infini-babysitter'

echo "Copying vllm_minicpm5 → /opt/vllm_minicpm5 ..."
docker exec "${BUILD_CONTAINER}" rm -rf /opt/vllm_minicpm5
docker exec "${BUILD_CONTAINER}" mkdir -p /opt/vllm_minicpm5
tar -C "${VLLM_MINICPM5_HOST}" \
  --exclude='.git' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  -cf - . | docker exec -i "${BUILD_CONTAINER}" tar -C /opt/vllm_minicpm5 -xf -

echo "pip install -e /opt/vllm_minicpm5 ..."
docker exec "${BUILD_CONTAINER}" bash -lc '
  source /opt/conda/etc/profile.d/conda.sh && conda activate base
  # Prefer no build isolation if setuptools already present (offline-friendly).
  if ! pip install --no-build-isolation -e /opt/vllm_minicpm5; then
    pip install -e /opt/vllm_minicpm5
  fi
  python3 -c "import vllm_minicpm5; print(\"plugin\", vllm_minicpm5.__file__)"
  test -d /opt/vllm_minicpm5/tokenizer_bytelevel
  test -d /opt/vllm_minicpm5/moe_configs
  command -v infini-entrypoint
'

IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TS="$(date -u +%Y%m%d)"

docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD ["-lc","sleep infinity"]' \
  --change "LABEL deployment.wrap=vllm-entrypoint-minicpm5" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  --change 'ENV VLLM_TUNED_CONFIG_FOLDER=/opt/vllm_minicpm5/moe_configs' \
  "${BUILD_CONTAINER}" \
  "${IMAGE_TAG}"

trap - EXIT
docker rm -f "${BUILD_CONTAINER}" >/dev/null

echo "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"
echo ""
echo "Built: ${IMAGE_TAG}"
echo "Next: ${SCRIPT_DIR}/run-wrap.sh"
