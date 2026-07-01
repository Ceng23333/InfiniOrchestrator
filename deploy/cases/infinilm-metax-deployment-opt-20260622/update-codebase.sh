#!/usr/bin/env bash
# Offline codebase update: rebuild InfiniCore/InfiniLM inside a running container, then commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
# shellcheck source=proxy-env.sh
source "${SCRIPT_DIR}/proxy-env.sh"

SOURCE_IMAGE=""
NEW_TAG=""
INFINICORE_SRC="${INFINICORE_SRC:-${MONOREPO_ROOT}/InfiniCore}"
INFINILM_SRC="${INFINILM_SRC:-${MONOREPO_ROOT}/InfiniLM}"
CONTAINER_NAME="${CONTAINER_NAME:-infinilm-update-ai3107-$(date +%s)}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260622}"

usage() {
  cat <<EOF
Usage: $0 --source-image IMAGE [--tag NEW_TAG] [--infinicore-src PATH] [--infinilm-src PATH]

Rebuild InfiniCore + InfiniLM in a container from an existing committed image, then docker commit.

Options:
  --source-image IMAGE   Existing runtime image (required)
  --tag TAG              Output image tag (default: auto from git SHAs)
  --infinicore-src PATH  InfiniCore source tree
  --infinilm-src PATH    InfiniLM source tree
  -h, --help             Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-image) SOURCE_IMAGE="$2"; shift 2 ;;
    --tag) NEW_TAG="$2"; shift 2 ;;
    --infinicore-src) INFINICORE_SRC="$2"; shift 2 ;;
    --infinilm-src) INFINILM_SRC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "${SOURCE_IMAGE}" ]]; then
  if [[ -f "${SCRIPT_DIR}/.image_tag" ]]; then
    SOURCE_IMAGE="$(cat "${SCRIPT_DIR}/.image_tag")"
  else
    echo "error: --source-image required (or .image_tag present)" >&2
    exit 1
  fi
fi

if git -C "${INFINILM_SRC}" rev-parse --short HEAD >/dev/null 2>&1; then
  IL_SHA="$(git -C "${INFINILM_SRC}" rev-parse --short HEAD)"
  IC_SHA="$(git -C "${INFINICORE_SRC}" rev-parse --short HEAD)"
  IO_SHA="$(git -C "${MONOREPO_ROOT}/InfiniOrchestrator" rev-parse --short HEAD 2>/dev/null || echo unknown)"
else
  IL_SHA="${IL_SHA:-unknown}"
  IC_SHA="${IC_SHA:-unknown}"
  IO_SHA="${IO_SHA:-unknown}"
fi
BUILD_TS="$(date -u +%Y%m%d)"
NEW_TAG="${NEW_TAG:-infinilm-svc:metax-hpcc-ai3107-${IL_SHA}-${IC_SHA}-${BUILD_TS}}"

echo "Source image: ${SOURCE_IMAGE}"
echo "Output tag:   ${NEW_TAG}"
echo "Container:    ${CONTAINER_NAME}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker create \
  --name "${CONTAINER_NAME}" \
  --network host \
  --workdir /app \
  --entrypoint /bin/bash \
  "${SOURCE_IMAGE}" \
  -c "sleep infinity"

docker cp "${INFINICORE_SRC}/." "${CONTAINER_NAME}:/workspace/InfiniCore/"
docker cp "${INFINILM_SRC}/." "${CONTAINER_NAME}:/workspace/InfiniLM/"
docker cp "${SCRIPT_DIR}/setup-in-container.sh" "${CONTAINER_NAME}:/app/setup-in-container.sh"

docker start "${CONTAINER_NAME}"
sleep 2

_run_update() {
  local -a _proxy_args=()
  if should_use_proxy; then
    proxy_env_args _proxy_args
  fi
  docker exec "${_proxy_args[@]}" "${CONTAINER_NAME}" bash -lc \
    'SKIP_RUST=true /app/setup-in-container.sh'
}

if ! _run_update; then
  if [[ "${USE_PROXY:-}" != "1" ]]; then
    echo "Update failed without proxy; retrying with ${DEFAULT_PROXY}..."
    USE_PROXY=1 _run_update || exit 1
  else
    exit 1
  fi
fi

docker commit \
  --change 'WORKDIR /app' \
  --change 'ENTRYPOINT ["/bin/bash", "/app/docker_entrypoint.sh"]' \
  --change "ENV IL_SHA=${IL_SHA}" \
  --change "ENV IC_SHA=${IC_SHA}" \
  --change "ENV IO_SHA=${IO_SHA}" \
  --change "ENV BUILD_TS=${BUILD_TS}" \
  --change "ENV IMAGE_TAG=${NEW_TAG}" \
  "${CONTAINER_NAME}" \
  "${NEW_TAG}"

docker rm -f "${CONTAINER_NAME}" >/dev/null

echo "${NEW_TAG}" > "${SCRIPT_DIR}/.image_tag"
cat > "${SCRIPT_DIR}/MANIFEST" <<EOF
IL_SHA=${IL_SHA}
IC_SHA=${IC_SHA}
IO_SHA=${IO_SHA}
BUILD_TS=${BUILD_TS}
SOURCE_IMAGE=${SOURCE_IMAGE}
IMAGE_TAG=${NEW_TAG}
DEPLOYMENT_CASE=${DEPLOYMENT_CASE}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "Updated image: ${NEW_TAG}"
