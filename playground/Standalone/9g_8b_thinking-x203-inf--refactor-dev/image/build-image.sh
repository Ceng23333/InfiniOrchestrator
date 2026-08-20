#!/usr/bin/env bash
# Package Standalone --refactor-dev IMAGE_TAG from pinned SOURCE_ROOT
# (default: itw-pins/v2026.08.19-refactor-dev-l8 via worktree_9g_isolate.sh).
# Mars InfiniLM/build prefix is excluded from the pin; for rebuilds override
# SOURCE_ROOT to live InfiniTensorWorktree-refactor-dev (GPU1) when needed.
#
# Copies Mars prefix + InfiniLM python (infinilm + infinicore) — NOT the product
# --refactor MetaX Phase-1 expect-fail path. Never overwrites deploy/main bases.
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${IMAGE_DIR}/.." && pwd)"
# shellcheck source=../../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"
# shellcheck source=../../../../scripts/worktree_9g_isolate.sh
source "${IO_ROOT}/scripts/worktree_9g_isolate.sh"
# shellcheck source=proxy-env.sh
source "${IMAGE_DIR}/proxy-env.sh"

CASE_ID="$(basename "${CASE_DIR}")"
SOURCE_ROOT="${SOURCE_ROOT:-$(worktree_9g_source_root_for refactor-dev)}"
export SOURCE_ROOT
export INFINI_TENSOR_WORKTREE="${SOURCE_ROOT}"
export WORKTREE_ROOT="${SOURCE_ROOT}"
worktree_9g_assert_not_mutating_product_refactor "${CASE_DIR}"
require_worktree_repos InfiniCore InfiniLM

ITW_TAG="v2026.08.19-refactor-dev"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-9g-standalone-refactor-dev}"
BUILD_TS="$(date -u +%Y%m%d)"
BASE_IMAGE_ID_PIN="1a3cbde5ff2a"
BASE_IMAGE="${BASE_IMAGE:-mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64}"
RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-refactor-dev-${BUILD_TS}}"
IMAGE_TAG="${IMAGE_TAG:-infini-orchestrator-metax:9g-refactor-dev-${BUILD_TS}}"
FROM_TAG="${FROM_TAG:-${BASE_IMAGE}}"
DEV_CTN="${DEV_CTN:-${WORKTREE_9G_GPU1_MARS_CTN}}"
PREFIX="${PREFIX:-${SOURCE_ROOT}/InfiniLM/build/integration/mars/prefix}"
RUST_DIR="${RUST_DIR:-${IO_ROOT}/rust}"
PACK_CTN="${PACK_CTN:-infinilm-pack-refactor-dev-$(date +%s)}"
PLATFORM="${PLATFORM:-hpcc}"

PROTECTED_TAGS=(
  "infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-20260813"
  "infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-main-20260819"
  "infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-main-20260818"
  "infini-orchestrator-metax:9g-main-20260819"
  "infini-orchestrator-metax:9g-main-20260818"
  "infini-orchestrator-metax:9g-refactor-20260818"
  "infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813"
)

refuse_protected() {
  local tag="$1"
  local p
  for p in "${PROTECTED_TAGS[@]}"; do
    if [[ "${tag}" == "${p}" ]]; then
      echo "error: refusing to overwrite protected tag ${tag}" >&2
      exit 1
    fi
  done
}
refuse_protected "${RUNTIME_BASE_TAG}"
refuse_protected "${IMAGE_TAG}"

if ! docker image inspect "${BASE_IMAGE_ID_PIN}" >/dev/null 2>&1; then
  echo "error: vendor BASE_IMAGE_ID ${BASE_IMAGE_ID_PIN} missing" >&2
  exit 1
fi

if [[ ! -x "${RUST_DIR}/target/release/infini-entrypoint" || ! -x "${RUST_DIR}/target/release/infini-loadbalancer" ]]; then
  echo "Building InfiniEntrypoint + InfiniLoadBalancer (host release)..."
  (cd "${RUST_DIR}" && cargo build --release --bin infini-entrypoint --bin infini-loadbalancer --bin infini-sharepool --bin infini-registry)
fi

