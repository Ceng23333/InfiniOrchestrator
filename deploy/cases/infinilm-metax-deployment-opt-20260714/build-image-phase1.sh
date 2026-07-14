#!/usr/bin/env bash
# Phase 1: vendor BASE_IMAGE → setup-phase1-deps.sh → docker commit RUNTIME_BASE_TAG
# See docs/IMAGE_BUILD_PHASES.md
#
# Example:
#   BASE_IMAGE=mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64 \
#     ./build-image-phase1.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

BASE_IMAGE="${BASE_IMAGE:-mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260714}"
BUILD_TS="$(date -u +%Y%m%d)"
RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-infinilm-svc:metax-hpcc-ai370-runtime-base-${BUILD_TS}}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-build-ai370-p1-$(date +%s)}"
PLATFORM="${PLATFORM:-hpcc37}"

# Optional seed trees (accelerate; committed image must not depend on mounts).
SOURCE_ROOT="${SOURCE_ROOT:-}"
if [[ -z "${SOURCE_ROOT}" ]]; then
  _wt="${MONOREPO_ROOT}/bench_results/hpcc_migration_20260703_161241/worktree-hpcc37"
  if [[ -d "${_wt}/InfiniCore" && -d "${_wt}/InfiniLM" ]]; then
    SOURCE_ROOT="${_wt}"
  else
    SOURCE_ROOT="${MONOREPO_ROOT}"
  fi
fi
DEV_CONTAINER="${DEV_CONTAINER:-infinilm-dev-hpcc37}"
BIN_SEED_IMAGE="${BIN_SEED_IMAGE:-infinilm-svc:metax-hpcc-ai3107-c73618c-56ef9cad-20260624}"

# shellcheck source=proxy-env.sh
source "${SCRIPT_DIR}/proxy-env.sh"

run_setup() {
  local -a _proxy_args=()
  if should_use_proxy; then
    proxy_env_args _proxy_args
    echo "Running Phase 1 setup with proxy ${DEFAULT_PROXY}..."
  else
    echo "Running Phase 1 setup without proxy..."
  fi
  docker exec \
    "${_proxy_args[@]}" \
    -e "DEPLOYMENT_CASE=${DEPLOYMENT_CASE}" \
    -e "FORCE_XMAKE_BUILD=${FORCE_XMAKE_BUILD:-false}" \
    -e "SKIP_RUST=${SKIP_RUST:-false}" \
    -e "SKIP_INFINICORE_INFINILM=${SKIP_INFINICORE_INFINILM:-false}" \
    -e "SEED_INDUCTOR_SRC=${SEED_INDUCTOR_SRC:-}" \
    -e "USE_PROXY=${USE_PROXY:-}" \
    "${CONTAINER_NAME}" bash /app/setup-phase1-deps.sh
}

echo "=========================================="
echo "Phase 1 runtime-base: ${DEPLOYMENT_CASE}"
echo "=========================================="
echo "Monorepo:         ${MONOREPO_ROOT}"
echo "SOURCE_ROOT:      ${SOURCE_ROOT}"
echo "BASE_IMAGE:       ${BASE_IMAGE}"
echo "RUNTIME_BASE_TAG: ${RUNTIME_BASE_TAG}"
echo "PLATFORM:         ${PLATFORM}"
echo "Container:        ${CONTAINER_NAME}"
echo "Design doc:       ${MONOREPO_ROOT}/docs/IMAGE_BUILD_PHASES.md"
echo ""

for d in InfiniCore InfiniLM InfiniLM-SVC; do
  if [[ ! -d "${SOURCE_ROOT}/${d}" ]]; then
    echo "error: expected ${SOURCE_ROOT}/${d}" >&2
    exit 1
  fi
done

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "Pulling base image ${BASE_IMAGE}..."
  if ! docker pull "${BASE_IMAGE}"; then
    if should_use_proxy; then
      echo "Retrying docker pull with proxy ${DEFAULT_PROXY}..."
      HTTP_PROXY="${DEFAULT_PROXY}" HTTPS_PROXY="${DEFAULT_PROXY}" docker pull "${BASE_IMAGE}"
    else
      exit 1
    fi
  fi
