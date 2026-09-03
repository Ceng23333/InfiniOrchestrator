#!/usr/bin/env bash
# Full Phase 1 native image (IC+IL xmake, no hot-patch) + Phase 2 product ENTRYPOINT.
#
# Builds from InfiniTensorWorktree-fix-issues-1-2 with FORCE_XMAKE_BUILD=true so
# runtime natives are self-consistent (no dev-container lib overlay).
#
# Usage:
#   ./regression/build-native-p1.sh
#   IMAGE_TAG=infini-orchestrator-metax:94502bf6-6ad5e1c9-20260827-native-p1 ./regression/build-native-p1.sh
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${CASE_DIR}/image"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

SOURCE_ROOT="${SOURCE_ROOT:-/root/zenghua/workspace/profiling_20260731/InfiniTensorWorktree-fix-issues-1-2}"
BUILD_TS="${BUILD_TS:-$(date -u +%Y%m%d)}"
IL_SHA="$(git -C "${SOURCE_ROOT}/InfiniLM" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IC_SHA="$(git -C "${SOURCE_ROOT}/InfiniCore" rev-parse --short HEAD 2>/dev/null || echo unknown)"
TAG_SUFFIX="${TAG_SUFFIX:-native-p1}"

RUNTIME_BASE_TAG="${RUNTIME_BASE_TAG:-infini-orchestrator-metax:${IL_SHA}-${IC_SHA}-${BUILD_TS}-${TAG_SUFFIX}-runtime}"
IMAGE_TAG="${IMAGE_TAG:-infini-orchestrator-metax:${IL_SHA}-${IC_SHA}-${BUILD_TS}-${TAG_SUFFIX}}"

INDUCTOR_SRC="${INDUCTOR_SRC:-${CASE_DIR}/../qwen3-32b+xiyan--x203-inf-disagg--opt20260817/cache/piecewise_inductor}"

echo "=========================================="
echo "Native Phase 1 + Phase 2 build"
echo "  SOURCE_ROOT:      ${SOURCE_ROOT}"
echo "  IL_SHA/IC_SHA:    ${IL_SHA}/${IC_SHA}"
echo "  RUNTIME_BASE_TAG: ${RUNTIME_BASE_TAG}"
echo "  IMAGE_TAG:        ${IMAGE_TAG}"
echo "  INDUCTOR_SRC:     ${INDUCTOR_SRC}"
echo "=========================================="

export SOURCE_ROOT FORCE_XMAKE_BUILD=true PHASE1_GPU=1 SKIP_RUST=true
export SVC_ROOT="${IO_ROOT}"
export RUNTIME_BASE_TAG BUILD_TS
export SEED_INDUCTOR_SRC="${INDUCTOR_SRC}"

echo ""
echo "===== Phase 1: runtime-base (xmake IC+IL) ====="
(
  cd "${CASE_DIR}"
  SVC_ROOT="${IO_ROOT}" ./image/build-image-phase1.sh
)

echo ""
echo "===== Phase 2: product image (docker_entrypoint.sh ENTRYPOINT) ====="
export FROM_TAG="${RUNTIME_BASE_TAG}"
export IMAGE_TAG
(
  cd "${CASE_DIR}"
  SVC_ROOT="${IO_ROOT}" ./image/build-image-phase2.sh
)

echo "${IMAGE_TAG}" > "${IMAGE_DIR}/.image_tag"
echo ""
echo "Built native product image: ${IMAGE_TAG}"
echo "Runtime base: ${RUNTIME_BASE_TAG}"
echo "Next: ./regression/run_dev_ab_mixed_4096.sh"
