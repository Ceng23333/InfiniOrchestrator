#!/usr/bin/env bash
# Unpack deployment-src-*.tar.gz into a fresh OFFLINE_ROOT and run sanity checks.
# Expects archive layout: InfiniOrchestrator/worktree/{InfiniCore,InfiniLM,...}
set -euo pipefail

OFFLINE_ROOT="${OFFLINE_ROOT:-/opt/offline/infinilm-metax-20260714}"
SRC_TAR="${SRC_TAR:-}"

if [[ -z "${SRC_TAR}" ]]; then
  echo "error: set SRC_TAR=/path/to/deployment-src-*.tar.gz" >&2
  exit 1
fi
if [[ ! -f "${SRC_TAR}" ]]; then
  echo "error: SRC_TAR not found: ${SRC_TAR}" >&2
  exit 1
fi

CASE_NAME="infinilm-metax-deployment-opt-20260714"
BASE_IMAGE="${BASE_IMAGE:-infinilm-svc:metax-hpcc-1004_218-202602281209}"

echo "OFFLINE_ROOT=${OFFLINE_ROOT}"
echo "SRC_TAR=${SRC_TAR}"

rm -rf "${OFFLINE_ROOT}"
mkdir -p "${OFFLINE_ROOT}"
tar -xzf "${SRC_TAR}" -C "${OFFLINE_ROOT}"

IO_ROOT="${OFFLINE_ROOT}/InfiniOrchestrator"
WORKTREE_ROOT="${IO_ROOT}/worktree"
MANIFEST="${IO_ROOT}/MANIFEST"
if [[ ! -f "${MANIFEST}" ]]; then
  # Older packs wrote MANIFEST at archive root
  if [[ -f "${OFFLINE_ROOT}/MANIFEST" ]]; then
    MANIFEST="${OFFLINE_ROOT}/MANIFEST"
  else
    echo "error: MANIFEST missing after unpack under ${IO_ROOT} or ${OFFLINE_ROOT}" >&2
    exit 1
  fi
fi

set -a
# shellcheck source=/dev/null
source "${MANIFEST}"
set +a

echo "IO_ROOT=${IO_ROOT}"
echo "WORKTREE_ROOT=${WORKTREE_ROOT}"
echo "IL_SHA=${IL_SHA:-?} IC_SHA=${IC_SHA:-?} IO_SHA=${IO_SHA:-?}"
echo "IM_SHA=${IM_SHA:-?} BW_SHA=${BW_SHA:-?}"
echo "PACK_DATE=${PACK_DATE:-?} CASE=${CASE:-?}"

echo ""
echo "Sanity checks:"
grep -n 'gc.collect' "${WORKTREE_ROOT}/InfiniLM/python/infinilm/modeling_utils.py"
test -f "${IO_ROOT}/deploy/cases/${CASE_NAME}/validate.sh"
test -f "${IO_ROOT}/deploy/cases/${CASE_NAME}/build-image-phase1.sh"
test -d "${WORKTREE_ROOT}/InfiniCore"
test -d "${WORKTREE_ROOT}/InfiniLM"

if docker images --format '{{.Repository}}:{{.Tag}}' | grep -qF "${BASE_IMAGE}"; then
  echo "Base image present: ${BASE_IMAGE}"
else
  echo "warning: base image not loaded: ${BASE_IMAGE}" >&2
  echo "  Load with: gunzip -c /path/to/infinilm-svc-metax-hpcc-base.tar.gz | docker load" >&2
fi

echo ""
echo "Unpack OK. Set:"
echo "  export IO_ROOT=${IO_ROOT}"
echo "  export WORKTREE_ROOT=${WORKTREE_ROOT}"
echo "  source \${IO_ROOT}/scripts/worktree_env.sh"
echo "Continue with Phase 1 in OFFLINE_DEPLOY_GUIDE_ZH_CN.md."
