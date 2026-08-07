#!/usr/bin/env bash
# Artifact layout keyed by server_id (metadata + metrics snapshots from HTTP).
set -euo pipefail

init_server_artifacts() {
  local server_id="${1:?server_id required}"
  local suite_dir="${2:?suite_dir required}"
  export SERVER_ARTIFACT_SUITE_DIR="${suite_dir}/${server_id}"
  mkdir -p "${SERVER_ARTIFACT_SUITE_DIR}/client" "${SERVER_ARTIFACT_SUITE_DIR}/server"
  if [[ -f "${suite_dir}/metadata.json" ]]; then
    cp -f "${suite_dir}/metadata.json" "${SERVER_ARTIFACT_SUITE_DIR}/metadata.json"
  fi
}

finalize_step_artifacts() {
  local bench_id="${1:?bench_id required}"
  local step_staging="${2:?step_staging required}"
  if [[ -z "${SERVER_ARTIFACT_SUITE_DIR:-}" ]]; then
    return 0
  fi
  local dest="${SERVER_ARTIFACT_SUITE_DIR}/client/${bench_id}"
  mkdir -p "${dest}"
  if [[ -d "${step_staging}" ]]; then
    cp -a "${step_staging}/." "${dest}/" 2>/dev/null || true
  fi
}
