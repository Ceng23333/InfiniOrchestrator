#!/usr/bin/env bash
# Phase 1 FROM vendor BASE for Standalone 9g --refactor (expected xmake fail).
# BASE_IMAGE_ID pin: 1a3cbde5ff2a. Does NOT overwrite deploy runtime-base-20260813.
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${IMAGE_DIR}/.." && pwd)"
# shellcheck source=../../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"
export SVC_ROOT="${IO_ROOT}"

CASE_ID="$(basename "${CASE_DIR}")"
BASE_IMAGE_ID_PIN="1a3cbde5ff2a"
BASE_IMAGE="mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64"
ITW_TAG="v2026.08.18-refactor"
IC_SHA_PIN="2a83578bff5ea84bc1ee9b20e371eb34f3f7128e"
IL_SHA_PIN="9439ea601614f7f78b63bd47314fc52f07eaea96"
SOURCE_ROOT="${SOURCE_ROOT:-/root/zenghua/workspace/profiling_20260731/InfiniTensorWorktree}"
DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-9g-standalone-refactor}"
SKIP_PHASE1="${SKIP_PHASE1:-0}"
FORCE_XMAKE_BUILD="${FORCE_XMAKE_BUILD:-true}"
RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-refactor-20260818}"
FROM_TAG="${FROM_TAG:-${RUNTIME_BASE_TAG}}"
DEPLOY_RUNTIME_BASE_TAG="infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-20260813"
export CASE_ID SOURCE_ROOT DEPLOYMENT_CASE FROM_TAG RUNTIME_BASE_TAG FORCE_XMAKE_BUILD
export IC_SHA_PIN IL_SHA_PIN

if [[ "${RUNTIME_BASE_TAG}" == "${DEPLOY_RUNTIME_BASE_TAG}" ]]; then
  echo "error: refusing to overwrite deploy runtime-base ${DEPLOY_RUNTIME_BASE_TAG}" >&2
  exit 1
fi

PHASE1_LOG="${IMAGE_DIR}/phase1-from-base.log"
if [[ -f "${IMAGE_DIR}/build-image-phase1.sh" && "${SKIP_PHASE1}" != "1" ]]; then
  echo "Phase 1 FROM BASE ${BASE_IMAGE_ID_PIN} (FORCE_XMAKE_BUILD=${FORCE_XMAKE_BUILD})"
  echo "  SOURCE_ROOT=${SOURCE_ROOT}"
  echo "  RUNTIME_BASE_TAG=${RUNTIME_BASE_TAG}"
  echo "  (refactor InfiniCore has no traditional xmake.lua; expect hard fail)"
  set +e
  BASE_IMAGE="${BASE_IMAGE}" \
    RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG}" \
    FORCE_XMAKE_BUILD="${FORCE_XMAKE_BUILD}" \
    SOURCE_ROOT="${SOURCE_ROOT}" \
    DEPLOYMENT_CASE="${DEPLOYMENT_CASE}" \
    IC_SHA_PIN="${IC_SHA_PIN}" \
    IL_SHA_PIN="${IL_SHA_PIN}" \
    "${IMAGE_DIR}/build-image-phase1.sh" 2>&1 | tee "${PHASE1_LOG}"
  p1_rc=${PIPESTATUS[0]}
  set -e
  if [[ ${p1_rc} -ne 0 ]]; then
    echo "Phase 1 failed (rc=${p1_rc}); writing BLOCKED_LAUNCH.md and skipping Phase 2"
    _tail="$(tail -n 80 "${PHASE1_LOG}" 2>/dev/null || true)"
    cat > "${CASE_DIR}/BLOCKED_LAUNCH.md" <<EOF
# BLOCKED_LAUNCH --refactor

ITW \`${ITW_TAG}\` (InfiniCore \`refactor/component-manifest\` \`${IC_SHA_PIN:0:8}\`, InfiniLM \`refactor/adopt-modern-infini-stack\` \`${IL_SHA_PIN:0:8}\`) cannot launch 9g on MetaX.

Phase 1 FROM vendor BASE \`${BASE_IMAGE_ID_PIN}\` with seeded xmake + \`FORCE_XMAKE_BUILD=true\` failed (rc=${p1_rc}). InfiniCore on this pin is an InfiniRT/InfiniOps/InfiniCCL submodule manifest — **no** traditional \`xmake.lua\` / MetaX InfiniCore. InfiniLM \`adopt-modern-infini-stack\` wants \`build_infini_stack.py --cuda-arch sm_80\` (NVIDIA) and only instantiates \`qwen3\`. NVIDIA stack was not attempted.

Runtime-base tag (not committed on fail): \`${RUNTIME_BASE_TAG}\`
SOURCE_ROOT: \`${SOURCE_ROOT}\`
Phase 1 log: \`${PHASE1_LOG}\`

## Hard fail (tail)

\`\`\`
${_tail}
\`\`\`

Campaign LongBench for this qualifier is **skipped**.
EOF
    echo "Wrote ${CASE_DIR}/BLOCKED_LAUNCH.md"
    exit 0
  fi
  FROM_TAG="$(cat "${IMAGE_DIR}/.runtime_base_tag")"
  export FROM_TAG
elif ! docker image inspect "${FROM_TAG}" >/dev/null 2>&1; then
  echo "error: runtime-base missing: ${FROM_TAG}; run Phase 1 first (SKIP_PHASE1=0)" >&2
  exit 1
fi

BUILD_TS="$(date -u +%Y%m%d)"
IMAGE_TAG="${IMAGE_TAG:-infini-orchestrator-metax:9g-refactor-${BUILD_TS}}"
export IMAGE_TAG

echo "=========================================="
echo "Standalone --refactor Phase 2"
echo "  FROM_TAG=${FROM_TAG}"
echo "  SOURCE_ROOT=${SOURCE_ROOT}"
echo "  IMAGE_TAG=${IMAGE_TAG}"
echo "  ITW_TAG=${ITW_TAG}"
echo "=========================================="

"${IMAGE_DIR}/build-image-phase2.sh"

if [[ -f "${IMAGE_DIR}/MANIFEST" ]]; then
  sed -i \
    -e "s|^CASE_ID=.*|CASE_ID=${CASE_ID}|" \
    -e "s|^ITW_TAG=.*|ITW_TAG=${ITW_TAG}|" \
    -e "s|^BASE_IMAGE=.*|BASE_IMAGE=mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64|" \
    -e "s|^BASE_IMAGE_ID=.*|BASE_IMAGE_ID=1a3cbde5ff2a|" \
    -e "s|^DEPLOYMENT_CASE=.*|DEPLOYMENT_CASE=${DEPLOYMENT_CASE}|" \
    -e "s|^IL_SHA=.*|IL_SHA=${IL_SHA_PIN}|" \
    -e "s|^IC_SHA=.*|IC_SHA=${IC_SHA_PIN}|" \
    "${IMAGE_DIR}/MANIFEST"
fi
echo "${ITW_TAG}" > "${IMAGE_DIR}/.worktree_tag"
echo "Wrote ${IMAGE_DIR}/MANIFEST"
