#!/usr/bin/env bash
# Resolve InfiniOrchestrator paths and sibling InfiniTensorWorktree.
#
# Usage:
#   source /path/to/InfiniOrchestrator/scripts/worktree_env.sh
#   require_worktree_repos InfiniCore InfiniLM
#
# InfiniTensorWorktree is an external sibling repo (not nested under IO).
# Override with INFINI_TENSOR_WORKTREE if needed.

_io_worktree_env_main() {
  local _here
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export IO_ROOT
  IO_ROOT="$(cd "${_here}/.." && pwd)"
  export INFINI_TENSOR_WORKTREE="${INFINI_TENSOR_WORKTREE:-$(cd "${IO_ROOT}/.." && pwd)/InfiniTensorWorktree}"
  export WORKTREE_ROOT="${INFINI_TENSOR_WORKTREE}"
  # Warehouse is external (not under InfiniTensorWorktree)
  export BENCH_WAREHOUSE_REPO="${BENCH_WAREHOUSE_REPO:-$(cd "${IO_ROOT}/.." && pwd)/bench-warehouse}"
  export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${IO_ROOT}/.." && pwd)/hardware-profile}"
  export HARNESS_ROOT="${IO_ROOT}/harness"
  export SVC_ROOT="${SVC_ROOT:-$(cd "${IO_ROOT}/.." && pwd)/InfiniLM-SVC}"
}

require_worktree_repos() {
  local name path
  if [[ -z "${INFINI_TENSOR_WORKTREE:-}${WORKTREE_ROOT:-}" ]]; then
    echo "error: INFINI_TENSOR_WORKTREE unset; source scripts/worktree_env.sh first" >&2
    return 1
  fi
  local root="${INFINI_TENSOR_WORKTREE:-${WORKTREE_ROOT}}"
  if [[ ! -d "${root}" ]]; then
    echo "error: InfiniTensorWorktree missing: ${root}" >&2
    echo "  clone sibling: git clone --recurse-submodules https://github.com/Ceng23333/InfiniTensorWorktree.git" >&2
    echo "  or: export INFINI_TENSOR_WORKTREE=/path/to/InfiniTensorWorktree" >&2
    return 1
  fi
  for name in "$@"; do
    path="${root}/${name}"
    if [[ ! -d "${path}" ]]; then
      echo "error: expected InfiniTensorWorktree repo: ${path}" >&2
      echo "  (sibling checkout — not nested under InfiniOrchestrator)" >&2
      echo "  cd \"${root}\" && git submodule update --init --recursive" >&2
      return 1
    fi
  done
  return 0
}

_io_worktree_env_main

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  echo "IO_ROOT=${IO_ROOT}"
  echo "INFINI_TENSOR_WORKTREE=${INFINI_TENSOR_WORKTREE}"
  echo "WORKTREE_ROOT=${WORKTREE_ROOT}"
  echo "BENCH_WAREHOUSE_REPO=${BENCH_WAREHOUSE_REPO}"
  echo "HARDWARE_PROFILE_REPO=${HARDWARE_PROFILE_REPO}"
  echo "HARNESS_ROOT=${HARNESS_ROOT}"
  echo "SVC_ROOT=${SVC_ROOT}"
  require_worktree_repos InfiniCore InfiniLM
  echo "InfiniTensorWorktree OK"
fi
