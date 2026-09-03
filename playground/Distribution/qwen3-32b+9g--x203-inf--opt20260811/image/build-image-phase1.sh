#!/usr/bin/env bash
# Phase 1: vendor BASE_IMAGE → setup-phase1-deps.sh → docker commit RUNTIME_BASE_TAG
# See docs/IMAGE_BUILD_PHASES.md
#
# Pinned vendor BASE_IMAGE (HPCC OS/stack only — tag contains "vllm-mars" but is NOT
# a case runtime backend; serving is InfiniLM via SVC entrypoint):
#   Docker ID: 1a3cbde5ff2a
#   Tag: …/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64
#
# Example:
#   ./image/build-image-phase1.sh
#   # or override (must still resolve to ID 1a3cbde5ff2a unless SKIP_BASE_IMAGE_ID_CHECK=1):
#   BASE_IMAGE=mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64 \
#     ./image/build-image-phase1.sh
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${IMAGE_DIR}/.." && pwd)"
SCRIPT_DIR="${IMAGE_DIR}"
# shellcheck source=../../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"
require_worktree_repos InfiniCore InfiniLM
MONOREPO_ROOT="$(cd "${IO_ROOT}/.." && pwd)"

# Default to short ID so local resolve is unambiguous; tag form also accepted.
BASE_IMAGE_ID_PIN="1a3cbde5ff2a"
BASE_IMAGE_TAG_PIN="mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64"
BASE_IMAGE="${BASE_IMAGE:-${BASE_IMAGE_TAG_PIN}}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260811}"
BUILD_TS="$(date -u +%Y%m%d)"
RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-${BUILD_TS}}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-build-ai370-p1-$(date +%s)}"
PLATFORM="${PLATFORM:-hpcc37}"

# Core/LM come from sibling InfiniTensorWorktree. Control plane = InfiniEntrypoint
# (InfiniOrchestrator/rust), not legacy InfiniLM-SVC.
SOURCE_ROOT="${SOURCE_ROOT:-${WORKTREE_ROOT}}"
SVC_ROOT="${SVC_ROOT:-${IO_ROOT}}"
RUST_DIR="${RUST_DIR:-${IO_ROOT}/rust}"
DEV_CONTAINER="${DEV_CONTAINER:-infinilm-dev-hpcc37}"
BIN_SEED_IMAGE="${BIN_SEED_IMAGE:-}"
# Read-only header seed when pin snapshots lack third_party submodules.
THIRD_PARTY_SEED_IMAGE="${THIRD_PARTY_SEED_IMAGE:-infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-20260813}"
PHASE1_GPU="${PHASE1_GPU:-1}"

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
echo "IO_ROOT:          ${IO_ROOT}"
echo "WORKTREE_ROOT:    ${WORKTREE_ROOT}"
echo "SOURCE_ROOT:      ${SOURCE_ROOT}"
echo "SVC_ROOT:         ${SVC_ROOT} (InfiniEntrypoint / InfiniOrchestrator)"
echo "RUST_DIR:         ${RUST_DIR}"
echo "BASE_IMAGE:       ${BASE_IMAGE}"
echo "BASE_IMAGE_ID:    ${BASE_IMAGE_ID_PIN} (pin)"
echo "RUNTIME_BASE_TAG: ${RUNTIME_BASE_TAG}"
echo "PLATFORM:         ${PLATFORM}"
echo "Container:        ${CONTAINER_NAME}"
echo "Design doc:       ${MONOREPO_ROOT}/docs/IMAGE_BUILD_PHASES.md"
echo ""
echo "Note: vendor tag may contain 'vllm-mars' (HPCC base); runtime backends are InfiniLM only."
echo "Control plane: InfiniEntrypoint + InfiniLoadBalancer from ${RUST_DIR}."
echo ""

for d in InfiniCore InfiniLM; do
  if [[ ! -d "${SOURCE_ROOT}/${d}" ]]; then
    echo "error: expected ${SOURCE_ROOT}/${d}" >&2
    exit 1
  fi
done
if [[ ! -d "${SVC_ROOT}/rust" ]]; then
  echo "error: expected InfiniOrchestrator rust/ at SVC_ROOT=${SVC_ROOT}" >&2
  exit 1
fi
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
IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
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

