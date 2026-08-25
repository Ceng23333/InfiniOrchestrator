#!/usr/bin/env bash
# Build wrap image: stock vllm-metax amd64 + infini-entrypoint (MetaX C550 node2).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUST_DIR="${IO_ROOT}/rust"

BASE_IMAGE="${BASE_IMAGE:-cr.metax-tech.com/public-ai-release/maca/vllm-metax:0.17.0-maca.ai3.5.3.307-torch2.8-py312-ubuntu22.04-amd64}"
IMAGE_TAG="${IMAGE_TAG:-vllm-metax-entrypoint:0.17.0-c550-9g}"
BUILD_CONTAINER="${BUILD_CONTAINER:-vllm-metax-entrypoint-c550-build}"
BIN_SEED_IMAGE="${BIN_SEED_IMAGE:-}"

echo "=========================================="
echo "Build wrap image (vllm-metax C550 + entrypoint)"
echo "=========================================="
echo "BASE_IMAGE:      ${BASE_IMAGE}"
echo "IMAGE_TAG:       ${IMAGE_TAG}"
echo "BUILD_CONTAINER: ${BUILD_CONTAINER}"
echo "IO_ROOT:         ${IO_ROOT}"
echo ""

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "Pulling ${BASE_IMAGE}..."
  docker pull "${BASE_IMAGE}"
fi

ENTRYPOINT_BIN=""
if [[ -x "${RUST_DIR}/target/release/infini-entrypoint" ]]; then
  ENTRYPOINT_BIN="${RUST_DIR}/target/release/infini-entrypoint"
  echo "Using prebuilt: ${ENTRYPOINT_BIN}"
else
  echo "Building infini-entrypoint..."
  (cd "${RUST_DIR}" && cargo build --release --bin infini-entrypoint)
  ENTRYPOINT_BIN="${RUST_DIR}/target/release/infini-entrypoint"
fi
test -x "${ENTRYPOINT_BIN}"

docker rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
docker run -d \
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

docker exec "${BUILD_CONTAINER}" mkdir -p /usr/local/bin /app
docker cp "${ENTRYPOINT_BIN}" "${BUILD_CONTAINER}:/usr/local/bin/infini-entrypoint"
docker exec "${BUILD_CONTAINER}" chmod +x /usr/local/bin/infini-entrypoint

docker exec "${BUILD_CONTAINER}" bash -lc 'command -v infini-entrypoint && infini-entrypoint --help >/dev/null'

IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TS="$(date -u +%Y%m%d)"

docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD ["-lc","sleep infinity"]' \
  --change "LABEL deployment.wrap=vllm-entrypoint" \
  --change "LABEL deployment.base=${BASE_IMAGE}" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  "${BUILD_CONTAINER}" \
  "${IMAGE_TAG}"

trap - EXIT
docker rm -f "${BUILD_CONTAINER}" >/dev/null

echo "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"
echo ""
echo "Built: ${IMAGE_TAG}"
echo "Next: ${SCRIPT_DIR}/run-wrap.sh"
