#!/usr/bin/env bash
# Validate opt20260811 via validate-case (M0 alpha) with legacy env bootstrap.
#
# Usage (from docker-compose/): ./validate.sh localhost
# Optional: VALIDATE_LEGACY=1 runs the pre-M0 curl checks after validate-case.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
CASE_PATH="${CASE_PATH:-${SCRIPT_DIR}/../case.toml}"

_OV_WORKER_9G_API_PORT="${WORKER_9G_API_PORT-}"
_OV_WORKER_9G_BABYSITTER_PORT="${WORKER_9G_BABYSITTER_PORT-}"
_OV_WORKER_QWEN_API_PORT="${WORKER_QWEN_API_PORT-}"
_OV_WORKER_QWEN_BABYSITTER_PORT="${WORKER_QWEN_BABYSITTER_PORT-}"
_OV_EMBEDDING_PORT="${EMBEDDING_PORT-}"
_OV_SKIP_EMBEDDING="${SKIP_EMBEDDING-}"

ENV_FILE=""
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  ENV_FILE="${SCRIPT_DIR}/.env"
  set -a
  # shellcheck disable=SC1091
  . "${ENV_FILE}"
  set +a
fi

[[ -n "${_OV_WORKER_9G_API_PORT}" ]] && export WORKER_9G_API_PORT="${_OV_WORKER_9G_API_PORT}"
[[ -n "${_OV_WORKER_9G_BABYSITTER_PORT}" ]] && export WORKER_9G_BABYSITTER_PORT="${_OV_WORKER_9G_BABYSITTER_PORT}"
[[ -n "${_OV_WORKER_QWEN_API_PORT}" ]] && export WORKER_QWEN_API_PORT="${_OV_WORKER_QWEN_API_PORT}"
[[ -n "${_OV_WORKER_QWEN_BABYSITTER_PORT}" ]] && export WORKER_QWEN_BABYSITTER_PORT="${_OV_WORKER_QWEN_BABYSITTER_PORT}"
[[ -n "${_OV_EMBEDDING_PORT}" ]] && export EMBEDDING_PORT="${_OV_EMBEDDING_PORT}"
[[ -n "${_OV_SKIP_EMBEDDING}" ]] && export SKIP_EMBEDDING="${_OV_SKIP_EMBEDDING}"

export no_proxy="${no_proxy:-*}"
export NO_PROXY="${NO_PROXY:-*}"
export FRONTEND_HOST="${1:-localhost}"

usage() {
  echo "Usage: $0 <FRONTEND_HOST>"
  echo "  Delegates to harness/bin/validate-case using ${CASE_PATH}"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-infiniorch-frontend-opt-20260811}"

echo "=========================================="
echo "InfiniOrchestrator opt20260811 Validation"
echo "=========================================="
echo "Frontend host: ${FRONTEND_HOST}"
echo "Case:          ${CASE_PATH}"
echo ""

_validate_args=(
  --case-path "${CASE_PATH}"
  --host "${FRONTEND_HOST}"
  --container "${CONTAINER_NAME}"
)
if [[ -n "${ENV_FILE}" ]]; then
  _validate_args+=(--env-file "${ENV_FILE}")
fi

set +e
"${IO_ROOT}/harness/bin/validate-case" "${_validate_args[@]}"
_rc=$?
set -e

if [[ "${VALIDATE_LEGACY:-0}" == "1" ]]; then
  echo ""
  echo "[legacy] Running supplemental curl checks..."
  REGISTRY_PORT="${REGISTRY_PORT:-18000}"
  ROUTER_PORT="${ROUTER_PORT:-8800}"
  REGISTRY_URL="http://${FRONTEND_HOST}:${REGISTRY_PORT}"
  ROUTER_URL="http://${FRONTEND_HOST}:${ROUTER_PORT}"
  curl -sf --noproxy "*" "${REGISTRY_URL}/health" >/dev/null && echo "  legacy registry /health OK"
  curl -sf --noproxy "*" "${ROUTER_URL}/health" >/dev/null && echo "  legacy router /health OK"
fi

exit "${_rc}"
