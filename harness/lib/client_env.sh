#!/usr/bin/env bash
# Client-side bench harness environment.
#
# bench-warehouse never starts/stops servers or reads docker logs. Server touchpoints
# over HTTP: GET /metadata (InfiniLM/IO) or stub metadata (vLLM/OpenAI); GET /metrics
# for srv_* columns (skipped for non-Infini backends).
#
# Required (one of):
#   BENCH_TARGET_URL          direct inference_server base URL (preferred)
#   INFERENCE_SERVER_BASE_URL same
#   BASE_URL                  legacy alias when router not used
#
# Optional:
#   BENCH_BACKEND             infinilm | infiniorchestrator | vllm | openai (default infinilm)
#   ROUTER_URL                traffic URL (defaults to BENCH_TARGET_URL)
#   BENCH_TOOL_ROOT           repo with benchmarks/ + scripts/vllm_bench_env.sh
#   BENCH_RESULTS_ROOT        local artifact root (default: ./bench_results)
#   TOKENIZER_DIR             host tokenizer path (throughput)
#   MODEL / MODELS
#
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

export BENCH_CLIENT_MODE=1

_bench_client_resolve_backend() {
  local backend
  backend="$(echo "${BENCH_BACKEND:-infinilm}" | tr '[:upper:]' '[:lower:]')"
  case "${backend}" in
    infinilm|infiniorchestrator|vllm|openai) ;;
    *)
      echo "[client_env] unknown BENCH_BACKEND=${BENCH_BACKEND:-} (use infinilm|infiniorchestrator|vllm|openai)" >&2
      return 1
      ;;
  esac
  export BENCH_BACKEND="${backend}"

  case "${backend}" in
    infinilm)
      export BENCH_FRONTEND="${BENCH_FRONTEND:-InfiniLM}"
      ;;
    infiniorchestrator)
      export BENCH_FRONTEND="${BENCH_FRONTEND:-InfiniOrchestrator}"
      ;;
    vllm)
      export BENCH_FRONTEND="${BENCH_FRONTEND:-vLLM}"
      export BENCH_SKIP_SERVER_METRICS="${BENCH_SKIP_SERVER_METRICS:-1}"
      ;;
    openai)
      export BENCH_FRONTEND="${BENCH_FRONTEND:-OpenAI}"
      export BENCH_SKIP_SERVER_METRICS="${BENCH_SKIP_SERVER_METRICS:-1}"
      ;;
  esac
}

_bench_client_resolve_urls() {
  local target="${BENCH_TARGET_URL:-${INFERENCE_SERVER_BASE_URL:-${BASE_URL:-}}}"
  if [[ -z "${target}" ]]; then
    echo "[client_env] BENCH_TARGET_URL (or INFERENCE_SERVER_BASE_URL / BASE_URL) required" >&2
    return 1
  fi
  target="${target%/}"

  export BENCH_TARGET_URL="${target}"
  export INFERENCE_SERVER_BASE_URL="${INFERENCE_SERVER_BASE_URL:-${target}}"
  export BASE_URL="${BASE_URL:-${target}}"
  export ROUTER_URL="${ROUTER_URL:-${BASE_URL}}"

  # Metrics/metadata hit inference_server directly (not via router proxy).
  export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${INFERENCE_SERVER_BASE_URL}}"
}

_bench_client_resolve_paths() {
  export BENCH_TOOL_ROOT="${BENCH_TOOL_ROOT:-${MONOREPO_WORK:-${INFINILM_PREFILL_WORK:-}}}"
  export BENCH_RESULTS_ROOT="${BENCH_RESULTS_ROOT:-${MONOREPO_WORK:+${MONOREPO_WORK}/bench_results}}"
  BENCH_RESULTS_ROOT="${BENCH_RESULTS_ROOT:-./bench_results}"
  export BENCH_RESULTS_ROOT
}

bench_client_preflight() {
  local artifact_dir="${1:-}"
  _bench_client_resolve_backend || return 1
  _bench_client_resolve_urls || return 1
  _bench_client_resolve_paths

  if [[ -n "${artifact_dir}" ]]; then
    mkdir -p "${artifact_dir}"
  fi

  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/server_preflight.sh"
  server_preflight "${INFERENCE_SERVER_BASE_URL}" "${artifact_dir:-}"
  echo "[client_env] backend=${BENCH_BACKEND} frontend=${BENCH_FRONTEND} target=${BENCH_TARGET_URL} metrics=${BENCH_METRICS_URL} router=${ROUTER_URL} server_id=${INFERENCE_SERVER_ID} skip_srv=${BENCH_SKIP_SERVER_METRICS:-0}"
}

# Resolve backend on source so orchestrators that set INFERENCE_SERVER_ID (skipping
# preflight) still get BENCH_FRONTEND / BENCH_SKIP_SERVER_METRICS.
_bench_client_resolve_backend || true

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bench_client_preflight "${1:-}"
fi