# Resolve to canonical tag for commit labels; enforce pinned short ID 1a3cbde5ff2a.
BASE_IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${BASE_IMAGE}")"
BASE_IMAGE_ID_SHORT="${BASE_IMAGE_ID#sha256:}"
BASE_IMAGE_ID_SHORT="${BASE_IMAGE_ID_SHORT:0:12}"
if [[ "${SKIP_BASE_IMAGE_ID_CHECK:-0}" != "1" && "${BASE_IMAGE_ID_SHORT}" != "${BASE_IMAGE_ID_PIN}" ]]; then
  echo "error: BASE_IMAGE resolves to ${BASE_IMAGE_ID_SHORT}, expected pin ${BASE_IMAGE_ID_PIN}" >&2
  echo "  BASE_IMAGE=${BASE_IMAGE}" >&2
  echo "  set SKIP_BASE_IMAGE_ID_CHECK=1 to override (not recommended)" >&2
  exit 1
fi
# Prefer tagged name in MANIFEST when available.
if docker image inspect "${BASE_IMAGE_TAG_PIN}" >/dev/null 2>&1; then
  if [[ "$(docker image inspect --format '{{.Id}}' "${BASE_IMAGE_TAG_PIN}")" == "${BASE_IMAGE_ID}" ]]; then
    BASE_IMAGE="${BASE_IMAGE_TAG_PIN}"
  fi
fi

