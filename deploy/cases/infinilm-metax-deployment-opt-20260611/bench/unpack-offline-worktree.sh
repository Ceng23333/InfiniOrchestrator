#!/usr/bin/env bash
# Unpack deployment-src-*.tar.gz into a fresh OFFLINE_ROOT and run sanity checks.
set -euo pipefail

OFFLINE_ROOT="${OFFLINE_ROOT:-/opt/offline/infinilm-metax-20260611}"
SRC_TAR="${SRC_TAR:-}"

if [[ -z "${SRC_TAR}" ]]; then
  echo "error: set SRC_TAR=/path/to/deployment-src-*.tar.gz" >&2
  exit 1
fi
if [[ ! -f "${SRC_TAR}" ]]; then
  echo "error: SRC_TAR not found: ${SRC_TAR}" >&2
  exit 1
fi

CASE_NAME="infinilm-metax-deployment-opt-20260611"
BASE_IMAGE="${BASE_IMAGE:-infinilm-svc:metax-hpcc-1004_218-202602281209}"

echo "OFFLINE_ROOT=${OFFLINE_ROOT}"
echo "SRC_TAR=${SRC_TAR}"

rm -rf "${OFFLINE_ROOT}"
mkdir -p "${OFFLINE_ROOT}"
tar -xzf "${SRC_TAR}" -C "${OFFLINE_ROOT}"

MANIFEST="${OFFLINE_ROOT}/MANIFEST"
if [[ ! -f "${MANIFEST}" ]]; then
  echo "error: MANIFEST missing after unpack: ${MANIFEST}" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "${MANIFEST}"
set +a

echo "WORKSPACE=${OFFLINE_ROOT}"
echo "IL_SHA=${IL_SHA:-?} IC_SHA=${IC_SHA:-?} IO_SHA=${IO_SHA:-?}"
echo "PACK_DATE=${PACK_DATE:-?} CASE=${CASE:-?}"

echo ""
echo "Sanity checks:"
grep -n 'gc.collect' "${OFFLINE_ROOT}/InfiniLM/python/infinilm/modeling_utils.py"
test -f "${OFFLINE_ROOT}/InfiniOrchestrator/deploy/cases/${CASE_NAME}/validate.sh"
test -f "${OFFLINE_ROOT}/InfiniOrchestrator/container/metax/build-image.sh"

if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qF "${BASE_IMAGE}"; then
  echo "Base image present: ${BASE_IMAGE}"
else
  echo "warning: base image not loaded: ${BASE_IMAGE}" >&2
  echo "  Load with: gunzip -c /path/to/infinilm-svc-metax-hpcc-base.tar.gz | docker load" >&2
fi

echo ""
echo "Unpack OK. Set WORKSPACE=${OFFLINE_ROOT} and continue with Phase 1 in OFFLINE_DEPLOY_GUIDE_ZH_CN.md."
