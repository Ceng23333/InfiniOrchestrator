#!/usr/bin/env bash
# Run inside the build container (docker exec) before docker commit.
# Installs Rust orchestration binaries + InfiniCore/InfiniLM native extensions.
set -euo pipefail

DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260622}"
SKIP_RUST="${SKIP_RUST:-false}"
SKIP_INFINICORE_INFINILM="${SKIP_INFINICORE_INFINILM:-false}"

echo "=========================================="
echo "setup-in-container.sh (${DEPLOYMENT_CASE})"
echo "=========================================="

# Case env (HPCC paths, flash-attn, includes)
if [[ -f /opt/conda/etc/profile.d/conda.sh ]]; then
  # shellcheck source=/dev/null
  source /opt/conda/etc/profile.d/conda.sh
  conda activate base
fi
if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env"
fi
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

# Use proxy only when explicitly requested and reachable (host network build containers).
_apply_proxy_if_available() {
  local proxy="${HTTP_PROXY:-${DEFAULT_PROXY:-http://127.0.0.1:57890}}"
  if [[ "${USE_PROXY:-}" == "1" || "${USE_PROXY:-}" == "true" ]]; then
    if curl -fsS --connect-timeout 3 --proxy "${proxy}" https://github.com >/dev/null 2>&1; then
      export HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}"
      export http_proxy="${proxy}" https_proxy="${proxy}"
      echo "[setup] using proxy ${proxy}"
      return 0
    fi
    echo "[setup] USE_PROXY set but ${proxy} unreachable; continuing without proxy" >&2
  fi
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy || true
}
_apply_proxy_if_available

if [[ -f /app/env-set.sh ]]; then
  # shellcheck source=/dev/null
  source /app/env-set.sh
fi

# Symlinks expected by babysitter TOMLs
mkdir -p /workspace
ln -sfn /workspace/InfiniCore /InfiniCore 2>/dev/null || true
ln -sfn /workspace/InfiniLM /InfiniLM 2>/dev/null || true
[[ -e /workspace/InfiniCore ]] || ln -sfn /InfiniCore /workspace/InfiniCore 2>/dev/null || true
[[ -e /workspace/InfiniLM ]] || ln -sfn /InfiniLM /workspace/InfiniLM 2>/dev/null || true

mkdir -p /InfiniCore/python/infinicore/lib /InfiniLM/python/infinilm/lib

cd /app

if [[ "${SKIP_RUST}" != "true" ]]; then
  echo "[setup] Installing InfiniLM-SVC (Rust + deps)..."
  ./scripts/install.sh \
    --install-path /usr/local/bin \
    --deployment-case "${DEPLOYMENT_CASE}" \
    --install-infinicore false \
    --install-infinilm false \
    --infinicore-src /workspace/InfiniCore \
    --infinilm-src /workspace/InfiniLM
fi

if [[ "${SKIP_INFINICORE_INFINILM}" != "true" ]]; then
  echo "[setup] Installing xmake build deps (boost, libffi)..."
  if command -v yum >/dev/null 2>&1; then
    yum install -y boost-devel libffi-devel >/dev/null 2>&1 || \
      yum install -y boost-devel libffi-devel || true
  fi

  _has_prebuilt=false
  if ls /workspace/InfiniCore/python/infinicore/lib/_infinicore*.so >/dev/null 2>&1 && \
     ls /workspace/InfiniLM/python/infinilm/lib/_infinilm*.so >/dev/null 2>&1; then
    _has_prebuilt=true
    echo "[setup] Found prebuilt native extensions in source tree; staging runtime paths..."
    cp -a /workspace/InfiniCore/python/infinicore/lib/* /InfiniCore/python/infinicore/lib/
    cp -a /workspace/InfiniLM/python/infinilm/lib/* /InfiniLM/python/infinilm/lib/
    mkdir -p /root/.infini/lib
    for _lib in libinfinicore_cpp_api.so libinfiniop.so libinfinirt.so libinfiniccl.so; do
      if [[ -f "/workspace/InfiniCore/python/infinicore/lib/${_lib}" ]]; then
        cp -a "/workspace/InfiniCore/python/infinicore/lib/${_lib}" /root/.infini/lib/ 2>/dev/null || true
      fi
    done
    # Headers from xmake install tree if present
    if [[ -d /workspace/InfiniCore/build/.pkg/infinicore/include ]]; then
      mkdir -p /root/.infini/include
      cp -a /workspace/InfiniCore/build/.pkg/infinicore/include/* /root/.infini/include/ 2>/dev/null || true
    fi
  fi

  if [[ "${FORCE_XMAKE_BUILD:-false}" == "true" || "${_has_prebuilt}" != "true" ]]; then
  echo "[setup] Building InfiniCore (PRD-03 flags)..."
  cd /workspace/InfiniCore
  xmake f --metax-gpu=y --aten=y --flash-attn=. --graph=y --ccl=y -y -cv
  xmake build
  xmake install
  xmake build _infinicore
  xmake install _infinicore
  mkdir -p /InfiniCore/python/infinicore/lib
  cp -a /workspace/InfiniCore/python/infinicore/lib/* /InfiniCore/python/infinicore/lib/ 2>/dev/null || true

  echo "[setup] Building InfiniLM..."
  cd /workspace/InfiniLM
  xmake build _infinilm
  xmake install _infinilm
  mkdir -p /InfiniLM/python/infinilm/lib
  cp -a /workspace/InfiniLM/python/infinilm/lib/* /InfiniLM/python/infinilm/lib/ 2>/dev/null || true
  fi
fi

# Ensure entrypoint is in place
if [[ ! -f /app/docker_entrypoint.sh && -f /app/docker/docker_entrypoint_rust.sh ]]; then
  cp /app/docker/docker_entrypoint_rust.sh /app/docker_entrypoint.sh
  chmod +x /app/docker_entrypoint.sh
fi
chmod +x /app/script/*.sh 2>/dev/null || true

echo "[setup] Gate 0 smoke checks..."
command -v infini-registry
command -v infini-router
command -v infini-babysitter
# shellcheck source=/dev/null
source /app/env-set.sh
export PYTHONPATH="/workspace/InfiniLM/python:/workspace/InfiniCore/python:${PYTHONPATH:-}"
ls /InfiniCore/python/infinicore/lib/_infinicore*.so
ls /InfiniLM/python/infinilm/lib/_infinilm*.so
grep -c 'gc.collect' /workspace/InfiniLM/python/infinilm/modeling_utils.py
if [[ -e /dev/dri/card0 || -e /dev/htcd ]]; then
  python3 -c "import infinicore, infinilm; print('imports OK')"
else
  echo "Skipping python GPU import (no GPU devices in build container)"
fi

echo "=========================================="
echo "setup-in-container.sh complete"
echo "=========================================="
