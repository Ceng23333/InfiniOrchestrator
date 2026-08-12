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
# Host tree mounted at /workspace in DEV_CONTAINER (profiling workspace root).
export MONOREPO_WORK="${MONOREPO_WORK:-$(cd "${IO_ROOT}/.." && pwd)}"
export INFINI_TENSOR_WORKTREE="${INFINI_TENSOR_WORKTREE:-$(cd "${IO_ROOT}/.." && pwd)/InfiniTensorWorktree}"
# Harness must be importable for emit/compact/query (vendored frontend/metrics helpers).
if [[ -z "${PYTHONPATH:-}" ]]; then
  export PYTHONPATH="${HARNESS_ROOT}"
elif [[ ":${PYTHONPATH}:" != *":${HARNESS_ROOT}:"* ]]; then
  export PYTHONPATH="${HARNESS_ROOT}:${PYTHONPATH}"
fi
if [[ -z "${BENCH_RESULTS_ROOT:-}" ]]; then
  BENCH_RESULTS_ROOT="${BENCH_WAREHOUSE_REPO}/bench_results"
fi
export BENCH_RESULTS_ROOT
mkdir -p "${BENCH_RESULTS_ROOT}"
