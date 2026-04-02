#!/usr/bin/env bash
# Stage InfiniCore + InfiniLM from the workspace sibling of InfiniOrchestrator, then docker build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# metax -> container -> InfiniOrchestrator -> monorepo root (InfiniCore, InfiniLM, InfiniOrchestrator are siblings here).
MONOREPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-infini-orchestrator-metax:local}"
BASE_IMAGE="${BASE_IMAGE:-infinilm-svc:metax-hpcc-1004_218-202602281209}"

for d in "${MONOREPO_ROOT}/InfiniCore" "${MONOREPO_ROOT}/InfiniLM"; do
  if [[ ! -d "${d}" ]]; then
    echo "error: expected directory ${d}" >&2
    exit 1
  fi
done

STAGE="$(mktemp -d)"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

cp "${SCRIPT_DIR}/Dockerfile.orchestrator-runtime" "${STAGE}/Dockerfile"
# Exclude VCS metadata and build caches from context and image layers.
# Some build-cache dirs (e.g. `.xmake/` and `build/`) may be root-owned after
# in-container builds; excluding them avoids host-side permission failures.
rsync -a \
  --no-perms --no-owner --no-group \
  --exclude='.git' \
  --exclude='.xmake/**' \
  --exclude='build/**' \
  --exclude='.pytest_cache/' \
  --exclude='*/.pytest_cache/' \
  --exclude='__pycache__/' \
  --exclude='*/__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='InfiniCore/python/infinicore/lib/**' \
  "${MONOREPO_ROOT}/InfiniCore" "${MONOREPO_ROOT}/InfiniLM" "${STAGE}/"

# Optional: copy prebuilt runtime artifacts into the image so vendored
# Python extensions can resolve ABI symbols without recompiling.
INFINI_RUNTIME_CONTAINER="${INFINI_RUNTIME_CONTAINER:-__base__}"

# Always create the directory so Docker COPY doesn't fail. In offline mode
# (`INFINI_RUNTIME_CONTAINER=__skip__`) this is kept empty, but note that the
# Dockerfile still runs a `COPY root/.infini /root/.infini`, so using
# `__skip__` would overwrite base-image runtime libs with an empty dir.
mkdir -p "${STAGE}/root/.infini"

if [[ "${INFINI_RUNTIME_CONTAINER}" == "__skip__" ]]; then
  echo "Skipping /root/.infini staging (offline mode)."
  echo "warning: __skip__ will overwrite /root/.infini in the built image."
elif [[ "${INFINI_RUNTIME_CONTAINER}" == "__base__" ]]; then
  echo "Staging runtime libs from base image '${BASE_IMAGE}'..."
  TMP_CID="$(docker create "${BASE_IMAGE}")"
  docker cp "${TMP_CID}:/root/.infini" "${STAGE}/root/"
  # Also stage the infinicore python native extension into the same paths
  # as the host workspace source layout.
  mkdir -p "${STAGE}/InfiniCore/python/infinicore/lib"
  docker cp "${TMP_CID}:/InfiniCore/python/infinicore/lib/." "${STAGE}/InfiniCore/python/infinicore/lib/" 2>/dev/null || true
  # Stage the matching InfiniLM native extension as well; otherwise
  # /workspace/InfiniLM imports may become ABI-incompatible with the base
  # image's infinicore runtime.
  mkdir -p "${STAGE}/InfiniLM/python/infinilm/lib"
  docker cp "${TMP_CID}:/InfiniLM/python/infinilm/lib/." "${STAGE}/InfiniLM/python/infinilm/lib/" 2>/dev/null || true
  docker rm -f "${TMP_CID}" >/dev/null
elif [[ -n "${INFINI_RUNTIME_CONTAINER}" ]] && docker inspect "${INFINI_RUNTIME_CONTAINER}" >/dev/null 2>&1; then
  echo "Staging runtime libs from container '${INFINI_RUNTIME_CONTAINER}:/root/.infini'..."
  rm -rf "${STAGE}/root/.infini"
  mkdir -p "${STAGE}/root"
  # Copy the whole directory so `root/.infini/*` is preserved for Docker COPY.
  docker cp "${INFINI_RUNTIME_CONTAINER}:/root/.infini" "${STAGE}/root/"

  echo "Staging prebuilt InfiniCore python native extension..."
  # The host workspace `InfiniCore/` may not contain compiled `_infinicore`.
  # In a custom runtime container, the prebuilt extension may live under a
  # mounted workspace path; copy it into our staged `InfiniCore/` so the
  # runtime image stays ABI-compatible with the staged `/root/.infini`.
  PREBUILT_INFINICORE_LIB_SRC="${INFINICORE_PREBUILT_LIB_SRC:-/workspace/InfiniCore/python/infinicore/lib}"
  # Remove any previously staged placeholder (or accidentally nested)
  # directory so we end up with:
  #   .../InfiniCore/python/infinicore/lib/_infinicore*.so
  rm -rf "${STAGE}/InfiniCore/python/infinicore/lib"
  mkdir -p "${STAGE}/InfiniCore/python/infinicore"
  if ! docker cp \
      "${INFINI_RUNTIME_CONTAINER}:${PREBUILT_INFINICORE_LIB_SRC}" \
      "${STAGE}/InfiniCore/python/infinicore/"; then
    echo "warning: failed to stage ${PREBUILT_INFINICORE_LIB_SRC} from ${INFINI_RUNTIME_CONTAINER}" >&2
  fi
else
  echo "warning: could not find '${INFINI_RUNTIME_CONTAINER}' container; using base image /root/.infini" >&2
fi

docker build \
  ${DOCKER_BUILD_NO_CACHE:+--no-cache} \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  -t "${IMAGE_TAG}" \
  "${STAGE}"

echo "Built ${IMAGE_TAG}"
