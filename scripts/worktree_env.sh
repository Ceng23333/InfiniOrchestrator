#!/usr/bin/env bash
# Resolve InfiniOrchestrator InfiniTensorWorktree paths (hard cutover — no sibling fallback).
#
# Usage:
#   source /path/to/InfiniOrchestrator/scripts/worktree_env.sh
#   # or:
#   . /path/to/InfiniOrchestrator/scripts/worktree_env.sh
#   require_worktree_repos InfiniCore InfiniLM
#
# When executed (not sourced), prints exported vars and validates default repos.

_io_worktree_env_main() {
  local _here
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export IO_ROOT
  IO_ROOT="$(cd "${_here}/.." && pwd)"
  # Prefer new name; keep WORKTREE_ROOT as alias for callers mid-migration
  export INFINI_TENSOR_WORKTREE="${IO_ROOT}/InfiniTensorWorktree"
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
    echo "  git submodule update --init --recursive" >&2
    return 1
  fi
  for name in "$@"; do
    path="${root}/${name}"
    if [[ ! -d "${path}" ]]; then
      echo "error: expected InfiniTensorWorktree repo: ${path}" >&2
      echo "  (hard cutover — sibling ${name}/ is not used)" >&2
      echo "  git submodule update --init --recursive" >&2
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
  require_worktree_repos InfiniCore InfiniLM InfiniMetadata
  echo "InfiniTensorWorktree OK"
fi
