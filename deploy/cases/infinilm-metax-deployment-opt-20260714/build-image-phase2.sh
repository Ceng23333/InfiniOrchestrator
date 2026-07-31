#!/usr/bin/env bash
# Phase 2 stub: runtime-base(-deps) + SOURCE_ROOT → product entrypoint → IMAGE_TAG
# Not executed in the 20260714 scaffolding iteration. See docs/IMAGE_BUILD_PHASES.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${SCRIPT_DIR}/../../../scripts/worktree_env.sh"
require_worktree_repos InfiniCore InfiniLM

if [[ -f "${SCRIPT_DIR}/.runtime_base_deps_tag" ]]; then
  FROM_TAG="${FROM_TAG:-$(cat "${SCRIPT_DIR}/.runtime_base_deps_tag")}"
elif [[ -f "${SCRIPT_DIR}/.runtime_base_tag" ]]; then
  FROM_TAG="${FROM_TAG:-$(cat "${SCRIPT_DIR}/.runtime_base_tag")}"
fi
FROM_TAG="${FROM_TAG:?set FROM_TAG / RUNTIME_BASE_TAG or run Phase 1 first}"

SOURCE_ROOT="${SOURCE_ROOT:-${WORKTREE_ROOT}}"
BUILD_TS="$(date -u +%Y%m%d)"
IL_SHA="$(git -C "${SOURCE_ROOT}/InfiniLM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IC_SHA="$(git -C "${SOURCE_ROOT}/InfiniCore" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IMAGE_TAG="${IMAGE_TAG:-infinilm-svc:metax-hpcc-ai370-${IL_SHA}-${IC_SHA}-${BUILD_TS}}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-build-ai370-p2-$(date +%s)}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260714}"

echo "=========================================="
echo "Phase 2 product image (STUB — not fully implemented)"
echo "=========================================="
echo "FROM_TAG:      ${FROM_TAG}"
echo "SOURCE_ROOT:   ${SOURCE_ROOT}"
echo "WORKTREE_ROOT: ${WORKTREE_ROOT}"
echo "IMAGE_TAG:     ${IMAGE_TAG}"
echo ""
echo "Would: docker run from ${FROM_TAG},"
echo "  sync worktree via setup-phase2-worktree.sh,"
echo "  apply product ENTRYPOINT [/bin/bash,/app/docker_entrypoint.sh],"
echo "  docker commit → ${IMAGE_TAG}, write .image_tag"
echo ""
echo "Stub exit: set IMPLEMENT_PHASE2=1 once setup-phase2-worktree.sh is complete."
if [[ "${IMPLEMENT_PHASE2:-0}" != "1" ]]; then
  exit 0
fi

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER_NAME}" --network host --workdir /app \
  --entrypoint /bin/bash "${FROM_TAG}" -c "sleep infinity"
docker cp "${SCRIPT_DIR}/setup-phase2-worktree.sh" "${CONTAINER_NAME}:/app/setup-phase2-worktree.sh"
docker exec -e SOURCE_ROOT_IN_CONTAINER=/src \
  "${CONTAINER_NAME}" bash /app/setup-phase2-worktree.sh || true
# Caller should docker cp SOURCE_ROOT trees before running setup when IMPLEMENT_PHASE2=1
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash","/app/docker_entrypoint.sh"]' \
  --change "LABEL deployment.phase=2" \
  --change "LABEL deployment.case=${DEPLOYMENT_CASE}" \
  --change "ENV IMAGE_TAG=${IMAGE_TAG}" \
  "${CONTAINER_NAME}" "${IMAGE_TAG}"
docker rm -f "${CONTAINER_NAME}" >/dev/null
echo "${IMAGE_TAG}" > "${SCRIPT_DIR}/.image_tag"
echo "Built: ${IMAGE_TAG}"
