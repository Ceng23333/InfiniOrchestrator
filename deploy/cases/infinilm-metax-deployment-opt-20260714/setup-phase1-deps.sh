#!/usr/bin/env bash
# Phase 1 first install (run inside build container via docker exec).
# Establishes toolchain + first-cut production stack. Does NOT set product PID 1.
# See docs/IMAGE_BUILD_PHASES.md
set -euo pipefail

DEPLOYMENT_CASE="${DEPLOYMENT_CASE:-infinilm-metax-deployment-opt-20260714}"
SKIP_RUST="${SKIP_RUST:-false}"
SKIP_INFINICORE_INFINILM="${SKIP_INFINICORE_INFINILM:-false}"
SEED_INDUCTOR_CACHE="${SEED_INDUCTOR_CACHE:-1}"

echo "=========================================="
echo "setup-phase1-deps.sh (${DEPLOYMENT_CASE})"
echo "=========================================="

if [[ -f /opt/conda/etc/profile.d/conda.sh ]]; then
  # shellcheck source=/dev/null
  source /opt/conda/etc/profile.d/conda.sh
  conda activate base
fi
if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env"
fi
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:/opt/conda/bin:${PATH}"

_apply_proxy_if_available() {
  local proxy="${HTTP_PROXY:-${DEFAULT_PROXY:-http://127.0.0.1:57890}}"
  if [[ "${USE_PROXY:-}" == "1" || "${USE_PROXY:-}" == "true" ]]; then
    if curl -fsS --connect-timeout 3 --proxy "${proxy}" https://github.com >/dev/null 2>&1; then
      export HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}"
      export http_proxy="${proxy}" https_proxy="${proxy}"
      echo "[phase1] using proxy ${proxy}"
      return 0
    fi
    echo "[phase1] USE_PROXY set but ${proxy} unreachable; continuing without proxy" >&2
  fi
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy || true
}
_apply_proxy_if_available

if [[ -f /app/env-set.sh ]]; then
  # shellcheck source=/dev/null
  source /app/env-set.sh
fi

mkdir -p /workspace /root/.infini/lib /root/.infini/bin /root/.infini/include \
  /workspace/piecewise_inductor_cache \
  /workspace/bench/ceval_cache

# Prefer /workspace trees; expose /InfiniCore and /InfiniLM as symlinks for TOML PYTHONPATH.
if [[ -d /workspace/InfiniCore ]]; then
  rm -rf /InfiniCore 2>/dev/null || true
  ln -sfn /workspace/InfiniCore /InfiniCore
  mkdir -p /InfiniCore/python/infinicore/lib
fi
if [[ -d /workspace/InfiniLM ]]; then
  rm -rf /InfiniLM 2>/dev/null || true
  ln -sfn /workspace/InfiniLM /InfiniLM
  mkdir -p /InfiniLM/python/infinilm/lib
fi

cd /app

if [[ "${SKIP_RUST}" != "true" ]]; then
  if [[ -x /usr/local/bin/infini-registry && -x /usr/local/bin/infini-router && -x /usr/local/bin/infini-babysitter ]]; then
    echo "[phase1] InfiniLM-SVC binaries already present; skipping cargo install"
  elif [[ -f ./scripts/install.sh ]]; then
    echo "[phase1] Installing InfiniLM-SVC (Rust + deps)..."
    ./scripts/install.sh \
      --install-path /usr/local/bin \
      --deployment-case "${DEPLOYMENT_CASE}" \
      --install-infinicore false \
      --install-infinilm false \
      --infinicore-src /workspace/InfiniCore \
      --infinilm-src /workspace/InfiniLM
  else
    echo "[phase1] warning: /app/scripts/install.sh missing and no pre-seeded infini-* binaries" >&2
  fi
fi

