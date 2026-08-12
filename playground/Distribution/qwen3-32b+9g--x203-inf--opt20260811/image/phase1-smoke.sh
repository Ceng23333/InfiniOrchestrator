#!/usr/bin/env bash
# Disposable Phase 1 runtime-base smoke (no external pulls).
# Usage: ./phase1-smoke.sh [RUNTIME_BASE_TAG]
# Case: infinilm-metax-deployment-opt-20260811 (InfiniLM master-only; BASE_IMAGE pin 1a3cbde5ff2a)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${SCRIPT_DIR}"
if [[ -n "${1:-}" ]]; then
  RUNTIME_BASE_TAG="$1"
elif [[ -f "${IMAGE_DIR}/.runtime_base_tag" ]]; then
  RUNTIME_BASE_TAG="$(cat "${IMAGE_DIR}/.runtime_base_tag")"
else
  echo "error: pass RUNTIME_BASE_TAG or run build-image-phase1.sh first" >&2
  exit 1
fi

echo "Phase 1 smoke: ${RUNTIME_BASE_TAG}"
docker run --rm --privileged --ipc=host --network host \
  --device /dev/dri --device /dev/htcd \
  --entrypoint /bin/bash "${RUNTIME_BASE_TAG}" -lc '
  set -e
  source /opt/conda/etc/profile.d/conda.sh && conda activate base
  source /app/env-set.sh
  command -v infini-entrypoint
  command -v infini-loadbalancer
  command -v infini-babysitter
  test -x /app/docker_entrypoint.sh
  test -d /workspace/piecewise_inductor_cache
  test -f /opt/hpcc/Version.txt
  head -1 /opt/hpcc/Version.txt
  # os._exit avoids HPCC destructor double-free after successful import
  python3 - <<PY
import infinicore, infinilm
print("imports OK", flush=True)
import os
os._exit(0)
PY
  echo SMOKE_PASS
'
