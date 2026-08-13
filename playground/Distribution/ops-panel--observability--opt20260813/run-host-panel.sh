#!/usr/bin/env bash
# Host-native Frontend/panel (no container image rebuild required).
# Default port 18880 avoids fighting a live Distribution Frontend on 8800.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
RUST_DIR="${ROOT}/InfiniOrchestrator/rust"
WAREHOUSE="${BENCH_WAREHOUSE_REPO:-${ROOT}/bench-warehouse}"
PORT="${FRONTEND_HOST_PORT:-${PANEL_HOST_PORT:-18880}}"

if ss -lntp 2>/dev/null | grep -q ":${PORT} "; then
  echo "[run-host-panel] error: port ${PORT} already in use." >&2
  echo "  A Distribution Frontend may already serve /panel (e.g. opt20260811 on 8800)." >&2
  echo "  Reuse that Frontend, or: FRONTEND_HOST_PORT=18880 $0" >&2
  echo "  For Prom/Grafana only: cd docker-compose && PROM_CONFIG=prometheus-host.yml ./compose.sh --profile observability up -d" >&2
  exit 98
fi

export BENCH_WAREHOUSE_REPO="${WAREHOUSE}"
export IO_ROOT="${ROOT}/InfiniOrchestrator"
cd "${RUST_DIR}"

echo "[run-host-panel] warehouse=${BENCH_WAREHOUSE_REPO}"
echo "[run-host-panel] io_root=${IO_ROOT}"
echo "[run-host-panel] listening http://0.0.0.0:${PORT}/panel"
exec cargo run --release --bin infini-loadbalancer -- --load-balancer-port "${PORT}"