if [[ "${SKIP_INFINICORE_INFINILM}" != "true" ]]; then
  echo "[phase1] Installing xmake build deps (boost, libffi) if available..."
  if command -v yum >/dev/null 2>&1; then
    yum install -y boost-devel libffi-devel >/dev/null 2>&1 || \
      yum install -y boost-devel libffi-devel || true
  fi

  _has_prebuilt=false
  if ls /workspace/InfiniCore/python/infinicore/lib/_infinicore*.so >/dev/null 2>&1 && \
     ls /workspace/InfiniLM/python/infinilm/lib/_infinilm*.so >/dev/null 2>&1; then
    _has_prebuilt=true
    echo "[phase1] Staging prebuilt native extensions..."
    mkdir -p /InfiniCore/python/infinicore/lib /InfiniLM/python/infinilm/lib /root/.infini/lib
    cp -a /workspace/InfiniCore/python/infinicore/lib/* /InfiniCore/python/infinicore/lib/ 2>/dev/null || true
    cp -a /workspace/InfiniLM/python/infinilm/lib/* /InfiniLM/python/infinilm/lib/ 2>/dev/null || true
    for _lib in libinfinicore_cpp_api.so libinfiniop.so libinfinirt.so libinfiniccl.so; do
      if [[ -f "/workspace/InfiniCore/python/infinicore/lib/${_lib}" ]]; then
        cp -a "/workspace/InfiniCore/python/infinicore/lib/${_lib}" /root/.infini/lib/ 2>/dev/null || true
      fi
    done
    if [[ -d /workspace/InfiniCore/build/.pkg/infinicore/include ]]; then
      mkdir -p /root/.infini/include
      cp -a /workspace/InfiniCore/build/.pkg/infinicore/include/* /root/.infini/include/ 2>/dev/null || true
    fi
  fi

  if [[ "${FORCE_XMAKE_BUILD:-false}" == "true" || "${_has_prebuilt}" != "true" ]]; then
    if ! command -v xmake >/dev/null 2>&1; then
      echo "[phase1] error: xmake required for rebuild but not installed; seed prebuilt .so or install xmake" >&2
      exit 1
    fi
    echo "[phase1] Building InfiniCore (PRD-03 HPCC flags, no --use-mc)..."
    cd /workspace/InfiniCore
    xmake f --metax-gpu=y --aten=y --flash-attn=. --graph=y --ccl=y -y -cv
    xmake build
    xmake install
    xmake build _infinicore
    xmake install _infinicore
    mkdir -p /InfiniCore/python/infinicore/lib
    cp -a /workspace/InfiniCore/python/infinicore/lib/* /InfiniCore/python/infinicore/lib/ 2>/dev/null || true

    echo "[phase1] Building InfiniLM..."
    cd /workspace/InfiniLM
    xmake build _infinilm
    xmake install _infinilm
    mkdir -p /InfiniLM/python/infinilm/lib
    cp -a /workspace/InfiniLM/python/infinilm/lib/* /InfiniLM/python/infinilm/lib/ 2>/dev/null || true
  fi
fi

# Stage entrypoint for Phase 2; Phase 1 commit keeps sleep/shell CMD.
if [[ ! -f /app/docker_entrypoint.sh && -f /app/docker/docker_entrypoint_rust.sh ]]; then
  cp /app/docker/docker_entrypoint_rust.sh /app/docker_entrypoint.sh
  chmod +x /app/docker_entrypoint.sh
fi
chmod +x /app/script/*.sh 2>/dev/null || true
chmod +x /app/scripts/*.sh 2>/dev/null || true

if [[ "${SEED_INDUCTOR_CACHE}" == "1" ]]; then
  mkdir -p /workspace/piecewise_inductor_cache
  # Optional: copy known-good AOT packages when SEED_INDUCTOR_SRC is set.
  if [[ -n "${SEED_INDUCTOR_SRC:-}" && -d "${SEED_INDUCTOR_SRC}" ]]; then
    echo "[phase1] Seeding inductor cache from ${SEED_INDUCTOR_SRC}"
    cp -a "${SEED_INDUCTOR_SRC}/." /workspace/piecewise_inductor_cache/ || true
  fi
  # Stub README so cold-start path exists in image even before AOT seed.
  if [[ ! -f /workspace/piecewise_inductor_cache/README ]]; then
    cat > /workspace/piecewise_inductor_cache/README <<'EOF'
Piecewise inductor cache (image-local).
Qwen TOML: INFINI_PIECEWISE_INDUCTOR_CACHE=/workspace/piecewise_inductor_cache
COMPILE_ON_MISS=1 allows cold-start compile into this directory.
EOF
  fi
fi

# InfiniLM runtime dep often missing from vendor BASE
if command -v pip >/dev/null 2>&1; then
  pip install -q janus 2>/dev/null || \
    pip install -q -i https://pypi.tuna.tsinghua.edu.cn/simple janus 2>/dev/null || \
    echo "[phase1] warning: could not pip install janus (install during Phase 1.5 offline-deps)" >&2
fi

echo "[phase1] Gate smoke checks..."
if command -v infini-registry >/dev/null 2>&1; then
  command -v infini-registry
  command -v infini-router
  command -v infini-babysitter
else
  echo "[phase1] warning: infini-* binaries not on PATH yet" >&2
fi
# shellcheck source=/dev/null
source /app/env-set.sh
export PYTHONPATH="/workspace/InfiniLM/python:/workspace/InfiniCore/python:${PYTHONPATH:-}"
ls /InfiniCore/python/infinicore/lib/_infinicore*.so
ls /InfiniLM/python/infinilm/lib/_infinilm*.so
if [[ -f /workspace/InfiniLM/python/infinilm/modeling_utils.py ]]; then
  grep -c 'gc.collect' /workspace/InfiniLM/python/infinilm/modeling_utils.py || true
fi
if [[ -e /dev/dri/card0 || -e /dev/htcd ]]; then
  # os._exit avoids HPCC destructor double-free on interpreter shutdown
  python3 - <<'PY'
import infinicore, infinilm
print("imports OK")
import os
os._exit(0)
PY
else
  echo "[phase1] Skipping python GPU import (no GPU devices in build container)"
fi

echo "=========================================="
echo "setup-phase1-deps.sh complete"
echo "=========================================="
