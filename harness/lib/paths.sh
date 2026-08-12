#!/usr/bin/env bash
# Resolve harness + warehouse roots for InfiniOrchestrator-hosted runners.
_HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "${_HARNESS_LIB_DIR}/.." && pwd)"
IO_ROOT="$(cd "${HARNESS_ROOT}/.." && pwd)"

# Warehouse is external data repo (owns bench_warehouse Python package)
if [[ -z "${BENCH_WAREHOUSE_REPO:-}" ]]; then
  BENCH_WAREHOUSE_REPO="$(cd "${IO_ROOT}/.." && pwd)/bench-warehouse"
fi
if [[ "${BENCH_WAREHOUSE_REPO}" == */harness ]]; then
  BENCH_WAREHOUSE_REPO="${BENCH_WAREHOUSE_REPO%/harness}"
fi

export HARNESS_ROOT IO_ROOT BENCH_WAREHOUSE_REPO
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${IO_ROOT}/.." && pwd)/hardware-profile}"
# Host tree mounted at /workspace in DEV_CONTAINER (profiling workspace root).
export MONOREPO_WORK="${MONOREPO_WORK:-$(cd "${IO_ROOT}/.." && pwd)}"
export INFINI_TENSOR_WORKTREE="${INFINI_TENSOR_WORKTREE:-$(cd "${IO_ROOT}/.." && pwd)/InfiniTensorWorktree}"

# PYTHONPATH: warehouse package (emit/compact) + harness root (server_client module)
_py_parts=("${BENCH_WAREHOUSE_REPO}" "${HARNESS_ROOT}")
_joined="$(IFS=:; echo "${_py_parts[*]}")"
if [[ -z "${PYTHONPATH:-}" ]]; then
  export PYTHONPATH="${_joined}"
else
  for _p in "${_py_parts[@]}"; do
    if [[ ":${PYTHONPATH}:" != *":${_p}:"* ]]; then
      export PYTHONPATH="${_p}:${PYTHONPATH}"
    fi
  done
fi
unset _py_parts _joined _p

if [[ -z "${BENCH_RESULTS_ROOT:-}" ]]; then
  BENCH_RESULTS_ROOT="${BENCH_WAREHOUSE_REPO}/bench_results"
fi
export BENCH_RESULTS_ROOT
mkdir -p "${BENCH_RESULTS_ROOT}"
