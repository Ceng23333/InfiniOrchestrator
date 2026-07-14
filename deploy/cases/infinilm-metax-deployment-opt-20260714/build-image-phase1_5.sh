#!/usr/bin/env bash
# Phase 1.5 stub: runtime-base + OFFLINE_DEPS_ROOT → offline pip/cargo → commit deps tag.
# Not executed in the 20260714 scaffolding iteration — implement install in
# setup-phase1_5-offline-deps.sh. See docs/IMAGE_BUILD_PHASES.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/.runtime_base_tag" ]]; then
  RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-$(cat "${SCRIPT_DIR}/.runtime_base_tag")}"
fi
RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:?set RUNTIME_BASE_TAG or run Phase 1 first}"
OFFLINE_DEPS_ROOT="${OFFLINE_DEPS_ROOT:-${SCRIPT_DIR}/offline-deps}"
BUILD_TS="$(date -u +%Y%m%d)"
RUNTIME_BASE_DEPS_TAG="${RUNTIME_BASE_DEPS_TAG:-infinilm-svc:metax-hpcc-ai370-runtime-base-deps-${BUILD_TS}}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-build-ai370-p15-$(date +%s)}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260714}"

echo "=========================================="
echo "Phase 1.5 offline deps (STUB — not fully implemented)"
echo "=========================================="
echo "RUNTIME_BASE_TAG:      ${RUNTIME_BASE_TAG}"
echo "OFFLINE_DEPS_ROOT:     ${OFFLINE_DEPS_ROOT}"
echo "RUNTIME_BASE_DEPS_TAG: ${RUNTIME_BASE_DEPS_TAG}"
echo ""

if [[ ! -d "${OFFLINE_DEPS_ROOT}" ]]; then
  echo "error: OFFLINE_DEPS_ROOT missing: ${OFFLINE_DEPS_ROOT}" >&2
  echo "Prepare offline-deps/ on a networked host (see offline-deps/README.md)." >&2
  exit 1
fi

if ! docker image inspect "${RUNTIME_BASE_TAG}" >/dev/null 2>&1; then
  echo "error: image not found: ${RUNTIME_BASE_TAG}" >&2
  exit 1
fi

echo "Would: docker run from ${RUNTIME_BASE_TAG},"
echo "  mount/copy ${OFFLINE_DEPS_ROOT},"
echo "  run setup-phase1_5-offline-deps.sh (pip --no-index, cargo vendor),"
echo "  docker commit → ${RUNTIME_BASE_DEPS_TAG}"
echo ""
echo "Stub exit: set IMPLEMENT_PHASE1_5=1 once setup-phase1_5-offline-deps.sh is complete."
if [[ "${IMPLEMENT_PHASE1_5:-0}" != "1" ]]; then
  exit 0
fi

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER_NAME}" --network host --workdir /app \
  --entrypoint /bin/bash "${RUNTIME_BASE_TAG}" -c "sleep infinity"
docker cp "${OFFLINE_DEPS_ROOT}/." "${CONTAINER_NAME}:/offline-deps/"
docker cp "${SCRIPT_DIR}/setup-phase1_5-offline-deps.sh" "${CONTAINER_NAME}:/app/setup-phase1_5-offline-deps.sh"
docker exec -e OFFLINE_DEPS_ROOT=/offline-deps "${CONTAINER_NAME}" bash /app/setup-phase1_5-offline-deps.sh
docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash"]' \
  --change 'CMD ["-lc","sleep infinity"]' \
  --change "LABEL deployment.phase=1.5" \
  --change "LABEL deployment.case=${DEPLOYMENT_CASE}" \
  "${CONTAINER_NAME}" "${RUNTIME_BASE_DEPS_TAG}"
docker rm -f "${CONTAINER_NAME}" >/dev/null
echo "${RUNTIME_BASE_DEPS_TAG}" > "${SCRIPT_DIR}/.runtime_base_deps_tag"
echo "Built: ${RUNTIME_BASE_DEPS_TAG}"
