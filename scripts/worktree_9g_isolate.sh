#!/usr/bin/env bash
# Shared GPU / SOURCE_ROOT isolation for 9g Standalone qualify & promote.
#
# Resource map (non-negotiable):
#   GPU0 / :8100/:8101  — exclusive wrap: only one of
#                         9g-inf-{main,refactor,refactor-dev,deploy}
#   GPU1 / :8230        — Mars rebuild/package only (infinilm-dev-refactor-dev);
#                         never the LongBench target during gates
#   SOURCE_ROOT pins    — main → itw-pins/v2026.08.19-main-ic1510
#                         refactor-dev → itw-pins/v2026.08.19-refactor-dev-l8
#                         product --refactor stays on InfiniTensorWorktree
#                         @ v2026.08.18-refactor (DO NOT mutate via this helper)
#
# Usage:
#   source "${IO_ROOT}/scripts/worktree_env.sh"
#   source "${IO_ROOT}/scripts/worktree_9g_isolate.sh"
#   worktree_9g_force_free_gpu0
#   worktree_9g_source_root_for main   # → prints pinned path
#
# shellcheck disable=SC2034

_worktree_9g_isolate_init() {
  local _ws
  if [[ -z "${IO_ROOT:-}" ]]; then
    echo "error: IO_ROOT unset; source scripts/worktree_env.sh first" >&2
    return 1
  fi
  _ws="$(cd "${IO_ROOT}/.." && pwd)"
  export WORKTREE_9G_WORKSPACE="${WORKTREE_9G_WORKSPACE:-${_ws}}"
  export WORKTREE_9G_STAND="${WORKTREE_9G_STAND:-${IO_ROOT}/playground/Standalone}"

  # Pinned SOURCE_ROOTs (never share across qualifiers).
  export WORKTREE_9G_SOURCE_ROOT_MAIN="${WORKTREE_9G_SOURCE_ROOT_MAIN:-${WORKTREE_9G_WORKSPACE}/itw-pins/v2026.08.19-main-ic1510}"
  export WORKTREE_9G_SOURCE_ROOT_REFACTOR_DEV="${WORKTREE_9G_SOURCE_ROOT_REFACTOR_DEV:-${WORKTREE_9G_WORKSPACE}/itw-pins/v2026.08.19-refactor-dev-l8}"
  # Product --refactor pin (read-only reference; mutate helpers refuse this path).
  export WORKTREE_9G_SOURCE_ROOT_REFACTOR_PRODUCT="${WORKTREE_9G_SOURCE_ROOT_REFACTOR_PRODUCT:-${WORKTREE_9G_WORKSPACE}/InfiniTensorWorktree}"

  # GPU0 wrap containers (exclusive).
  WORKTREE_9G_GPU0_WRAPS=(main refactor refactor-dev deploy)
  # GPU1 Mars build container — leave running during GPU0 gates.
  export WORKTREE_9G_GPU1_MARS_CTN="${WORKTREE_9G_GPU1_MARS_CTN:-infinilm-dev-refactor-dev}"
}

worktree_9g_source_root_for() {
  local q="$1"
  case "${q}" in
    main) echo "${WORKTREE_9G_SOURCE_ROOT_MAIN}" ;;
    refactor-dev) echo "${WORKTREE_9G_SOURCE_ROOT_REFACTOR_DEV}" ;;
    refactor)
      echo "error: product --refactor SOURCE_ROOT is out of mutate scope (${WORKTREE_9G_SOURCE_ROOT_REFACTOR_PRODUCT})" >&2
      return 1
      ;;
    deploy)
      echo "error: deploy pin is out of qualify mutate scope" >&2
      return 1
      ;;
    *)
      echo "error: unknown qualifier '${q}'" >&2
      return 1
      ;;
  esac
}

