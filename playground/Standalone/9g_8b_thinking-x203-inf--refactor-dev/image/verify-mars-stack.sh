#!/usr/bin/env bash
# Verify (and optionally rebuild) the Mars stack inside infinilm-dev-refactor-dev (GPU1).
# Does not touch GPU0 wraps or product --refactor.
set -euo pipefail

IMAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${IMAGE_DIR}/.." && pwd)"
# shellcheck source=../../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"
# shellcheck source=../../../../scripts/worktree_9g_isolate.sh
source "${IO_ROOT}/scripts/worktree_9g_isolate.sh"

SOURCE_ROOT="${SOURCE_ROOT:-$(worktree_9g_source_root_for refactor-dev)}"
export INFINI_TENSOR_WORKTREE="${SOURCE_ROOT}"
export WORKTREE_ROOT="${SOURCE_ROOT}"
worktree_9g_assert_not_mutating_product_refactor "${CASE_DIR}"
require_worktree_repos InfiniCore InfiniLM

DEV_CTN="${DEV_CTN:-${WORKTREE_9G_GPU1_MARS_CTN}}"
PREFIX="${PREFIX:-${SOURCE_ROOT}/InfiniLM/build/integration/mars/prefix}"
FORCE_MARS_REBUILD="${FORCE_MARS_REBUILD:-0}"

need_rebuild=0
if [[ "${FORCE_MARS_REBUILD}" == "1" || "${FORCE_MARS_REBUILD}" == "true" ]]; then
  need_rebuild=1
fi

check_host_prefix() {
  local ok=1
  [[ -f "${PREFIX}/lib64/libinfinirt.so" || -f "${PREFIX}/lib/libinfinirt.so" ]] || ok=0
  [[ -f "${PREFIX}/lib64/libinfiniops.so" || -f "${PREFIX}/lib/libinfiniops.so" ]] || ok=0
  [[ -f "${PREFIX}/lib64/libinfiniccl.so" || -f "${PREFIX}/lib/libinfiniccl.so" ]] || ok=0
  ls "${SOURCE_ROOT}/InfiniLM/python/infinilm/lib"/_infinilm*.so >/dev/null 2>&1 || ok=0
  ls "${SOURCE_ROOT}/InfiniLM/python/infinicore/lib"/_infinicore*.so >/dev/null 2>&1 || ok=0
  return $((1 - ok))
}

if ! check_host_prefix; then
  echo "Mars prefix/python natives missing under ${SOURCE_ROOT}"
  need_rebuild=1
fi

if [[ ${need_rebuild} -eq 0 ]]; then
  echo "Mars stack OK (prefix + InfiniLM/InfiniCore python natives present)"
  echo "  SOURCE_ROOT=${SOURCE_ROOT}"
  echo "  PREFIX=${PREFIX}"
  ls -l "${PREFIX}/lib64"/libinfini*.so 2>/dev/null || ls -l "${PREFIX}/lib"/libinfini*.so
  ls -l "${SOURCE_ROOT}/InfiniLM/python/infinicore/lib"/_infinicore*.so \
    "${SOURCE_ROOT}/InfiniLM/python/infinilm/lib"/_infinilm*.so
  exit 0
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${DEV_CTN}"; then
  echo "error: ${DEV_CTN} not running; start it with ${SOURCE_ROOT}/scripts/create-dev-container.sh" >&2
  exit 1
fi

echo "Rebuilding Mars stack in ${DEV_CTN} (GPU1)..."
# Free GPU1 from leftover smoke servers; do not stop the container.
"${SOURCE_ROOT}/scripts/stop-inference-server.sh" >/dev/null 2>&1 || true

docker exec \
  -e "HPCC_PATH=/opt/hpcc" \
  -e "HPCC_VISIBLE_DEVICES=1" \
  -e "INFINI_ROOT=/workspace/InfiniLM/build/integration/mars/prefix" \
  -e "XMAKE_ROOT=y" \
  "${DEV_CTN}" bash -lc '
    set -euo pipefail
    unset MACA_PATH MACA_HOME MACA_ROOT || true
    source /workspace/scripts/hpcc-env.sh
    cd /workspace
    ./scripts/build-mars-stack.sh
  '

if ! check_host_prefix; then
  echo "error: Mars rebuild finished but prefix/python natives still missing" >&2
  exit 1
fi
echo "Mars stack rebuilt → ${PREFIX}"