IL_SHA="$(git -C "${SOURCE_ROOT}/InfiniLM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IC_SHA="$(git -C "${SOURCE_ROOT}/InfiniCore" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ITW_TAG="$(git -C "${SOURCE_ROOT}" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ -z "${ITW_TAG}" ]]; then
  ITW_TAG="$(git -C "${SOURCE_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
ITW_SHA="$(git -C "${SOURCE_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "${ITW_TAG}" > "${IMAGE_DIR}/.worktree_tag"
BASE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "${BASE_IMAGE}" 2>/dev/null || true)"
if [[ -z "${BASE_DIGEST}" || "${BASE_DIGEST}" == "<no value>" ]]; then
  BASE_DIGEST="${BASE_IMAGE_ID}"
fi

echo "Step 1: Create Phase 1 build container (sleep entrypoint)..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
_phase1_run_args=(
  -d
  --name "${CONTAINER_NAME}"
  --network host
  --workdir /app
  --entrypoint /bin/bash
  -e XMAKE_ROOT=y
)
if [[ "${PHASE1_GPU}" == "1" ]]; then
  echo "  Attaching GPU devices (/dev/dri /dev/htcd) for MetaX xmake..."
  _phase1_run_args+=(--privileged --ipc=shareable --device=/dev/dri:/dev/dri --device=/dev/htcd:/dev/htcd)
fi
docker run "${_phase1_run_args[@]}" \
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
  /workspace/piecewise_inductor_cache

docker cp "${IMAGE_DIR}/env-set.sh" "${CONTAINER_NAME}:/app/env-set.sh"
docker cp "${IMAGE_DIR}/setup-phase1-deps.sh" "${CONTAINER_NAME}:/app/setup-phase1-deps.sh"

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

echo "  Staging InfiniEntrypoint control plane → /app + /usr/local/bin ..."
docker exec "${CONTAINER_NAME}" mkdir -p /app /usr/local/bin /app/logs
docker cp "${IMAGE_DIR}/docker_entrypoint.sh" "${CONTAINER_NAME}:/app/docker_entrypoint.sh"
docker exec "${CONTAINER_NAME}" chmod +x /app/docker_entrypoint.sh
# Host-built InfiniOrchestrator rust release binaries (InfiniEntrypoint stack).
for _bin in infini-entrypoint infini-loadbalancer infini-sharepool infini-registry; do
  if [[ -x "${RUST_DIR}/target/release/${_bin}" ]]; then
    docker cp "${RUST_DIR}/target/release/${_bin}" "${CONTAINER_NAME}:/usr/local/bin/${_bin}"
  fi
done
# Compat aliases used by older smoke / launch helpers.
docker exec "${CONTAINER_NAME}" bash -lc '
  chmod +x /usr/local/bin/infini-* 2>/dev/null || true
  ln -sfn /usr/local/bin/infini-entrypoint /usr/local/bin/infini-babysitter
  ln -sfn /usr/local/bin/infini-loadbalancer /usr/local/bin/infini-router
  # registry stub remains for PATH checks; it exits with deprecation message.
'
# Light marker so /app looks like an InfiniOrchestrator product root.
docker exec "${CONTAINER_NAME}" bash -lc "printf '%s\n' 'InfiniOrchestrator InfiniEntrypoint runtime-base' > /app/README.entrypoint"
echo "  Streaming InfiniTensorWorktree InfiniCore/InfiniLM → /workspace ..."
stream_tree "${SOURCE_ROOT}/InfiniCore" /workspace/InfiniCore
stream_tree "${SOURCE_ROOT}/InfiniLM" /workspace/InfiniLM

# Vendor BASE has no xmake. Copy binary + program files from dev container or host.
seed_xmake() {
  echo "  Seeding xmake (vendor BASE has none)..."
  docker exec "${CONTAINER_NAME}" mkdir -p \
    /root/.local/bin /root/.local/share/xmake /usr/local/bin /root/.xmake
  local _xstage
  _xstage="$(mktemp -d)"
  mkdir -p "${_xstage}/share" "${_xstage}/dotxmake"
  if docker ps --format '{{.Names}}' | grep -qx "${DEV_CONTAINER}"; then
    echo "    binary/share from running ${DEV_CONTAINER}"
    docker cp "${DEV_CONTAINER}:/root/.local/bin/xmake" "${_xstage}/xmake" 2>/dev/null || true
    docker cp "${DEV_CONTAINER}:/usr/local/bin/xmake" "${_xstage}/xmake" 2>/dev/null || true
    docker cp "${DEV_CONTAINER}:/root/.local/share/xmake/." "${_xstage}/share/" 2>/dev/null || true
    docker cp "${DEV_CONTAINER}:/root/.xmake/." "${_xstage}/dotxmake/" 2>/dev/null || true
  fi
  if [[ ! -f "${_xstage}/xmake" && -x /root/.local/bin/xmake ]]; then
    echo "    binary from host /root/.local/bin/xmake"
    cp -a /root/.local/bin/xmake "${_xstage}/xmake"
  fi
  if [[ ! -d "${_xstage}/share" || -z "$(ls -A "${_xstage}/share" 2>/dev/null || true)" ]]; then
    if [[ -d /root/.local/share/xmake ]]; then
      mkdir -p "${_xstage}/share"
      cp -a /root/.local/share/xmake/. "${_xstage}/share/"
    fi
  fi
  if [[ ! -f "${_xstage}/xmake" ]]; then
    echo "error: could not seed xmake (need ${DEV_CONTAINER} or /root/.local/bin/xmake)" >&2
    rm -rf "${_xstage}"
    return 1
  fi
  docker cp "${_xstage}/xmake" "${CONTAINER_NAME}:/root/.local/bin/xmake"
  docker cp "${_xstage}/xmake" "${CONTAINER_NAME}:/usr/local/bin/xmake"
  if [[ -d "${_xstage}/share" ]]; then
    docker cp "${_xstage}/share/." "${CONTAINER_NAME}:/root/.local/share/xmake/"
  fi
  if [[ -d "${_xstage}/dotxmake" ]]; then
    docker cp "${_xstage}/dotxmake/." "${CONTAINER_NAME}:/root/.xmake/"
  fi
  rm -rf "${_xstage}"
  docker exec "${CONTAINER_NAME}" chmod +x /root/.local/bin/xmake /usr/local/bin/xmake
  docker exec "${CONTAINER_NAME}" bash -lc '
    export PATH="/root/.local/bin:/usr/local/bin:${PATH}"
    export XMAKE_ROOT=y
    command -v xmake
    xmake --version
  '
}

seed_infinicore_third_party() {
  if ! docker image inspect "${THIRD_PARTY_SEED_IMAGE}" >/dev/null 2>&1; then
    echo "warning: ${THIRD_PARTY_SEED_IMAGE} missing; cannot seed third_party headers" >&2
    return 0
  fi
  echo "  Seeding InfiniCore/InfiniLM third_party headers from ${THIRD_PARTY_SEED_IMAGE}..."
  local _seed _stage
  _seed="$(docker create "${THIRD_PARTY_SEED_IMAGE}")"
  _stage="$(mktemp -d)"
  docker cp "${_seed}:/workspace/InfiniCore/third_party/spdlog" "${_stage}/spdlog" 2>/dev/null || true
  docker cp "${_seed}:/workspace/InfiniLM/third_party/json" "${_stage}/json" 2>/dev/null || true
  docker rm -f "${_seed}" >/dev/null
  docker exec "${CONTAINER_NAME}" mkdir -p /workspace/InfiniCore/third_party /workspace/InfiniLM/third_party
  if [[ -f "${_stage}/spdlog/include/spdlog/spdlog.h" ]]; then
    if ! docker exec "${CONTAINER_NAME}" test -f /workspace/InfiniCore/third_party/spdlog/include/spdlog/spdlog.h; then
      docker cp "${_stage}/spdlog" "${CONTAINER_NAME}:/workspace/InfiniCore/third_party/spdlog"
    fi
    if ! docker exec "${CONTAINER_NAME}" test -f /workspace/InfiniLM/third_party/spdlog/include/spdlog/spdlog.h; then
      docker cp "${_stage}/spdlog" "${CONTAINER_NAME}:/workspace/InfiniLM/third_party/spdlog"
    fi
  fi
  if [[ -d "${_stage}/json/single_include" ]]; then
    if ! docker exec "${CONTAINER_NAME}" test -d /workspace/InfiniLM/third_party/json/single_include; then
      docker cp "${_stage}/json" "${CONTAINER_NAME}:/workspace/InfiniLM/third_party/json"
    fi
  fi
  rm -rf "${_stage}"
}

seed_infinicore_third_party
if [[ "${FORCE_XMAKE_BUILD:-false}" == "true" ]]; then
  seed_xmake
fi

# Prefer /root/.infini natives from running HPCC 3.7 dev container (host-staged;
# docker cp between containers is unsupported). Skip when FORCE_XMAKE_BUILD —
# those libs are deploy-era and would mix with the pin we are compiling.
if [[ "${FORCE_XMAKE_BUILD:-false}" != "true" ]] && docker ps -a --format '{{.Names}}' | grep -qx "${DEV_CONTAINER}"; then
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
    # Bake full native extensions from dev-container xmake (not runtime hot-patch).
    _extstage="$(mktemp -d)"
    docker cp "${DEV_CONTAINER}:/workspace/InfiniCore/python/infinicore/lib/." "${_extstage}/ic/" 2>/dev/null || true
    docker cp "${DEV_CONTAINER}:/workspace/InfiniLM/python/infinilm/lib/." "${_extstage}/il/" 2>/dev/null || true
    if ls "${_extstage}/ic"/_infinicore*.so >/dev/null 2>&1; then
      docker cp "${_extstage}/ic/." "${CONTAINER_NAME}:/workspace/InfiniCore/python/infinicore/lib/"
    fi
    if ls "${_extstage}/il"/_infinilm*.so >/dev/null 2>&1; then
      docker cp "${_extstage}/il/." "${CONTAINER_NAME}:/workspace/InfiniLM/python/infinilm/lib/"
    fi
    if docker exec "${DEV_CONTAINER}" test -d /workspace/InfiniCore/build/.pkg/infinicore/include 2>/dev/null; then
      docker exec "${CONTAINER_NAME}" mkdir -p /root/.infini/include
      docker cp "${DEV_CONTAINER}:/workspace/InfiniCore/build/.pkg/infinicore/include/." \
        "${CONTAINER_NAME}:/root/.infini/include/" 2>/dev/null || true
    fi
    rm -rf "${_extstage}"
  fi
  rm -rf "${_libstage}"
fi

# Optional: seed additional bins from a prior image when BIN_SEED_IMAGE is set.
if [[ -n "${BIN_SEED_IMAGE}" ]] && docker image inspect "${BIN_SEED_IMAGE}" >/dev/null 2>&1; then
  echo "  Seeding extra infini-* binaries from ${BIN_SEED_IMAGE} (optional)..."
  _seed="$(docker create "${BIN_SEED_IMAGE}")"
  _binstage="$(mktemp -d)"
  for _bin in infini-entrypoint infini-loadbalancer infini-babysitter; do
    docker cp "${_seed}:/usr/local/bin/${_bin}" "${_binstage}/" 2>/dev/null || true
  done
  docker rm -f "${_seed}" >/dev/null
  for _bin in infini-entrypoint infini-loadbalancer infini-babysitter; do
    if [[ -f "${_binstage}/${_bin}" ]]; then
      docker cp "${_binstage}/${_bin}" "${CONTAINER_NAME}:/usr/local/bin/"
    fi
  done
  rm -rf "${_binstage}"
  docker exec "${CONTAINER_NAME}" chmod +x /usr/local/bin/infini-* 2>/dev/null || true
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

echo "${RUNTIME_BASE_TAG}" > "${IMAGE_DIR}/.runtime_base_tag"
cat > "${IMAGE_DIR}/MANIFEST" <<EOF
PHASE=1
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
echo "Built runtime-base: ${RUNTIME_BASE_TAG}"
echo "Wrote: ${IMAGE_DIR}/.runtime_base_tag"
echo "Wrote: ${IMAGE_DIR}/.worktree_tag (${ITW_TAG})"
echo "Wrote: ${IMAGE_DIR}/MANIFEST"
echo ""
echo "Next: ./phase1-smoke.sh && ./build-image-phase2.sh"
echo "Smoke: docker run --rm --privileged --device /dev/dri --device /dev/htcd \\"
echo "  --entrypoint /bin/bash ${RUNTIME_BASE_TAG} -lc 'source /app/env-set.sh; python3 -c \"import infinicore, infinilm; print(OK)\"'"
