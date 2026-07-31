#!/usr/bin/env bash
# Build wrap image: stock vllm-mars + infini-babysitter (no InfiniLM/InfiniCore).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUST_DIR="${IO_ROOT}/rust"

BASE_IMAGE="${BASE_IMAGE:-mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64}"
IMAGE_TAG="${IMAGE_TAG:-vllm-mars-babysitter:0.20.0-hpcc.ai3.7.0.102-9g}"
BUILD_CONTAINER="${BUILD_CONTAINER:-vllm-mars-babysitter-build}"
BIN_SEED_IMAGE="${BIN_SEED_IMAGE:-}"

echo "=========================================="
echo "Build wrap image (stock vLLM + babysitter)"
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

BABYSITTER_BIN=""
if [[ -x "${RUST_DIR}/target/release/infini-babysitter" ]]; then
  BABYSITTER_BIN="${RUST_DIR}/target/release/infini-babysitter"
  echo "Using prebuilt: ${BABYSITTER_BIN}"
else
  echo "Building infini-babysitter (host aarch64)..."
  (cd "${RUST_DIR}" && cargo build --release --bin infini-babysitter)
  BABYSITTER_BIN="${RUST_DIR}/target/release/infini-babysitter"
fi
test -x "${BABYSITTER_BIN}"

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
docker cp "${BABYSITTER_BIN}" "${BUILD_CONTAINER}:/usr/local/bin/infini-babysitter"
docker exec "${BUILD_CONTAINER}" chmod +x /usr/local/bin/infini-babysitter

# Optional: seed registry/router too if BIN_SEED_IMAGE is set
if [[ -n "${BIN_SEED_IMAGE}" ]] && docker image inspect "${BIN_SEED_IMAGE}" >/dev/null 2>&1; then
  echo "Seeding optional infini-* from ${BIN_SEED_IMAGE}..."
  _seed="$(docker create "${BIN_SEED_IMAGE}")"
  _stage="$(mktemp -d)"
  for _bin in infini-registry infini-router; do
    docker cp "${_seed}:/usr/local/bin/${_bin}" "${_stage}/" 2>/dev/null || true
    if [[ -f "${_stage}/${_bin}" ]]; then
      docker cp "${_stage}/${_bin}" "${BUILD_CONTAINER}:/usr/local/bin/"
      docker exec "${BUILD_CONTAINER}" chmod +x "/usr/local/bin/${_bin}"
    fi
  done
  docker rm -f "${_seed}" >/dev/null
  rm -rf "${_stage}"
fi

docker exec "${BUILD_CONTAINER}" bash -lc 'command -v infini-babysitter && infini-babysitter --help >/dev/null'

IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TS="$(date -u +%Y%m%d)"

docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD ["-lc","sleep infinity"]' \
  --change "LABEL deployment.wrap=vllm-babysitter" \
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
