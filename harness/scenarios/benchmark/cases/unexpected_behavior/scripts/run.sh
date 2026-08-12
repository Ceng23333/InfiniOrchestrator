#!/usr/bin/env bash
# Run unexpected-behavior fault-injection steps against a live inference endpoint.
# Per-step emits to raw/<date>/<suite_prefix>.tsv via bench_warehouse.emit.
# Server touchpoints: GET /metadata + GET /metrics (HTTP only).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARNESS_ROOT="$(cd "${CASE_ROOT}/../../../.." && pwd)"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/client_env.sh"
# shellcheck disable=SC1091
source "${CASE_ROOT}/config/default.env"
# shellcheck disable=SC1091
source "${CASE_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/artifact_layout.sh"

_bench_client_resolve_urls || true
_bench_client_resolve_paths || true
export BENCH_METRICS_URL="${BENCH_METRICS_URL:-${INFERENCE_SERVER_BASE_URL:-${BASE_URL:-}}}"

VIA_ROUTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --via-router)
      VIA_ROUTER=1
      shift
      ;;
    -h|--help)
      sed -n '1,14p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "${VIA_ROUTER}" -eq 1 ]]; then
  BASE_URL="${ROUTER_URL}"
fi

TS="$(_ts)"
SUMMARY_DIR="${SUMMARY_DIR:-${BENCH_RESULTS_ROOT}/unexpected_behavior_${TS}}"
mkdir -p "${SUMMARY_DIR}"
export SUMMARY_DIR BASE_URL

SUITE_STARTED_AT="${SUITE_STARTED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
export SUITE_STARTED_AT

DEFAULT_SCENARIOS="${SCENARIOS}"
IFS=',' read -r -a SCENARIO_LIST <<< "${DEFAULT_SCENARIOS}"

{
  echo "# Unexpected behavior bench"
  echo ""
  echo "- started: ${SUITE_STARTED_AT}"
  echo "- BASE_URL: ${BASE_URL}"
  echo "- MODEL: ${MODEL}"
  echo "- scenarios: ${SCENARIO_LIST[*]}"
  echo ""
  echo "| scenario | status | log |"
  echo "|----------|--------|-----|"
} > "${SUMMARY_DIR}/summary.md"

printf 'scenario\tstatus\tdetail\n' > "${SUMMARY_DIR}/results.tsv"

server_base="${INFERENCE_SERVER_BASE_URL:-${BASE_URL}}"
if [[ -z "${INFERENCE_SERVER_ID:-}" ]]; then
  echo "[unexpected-bench] metadata preflight ${server_base}/metadata"
  # shellcheck disable=SC1091
  source "${HARNESS_ROOT}/lib/server_preflight.sh"
  server_preflight "${server_base}" "${SUMMARY_DIR}"
else
  echo "[unexpected-bench] using INFERENCE_SERVER_ID=${INFERENCE_SERVER_ID}"
  if [[ ! -f "${SUMMARY_DIR}/metadata.json" ]]; then
    parent_meta="${SUMMARY_DIR%/unexpected_behavior}/metadata.json"
    if [[ -f "${parent_meta}" ]]; then
      cp -f "${parent_meta}" "${SUMMARY_DIR}/metadata.json"
    fi
  fi
fi
init_server_artifacts "${INFERENCE_SERVER_ID}" "${SUMMARY_DIR}"
export INFERENCE_SERVER_ID

echo "[unexpected-bench] preflight health ${BASE_URL}/health"
if ! worker_health_ok "${BASE_URL}/health"; then
  echo "[unexpected-bench] FAIL: endpoint not healthy at ${BASE_URL}" >&2
  exit 1
fi

failures=0
for scenario in "${SCENARIO_LIST[@]}"; do
  scenario="${scenario// /}"
  script="${CASE_ROOT}/steps/${scenario}.sh"
  log_file="${SUMMARY_DIR}/${scenario}.log"
  if [[ ! -x "${script}" ]]; then
    chmod +x "${script}" 2>/dev/null || true
  fi
  if [[ ! -f "${script}" ]]; then
    echo "[unexpected-bench] missing scenario script: ${script}" >&2
    failures=$((failures + 1))
    echo "| ${scenario} | MISSING | - |" >> "${SUMMARY_DIR}/summary.md"
    continue
  fi

  step_started="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  step_server_dir="${SUMMARY_DIR}/server/${scenario}"
  mkdir -p "${step_server_dir}"
  bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" before "${step_server_dir}" || true
  echo "[unexpected-bench] running ${scenario} ..."
  set +e
  bash "${script}" 2>&1 | tee "${log_file}"
  rc=${PIPESTATUS[0]}
  set -e
  step_finished="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  bash "${HARNESS_ROOT}/lib/scrape_server_metrics.sh" after "${step_server_dir}" || true
  mkdir -p "${SUMMARY_DIR}/server"
  cp -f "${step_server_dir}/metrics_after.json" "${SUMMARY_DIR}/server/metrics_after.json" 2>/dev/null || true

  if [[ "${rc}" -eq 0 ]]; then
    status="PASS"
    record_scenario "${scenario}" "PASS"
  else
    status="FAIL"
    record_scenario "${scenario}" "FAIL" "exit=${rc}"
    failures=$((failures + 1))
  fi
  echo "| ${scenario} | ${status} | ${scenario}.log |" >> "${SUMMARY_DIR}/summary.md"

  bench_id="unexpected_behavior__${scenario}"
  if [[ -f "${HARNESS_ROOT}/lib/emit_bench.sh" ]]; then
    bash "${HARNESS_ROOT}/lib/emit_bench.sh" "${bench_id}" "${SUMMARY_DIR}" "${step_started}" "${step_finished}" || {
      echo "[unexpected-bench] WARN: emit failed for ${bench_id}" >&2
    }
    finalize_step_artifacts "${bench_id}" "${SUMMARY_DIR}"
  fi
done

echo "" >> "${SUMMARY_DIR}/summary.md"
if worker_health_ok "${BASE_URL}/health"; then
  echo "- final health: OK" >> "${SUMMARY_DIR}/summary.md"
else
  echo "- final health: **FAIL**" >> "${SUMMARY_DIR}/summary.md"
  failures=$((failures + 1))
fi

echo "[unexpected-bench] summary: ${SUMMARY_DIR}/summary.md"
if [[ "${failures}" -gt 0 ]]; then
  echo "[unexpected-bench] FAIL (${failures} issue(s))" >&2
  exit 1
fi
echo "[unexpected-bench] PASS"
