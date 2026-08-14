#!/usr/bin/env bash
# Export offline bundle: runtime-base / product image + case config (no AOT cache by default).
# Phase 1 minimum: saves RUNTIME_BASE_TAG from image/.runtime_base_tag
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${CASE_DIR}/image"
COMPOSE_DIR="${CASE_DIR}/docker-compose"
STAGING="${STAGING:-${CASE_DIR}/../offline-bundle-20260811-$(date -u +%Y%m%d)}"
mkdir -p "${STAGING}"

TAGS=()
if [[ -f "${IMAGE_DIR}/.runtime_base_tag" ]]; then
  TAGS+=("$(cat "${IMAGE_DIR}/.runtime_base_tag")")
fi
if [[ -f "${IMAGE_DIR}/.runtime_base_deps_tag" ]]; then
  TAGS+=("$(cat "${IMAGE_DIR}/.runtime_base_deps_tag")")
fi
if [[ -f "${IMAGE_DIR}/.image_tag" ]]; then
  TAGS+=("$(cat "${IMAGE_DIR}/.image_tag")")
fi
if [[ -n "${IMAGE_TAG:-}" ]]; then
  TAGS+=("${IMAGE_TAG}")
fi
if [[ -n "${RUNTIME_BASE_TAG:-}" ]]; then
  TAGS+=("${RUNTIME_BASE_TAG}")
fi

if [[ ${#TAGS[@]} -eq 0 ]]; then
  echo "error: no image/.runtime_base_tag / image/.image_tag; run Phase 1 (or set RUNTIME_BASE_TAG)" >&2
  exit 1
fi

# unique tags
mapfile -t TAGS < <(printf '%s\n' "${TAGS[@]}" | awk '!seen[$0]++')

for tag in "${TAGS[@]}"; do
  if ! docker image inspect "${tag}" >/dev/null 2>&1; then
    echo "error: image not found locally: ${tag}" >&2
    exit 1
  fi
  SAFE_TAG="${tag//[:\/]/_}"
  OUT="${STAGING}/image-${SAFE_TAG}.tar.gz"
  echo "Exporting ${tag} → ${OUT}"
  docker save "${tag}" | gzip > "${OUT}"
done

CONFIG_TAR="${STAGING}/deploy-case-20260811-config.tar.gz"
echo "Exporting case config → ${CONFIG_TAR}"
# Large AOT under cache/piecewise_inductor is excluded (rsync separately if needed).
tar -C "${CASE_DIR}" -czf "${CONFIG_TAR}" \
  --exclude='.env' \
  --exclude='offline-bundle-*' \
  --exclude='cache/piecewise_inductor/**' \
  --exclude='cache/piecewise_inductor/*' \
  case.toml README.md OFFLINE_DEPLOY_GUIDE_ZH_CN.md export-bundle.sh \
  image \
  docker-compose \
  regression \
  k8s \
  cache/README.md \
  2>/dev/null || \
tar -C "${CASE_DIR}" -czf "${CONFIG_TAR}" \
  --exclude='.env' \
  case.toml README.md export-bundle.sh \
  image/build-image-phase1.sh image/build-image-phase2.sh \
  image/setup-phase1-deps.sh image/setup-phase2-worktree.sh \
  image/env-set.sh image/proxy-env.sh image/docker_entrypoint.sh \
  docker-compose/docker-compose.yml docker-compose/config \
  docker-compose/embeddings_server.py docker-compose/validate.sh \
  docker-compose/.env.example docker-compose/.env.frontend.example \
  docker-compose/.env.workers.example docker-compose/.env.workers-sim.example \
  regression/run_longbench.sh

if [[ -f "${IMAGE_DIR}/MANIFEST" ]]; then
  cp "${IMAGE_DIR}/MANIFEST" "${STAGING}/MANIFEST"
else
  cat > "${STAGING}/MANIFEST" <<EOF
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TAGS=$(IFS=,; echo "${TAGS[*]}")
EOF
fi

echo ""
echo "Bundle written to ${STAGING}/"
echo "Note: cache/piecewise_inductor not included; seed via SEED_INDUCTOR_SRC or rsync."
ls -lh "${STAGING}/"
