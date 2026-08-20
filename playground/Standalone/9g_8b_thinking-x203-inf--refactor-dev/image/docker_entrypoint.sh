#!/usr/bin/env bash
# Minimal product entrypoint for InfiniOrchestrator InfiniEntrypoint stack.
# LAUNCH_COMPONENTS (comma-separated):
#   etcd,loadbalancer  — master control plane
#   entrypoint         — worker (reads BABYSITTER_CONFIGS / ENTRYPOINT_CONFIGS TOML)
#   babysitter         — alias for entrypoint (compat)
set -euo pipefail

if [[ -f /opt/conda/etc/profile.d/conda.sh ]]; then
  # shellcheck disable=SC1091
  source /opt/conda/etc/profile.d/conda.sh
  conda activate base
fi
if [[ -f /app/env-set.sh ]]; then
  # shellcheck disable=SC1091
  source /app/env-set.sh
fi

mkdir -p /workspace /app/logs
LAUNCH_COMPONENTS="$(echo "${LAUNCH_COMPONENTS:-none}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"

_start_etcd() {
  if command -v etcd >/dev/null 2>&1; then
    # Prefer INFINI_* name — bare ETCD_ADVERTISE_CLIENT_URLS conflicts with etcd's own flag parsing.
    local advertise="${INFINI_ETCD_ADVERTISE_CLIENT_URLS:-${ETCD_ADVERTISE_URL:-http://127.0.0.1:2379}}"
    echo "[entrypoint] starting etcd on :2379 (advertise ${advertise})"
    # Unset etcd server env knobs that clash with explicit flags / client-only vars.
    env -u ETCD_ADVERTISE_CLIENT_URLS -u ETCD_ENDPOINTS -u ETCD_LISTEN_CLIENT_URLS \
      etcd --listen-client-urls http://0.0.0.0:2379 \
      --advertise-client-urls "${advertise}" \
      --data-dir /tmp/etcd-data \
      >/app/logs/etcd.log 2>&1 &
    echo $! >/app/logs/etcd.pid
    # Brief wait so loadbalancer can connect on the same container.
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if etcdctl --endpoints=http://127.0.0.1:2379 endpoint health >/dev/null 2>&1; then
        echo "[entrypoint] etcd healthy"
        break
      fi
      sleep 0.5
    done
  else
    echo "[entrypoint] WARN: etcd binary not found; set ETCD_ENDPOINTS to an external cluster" >&2
  fi
}

_start_loadbalancer() {
  local bin
  bin="$(command -v infini-loadbalancer || true)"
  if [[ -z "${bin}" ]]; then
    echo "[entrypoint] error: infini-loadbalancer not on PATH" >&2
    exit 1
  fi
  local port="${ROUTER_PORT:-8000}"
  local etcd_eps="${ETCD_ENDPOINTS:-http://127.0.0.1:2379}"
  local prefix="${DISCOVERY_PREFIX:-/infini/orchestrator}"
  echo "[entrypoint] starting infini-loadbalancer port=${port}"
  "${bin}" \
    --load-balancer-port "${port}" \
    --etcd-endpoints "${etcd_eps}" \
    --discovery-prefix "${prefix}" \
    >/app/logs/loadbalancer.log 2>&1 &
  echo $! >/app/logs/loadbalancer.pid
}

_start_entrypoint_worker() {
  local bin cfg
  bin="$(command -v infini-entrypoint || command -v infini-babysitter || true)"
  if [[ -z "${bin}" ]]; then
    echo "[entrypoint] error: infini-entrypoint not on PATH" >&2
    exit 1
  fi
  cfg="${ENTRYPOINT_CONFIGS:-${BABYSITTER_CONFIGS:-}}"
  if [[ -z "${cfg}" ]]; then
    echo "[entrypoint] error: set ENTRYPOINT_CONFIGS or BABYSITTER_CONFIGS" >&2
    exit 1
  fi
  # First config path only for single-worker compose services.
  cfg="${cfg%% *}"
  echo "[entrypoint] exec ${bin} --config-file ${cfg}"
  # shellcheck disable=SC2086
  exec "${bin}" --config-file "${cfg}" \
    ${BABYSITTER_HOST:+--host "${BABYSITTER_HOST}"} \
    ${REGISTRY_URL:+--registry-url "${REGISTRY_URL}"} \
    ${ROUTER_URL:+--load-balancer-url "${ROUTER_URL}"} \
    ${ETCD_ENDPOINTS:+--etcd-endpoints "${ETCD_ENDPOINTS}"} \
    ${DISCOVERY_PREFIX:+--discovery-prefix "${DISCOVERY_PREFIX}"}
}

_shutdown() {
  echo "[entrypoint] shutting down..."
  for pidf in /app/logs/*.pid; do
    [[ -f "${pidf}" ]] || continue
    kill "$(cat "${pidf}")" 2>/dev/null || true
  done
  exit 0
}
trap _shutdown SIGTERM SIGINT

if [[ "${LAUNCH_COMPONENTS}" == "none" || -z "${LAUNCH_COMPONENTS}" ]]; then
  echo "[entrypoint] LAUNCH_COMPONENTS=none; sleeping"
  exec sleep infinity
fi

IFS=',' read -ra _comps <<< "${LAUNCH_COMPONENTS}"
_run_worker=0
for c in "${_comps[@]}"; do
  case "${c}" in
    etcd) _start_etcd ;;
    loadbalancer|router) _start_loadbalancer ;;
    entrypoint|babysitter) _run_worker=1 ;;
    registry)
      echo "[entrypoint] WARN: infini-registry removed; use etcd discovery" >&2
      ;;
    *)
      echo "[entrypoint] WARN: unknown component '${c}'" >&2
      ;;
  esac
done

if [[ "${_run_worker}" == "1" ]]; then
  _start_entrypoint_worker
fi

echo "[entrypoint] control-plane up; waiting on signals"
wait
