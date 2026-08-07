#!/usr/bin/env bash
# Scrape GET /metrics before or after a bench step (HTTP only; no server lifecycle).
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/paths.sh"

scrape_server_metrics() {
  local label="${1:?label required (before|after)}"
  local out_dir="${2:?out_dir required}"

  if [[ "${BENCH_SKIP_SERVER_METRICS:-0}" == "1" ]]; then
    mkdir -p "${out_dir}"
    printf '{}\n' > "${out_dir}/metrics_${label}.json"
    : > "${out_dir}/metrics_${label}.prom"
    echo "[scrape_server_metrics] skip (BENCH_SKIP_SERVER_METRICS=1) → ${out_dir}/metrics_${label}.json"
    return 0
  fi

  local base_url="${BENCH_METRICS_URL:-${INFERENCE_SERVER_BASE_URL:-${BASE_URL:-}}}"
  if [[ -z "${base_url}" ]]; then
    echo "[scrape_server_metrics] BENCH_METRICS_URL or INFERENCE_SERVER_BASE_URL required" >&2
    exit 1
  fi

  cd "${BENCH_WAREHOUSE_REPO}"
  python3 -m bench_harness.server_client scrape \
    --base-url "${base_url}" \
    --out-dir "${out_dir}" \
    --label "${label}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  scrape_server_metrics "${1:?}" "${2:?}"
fi