# Refuse packaging / rebuild that would overwrite product --refactor artifacts.
worktree_9g_assert_not_mutating_product_refactor() {
  local target="${1:-}"
  local product_case="${WORKTREE_9G_STAND}/9g_8b_thinking-x203-inf--refactor"
  if [[ -n "${target}" ]]; then
    local abs
    abs="$(cd "$(dirname "${target}")" 2>/dev/null && pwd)/$(basename "${target}")" || abs="${target}"
    if [[ "${abs}" == "${product_case}" || "${abs}" == "${product_case}/"* ]]; then
      echo "error: refusing to mutate product --refactor under ${product_case}" >&2
      return 1
    fi
  fi
  if [[ "${SOURCE_ROOT:-}" == "${WORKTREE_9G_SOURCE_ROOT_REFACTOR_PRODUCT}" ]] \
    && [[ "${CASE_ID:-}" == *"--refactor" && "${CASE_ID:-}" != *"--refactor-dev"* ]]; then
    echo "error: refusing SOURCE_ROOT mutate for product --refactor (CASE_ID=${CASE_ID})" >&2
    return 1
  fi
  return 0
}

worktree_9g_stop_gpu0_wraps() {
  local other case_dir
  for other in "${WORKTREE_9G_GPU0_WRAPS[@]}"; do
    case_dir="${WORKTREE_9G_STAND}/9g_8b_thinking-x203-inf--${other}"
    if [[ -x "${case_dir}/stop-wrap.sh" ]]; then
      CONTAINER_NAME="9g-inf-${other}" "${case_dir}/stop-wrap.sh" >/dev/null 2>&1 || true
    fi
  done
  docker rm -f \
    9g-inf-main 9g-inf-refactor 9g-inf-refactor-dev 9g-inf-deploy \
    9g-vllm-x203 infiniorch-worker-9g-8100-20260811 \
    >/dev/null 2>&1 || true
}

# Kill competing host kick/LongBench jobs and stop GPU0 wraps.
# Does NOT stop WORKTREE_9G_GPU1_MARS_CTN (Mars build on GPU1).
# Does NOT kill this shell (caller qualify / promote).
worktree_9g_force_free_gpu0() {
  local pat pid walk skip
  set +e
  # Sibling qualify drivers (exclusive GPU0); skip this shell and ancestors
  # so a wrapper whose cmdline contains qualify.sh is not SIGKILL'd.
  while read -r pid; do
    [[ -z "${pid}" ]] && continue
    skip=0
    walk=$$
    while [[ -n "${walk}" && "${walk}" != "0" && "${walk}" != "1" ]]; do
      if [[ "${pid}" == "${walk}" ]]; then skip=1; break; fi
      walk="$(ps -o ppid= -p "${walk}" 2>/dev/null | tr -d ' ')"
    done
    [[ "${skip}" -eq 1 ]] && continue
    kill -9 "${pid}" 2>/dev/null
  done < <(pgrep -f 'run_longbench_v2_worktree_9g_qualify\.sh' 2>/dev/null || true)

  for pat in \
    'bench_results/kick_main' \
    'kick_main_short' \
    'kick_main_leg' \
    'kick_main_qualify' \
    'wait_l8_then_push_repin' \
    'wait_l8_then_campaign' \
    'run_longbench_v2_worktree_9g\.sh' \
    'run_longbench_v2_worktree_9g_promote' \
    '9g_8b_thinking-x203-inf--main/regression/run_longbench' \
    '9g_8b_thinking-x203-inf--deploy/regression/run_longbench' \
    '9g_8b_thinking-x203-inf--refactor-dev/regression/run_longbench' \
    'longbench_v2/client\.py' \
    'harness/scenarios/benchmark/cases/longbench_v2'
  do
    pkill -9 -f "${pat}" 2>/dev/null
  done
  # Host leftover docker-exec clients inside GPU1 Mars ctn (if any).
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${WORKTREE_9G_GPU1_MARS_CTN}"; then
    docker exec "${WORKTREE_9G_GPU1_MARS_CTN}" \
      bash -lc "pkill -9 -f 'longbench_v2/client.py' 2>/dev/null; true" >/dev/null 2>&1
  fi
  set -e
  worktree_9g_stop_gpu0_wraps
}

_worktree_9g_isolate_init
