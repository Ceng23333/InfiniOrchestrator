#!/usr/bin/env bash
# Multi-file compose wrapper using shared deploy/docker-compose fragments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAG="$(cd "${SCRIPT_DIR}/../../../../deploy/docker-compose" && pwd)"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-docker-compose}"
export PROM_CONFIG_FILE="${PROM_CONFIG_FILE:-${FRAG}/observability/${PROM_CONFIG:-prometheus.yml}}"
export GRAFANA_PROVISIONING_DIR="${GRAFANA_PROVISIONING_DIR:-${FRAG}/observability/grafana/provisioning}"

ENV_ARGS=()
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  ENV_ARGS+=(--env-file "${SCRIPT_DIR}/.env")
fi

cd "${SCRIPT_DIR}"
exec docker-compose \
  --project-directory "${SCRIPT_DIR}" \
  "${ENV_ARGS[@]}" \
  -f "${FRAG}/etcd.yml" \
  -f "${FRAG}/frontend.yml" \
  -f "${FRAG}/observability.yml" \
  -f "${SCRIPT_DIR}/docker-compose.yml" \
  "$@"
