#!/usr/bin/env bash
# HPCC ai3.7 / torch2.8 runtime + build env for infinilm-metax-deployment-opt-20260714.
#
# Parity with live `infinilm-dev-hpcc37` sourcing:
#   source /workspace/scripts/hpcc_env.sh
# (vendor image already bakes HPCC_PATH/PATH/LD_LIBRARY_PATH; /opt/hpcc/env-set.sh
# may be absent — that is expected on vllm-mars 0.20.0-hpcc.ai3.7.)
#
# Installed at /app/env-set.sh in Phase-1+ images; sourced by setup-phase*.sh.
# Host helper for the bind-mount dev container:
#   source …/scripts/source_infinilm_dev_hpcc37.sh
# See ../../../../docs/IMAGE_BUILD_PHASES.md

set +u

export HPCC_PATH="${HPCC_PATH:-/opt/hpcc}"
if [[ -f "${HPCC_PATH}/env-set.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HPCC_PATH}/env-set.sh"
elif [[ -f "${HPCC_PATH}/bin/env-set.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HPCC_PATH}/bin/env-set.sh"
fi

# xmake metax.lua + InfiniCore build read MACA_* (map onto HPCC toolkit root).
export MACA_ROOT="${MACA_ROOT:-${MACA_PATH:-${MACA_HOME:-${HPCC_PATH}}}}"
export MACA_PATH="${MACA_PATH:-${MACA_ROOT}}"
export MACA_HOME="${MACA_HOME:-${MACA_ROOT}}"

export REPO="${REPO:-/workspace}"
export INFINILM_PREFILL_WORK="${INFINILM_PREFILL_WORK:-${REPO}}"
export INFINI_ROOT="${INFINI_ROOT:-${HOME}/.infini}"
export XMAKE_ROOT="${XMAKE_ROOT:-y}"

if [[ -d /workspace/InfiniLM/python && -d /workspace/InfiniCore/python ]]; then
  export PYTHONPATH="/workspace/InfiniLM/python:/workspace/InfiniCore/python:${PYTHONPATH:-}"
elif [[ -d /InfiniLM/python && -d /InfiniCore/python ]]; then
  export PYTHONPATH="/InfiniLM/python:/InfiniCore/python:${PYTHONPATH:-}"
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
export LD_LIBRARY_PATH="${TORCH_LIB:-}:${INFINI_ROOT}/lib:${HPCC_PATH}/lib:${HPCC_PATH}/htgpu_llvm/lib:${HPCC_PATH}/ompi/lib:${LD_LIBRARY_PATH:-}"

# flash-attn extension path + Mars ABI flags (same logic as scripts/hpcc_env.sh)
if [[ -z "${FLASH_ATTN_2_CUDA_SO:-}" ]]; then
  _pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "3.10")"
  _fa_glob="/opt/conda/lib/python${_pyver}/site-packages/flash_attn_2_cuda"*.so
  # shellcheck disable=SC2086
  _fa_so="$(ls -1 ${_fa_glob} 2>/dev/null | head -1 || true)"
  if [[ -n "${_fa_so}" ]]; then
    export FLASH_ATTN_2_CUDA_SO="${_fa_so}"
  fi
fi
if [[ -n "${FLASH_ATTN_2_CUDA_SO:-}" && -f "${FLASH_ATTN_2_CUDA_SO}" ]]; then
  export LD_LIBRARY_PATH="$(dirname "${FLASH_ATTN_2_CUDA_SO}"):${LD_LIBRARY_PATH}"
  if [[ -z "${INFINICORE_FLASH_ATTN_MARS_EXT:-}" || -z "${INFINICORE_FLASH_ATTN_VARLEN_MARS_EXT:-}" || -z "${INFINICORE_FLASH_ATTN_VARLEN_TAIL_BOOL:-}" ]]; then
    # shellcheck disable=SC1090
    eval "$(python3 - <<'PY' 2>/dev/null || true
import os, subprocess, sys
so = os.environ.get("FLASH_ATTN_2_CUDA_SO", "")
if not so or not os.path.isfile(so):
    sys.exit(0)
lines = subprocess.check_output(["bash", "-lc", f"nm -D {so} | c++filt"], text=True).splitlines()
kvcache = [ln for ln in lines if "mha_fwd_kvcache" in ln and "dequant" not in ln]
varlen = [ln for ln in lines if "mha_varlen_fwd" in ln and "mha_varlen_bwd" not in ln and "inference" not in ln]
kc = kvcache[0].strip() if kvcache else ""
vl = varlen[0].strip() if varlen else ""
kvcache_mars_ext = kc.endswith("std::optional<at::Tensor>&)")
varlen_tail_bool = vl.endswith(", bool)")
varlen_mars_ext = varlen_tail_bool or vl.endswith("std::optional<at::Generator>, std::optional<at::Tensor>&)")
print(f"export INFINICORE_FLASH_ATTN_MARS_EXT={'1' if kvcache_mars_ext else '0'}")
print(f"export INFINICORE_FLASH_ATTN_VARLEN_MARS_EXT={'1' if varlen_mars_ext else '0'}")
print(f"export INFINICORE_FLASH_ATTN_VARLEN_TAIL_BOOL={'1' if varlen_tail_bool else '0'}")
PY
)"
  fi
fi

_hpcc_inc=(
  "${HPCC_PATH}/tools/cu-bridge/include"
  "${HPCC_PATH}/include/hcr"
  "${HPCC_PATH}/include/common"
  "${HPCC_PATH}/include/hcsparse"
  "${HPCC_PATH}/include/hcblas"
  "${HPCC_PATH}/include/hcsolver"
  "${HPCC_PATH}/include"
)
for _var in CPATH CPLUS_INCLUDE_PATH C_INCLUDE_PATH; do
  _chunk="$(IFS=:; echo "${_hpcc_inc[*]}")"
  _cur="${!_var:-}"
  export "${_var}=${_chunk}${_cur:+:${_cur}}"
done

_gpu="${HPCC_VISIBLE_DEVICES:-${MACA_VISIBLE_DEVICES:-}}"
if [[ -n "${_gpu}" ]]; then
  export HPCC_VISIBLE_DEVICES="${_gpu}"
  export MACA_VISIBLE_DEVICES="${_gpu}"
fi

export PATH="${INFINI_ROOT}/bin:${HOME}/.cargo/bin:/usr/local/bin:/opt/conda/bin:${PATH}"

unset _TORCH_LIB _pyver _fa_glob _fa_so _hpcc_inc _var _chunk _cur _gpu