fi

IL_SHA="$(git -C "${SOURCE_ROOT}/InfiniLM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IC_SHA="$(git -C "${SOURCE_ROOT}/InfiniCore" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IO_SHA="$(git -C "${SOURCE_ROOT}/InfiniOrchestrator" rev-parse --short HEAD 2>/dev/null || \
  git -C "${MONOREPO_ROOT}/InfiniOrchestrator" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BASE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "${BASE_IMAGE}" 2>/dev/null || \
  docker image inspect --format '{{.Id}}' "${BASE_IMAGE}")"

echo "Step 1: Create Phase 1 build container (sleep entrypoint)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${CONTAINER_NAME}" \
  --network host \
  --workdir /app \
  --entrypoint /bin/bash \
  "${BASE_IMAGE}" \
  -c "sleep infinity"

cleanup_on_fail() {
  local ec=$?
  if [[ ${ec} -ne 0 ]]; then
    echo ""
    echo "Phase 1 failed (exit ${ec}). Container kept for debugging:"
    echo "  docker exec -it ${CONTAINER_NAME} bash"
  fi
}
trap cleanup_on_fail EXIT

echo "Step 2: Copy scripts + sources into container..."
docker exec "${CONTAINER_NAME}" mkdir -p /app /workspace /root/.infini \
  /workspace/piecewise_inductor_cache "/app/deployment/cases/${DEPLOYMENT_CASE}"

docker cp "${SCRIPT_DIR}/env-set.sh" "${CONTAINER_NAME}:/app/env-set.sh"
docker cp "${SCRIPT_DIR}/setup-phase1-deps.sh" "${CONTAINER_NAME}:/app/setup-phase1-deps.sh"
docker cp "${SCRIPT_DIR}/install.defaults.sh" \
  "${CONTAINER_NAME}:/app/deployment/cases/${DEPLOYMENT_CASE}/install.defaults.sh"
docker cp "${SCRIPT_DIR}/env-set.sh" \
  "${CONTAINER_NAME}:/app/deployment/cases/${DEPLOYMENT_CASE}/env-set.sh"

# Stream filtered trees (skip .git / build / xmake caches) — committed image is self-contained.
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

echo "  Copying InfiniLM-SVC → /app ..."
stream_tree "${SOURCE_ROOT}/InfiniLM-SVC" /app
stream_tree "${SOURCE_ROOT}/InfiniCore" /workspace/InfiniCore
stream_tree "${SOURCE_ROOT}/InfiniLM" /workspace/InfiniLM

# Prefer /root/.infini natives from running HPCC 3.7 dev container (host-staged;
# docker cp between containers is unsupported). Keeps flash-attn ABI aligned.
if docker ps -a --format '{{.Names}}' | grep -qx "${DEV_CONTAINER}"; then
  echo "  Overlay /root/.infini libs from ${DEV_CONTAINER} via host stage..."
  _libstage="$(mktemp -d)"
  docker cp "${DEV_CONTAINER}:/root/.infini/lib/." "${_libstage}/" 2>/dev/null || true
  if ls "${_libstage}"/libinfinicore_cpp_api.so >/dev/null 2>&1; then
    docker exec "${CONTAINER_NAME}" mkdir -p \
      /root/.infini/lib \
      /workspace/InfiniCore/python/infinicore/lib \
      /workspace/InfiniLM/python/infinilm/lib
    docker cp "${_libstage}/." "${CONTAINER_NAME}:/root/.infini/lib/"
    for _so in libinfinicore_cpp_api.so libinfiniop.so libinfinirt.so libinfiniccl.so; do
      [[ -f "${_libstage}/${_so}" ]] || continue
      docker cp "${_libstage}/${_so}" \
        "${CONTAINER_NAME}:/workspace/InfiniCore/python/infinicore/lib/"
    done
  fi
  rm -rf "${_libstage}"
fi

