#!/usr/bin/env bash
# Phase 1.5 stub: install ONLY from repo-specified wheelhouse + cargo vendor.
# No network to PyPI / crates.io. See docs/IMAGE_BUILD_PHASES.md and offline-deps/README.md
set -euo pipefail

OFFLINE_DEPS_ROOT="${OFFLINE_DEPS_ROOT:-/offline-deps}"

echo "=========================================="
echo "setup-phase1_5-offline-deps.sh (STUB)"
echo "=========================================="
echo "OFFLINE_DEPS_ROOT=${OFFLINE_DEPS_ROOT}"

if [[ ! -d "${OFFLINE_DEPS_ROOT}" ]]; then
  echo "error: missing ${OFFLINE_DEPS_ROOT}" >&2
  exit 1
fi

# Expected layout (document + enforce when IMPLEMENT_PHASE1_5=1):
#   ${OFFLINE_DEPS_ROOT}/pip/wheels/ + requirements.lock
#   ${OFFLINE_DEPS_ROOT}/cargo/vendor/ + .cargo/config.toml

if [[ "${IMPLEMENT_PHASE1_5:-0}" != "1" ]]; then
  echo "Stub: listing offline-deps tree only."
  find "${OFFLINE_DEPS_ROOT}" -maxdepth 3 -type d 2>/dev/null | head -50 || true
  echo "Set IMPLEMENT_PHASE1_5=1 after locks/vendor are populated."
  exit 0
fi

if [[ -f /opt/conda/etc/profile.d/conda.sh ]]; then
  # shellcheck source=/dev/null
  source /opt/conda/etc/profile.d/conda.sh
  conda activate base
fi
# shellcheck source=/dev/null
[[ -f /app/env-set.sh ]] && source /app/env-set.sh

if [[ -d "${OFFLINE_DEPS_ROOT}/pip/wheels" ]]; then
  echo "[phase1.5] pip install --no-index from wheelhouse..."
  REQ="${OFFLINE_DEPS_ROOT}/pip/requirements.lock"
  if [[ -f "${REQ}" ]]; then
    pip install --no-index --find-links="${OFFLINE_DEPS_ROOT}/pip/wheels" -r "${REQ}"
  else
    pip install --no-index --find-links="${OFFLINE_DEPS_ROOT}/pip/wheels" \
      "$(ls "${OFFLINE_DEPS_ROOT}/pip/wheels"/*.whl 2>/dev/null | head -1 || true)" || true
  fi
fi

if [[ -d "${OFFLINE_DEPS_ROOT}/cargo/vendor" ]]; then
  echo "[phase1.5] cargo offline install from vendor (placeholder — wire crate roots)..."
  mkdir -p /app/.cargo
  if [[ -f "${OFFLINE_DEPS_ROOT}/cargo/config.toml" ]]; then
    cp "${OFFLINE_DEPS_ROOT}/cargo/config.toml" /app/.cargo/config.toml
  fi
  # Example: cd /app && cargo build --offline --release
  echo "[phase1.5] TODO: cargo build --offline against vendored crates"
fi

echo "setup-phase1_5-offline-deps.sh complete"
