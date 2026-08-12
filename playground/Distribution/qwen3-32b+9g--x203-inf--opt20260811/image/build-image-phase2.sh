#!/usr/bin/env bash
# Phase 2: runtime-base + SOURCE_ROOT → product entrypoint → IMAGE_TAG
# See docs/IMAGE_BUILD_PHASES.md
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${IMAGE_DIR}/.." && pwd)"
SCRIPT_DIR="${IMAGE_DIR}"
# shellcheck source=../../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"
require_worktree_repos InfiniCore InfiniLM

if [[ -f "${IMAGE_DIR}/.runtime_base_deps_tag" ]]; then
  FROM_TAG="${FROM_TAG:-$(cat "${IMAGE_DIR}/.runtime_base_deps_tag")}"
elif [[ -f "${IMAGE_DIR}/.runtime_base_tag" ]]; then
  FROM_TAG="${FROM_TAG:-$(cat "${IMAGE_DIR}/.runtime_base_tag")}"
fi
FROM_TAG="${FROM_TAG:?set FROM_TAG / RUNTIME_BASE_TAG or run Phase 1 first}"

SOURCE_ROOT="${SOURCE_ROOT:-${INFINI_TENSOR_WORKTREE:-${WORKTREE_ROOT}}}"
SVC_ROOT="${SVC_ROOT:-${IO_ROOT}}"
RUST_DIR="${RUST_DIR:-${IO_ROOT}/rust}"
BUILD_TS="$(date -u +%Y%m%d)"
IL_SHA="$(git -C "${SOURCE_ROOT}/InfiniLM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IC_SHA="$(git -C "${SOURCE_ROOT}/InfiniCore" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ITW_TAG="$(git -C "${SOURCE_ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ -z "${ITW_TAG}" ]]; then
  ITW_TAG="$(git -C "${SOURCE_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
ITW_SHA="$(git -C "${SOURCE_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "${ITW_TAG}" > "${IMAGE_DIR}/.worktree_tag"
IMAGE_TAG="${IMAGE_TAG:-infini-orchestrator-metax:${IL_SHA}-${IC_SHA}-${BUILD_TS}}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-build-ai370-p2-$(date +%s)}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260811}"
PLATFORM="${PLATFORM:-hpcc37}"

echo "=========================================="
echo "Phase 2 product image: ${DEPLOYMENT_CASE}"
echo "=========================================="
echo "FROM_TAG:      ${FROM_TAG}"
echo "SOURCE_ROOT:   ${SOURCE_ROOT}"
echo "WORKTREE_ROOT: ${WORKTREE_ROOT}"
echo "ITW_TAG:       ${ITW_TAG}"
echo "SVC_ROOT:      ${SVC_ROOT}"
echo "RUST_DIR:      ${RUST_DIR}"
echo "IMAGE_TAG:     ${IMAGE_TAG}"
echo "IL_SHA/IC_SHA: ${IL_SHA}/${IC_SHA}"
echo ""

for d in InfiniCore InfiniLM; do
  if [[ ! -d "${SOURCE_ROOT}/${d}" ]]; then
    echo "error: expected ${SOURCE_ROOT}/${d}" >&2
    exit 1
  fi
done
if ! docker image inspect "${FROM_TAG}" >/dev/null 2>&1; then
  echo "error: image not found: ${FROM_TAG}" >&2
  exit 1
fi

# Ensure host-built InfiniEntrypoint bins are present (refresh into image below).
if [[ ! -x "${RUST_DIR}/target/release/infini-entrypoint" || ! -x "${RUST_DIR}/target/release/infini-loadbalancer" ]]; then
  echo "Building InfiniEntrypoint + InfiniLoadBalancer (host release)..."
  (cd "${RUST_DIR}" && cargo build --release --bin infini-entrypoint --bin infini-loadbalancer --bin infini-sharepool --bin infini-registry)
fi
for _need in infini-entrypoint infini-loadbalancer; do
  if [[ ! -x "${RUST_DIR}/target/release/${_need}" ]]; then
    echo "error: missing ${RUST_DIR}/target/release/${_need}" >&2
    exit 1
  fi
done

stream_tree() {
  local src="$1" dest="$2"
  echo "  Streaming ${src} → ${dest} (excludes .git/build/.xmake)..."
  docker exec "${CONTAINER_NAME}" mkdir -p "${dest}"
  tar -C "${src}" \
    --exclude='.git' \
    --exclude='.xmake' \
    --exclude='build' \
    --exclude='__pycache__' \
    --exclude='.pytest_cache' \
    --exclude='*.pyc' \
    -cf - . | docker exec -i "${CONTAINER_NAME}" tar -C "${dest}" -xf -
}

echo "Step 1: Create Phase 2 build container from ${FROM_TAG}..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  --workdir /app \
  --entrypoint /bin/bash \
  "${FROM_TAG}" \
  -c "sleep infinity"

cleanup_on_fail() {
  local ec=$?
  if [[ ${ec} -ne 0 ]]; then
    echo ""
    echo "Phase 2 failed (exit ${ec}). Container kept for debugging:"
    echo "  docker exec -it ${CONTAINER_NAME} bash"
  fi
}
trap cleanup_on_fail EXIT

echo "Step 2: Stream InfiniTensorWorktree + refresh InfiniEntrypoint bins..."
docker exec "${CONTAINER_NAME}" mkdir -p /app /workspace /usr/local/bin /app/logs \
  /workspace/piecewise_inductor_cache

stream_tree "${SOURCE_ROOT}/InfiniCore" /workspace/InfiniCore
stream_tree "${SOURCE_ROOT}/InfiniLM" /workspace/InfiniLM

docker cp "${IMAGE_DIR}/docker_entrypoint.sh" "${CONTAINER_NAME}:/app/docker_entrypoint.sh"
docker exec "${CONTAINER_NAME}" chmod +x /app/docker_entrypoint.sh
docker cp "${IMAGE_DIR}/env-set.sh" "${CONTAINER_NAME}:/app/env-set.sh"
docker cp "${IMAGE_DIR}/setup-phase2-worktree.sh" "${CONTAINER_NAME}:/app/setup-phase2-worktree.sh"

for _bin in infini-entrypoint infini-loadbalancer infini-sharepool infini-registry; do
  if [[ -x "${RUST_DIR}/target/release/${_bin}" ]]; then
    docker cp "${RUST_DIR}/target/release/${_bin}" "${CONTAINER_NAME}:/usr/local/bin/${_bin}"
  fi
done
# etcd is provided by compose service (quay.io/coreos/etcd). Optional bake-in for offline hosts.
if [[ "${BAKE_ETCD:-0}" == "1" ]]; then
  if [[ -x "${ETCD_BIN:-/usr/local/bin/etcd}" ]]; then
    docker cp "${ETCD_BIN:-/usr/local/bin/etcd}" "${CONTAINER_NAME}:/usr/local/bin/etcd"
    if [[ -x "${ETCDCTL_BIN:-/usr/local/bin/etcdctl}" ]]; then
      docker cp "${ETCDCTL_BIN:-/usr/local/bin/etcdctl}" "${CONTAINER_NAME}:/usr/local/bin/etcdctl"
    fi
  elif command -v etcd >/dev/null 2>&1; then
    docker cp "$(command -v etcd)" "${CONTAINER_NAME}:/usr/local/bin/etcd"
    if command -v etcdctl >/dev/null 2>&1; then
      docker cp "$(command -v etcdctl)" "${CONTAINER_NAME}:/usr/local/bin/etcdctl"
    fi
  else
    echo "error: BAKE_ETCD=1 but etcd binary missing (set ETCD_BIN)" >&2
    exit 1
  fi
fi
docker exec "${CONTAINER_NAME}" bash -lc '
  chmod +x /usr/local/bin/infini-* /usr/local/bin/etcd /usr/local/bin/etcdctl 2>/dev/null || true
  ln -sfn /usr/local/bin/infini-entrypoint /usr/local/bin/infini-babysitter
  ln -sfn /usr/local/bin/infini-loadbalancer /usr/local/bin/infini-router
'

echo "Step 3: Run setup-phase2-worktree.sh..."
docker exec "${CONTAINER_NAME}" bash /app/setup-phase2-worktree.sh

echo "Step 4: Commit product image with ENTRYPOINT..."
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash","/app/docker_entrypoint.sh"]' \
  --change "LABEL org.opencontainers.image.revision=${IL_SHA}-${IC_SHA}" \
  --change "LABEL deployment.phase=2" \
  --change "LABEL deployment.case=${DEPLOYMENT_CASE}" \
  --change "LABEL deployment.platform=${PLATFORM}" \
  --change "ENV IMAGE_TAG=${IMAGE_TAG}" \
  --change "ENV IL_SHA=${IL_SHA}" \
  --change "ENV IC_SHA=${IC_SHA}" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  --change "ENV PLATFORM=${PLATFORM}" \
  "${CONTAINER_NAME}" \
  "${IMAGE_TAG}"

echo "Step 5: Cleanup build container..."
trap - EXIT
docker rm -f "${CONTAINER_NAME}" >/dev/null

echo "${IMAGE_TAG}" > "${IMAGE_DIR}/.image_tag"

# Preserve Phase 1 BASE_* fields when present.
BASE_IMAGE=""
BASE_IMAGE_ID=""
BASE_DIGEST=""
RUNTIME_BASE_TAG="${FROM_TAG}"
if [[ -f "${IMAGE_DIR}/MANIFEST" ]]; then
  # shellcheck disable=SC1090
  source <(grep -E '^(BASE_IMAGE|BASE_IMAGE_ID|BASE_DIGEST|RUNTIME_BASE_TAG)=' "${IMAGE_DIR}/MANIFEST" || true)
fi
RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-${FROM_TAG}}"

cat > "${IMAGE_DIR}/MANIFEST" <<EOF
PHASE=2
PLATFORM=${PLATFORM}
DEPLOYMENT_CASE=${DEPLOYMENT_CASE}
ITW_TAG=${ITW_TAG}
ITW_SHA=${ITW_SHA}
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
IO_SHA=${IO_SHA}
BUILD_TS=${BUILD_TS}
BASE_IMAGE=${BASE_IMAGE}
BASE_IMAGE_ID=${BASE_IMAGE_ID}
BASE_DIGEST=${BASE_DIGEST}
RUNTIME_BASE_TAG=${RUNTIME_BASE_TAG}
IMAGE_TAG=${IMAGE_TAG}
SOURCE_ROOT=${SOURCE_ROOT}
SVC_ROOT=${SVC_ROOT}
WORKTREE_ROOT=${WORKTREE_ROOT}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INDUCTOR_CACHE=/workspace/piecewise_inductor_cache
HOST_INDUCTOR_CACHE=cache/piecewise_inductor
IMAGE_BUILD_PHASES=docs/IMAGE_BUILD_PHASES.md
CASE_ID=qwen3-32b+9g--x203-inf--opt20260811
BE_ABBR=inf
CONTROL_PLANE=InfiniEntrypoint
NOTE=vendor_base_tag_vllm-mars_is_HPCC_OS_stack_not_runtime_backend
EOF

echo ""
echo "Built product image: ${IMAGE_TAG}"
echo "Wrote: ${IMAGE_DIR}/.image_tag"
echo "Wrote: ${IMAGE_DIR}/.worktree_tag (${ITW_TAG})"
echo "Wrote: ${IMAGE_DIR}/MANIFEST (PHASE=2)"
echo ""
echo "Next: cd ../docker-compose && cp .env.master.example .env"
echo "  IMAGE_TAG=\$(cat ../image/.image_tag) → docker-compose up"