echo "=========================================="
echo "Verify Mars stack (GPU1 ${DEV_CTN})"
echo "  SOURCE_ROOT=${SOURCE_ROOT}"
echo "=========================================="
"${IMAGE_DIR}/verify-mars-stack.sh"

IL_SHA="$(git -C "${SOURCE_ROOT}/InfiniLM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IC_SHA="$(git -C "${SOURCE_ROOT}/InfiniCore" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ITW_SHA="$(git -C "${SOURCE_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
_tag_now="$(git -C "${SOURCE_ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ -n "${_tag_now}" ]]; then
  ITW_TAG="${_tag_now}"
fi

stream_tree() {
  local src="$1" dest="$2"
  echo "  Streaming ${src} → ${dest}..."
  docker exec "${PACK_CTN}" mkdir -p "${dest}"
  tar -C "${src}" \
    --exclude='.git' \
    --exclude='.xmake' \
    --exclude='__pycache__' \
    --exclude='.pytest_cache' \
    --exclude='*.pyc' \
    --exclude='*.egg-info' \
    -cf - . | docker exec -i "${PACK_CTN}" tar -C "${dest}" -xf -
}

echo "=========================================="
echo "Package --refactor-dev"
echo "  FROM=${FROM_TAG} (${BASE_IMAGE_ID_PIN})"
echo "  RUNTIME_BASE_TAG=${RUNTIME_BASE_TAG}"
echo "  IMAGE_TAG=${IMAGE_TAG}"
echo "  SOURCE_ROOT=${SOURCE_ROOT}"
echo "=========================================="

docker rm -f "${PACK_CTN}" >/dev/null 2>&1 || true
docker run -d \
  --name "${PACK_CTN}" \
  --privileged \
  --network host \
  --device=/dev/dri:/dev/dri \
  --device=/dev/htcd:/dev/htcd \
  --workdir /app \
  --entrypoint /bin/bash \
  -e "HPCC_PATH=/opt/hpcc" \
  -e "HPCC_VISIBLE_DEVICES=1" \
  "${FROM_TAG}" \
  -c "sleep infinity"

cleanup_on_fail() {
  local ec=$?
  if [[ ${ec} -ne 0 ]]; then
    echo "packaging failed (exit ${ec}). Container kept: ${PACK_CTN}"
  fi
}
trap cleanup_on_fail EXIT

docker exec "${PACK_CTN}" mkdir -p /app /workspace /usr/local/bin /app/logs \
  /workspace/piecewise_inductor_cache \
  /workspace/InfiniLM/python \
  /workspace/InfiniLM/build/integration/mars/prefix \
  /workspace/InfiniCore

docker cp "${IMAGE_DIR}/docker_entrypoint.sh" "${PACK_CTN}:/app/docker_entrypoint.sh"
docker exec "${PACK_CTN}" chmod +x /app/docker_entrypoint.sh
docker cp "${IMAGE_DIR}/env-set.sh" "${PACK_CTN}:/app/env-set.sh"
docker cp "${IMAGE_DIR}/setup-mars-worktree.sh" "${PACK_CTN}:/app/setup-mars-worktree.sh"

for _bin in infini-entrypoint infini-loadbalancer infini-sharepool infini-registry; do
  if [[ -x "${RUST_DIR}/target/release/${_bin}" ]]; then
    docker cp "${RUST_DIR}/target/release/${_bin}" "${PACK_CTN}:/usr/local/bin/${_bin}"
  fi
done
docker exec "${PACK_CTN}" bash -lc '
  chmod +x /usr/local/bin/infini-* 2>/dev/null || true
  ln -sfn /usr/local/bin/infini-entrypoint /usr/local/bin/infini-babysitter
  ln -sfn /usr/local/bin/infini-loadbalancer /usr/local/bin/infini-router
'

# Dedicated runtime-base: vendor BASE + Mars env-set + InfiniEntrypoint (no InfiniLM yet).
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENV HPCC_PATH=/opt/hpcc' \
  --change "LABEL deployment.phase=runtime-base" \
  --change "LABEL deployment.case=${DEPLOYMENT_CASE}" \
  "${PACK_CTN}" \
  "${RUNTIME_BASE_TAG}"
echo "${RUNTIME_BASE_TAG}" > "${IMAGE_DIR}/.runtime_base_tag"
echo "Committed runtime-base ${RUNTIME_BASE_TAG}"

