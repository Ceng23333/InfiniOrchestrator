#!/usr/bin/env bash
# Post-deploy validation ladder for infinilm-metax-deployment-opt-20260611.
#
# Prerequisites: docker-compose master stack already up.
#
# Steps:
#   1. Poll worker logs for LLMEngine initialized + C++ capture complete
#   2. validate.sh smoke curl
#   3. prefix cache test (Qwen3-32B)
#   4. throughput (9g + Qwen3-32B)
#   5. C-Eval limit1 (9g + Qwen3-32B)
#   6. summary.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../" && pwd)"

if [[ -f "${CASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env" && set +a
fi

REGISTRY_HOST="${REGISTRY_HOST:-localhost}"
ROUTER_PORT="${ROUTER_PORT:-8800}"
EMBEDDING_PORT="${EMBEDDING_PORT:-20003}"
ROUTER_URL="http://localhost:${ROUTER_PORT}"
CAPTURE_TIMEOUT_SEC="${CAPTURE_TIMEOUT_SEC:-7200}"
CAPTURE_POLL_SEC="${CAPTURE_POLL_SEC:-30}"

WORKER_CONTAINERS=(
  "infiniorch-worker-master-9g-8100-20260611"
  "infiniorch-worker-master-qwen-paged-8200-20260611"
)

TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY_DIR="${SUMMARY_DIR:-${REPO_ROOT}/bench_results/deploy_validation_${TS}}"
mkdir -p "${SUMMARY_DIR}"
SUMMARY_FILE="${SUMMARY_DIR}/summary.md"

log_step() {
  echo ""
  echo "=========================================="
  echo "$1"
  echo "=========================================="
}

worker_ready() {
  local c="$1"
  if ! docker ps --format '{{.Names}}' | grep -qx "${c}"; then
    return 1
  fi
  local logs
  logs="$(docker exec "${c}" bash -lc 'f=$(ls -t /app/logs/babysitter_*.log 2>/dev/null | head -1); tail -500 "$f" 2>/dev/null' 2>/dev/null || true)"
  if [[ -z "${logs}" ]]; then
    logs="$(docker logs "${c}" 2>&1 | tail -500 || true)"
  fi
  echo "${logs}" | grep -q "LLMEngine initialized" \
    && echo "${logs}" | grep -q "C++ capture complete"
}

wait_cg_capture() {
  log_step "[1] Startup CG capture (worker logs)"
  local deadline=$((SECONDS + CAPTURE_TIMEOUT_SEC))
  declare -A ready_map=()
  for c in "${WORKER_CONTAINERS[@]}"; do
    ready_map["${c}"]=0
  done

  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    local all_ready=1
    for c in "${WORKER_CONTAINERS[@]}"; do
      if [[ "${ready_map[${c}]}" == "1" ]]; then
        continue
      fi
      if ! docker ps --format '{{.Names}}' | grep -qx "${c}"; then
        echo "  WARN: container not running: ${c}"
        all_ready=0
        continue
      fi
      if worker_ready "${c}"; then
        echo "  READY ${c}"
        ready_map["${c}"]=1
      else
        all_ready=0
        echo "  waiting ${c} ..."
      fi
    done
    if [[ "${all_ready}" == "1" ]]; then
      echo "All workers report CG capture complete."
      return 0
    fi
    sleep "${CAPTURE_POLL_SEC}"
  done
  echo "Error: timed out after ${CAPTURE_TIMEOUT_SEC}s waiting for CG capture" >&2
  return 1
}

{
  echo "# Deploy validation ${TS}"
  echo ""
  echo "- Case: infinilm-metax-deployment-opt-20260611"
  echo "- Router: ${ROUTER_URL}"
  echo ""
} > "${SUMMARY_FILE}"

run_and_record() {
  local name="$1"
  shift
  local log="${SUMMARY_DIR}/${name}.log"
  echo "## ${name}" >> "${SUMMARY_FILE}"
  echo '```' >> "${SUMMARY_FILE}"
  if "$@" 2>&1 | tee "${log}"; then
    echo '```' >> "${SUMMARY_FILE}"
    echo "" >> "${SUMMARY_FILE}"
    echo "- **${name}**: PASS" >> "${SUMMARY_FILE}"
    return 0
  else
    echo '```' >> "${SUMMARY_FILE}"
    echo "" >> "${SUMMARY_FILE}"
    echo "- **${name}**: FAIL (see ${log})" >> "${SUMMARY_FILE}"
    return 1
  fi
}

FAILED=0

wait_cg_capture || FAILED=1

if [[ "${FAILED}" -eq 0 ]]; then
  log_step "[2] Smoke curl (validate.sh)"
  run_and_record "validate_smoke" \
    env ROUTER_PORT="${ROUTER_PORT}" EMBEDDING_PORT="${EMBEDDING_PORT}" \
    "${CASE_DIR}/validate.sh" "${REGISTRY_HOST}" || FAILED=1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  log_step "[3] Prefix cache (Qwen3-32B)"
  run_and_record "prefix_cache_qwen" \
    "${SCRIPT_DIR}/test_prefix_cache.sh" "${ROUTER_URL}" "Qwen3-32B" || FAILED=1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  log_step "[4] Throughput (9g_8b_thinking)"
  run_and_record "throughput_9g" \
    env MODEL=9g_8b_thinking ROUTER_PORT="${ROUTER_PORT}" \
    "${SCRIPT_DIR}/run_deploy_throughput.sh" || FAILED=1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  log_step "[4b] Throughput (Qwen3-32B)"
  run_and_record "throughput_qwen" \
    env MODEL=Qwen3-32B ROUTER_PORT="${ROUTER_PORT}" \
    "${SCRIPT_DIR}/run_deploy_throughput.sh" || FAILED=1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  log_step "[5] C-Eval limit1 (9g_8b_thinking)"
  run_and_record "ceval_9g" \
    env ROUTER_URL="${ROUTER_URL}" MODELS=9g_8b_thinking TIMEOUT=600 MAX_GEN_TOKS=256 \
    "${SCRIPT_DIR}/run_deploy_ceval.sh" || FAILED=1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  log_step "[5b] C-Eval limit1 (Qwen3-32B)"
  run_and_record "ceval_qwen" \
    env ROUTER_URL="${ROUTER_URL}" MODELS=Qwen3-32B TIMEOUT=600 MAX_GEN_TOKS=1024 \
    "${SCRIPT_DIR}/run_deploy_ceval.sh" || FAILED=1
fi

echo "" >> "${SUMMARY_FILE}"
if [[ "${FAILED}" -eq 0 ]]; then
  echo "**Overall: PASS**" >> "${SUMMARY_FILE}"
  log_step "Validation ladder PASS"
  echo "Summary: ${SUMMARY_FILE}"
  exit 0
else
  echo "**Overall: FAIL**" >> "${SUMMARY_FILE}"
  log_step "Validation ladder FAIL"
  echo "Summary: ${SUMMARY_FILE}"
  exit 1
fi
