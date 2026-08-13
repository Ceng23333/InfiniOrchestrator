#!/usr/bin/env bash
# Usage (from docker-compose/): ./validate.sh [host-ip-or-localhost]
set -euo pipefail

HOST="${1:-localhost}"
FRONTEND_HOST_PORT="${FRONTEND_HOST_PORT:-8800}"
PROM_HOST_PORT="${PROM_HOST_PORT:-9090}"
GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-3000}"

if [ -f "$(dirname "$0")/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$(dirname "$0")/.env"
  set +a
fi

FRONTEND_HOST_PORT="${FRONTEND_HOST_PORT:-8800}"
PROM_HOST_PORT="${PROM_HOST_PORT:-9090}"
GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-3000}"

echo "[validate] frontend http://${HOST}:${FRONTEND_HOST_PORT}/panel"
curl -fsS "http://${HOST}:${FRONTEND_HOST_PORT}/panel" >/dev/null || \
  echo "[validate] warn: /panel not reachable (obs-only mode?)"

echo "[validate] prometheus http://${HOST}:${PROM_HOST_PORT}/-/ready"
curl -fsS "http://${HOST}:${PROM_HOST_PORT}/-/ready" >/dev/null

echo "[validate] grafana http://${HOST}:${GRAFANA_HOST_PORT}/api/health"
curl -fsS "http://${HOST}:${GRAFANA_HOST_PORT}/api/health" >/dev/null

echo "[validate] ok"
