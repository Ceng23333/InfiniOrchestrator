#!/usr/bin/env bash
# Commit-based image build: Dockerfile scaffold → container setup → docker commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${SCRIPT_DIR}/../../../scripts/worktree_env.sh"
require_worktree_repos InfiniCore InfiniLM

BASE_IMAGE="${BASE_IMAGE:-cr.metax-tech.com/public-ai-release-wb/hpcc/vllm:hpcc.ai3.1.0.7-torch2.6-py310-kylin2309a-arm64}"
SCAFFOLD_TAG="${SCAFFOLD_TAG:-infinilm-svc:metax-hpcc-ai3107-scaffold}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260622}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-build-ai3107-$(date +%s)}"
SVC_ROOT="${SVC_ROOT:-$(cd "${IO_ROOT}/.." && pwd)/InfiniLM-SVC}"
# shellcheck source=proxy-env.sh
source "${SCRIPT_DIR}/proxy-env.sh"

run_setup_in_container() {
  local -a _proxy_args=()
  if should_use_proxy; then
    proxy_env_args _proxy_args
    echo "Running setup with proxy ${DEFAULT_PROXY}..."
  else
    echo "Running setup without proxy..."
  fi
  docker exec "${_proxy_args[@]}" "${CONTAINER_NAME}" bash /app/setup-in-container.sh
}

if [[ ! -d "${SVC_ROOT}" ]]; then
  echo "error: expected InfiniLM-SVC at SVC_ROOT=${SVC_ROOT}" >&2
  exit 1
fi

if git -C "${WORKTREE_ROOT}/InfiniLM" rev-parse --short HEAD >/dev/null 2>&1; then
  IL_SHA="$(git -C "${WORKTREE_ROOT}/InfiniLM" rev-parse --short HEAD)"
  IC_SHA="$(git -C "${WORKTREE_ROOT}/InfiniCore" rev-parse --short HEAD)"
  IO_SHA="$(git -C "${IO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
else
  IL_SHA="${IL_SHA:-unknown}"
  IC_SHA="${IC_SHA:-unknown}"
  IO_SHA="${IO_SHA:-unknown}"
fi
BUILD_TS="$(date -u +%Y%m%d)"
IMAGE_TAG="${IMAGE_TAG:-infinilm-svc:metax-hpcc-ai3107-${IL_SHA}-${IC_SHA}-${BUILD_TS}}"

echo "=========================================="
echo "Build: ${DEPLOYMENT_CASE}"
echo "=========================================="
echo "IO_ROOT:      ${IO_ROOT}"
echo "WORKTREE:     ${WORKTREE_ROOT}"
echo "SVC_ROOT:     ${SVC_ROOT}"
echo "Base image:   ${BASE_IMAGE}"
echo "Output tag:   ${IMAGE_TAG}"
echo "IL_SHA:       ${IL_SHA}"
echo "IC_SHA:       ${IC_SHA}"
echo "Container:    ${CONTAINER_NAME}"
echo ""

if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
  echo "Pulling base image ${BASE_IMAGE}..."
  if ! docker pull "${BASE_IMAGE}"; then
    if should_use_proxy; then
      echo "Retrying docker pull with proxy ${DEFAULT_PROXY}..."
      HTTP_PROXY="${DEFAULT_PROXY}" HTTPS_PROXY="${DEFAULT_PROXY}" \
        docker pull "${BASE_IMAGE}"
    else
      exit 1
    fi
  fi
fi

echo "Step 1: Build scaffold image..."
docker build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  -t "${SCAFFOLD_TAG}" \
  "${SCRIPT_DIR}"

echo "Step 2: Create build container..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker create \
  --name "${CONTAINER_NAME}" \
  --network host \
  --workdir /app \
  --entrypoint /bin/bash \
  "${SCAFFOLD_TAG}" \
  -c "sleep infinity"

echo "Step 3: Copy sources into container..."
docker cp "${SVC_ROOT}/." "${CONTAINER_NAME}:/app/"
docker cp "${WORKTREE_ROOT}/InfiniCore/." "${CONTAINER_NAME}:/workspace/InfiniCore/"
docker cp "${WORKTREE_ROOT}/InfiniLM/." "${CONTAINER_NAME}:/workspace/InfiniLM/"
# Optional: overlay /root/.infini from dev container when present (offline xmake fallback)
if docker ps -a --format '{{.Names}}' | grep -qx 'infinilm-dev-20260622'; then
  docker cp infinilm-dev-20260622:/root/.infini/. "${CONTAINER_NAME}:/root/.infini/" 2>/dev/null || true
fi
docker cp "${SCRIPT_DIR}/env-set.sh" "${CONTAINER_NAME}:/app/env-set.sh"
docker cp "${SCRIPT_DIR}/setup-in-container.sh" "${CONTAINER_NAME}:/app/setup-in-container.sh"

echo "Step 4: Start container, stage deployment preset, run setup..."
docker start "${CONTAINER_NAME}"
sleep 2
docker exec "${CONTAINER_NAME}" mkdir -p "/app/deployment/cases/${DEPLOYMENT_CASE}"
docker cp "${SCRIPT_DIR}/install.defaults.sh" \
  "${CONTAINER_NAME}:/app/deployment/cases/${DEPLOYMENT_CASE}/install.defaults.sh"
docker cp "${SCRIPT_DIR}/env-set.sh" \
  "${CONTAINER_NAME}:/app/deployment/cases/${DEPLOYMENT_CASE}/env-set.sh"

sleep 2

if ! run_setup_in_container; then
  if [[ "${USE_PROXY:-}" == "1" ]]; then
    echo ""
    echo "Setup failed with proxy ${DEFAULT_PROXY}. Container kept for debugging:"
    echo "  docker exec -it ${CONTAINER_NAME} bash"
    exit 1
  fi
  echo ""
  echo "Setup failed without proxy; retrying with ${DEFAULT_PROXY}..."
  USE_PROXY=1 run_setup_in_container || {
    echo ""
    echo "Setup failed. Container kept for debugging:"
    echo "  docker exec -it ${CONTAINER_NAME} bash"
    exit 1
  }
fi

echo "Step 5: Commit deliverable image..."
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash", "/app/docker_entrypoint.sh"]' \
  --change "LABEL org.opencontainers.image.revision=${IL_SHA}-${IC_SHA}" \
  --change "LABEL deployment.case=${DEPLOYMENT_CASE}" \
  --change "ENV IL_SHA=${IL_SHA}" \
  --change "ENV IC_SHA=${IC_SHA}" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  --change "ENV IMAGE_TAG=${IMAGE_TAG}" \
  "${CONTAINER_NAME}" \
  "${IMAGE_TAG}"

echo "Step 6: Cleanup build container..."
docker rm -f "${CONTAINER_NAME}" >/dev/null

echo "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"
cat > "${SCRIPT_DIR}/MANIFEST" <<EOF
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
IO_SHA=${IO_SHA}
BUILD_TS=${BUILD_TS}
BASE_IMAGE=${BASE_IMAGE}
IMAGE_TAG=${IMAGE_TAG}
DEPLOYMENT_CASE=${DEPLOYMENT_CASE}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo ""
echo "Built: ${IMAGE_TAG}"
echo "Wrote: ${SCRIPT_DIR}/.image_tag"
echo "Wrote: ${SCRIPT_DIR}/MANIFEST"
