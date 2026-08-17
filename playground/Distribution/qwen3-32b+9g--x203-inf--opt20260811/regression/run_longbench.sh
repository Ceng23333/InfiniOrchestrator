#!/usr/bin/env bash
# Post-compose LongBench-v2 regression against the running InfiniOrchestrator router.
# Wraps harness scenarios/benchmark/cases/longbench_v2/scripts/run.sh (official 0-shot).
#
# Prereq: docker-compose stack up + ./docker-compose/validate.sh localhost
#
# Usage:
#   ./regression/run_longbench.sh
#   LIMIT=8 ./regression/run_longbench.sh          # quick gate
#   MODEL=9g_8b_thinking ./regression/run_longbench.sh
#   MODELS="Qwen3-32B 9g_8b_thinking" ./regression/run_longbench.sh
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../../scripts/worktree_env.sh
source "${CASE_DIR}/../../../scripts/worktree_env.sh"

if [[ -f "${CASE_DIR}/docker-compose/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${CASE_DIR}/docker-compose/.env"
  set +a
fi

export BENCH_TARGET_URL="${BENCH_TARGET_URL:-http://localhost:${ROUTER_PORT:-8800}}"
export ROUTER_URL="${ROUTER_URL:-${BENCH_TARGET_URL}}"
export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${ROUTER_URL}}"
export CASE_ID="${CASE_ID:-qwen3-32b+9g--x203-inf--opt20260811}"
export CASE_PATH="${CASE_PATH:-${CASE_DIR}/case.toml}"
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-$(cd "${CASE_DIR}/../../../../hardware-profile" && pwd)}"
export LONGBENCH_LENGTH="${LONGBENCH_LENGTH:-all}"
export LONGBENCH_DIFFICULTY="${LONGBENCH_DIFFICULTY:-all}"
export ENABLE_THINKING="${ENABLE_THINKING:-0}"
export LIMIT="${LIMIT:-0}"
export BENCH_BACKEND="${BENCH_BACKEND:-infinilm}"
# InfiniLM path: scrape LB /metrics and Entrypoint /metadata (do not skip).
unset BENCH_SKIP_SERVER_METRICS 2>/dev/null || true

# Harness runs the client inside DEV_CONTAINER; multi-network docker inspect can
# concatenate gateways. Prefer an explicit in-container URL to the host-published router.
if [[ -z "${BENCH_CTN_URL:-}" ]]; then
  if [[ "${BENCH_TARGET_URL}" =~ ^https?://(127\.0\.0\.1|localhost)(:([0-9]+))?(/.*)?$ ]]; then
    _port="${BASH_REMATCH[3]:-${ROUTER_PORT:-8800}}"
    BENCH_CTN_URL="http://172.17.0.1:${_port}"
  fi
fi
export BENCH_CTN_URL="${BENCH_CTN_URL:-}"

HARNESS="${IO_ROOT}/harness/scenarios/benchmark/cases/longbench_v2/scripts/run.sh"
if [[ ! -f "${HARNESS}" ]]; then
  echo "error: missing ${HARNESS}" >&2
  exit 1
fi

# Optional caller override; otherwise resolve Entrypoint (babysitter) per model.
_INFERENCE_METADATA_URL_OVERRIDE="${INFERENCE_METADATA_URL:-}"
# Caller may set MAX_INPUT_TOKENS; otherwise apply per-model serve compile caps
# (INFINI_COMPILE_MAX_SEQ − overhead). Official LongBench uses ~120k; we cap to serve.
_MAX_INPUT_TOKENS_OVERRIDE="${MAX_INPUT_TOKENS:-}"

resolve_metadata_url() {
  local model="$1"
  if [[ -n "${_INFERENCE_METADATA_URL_OVERRIDE}" ]]; then
    printf '%s\n' "${_INFERENCE_METADATA_URL_OVERRIDE}"
    return 0
  fi
  case "${model}" in
    Qwen3-32B|Qwen3-32B-*)
      printf 'http://localhost:%s\n' "${WORKER_QWEN_BABYSITTER_PORT:-8201}"
      ;;
    9g_8b_thinking|9g*)
      printf 'http://localhost:%s\n' "${WORKER_9G_BABYSITTER_PORT:-8103}"
      ;;
    *)
      printf 'http://localhost:%s\n' "${WORKER_QWEN_BABYSITTER_PORT:-8201}"
      ;;
  esac
}

resolve_max_input_tokens() {
  local model="$1"
  if [[ -n "${_MAX_INPUT_TOKENS_OVERRIDE}" ]]; then
    printf '%s\n' "${_MAX_INPUT_TOKENS_OVERRIDE}"
    return 0
  fi
  case "${model}" in
    Qwen3-32B|Qwen3-32B-*)
      # qwen3-32b-paged.toml INFINI_COMPILE_MAX_SEQ=40960 → leave headroom
      printf '40832\n'
      ;;
    9g_8b_thinking|9g*)
      # 9g_8b_thinking.toml INFINI_COMPILE_MAX_SEQ=65536 → leave headroom
      printf '65408\n'
      ;;
    *)
      printf '40832\n'
      ;;
  esac
}

run_one() {
  local model="$1"
  local meta_url max_in
  meta_url="$(resolve_metadata_url "${model}")"
  max_in="$(resolve_max_input_tokens "${model}")"
  export INFERENCE_METADATA_URL="${meta_url}"
  export MAX_INPUT_TOKENS="${max_in}"
  echo "=========================================="
  echo "LongBench-v2 regression: MODEL=${model}"
  echo "  BENCH_TARGET_URL=${BENCH_TARGET_URL}"
  echo "  BENCH_METRICS_URL=${BENCH_METRICS_URL}"
  echo "  INFERENCE_METADATA_URL=${INFERENCE_METADATA_URL}"
  echo "  HARDWARE_PROFILE_REPO=${HARDWARE_PROFILE_REPO}"
  echo "  CASE_ID=${CASE_ID} CASE_PATH=${CASE_PATH}"
  echo "  LIMIT=${LIMIT} ENABLE_THINKING=${ENABLE_THINKING}"
  echo "  LONGBENCH_LENGTH=${LONGBENCH_LENGTH} MAX_INPUT_TOKENS=${MAX_INPUT_TOKENS}"
  echo "  note: MAX_INPUT_TOKENS is serve-capped (not official ~120k)"
  echo "=========================================="
  MODEL="${model}" bash "${HARNESS}"
}

if [[ -n "${MODELS:-}" ]]; then
  # shellcheck disable=SC2086
  for m in ${MODELS}; do
    run_one "${m}"
  done
else
  run_one "${MODEL:-Qwen3-32B}"
fi
