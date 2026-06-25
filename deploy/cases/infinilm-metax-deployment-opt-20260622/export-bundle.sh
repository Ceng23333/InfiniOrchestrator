#!/usr/bin/env bash
# Export offline delivery bundle (runtime image tar + case config tar + MANIFEST).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING="${STAGING:-${SCRIPT_DIR}/../offline-bundle-$(date -u +%Y%m%d)}"
mkdir -p "${STAGING}"

if [[ -f "${SCRIPT_DIR}/.image_tag" ]]; then
  IMAGE_TAG="$(cat "${SCRIPT_DIR}/.image_tag")"
else
  IMAGE_TAG="${IMAGE_TAG:-}"
fi

if [[ -z "${IMAGE_TAG}" ]]; then
  echo "error: set IMAGE_TAG or run build-image.sh first (.image_tag missing)" >&2
  exit 1
fi

if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "error: image not found locally: ${IMAGE_TAG}" >&2
  exit 1
fi

SAFE_TAG="${IMAGE_TAG//[:\/]/_}"
RUNTIME_TAR="${STAGING}/infinilm-svc-runtime-${SAFE_TAG}.tar.gz"
CONFIG_TAR="${STAGING}/deploy-case-20260622-config.tar.gz"

echo "Exporting runtime image: ${IMAGE_TAG}"
docker save "${IMAGE_TAG}" | gzip > "${RUNTIME_TAR}"

echo "Exporting case config..."
tar -C "${SCRIPT_DIR}" -czf "${CONFIG_TAR}" \
  --exclude='.env' \
  --exclude='.image_tag' \
  --exclude='MANIFEST' \
  --exclude='offline-bundle-*' \
  docker-compose.yml config embeddings_server.py validate.sh \
  .env.example README.md OFFLINE_DEPLOY_GUIDE_ZH_CN.md BUILD_GUIDE.md \
  build-image.sh update-codebase.sh export-bundle.sh setup-in-container.sh \
  env-set.sh install.defaults.sh Dockerfile 2>/dev/null || \
tar -C "${SCRIPT_DIR}" -czf "${CONFIG_TAR}" \
  docker-compose.yml config embeddings_server.py validate.sh .env.example \
  build-image.sh update-codebase.sh export-bundle.sh setup-in-container.sh \
  env-set.sh install.defaults.sh Dockerfile

if [[ -f "${SCRIPT_DIR}/MANIFEST" ]]; then
  cp "${SCRIPT_DIR}/MANIFEST" "${STAGING}/MANIFEST"
else
  cat > "${STAGING}/MANIFEST" <<EOF
IMAGE_TAG=${IMAGE_TAG}
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
fi

echo ""
echo "Bundle written to ${STAGING}/"
ls -lh "${STAGING}/"
