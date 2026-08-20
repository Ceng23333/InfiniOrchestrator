#!/usr/bin/env bash
# Mars device backend + HPCC toolkit for --refactor-dev images.
# Do NOT alias MACA_* onto HPCC_PATH — that mixes InfiniRT Mars with InfiniOps MetaX.
set +u

export HPCC_PATH="${HPCC_PATH:-/opt/hpcc}"
if [[ -f "${HPCC_PATH}/env-set.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HPCC_PATH}/env-set.sh"
elif [[ -f "${HPCC_PATH}/bin/env-set.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HPCC_PATH}/bin/env-set.sh"
fi

unset MACA_PATH MACA_HOME MACA_ROOT || true

export REPO="${REPO:-/workspace}"
export INFINI_ROOT="${INFINI_ROOT:-${REPO}/InfiniLM/build/integration/mars/prefix}"
export XMAKE_ROOT="${XMAKE_ROOT:-y}"

if [[ -d "${REPO}/InfiniLM/python" ]]; then
  export PYTHONPATH="${REPO}/InfiniLM/python:${PYTHONPATH:-}"
fi

_TORCH_LIB=""
if command -v python3 &>/dev/null; then
  _TORCH_LIB="$(python3 - <<'PY' 2>/dev/null || true
import os, torch
print(os.path.join(os.path.dirname(torch.__file__), "lib"))
PY
)"
fi
if [[ -n "${_TORCH_LIB}" && -d "${_TORCH_LIB}" ]]; then
  export TORCH_LIB="${_TORCH_LIB}"
fi
export LD_LIBRARY_PATH="${TORCH_LIB:-}:${REPO}/InfiniLM/python/infinicore/lib:${INFINI_ROOT}/lib:${INFINI_ROOT}/lib64:${HPCC_PATH}/lib:${HPCC_PATH}/htgpu_llvm/lib:${HPCC_PATH}/ompi/lib:${LD_LIBRARY_PATH:-}"

_gpu="${HPCC_VISIBLE_DEVICES:-0}"
export HPCC_VISIBLE_DEVICES="${_gpu}"

export PATH="${INFINI_ROOT}/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:/opt/conda/bin:${PATH}"

unset _TORCH_LIB _gpu
