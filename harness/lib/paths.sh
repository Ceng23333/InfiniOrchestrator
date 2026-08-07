#!/usr/bin/env bash
# Resolve harness + warehouse roots for InfiniOrchestrator-hosted harness.
_HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "${_HARNESS_LIB_DIR}/.." && pwd)"
IO_ROOT="$(cd "${HARNESS_ROOT}/.." && pwd)"

# Warehouse is external data-only repo
if [[ -z "${BENCH_WAREHOUSE_REPO:-}" ]]; then
  BENCH_WAREHOUSE_REPO="$(cd "${IO_ROOT}/.." && pwd)/bench-warehouse"
fi
if [[ "${BENCH_WAREHOUSE_REPO}" == */harness ]]; then
  BENCH_WAREHOUSE_REPO="${BENCH_WAREHOUSE_REPO%/harness}"
fi

export HARNESS_ROOT IO_ROOT BENCH_WAREHOUSE_REPO
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${IO_ROOT}/.." && pwd)/hardware-profile}"
export MONOREPO_WORK="${MONOREPO_WORK:-${IO_ROOT}}"
export INFINI_TENSOR_WORKTREE="${INFINI_TENSOR_WORKTREE:-${IO_ROOT}/InfiniTensorWorktree}"
_IM_SRC="${INFINI_TENSOR_WORKTREE}/InfiniMetadata/src"
# Harness + InfiniMetadata must be importable for emit/compact/query.
_py_parts=("${HARNESS_ROOT}")
if [[ -d "${_IM_SRC}" ]]; then
  _py_parts+=("${_IM_SRC}")
fi
_joined="$(IFS=:; echo "${_py_parts[*]}")"
if [[ -z "${PYTHONPATH:-}" ]]; then
  export PYTHONPATH="${_joined}"
elif [[ ":${PYTHONPATH}:" != *":${HARNESS_ROOT}:"* ]] || { [[ -d "${_IM_SRC}" ]] && [[ ":${PYTHONPATH}:" != *":${_IM_SRC}:"* ]]; }; then
  export PYTHONPATH="${_joined}:${PYTHONPATH}"
fi
unset _IM_SRC _py_parts _joined
if [[ -z "${BENCH_RESULTS_ROOT:-}" ]]; then
  BENCH_RESULTS_ROOT="${BENCH_WAREHOUSE_REPO}/bench_results"
fi
export BENCH_RESULTS_ROOT
mkdir -p "${BENCH_RESULTS_ROOT}"
