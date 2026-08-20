#!/usr/bin/env bash
# In-container layout check after streaming Mars prefix + InfiniLM python.
set -euo pipefail

echo "=========================================="
echo "setup-mars-worktree.sh"
echo "=========================================="

# shellcheck source=/dev/null
[[ -f /app/env-set.sh ]] && source /app/env-set.sh
unset MACA_PATH MACA_HOME MACA_ROOT || true

INFINI_ROOT="${INFINI_ROOT:-/workspace/InfiniLM/build/integration/mars/prefix}"

if [[ ! -d /workspace/InfiniLM/python/infinilm ]]; then
  echo "error: missing /workspace/InfiniLM/python/infinilm" >&2
  exit 1
fi
if [[ ! -d /workspace/InfiniLM/python/infinicore ]]; then
  echo "error: missing /workspace/InfiniLM/python/infinicore (InfiniCore python lives here)" >&2
  exit 1
fi
if [[ ! -f "${INFINI_ROOT}/lib64/libinfinirt.so" && ! -f "${INFINI_ROOT}/lib/libinfinirt.so" ]]; then
  echo "error: missing Mars prefix libinfinirt.so under ${INFINI_ROOT}" >&2
  exit 1
fi
if ! ls /workspace/InfiniLM/python/infinilm/lib/_infinilm*.so >/dev/null 2>&1; then
  echo "error: missing _infinilm extension under /workspace/InfiniLM/python/infinilm/lib" >&2
  exit 1
fi
if ! ls /workspace/InfiniLM/python/infinicore/lib/_infinicore*.so >/dev/null 2>&1; then
  echo "error: missing _infinicore extension under /workspace/InfiniLM/python/infinicore/lib" >&2
  exit 1
fi

mkdir -p /workspace/piecewise_inductor_cache /app/logs /usr/local/bin

if [[ ! -f /app/docker_entrypoint.sh ]]; then
  echo "error: /app/docker_entrypoint.sh missing" >&2
  exit 1
fi
chmod +x /app/docker_entrypoint.sh

if [[ -x /usr/local/bin/infini-entrypoint ]]; then
  ln -sfn /usr/local/bin/infini-entrypoint /usr/local/bin/infini-babysitter
fi
if [[ -x /usr/local/bin/infini-loadbalancer ]]; then
  ln -sfn /usr/local/bin/infini-loadbalancer /usr/local/bin/infini-router
fi
chmod +x /usr/local/bin/infini-* 2>/dev/null || true

# janus is required by InfiniLM schedulers; vendor BASE may not ship it.
if ! python3 -c "import janus" >/dev/null 2>&1; then
  echo "error: janus missing; packaging must copy/install it" >&2
  exit 1
fi

echo "setup-mars-worktree.sh complete"
echo "  INFINI_ROOT=${INFINI_ROOT}"
echo "  PYTHONPATH=${PYTHONPATH:-}"
