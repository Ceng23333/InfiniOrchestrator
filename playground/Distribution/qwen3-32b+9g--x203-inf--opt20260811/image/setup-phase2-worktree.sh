#!/usr/bin/env bash
# Phase 2 in-container setup: ensure worktree layout + product entrypoint.
# InfiniCore/InfiniLM are streamed by build-image-phase2.sh; this script only
# verifies layout and entrypoint prep (no InfiniLM-SVC sync).
set -euo pipefail

echo "=========================================="
echo "setup-phase2-worktree.sh"
echo "=========================================="

# shellcheck source=/dev/null
[[ -f /app/env-set.sh ]] && source /app/env-set.sh

for d in InfiniCore InfiniLM; do
  if [[ ! -d "/workspace/${d}" ]]; then
    echo "error: missing /workspace/${d} (host must stream SOURCE_ROOT before setup)" >&2
    exit 1
  fi
done

mkdir -p /workspace/piecewise_inductor_cache /app/logs /usr/local/bin

if [[ ! -f /app/docker_entrypoint.sh ]]; then
  echo "error: /app/docker_entrypoint.sh missing" >&2
  exit 1
fi
chmod +x /app/docker_entrypoint.sh

# Compat aliases for older launch helpers.
if [[ -x /usr/local/bin/infini-entrypoint ]]; then
  ln -sfn /usr/local/bin/infini-entrypoint /usr/local/bin/infini-babysitter
fi
if [[ -x /usr/local/bin/infini-loadbalancer ]]; then
  ln -sfn /usr/local/bin/infini-loadbalancer /usr/local/bin/infini-router
fi
chmod +x /usr/local/bin/infini-* 2>/dev/null || true

echo "setup-phase2-worktree.sh complete"
