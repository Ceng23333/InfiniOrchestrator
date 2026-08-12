#!/usr/bin/env bash
# Shared helpers for unexpected-behavior fault-injection steps (client-only).

set -euo pipefail

_UB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_UB_ROOT="$(cd "${_UB_LIB_DIR}/.." && pwd)"
# cases/unexpected_behavior -> cases -> benchmark -> scenarios -> harness
HARNESS_ROOT="$(cd "${HARNESS_UB_ROOT}/../../../.." && pwd)"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/paths.sh"

BASE_URL="${BASE_URL:-${BENCH_TARGET_URL:-${INFERENCE_SERVER_BASE_URL:-}}}"
ROUTER_URL="${ROUTER_URL:-${BASE_URL}}"
MODEL="${MODEL:-9g_8b_thinking}"
SCENARIO_TIMEOUT_SEC="${SCENARIO_TIMEOUT_SEC:-120}"
POST_FAULT_WAIT_SEC="${POST_FAULT_WAIT_SEC:-5}"
SIM_CLIENT="${HARNESS_UB_ROOT}/sim_client.py"

_ts() { date +%Y%m%d_%H%M%S; }

worker_health_ok() {
  local url="${1:-${BASE_URL}/health}"
  curl -sf --connect-timeout 3 --max-time 5 "${url}" >/dev/null 2>&1
}

# Client harness has no server log access; keep steps compatible.
assert_no_fatal_step_loop() {
  return 0
}

record_scenario() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  local summary_dir="${SUMMARY_DIR:-}"
  if [[ -n "${summary_dir}" ]]; then
    printf '%s\t%s\t%s\n' "${name}" "${status}" "${detail}" >> "${summary_dir}/results.tsv"
  fi
}

chat_payload() {
  local prompt="${1:-Hello}"
  local stream="${2:-false}"
  python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': sys.argv[2]}],
    'max_tokens': int(sys.argv[3]),
    'stream': sys.argv[4].lower() == 'true',
}))
" "${MODEL}" "${prompt}" "${MAX_TOKENS:-64}" "${stream}"
}
