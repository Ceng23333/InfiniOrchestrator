#!/usr/bin/env bash
# Export offline bundle: runtime-base / deps-base / product + MANIFEST + case config.
# Phase 1 minimum: saves RUNTIME_BASE_TAG from .runtime_base_tag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING="${STAGING:-${SCRIPT_DIR}/../offline-bundle-20260714-$(date -u +%Y%m%d)}"
mkdir -p "${STAGING}"

TAGS=()
if [[ -f "${SCRIPT_DIR}/.runtime_base_tag" ]]; then
  TAGS+=("$(cat "${SCRIPT_DIR}/.runtime_base_tag")")
fi
if [[ -f "${SCRIPT_DIR}/.runtime_base_deps_tag" ]]; then
  TAGS+=("$(cat "${SCRIPT_DIR}/.runtime_base_deps_tag")")
fi
if [[ -f "${SCRIPT_DIR}/.image_tag" ]]; then
  TAGS+=("$(cat "${SCRIPT_DIR}/.image_tag")")
fi
if [[ -n "${IMAGE_TAG:-}" ]]; then
  TAGS+=("${IMAGE_TAG}")
fi
if [[ -n "${RUNTIME_BASE_TAG:-}" ]]; then
  TAGS+=("${RUNTIME_BASE_TAG}")
fi

if [[ ${#TAGS[@]} -eq 0 ]]; then
  echo "error: no .runtime_base_tag / .image_tag; run Phase 1 (or set RUNTIME_BASE_TAG)" >&2
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

CONFIG_TAR="${STAGING}/deploy-case-20260714-config.tar.gz"
echo "Exporting case config → ${CONFIG_TAR}"
tar -C "${SCRIPT_DIR}" -czf "${CONFIG_TAR}" \
  --exclude='.env' \
  --exclude='offline-bundle-*' \
  --exclude='bench/ceval_cache/**' \
  docker-compose.yml config embeddings_server.py validate.sh \
  .env.example .env.master.example .env.slave.example .env.slave-sim.example \
  README.md \
  build-image-phase1.sh build-image-phase1_5.sh build-image-phase2.sh \
  setup-phase1-deps.sh setup-phase1_5-offline-deps.sh setup-phase2-worktree.sh \
  env-set.sh install.defaults.sh proxy-env.sh export-bundle.sh \
  offline-deps/README.md \
  bench \
  MANIFEST .runtime_base_tag .runtime_base_deps_tag .image_tag 2>/dev/null || \
tar -C "${SCRIPT_DIR}" -czf "${CONFIG_TAR}" \
  docker-compose.yml config embeddings_server.py validate.sh \
  .env.example build-image-phase1.sh setup-phase1-deps.sh env-set.sh

if [[ -f "${SCRIPT_DIR}/MANIFEST" ]]; then
  cp "${SCRIPT_DIR}/MANIFEST" "${STAGING}/MANIFEST"
else
  cat > "${STAGING}/MANIFEST" <<EOF
PACK_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TAGS=$(IFS=,; echo "${TAGS[*]}")
EOF
fi

echo ""
echo "Bundle written to ${STAGING}/"
ls -lh "${STAGING}/"
