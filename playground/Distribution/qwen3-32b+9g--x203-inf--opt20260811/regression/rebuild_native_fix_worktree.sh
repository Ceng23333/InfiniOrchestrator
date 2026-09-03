#!/usr/bin/env bash
# Rebuild InfiniCore + InfiniLM native (_infinilm) in infinilm-dev-hpcc37 for fix worktree.
# Prereq: SOURCE_ROOT streams to /workspace/{InfiniCore,InfiniLM} (no vendored csrc/infinicore).
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-/root/zenghua/workspace/profiling_20260731/InfiniTensorWorktree-fix-issues-1-2}"
DEV_CONTAINER="${DEV_CONTAINER:-infinilm-dev-hpcc37}"

echo "Syncing ${SOURCE_ROOT} → ${DEV_CONTAINER}:/workspace/..."
rsync -a --delete --exclude '.git' --exclude 'build' --exclude '.xmake' \
  "${SOURCE_ROOT}/InfiniCore/" /tmp/fix_infinicore_sync/
rsync -a --delete --exclude '.git' --exclude 'build' --exclude '.xmake' \
  "${SOURCE_ROOT}/InfiniLM/" /tmp/fix_infinilm_sync/
# docker cp merges; wipe targets so deleted upstream files do not linger.
docker exec "${DEV_CONTAINER}" bash -lc 'rm -rf /workspace/InfiniCore /workspace/InfiniLM && mkdir -p /workspace/InfiniCore /workspace/InfiniLM'
docker cp /tmp/fix_infinicore_sync/. "${DEV_CONTAINER}:/workspace/InfiniCore/"
docker cp /tmp/fix_infinilm_sync/. "${DEV_CONTAINER}:/workspace/InfiniLM/"

docker cp "${CASE_DIR}/image/env-set.sh" "${DEV_CONTAINER}:/tmp/env-set.sh"

docker exec "${DEV_CONTAINER}" bash -lc "$(cat <<'EOS'
set -euo pipefail
set +u
source /tmp/env-set.sh
set -u
export XMAKE_ROOT=y
export PATH="/root/.local/bin:${PATH}"
export INFINI_ROOT=/root/.infini

rm -rf /workspace/InfiniLM/csrc/infinicore
mkdir -p /root/.infini/include /root/.infini/lib \
  /workspace/InfiniCore/python/infinicore/lib \
  /workspace/InfiniLM/python/infinilm/lib

echo "===== InfiniCore rebuild ====="
cd /workspace/InfiniCore
xmake f --metax-gpu=y --aten=y --flash-attn=. --graph=y --ccl=y -y -cv
xmake build
xmake install
xmake build _infinicore
xmake install _infinicore
for _lib in libinfinicore_cpp_api.so libinfiniop.so libinfinirt.so libinfiniccl.so; do
  [[ -f "/workspace/InfiniCore/python/infinicore/lib/${_lib}" ]] && \
    cp -a "/workspace/InfiniCore/python/infinicore/lib/${_lib}" /root/.infini/lib/
done
if [[ -d /workspace/InfiniCore/build/.pkg/infinicore/include ]]; then
  cp -a /workspace/InfiniCore/build/.pkg/infinicore/include/. /root/.infini/include/
fi

echo "===== InfiniLM rebuild ====="
cd /workspace/InfiniLM
if grep -q "python\.module" xmake.lua && \
   ! grep -q "rule(\"python.module\")" /root/.local/share/xmake/rules/python/xmake.lua 2>/dev/null; then
  sed -i "s/python\.module/python.library/g" xmake.lua
fi
mkdir -p third_party
if [[ ! -f third_party/spdlog/include/spdlog/spdlog.h && \
      -f /workspace/InfiniCore/third_party/spdlog/include/spdlog/spdlog.h ]]; then
  cp -a /workspace/InfiniCore/third_party/spdlog third_party/spdlog
fi
xmake f -y -cv
xmake build _infinilm
xmake install _infinilm
ls -la /workspace/InfiniLM/python/infinilm/lib/_infinilm*.so
grep -n logits_use_per_request_row_index csrc/engine/rank_worker.cpp | head -1
echo "===== REBUILD_OK ====="
EOS
)"
