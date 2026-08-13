#!/usr/bin/env bash
# Build wrap image: official MindIE + infini-entrypoint. Avoid docker exec because
# docker exec can hang on this Ascend host/image; docker cp + commit is enough.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RUST_DIR="${IO_ROOT}/rust"
BASE_IMAGE="${BASE_IMAGE:-swr.cn-south-1.myhuaweicloud.com/ascendhub/mindie:2.3.0-800I-A2-py311-openeuler24.03-lts}"
IMAGE_TAG="${IMAGE_TAG:-mindie-9g-8b-entrypoint:2.3.0-910b4-20260812}"
BUILD_CONTAINER="${BUILD_CONTAINER:-mindie-9g-8b-entrypoint-build}"
ENTRYPOINT_BIN="${ENTRYPOINT_BIN:-}"
WRAP_ENTRYPOINT="${SCRIPT_DIR}/image/mindie-infini-entrypoint.sh"

echo "=========================================="
echo "Build wrap image (MindIE + InfiniEntrypoint)"
echo "=========================================="
echo "BASE_IMAGE:      ${BASE_IMAGE}"
echo "IMAGE_TAG:       ${IMAGE_TAG}"
echo "BUILD_CONTAINER: ${BUILD_CONTAINER}"
echo "SCRIPT_DIR:      ${SCRIPT_DIR}"
echo "IO_ROOT:         ${IO_ROOT}"
echo ""

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "error: missing base image ${BASE_IMAGE}" >&2
  exit 1
fi
if [[ -z "${ENTRYPOINT_BIN}" ]]; then
  if [[ -x "${RUST_DIR}/target/release/infini-entrypoint" ]]; then
    ENTRYPOINT_BIN="${RUST_DIR}/target/release/infini-entrypoint"
    echo "Using prebuilt: ${ENTRYPOINT_BIN}"
  else
    echo "Building infini-entrypoint (host aarch64)..."
    (cd "${RUST_DIR}" && cargo build --release --bin infini-entrypoint)
    ENTRYPOINT_BIN="${RUST_DIR}/target/release/infini-entrypoint"
  fi
fi
test -x "${ENTRYPOINT_BIN}"
test -x "${WRAP_ENTRYPOINT}"

docker rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true
docker network disconnect -f bridge "${BUILD_CONTAINER}" >/dev/null 2>&1 || true

cid="$(docker create --name "${BUILD_CONTAINER}" --entrypoint /bin/bash "${BASE_IMAGE}" -lc 'sleep infinity')"
echo "Created build container ${cid}"

cleanup_on_fail() {
  local ec=$?
  if [[ ${ec} -ne 0 ]]; then
    echo "Build failed (exit ${ec}). Container kept: docker start ${BUILD_CONTAINER}; docker logs ${BUILD_CONTAINER}" >&2
  fi
}
trap cleanup_on_fail EXIT

docker cp "${ENTRYPOINT_BIN}" "${BUILD_CONTAINER}:/usr/bin/infini-entrypoint"
docker cp "${WRAP_ENTRYPOINT}" "${BUILD_CONTAINER}:/usr/bin/mindie-infini-entrypoint.sh"

BUILD_TS="$(date -u +%Y%m%d)"
docker commit \
  --change 'WORKDIR /home/mindie-run' \
  --change 'ENTRYPOINT ["/usr/bin/mindie-infini-entrypoint.sh"]' \
  --change "LABEL deployment.wrap=mindie-entrypoint" \
  --change "LABEL deployment.case_id=9g_8b_thinking-910b4-mindie" \
  --change "LABEL deployment.base=${BASE_IMAGE}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  "${BUILD_CONTAINER}" \
  "${IMAGE_TAG}"

trap - EXIT
docker rm -f "${BUILD_CONTAINER}" >/dev/null 2>&1 || true

echo "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"
echo "Built: ${IMAGE_TAG}"
echo "Next: ${SCRIPT_DIR}/run-wrap.sh"
