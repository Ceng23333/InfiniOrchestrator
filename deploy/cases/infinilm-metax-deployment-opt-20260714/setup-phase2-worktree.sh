#!/usr/bin/env bash
# Phase 2 stub: sync worktree + optional rebuild; apply product entrypoint prep.
# See docs/IMAGE_BUILD_PHASES.md
set -euo pipefail

echo "=========================================="
echo "setup-phase2-worktree.sh (STUB)"
echo "=========================================="

if [[ "${IMPLEMENT_PHASE2:-0}" != "1" ]]; then
  echo "Stub only. When enabled:"
  echo "  1. rsync/cp InfiniCore InfiniLM InfiniLM-SVC from host-copied /src"
  echo "  2. optional FORCE_XMAKE_BUILD rebuild"
  echo "  3. ensure /app/docker_entrypoint.sh is product entrypoint"
  echo "  4. ensure /workspace/piecewise_inductor_cache exists"
  exit 0
fi

# shellcheck source=/dev/null
[[ -f /app/env-set.sh ]] && source /app/env-set.sh

SRC="${SOURCE_ROOT_IN_CONTAINER:-/src}"
for d in InfiniCore InfiniLM; do
  if [[ -d "${SRC}/${d}" ]]; then
    mkdir -p "/workspace/${d}"
    cp -a "${SRC}/${d}/." "/workspace/${d}/"
  fi
done
if [[ -d "${SRC}/InfiniLM-SVC" ]]; then
  cp -a "${SRC}/InfiniLM-SVC/." /app/
fi

mkdir -p /workspace/piecewise_inductor_cache
if [[ ! -f /app/docker_entrypoint.sh && -f /app/docker/docker_entrypoint_rust.sh ]]; then
  cp /app/docker/docker_entrypoint_rust.sh /app/docker_entrypoint.sh
  chmod +x /app/docker_entrypoint.sh
fi

echo "setup-phase2-worktree.sh complete"