echo "Step: stream Mars prefix + InfiniLM/InfiniCore python..."
stream_tree "${SOURCE_ROOT}/InfiniLM/python" /workspace/InfiniLM/python
stream_tree "${PREFIX}" /workspace/InfiniLM/build/integration/mars/prefix
if [[ -f "${SOURCE_ROOT}/InfiniCore/README.md" ]]; then
  docker cp "${SOURCE_ROOT}/InfiniCore/README.md" "${PACK_CTN}:/workspace/InfiniCore/README.md"
fi

# janus: copy from GPU1 Mars container site-packages (already pip-installed there).
if docker ps --format '{{.Names}}' | grep -qx "${DEV_CTN}"; then
  echo "  Copying janus from ${DEV_CTN} site-packages..."
  docker exec "${DEV_CTN}" bash -lc '
    cd /opt/conda/lib/python3.10/site-packages
    tar -cf - janus janus-*.dist-info 2>/dev/null || tar -cf - janus
  ' | docker exec -i "${PACK_CTN}" tar -C /opt/conda/lib/python3.10/site-packages -xf -
else
  echo "  ${DEV_CTN} not running; pip-install janus in pack container"
  _proxy_args=()
  if should_use_proxy; then
    proxy_env_args _proxy_args
  fi
  docker exec "${_proxy_args[@]}" "${PACK_CTN}" python3 -m pip install janus
fi

docker exec \
  -e "HPCC_PATH=/opt/hpcc" \
  -e "INFINI_ROOT=/workspace/InfiniLM/build/integration/mars/prefix" \
  "${PACK_CTN}" bash /app/setup-mars-worktree.sh

# Import smoke (no GPU required). os._exit avoids HPCC destructor issues.
docker exec \
  -e "HPCC_PATH=/opt/hpcc" \
  -e "INFINI_ROOT=/workspace/InfiniLM/build/integration/mars/prefix" \
  -e "PYTHONPATH=/workspace/InfiniLM/python" \
  "${PACK_CTN}" bash -lc '
    set -e
    source /opt/conda/etc/profile.d/conda.sh && conda activate base
    source /app/env-set.sh
    unset MACA_PATH MACA_HOME MACA_ROOT || true
    python3 - <<PY
import infinicore, infinilm, janus
print("imports OK", infinicore.__file__, infinilm.__file__, flush=True)
import os
os._exit(0)
PY
  '

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
  --change "ENV HPCC_PATH=/opt/hpcc" \
  --change "ENV INFINI_ROOT=/workspace/InfiniLM/build/integration/mars/prefix" \
  "${PACK_CTN}" \
  "${IMAGE_TAG}"

trap - EXIT
docker rm -f "${PACK_CTN}" >/dev/null

echo "${IMAGE_TAG}" > "${IMAGE_DIR}/.image_tag"
echo "${ITW_TAG}" > "${IMAGE_DIR}/.worktree_tag"

BASE_DIGEST="$(docker image inspect "${BASE_IMAGE_ID_PIN}" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
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
BASE_IMAGE_ID=${BASE_IMAGE_ID_PIN}
BASE_DIGEST=${BASE_DIGEST}
RUNTIME_BASE_TAG=${RUNTIME_BASE_TAG}
IMAGE_TAG=${IMAGE_TAG}
SOURCE_ROOT=${SOURCE_ROOT}
SVC_ROOT=${IO_ROOT}
WORKTREE_ROOT=${SOURCE_ROOT}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INDUCTOR_CACHE=/workspace/piecewise_inductor_cache
HOST_INDUCTOR_CACHE=cache/piecewise_inductor
CASE_ID=${CASE_ID}
BE_ABBR=inf
CONTROL_PLANE=InfiniEntrypoint
NOTE=mars_device_hpcc_toolkit_no_maca_alias_no_metax_phase1
EOF

echo ""
echo "Built product image: ${IMAGE_TAG}"
echo "Runtime-base:        ${RUNTIME_BASE_TAG}"
echo "Wrote: ${IMAGE_DIR}/.image_tag ${IMAGE_DIR}/.runtime_base_tag ${IMAGE_DIR}/MANIFEST"
