#!/usr/bin/env bash
# Resolve InfiniOrchestrator worktree paths (hard cutover — no sibling fallback).
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
  export WORKTREE_ROOT="${IO_ROOT}/worktree"
  export BENCH_WAREHOUSE_REPO="${WORKTREE_ROOT}/bench-warehouse"
  export SVC_ROOT="${SVC_ROOT:-$(cd "${IO_ROOT}/.." && pwd)/InfiniLM-SVC}"
}

require_worktree_repos() {
  local name path
  if [[ -z "${WORKTREE_ROOT:-}" ]]; then
    echo "error: WORKTREE_ROOT unset; source scripts/worktree_env.sh first" >&2
    return 1
  fi
  if [[ ! -d "${WORKTREE_ROOT}" ]]; then
    echo "error: worktree missing: ${WORKTREE_ROOT}" >&2
    echo "  git submodule update --init --recursive" >&2
    return 1
  fi
  for name in "$@"; do
    path="${WORKTREE_ROOT}/${name}"
    if [[ ! -d "${path}" ]]; then
      echo "error: expected worktree repo: ${path}" >&2
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
  echo "WORKTREE_ROOT=${WORKTREE_ROOT}"
  echo "BENCH_WAREHOUSE_REPO=${BENCH_WAREHOUSE_REPO}"
  echo "SVC_ROOT=${SVC_ROOT}"
  require_worktree_repos InfiniCore InfiniLM InfiniMetadata bench-warehouse
  echo "worktree OK"
fi