# Seed aarch64 InfiniLM-SVC binaries from a prior image when cargo network is weak.
if docker image inspect "${BIN_SEED_IMAGE}" >/dev/null 2>&1; then
  echo "  Seeding infini-* binaries from ${BIN_SEED_IMAGE} (optional)..."
  _seed="$(docker create "${BIN_SEED_IMAGE}")"
  _binstage="$(mktemp -d)"
  docker cp "${_seed}:/usr/local/bin/infini-registry" "${_binstage}/" 2>/dev/null || true
  docker cp "${_seed}:/usr/local/bin/infini-router" "${_binstage}/" 2>/dev/null || true
  docker cp "${_seed}:/usr/local/bin/infini-babysitter" "${_binstage}/" 2>/dev/null || true
  docker rm -f "${_seed}" >/dev/null
  for _bin in infini-registry infini-router infini-babysitter; do
    if [[ -f "${_binstage}/${_bin}" ]]; then
      docker cp "${_binstage}/${_bin}" "${CONTAINER_NAME}:/usr/local/bin/"
    fi
  done
  rm -rf "${_binstage}"
  docker exec "${CONTAINER_NAME}" chmod +x \
    /usr/local/bin/infini-registry /usr/local/bin/infini-router /usr/local/bin/infini-babysitter 2>/dev/null || true
fi

echo "Step 3: Run setup-phase1-deps.sh..."
if ! run_setup; then
  if [[ "${USE_PROXY:-}" == "1" ]]; then
    exit 1
  fi
  echo "Setup failed without proxy; retrying with ${DEFAULT_PROXY}..."
  USE_PROXY=1 run_setup
fi

echo "Step 4: Commit runtime-base (shell entrypoint; no product restart policy)..."
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD ["-lc","sleep infinity"]' \
  --change "LABEL org.opencontainers.image.revision=${IL_SHA}-${IC_SHA}" \
  --change "LABEL deployment.case=${DEPLOYMENT_CASE}" \
  --change "LABEL deployment.phase=1" \
  --change "LABEL deployment.platform=${PLATFORM}" \
  --change "ENV IL_SHA=${IL_SHA}" \
  --change "ENV IC_SHA=${IC_SHA}" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  --change "ENV RUNTIME_BASE_TAG=${RUNTIME_BASE_TAG}" \
  --change "ENV PLATFORM=${PLATFORM}" \
  "${CONTAINER_NAME}" \
  "${RUNTIME_BASE_TAG}"

echo "Step 5: Cleanup build container..."
trap - EXIT
docker rm -f "${CONTAINER_NAME}" >/dev/null

echo "${RUNTIME_BASE_TAG}" > "${SCRIPT_DIR}/.runtime_base_tag"
cat > "${SCRIPT_DIR}/MANIFEST" <<EOF
PHASE=1
PLATFORM=${PLATFORM}
DEPLOYMENT_CASE=${DEPLOYMENT_CASE}
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
IO_SHA=${IO_SHA}
BUILD_TS=${BUILD_TS}
BASE_IMAGE=${BASE_IMAGE}
BASE_DIGEST=${BASE_DIGEST}
RUNTIME_BASE_TAG=${RUNTIME_BASE_TAG}
SOURCE_ROOT=${SOURCE_ROOT}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CEVAL_CACHE_LAYOUT=bench/ceval_cache
INDUCTOR_CACHE=/workspace/piecewise_inductor_cache
IMAGE_BUILD_PHASES=docs/IMAGE_BUILD_PHASES.md
EOF

echo ""
echo "Built runtime-base: ${RUNTIME_BASE_TAG}"
echo "Wrote: ${SCRIPT_DIR}/.runtime_base_tag"
echo "Wrote: ${SCRIPT_DIR}/MANIFEST"
echo ""
echo "Next: Phase 1.5 (optional) or Phase 2 — see docs/IMAGE_BUILD_PHASES.md"
echo "Smoke: docker run --rm --privileged --device /dev/dri --device /dev/htcd \\"
echo "  --entrypoint /bin/bash ${RUNTIME_BASE_TAG} -lc 'source /app/env-set.sh; python3 -c \"import infinicore, infinilm; print(OK)\"'"
