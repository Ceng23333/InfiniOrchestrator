#!/usr/bin/env bash
# Single-host XiYan slave simulation: stop master GPU workers, advertise LAN IP, start slave.
#
# Prerequisites: docker-compose master stack (registry + router) already deployed.
# See OFFLINE_DEPLOY_GUIDE_ZH_CN.md §「单机 Slave 模拟（无分机）」.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${CASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env" && set +a
fi
if [[ -f "${CASE_DIR}/.env.slave-sim" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env.slave-sim" && set +a
elif [[ -f "${CASE_DIR}/.env.slave-sim.example" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env.slave-sim.example" && set +a
fi

REGISTRY_PORT="${REGISTRY_PORT:-18000}"
ROUTER_PORT="${ROUTER_PORT:-8800}"
SLAVE_XIYAN_API_PORT="${SLAVE_XIYAN_API_PORT:-8200}"
CAPTURE_TIMEOUT_SEC="${CAPTURE_TIMEOUT_SEC:-7200}"
CAPTURE_POLL_SEC="${CAPTURE_POLL_SEC:-30}"

MASTER_CONTAINER="${MASTER_CONTAINER:-infiniorch-master-opt-20260611}"
SLAVE_CONTAINER="${SLAVE_CONTAINER:-infiniorch-worker-slave-xiyan-qwencoder-8200-20260611}"

MASTER_GPU_WORKERS=(
  worker-master-9g-8100
  worker-master-qwen-paged-8200
)

log_step() {
  echo ""
  echo "=========================================="
  echo "$1"
  echo "=========================================="
}

resolve_slave_sim_ip() {
  if [[ -n "${SLAVE_SIM_IP:-}" ]]; then
    echo "${SLAVE_SIM_IP}"
    return 0
  fi
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "${ip}" ]]; then
    echo "Error: could not detect LAN IP; set SLAVE_SIM_IP" >&2
    return 1
  fi
  echo "${ip}"
}

slave_ready() {
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

wait_slave_cg_capture() {
  log_step "[4] XiYan slave CG capture (babysitter log)"
  local deadline=$((SECONDS + CAPTURE_TIMEOUT_SEC))
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${SLAVE_CONTAINER}"; then
      echo "  WARN: slave container not running: ${SLAVE_CONTAINER}"
    elif slave_ready "${SLAVE_CONTAINER}"; then
      echo "  READY ${SLAVE_CONTAINER}"
      return 0
    else
      echo "  waiting ${SLAVE_CONTAINER} ..."
    fi
    sleep "${CAPTURE_POLL_SEC}"
  done
  echo "Error: timed out after ${CAPTURE_TIMEOUT_SEC}s waiting for slave CG capture" >&2
  echo "  Log tail:" >&2
  docker logs "${SLAVE_CONTAINER}" 2>&1 | tail -80 >&2 || true
  return 1
}

wait_registry_slave() {
  local sim_ip="$1"
  log_step "[5] Wait for slave registry entry"
  local deadline=$((SECONDS + 300))
  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    if check_registry_entry "${sim_ip}" 2>/dev/null; then
      return 0
    fi
    echo "  waiting for slave-xiyan-qwencoder-32b in registry ..."
    sleep 5
  done
  check_registry_entry "${sim_ip}"
}

check_registry_entry() {
  local sim_ip="$1"
  local services_json
  services_json="$(curl -s --noproxy "*" "http://127.0.0.1:${REGISTRY_PORT}/services" 2>/dev/null || echo '{}')"

  if ! echo "${services_json}" | grep -q '"name":"slave-xiyan-qwencoder-32b"'; then
    echo "Error: slave-xiyan-qwencoder-32b not found in registry" >&2
    echo "${services_json}" >&2
    return 1
  fi

  if ! echo "${services_json}" | grep -q "\"host\":\"${sim_ip}\""; then
    echo "Error: registry host does not match SLAVE_SIM_IP=${sim_ip}" >&2
    echo "${services_json}" >&2
    return 1
  fi

  if ! echo "${services_json}" | grep -q '"port":8200'; then
    echo "Error: registry port is not 8200" >&2
    echo "${services_json}" >&2
    return 1
  fi

  echo "  Registry OK: slave-xiyan-qwencoder-32b @ ${sim_ip}:8200"
  return 0
}

check_router_reachability() {
  local sim_ip="$1"
  log_step "[6] Router reachability (master → slave LAN IP)"
  if ! docker ps --format '{{.Names}}' | grep -qx "${MASTER_CONTAINER}"; then
    echo "  WARN: master container ${MASTER_CONTAINER} not running; skipping in-container curl"
    curl -sf --connect-timeout 5 --noproxy "*" "http://${sim_ip}:${SLAVE_XIYAN_API_PORT}/v1/models" > /dev/null
    return $?
  fi
  docker exec "${MASTER_CONTAINER}" curl -sf --connect-timeout 5 --noproxy "*" \
    "http://${sim_ip}:${SLAVE_XIYAN_API_PORT}/v1/models" > /dev/null
}

SLAVE_SIM_IP="$(resolve_slave_sim_ip)"
export SLAVE_SIM_IP
export SLAVE_ADVERTISE_HOST="${SLAVE_ADVERTISE_HOST:-${SLAVE_SIM_IP}}"

log_step "Single-host XiYan slave simulation"
echo "  SLAVE_SIM_IP:        ${SLAVE_SIM_IP}"
echo "  SLAVE_ADVERTISE_HOST: ${SLAVE_ADVERTISE_HOST}"
echo "  SLAVE_REGISTRY_URL:  ${SLAVE_REGISTRY_URL:-http://${SLAVE_SIM_IP}:${REGISTRY_PORT}}"
echo "  SLAVE_ROUTER_URL:    ${SLAVE_ROUTER_URL:-http://${SLAVE_SIM_IP}:${ROUTER_PORT}}"
echo "  SLAVE_XIYAN_API_PORT: ${SLAVE_XIYAN_API_PORT}"

cd "${CASE_DIR}"

log_step "[1] Stop master GPU workers (free GPUs 0–7 + port 8200)"
for svc in "${MASTER_GPU_WORKERS[@]}"; do
  echo "  stopping ${svc} ..."
  docker-compose stop "${svc}" 2>/dev/null || true
done

log_step "[2] Ensure master + embeddings running"
docker-compose up -d master worker-master-embeddings-20002

log_step "[3] Start XiYan slave (LAN IP advertise)"
# Slave container cannot reach registry/router on 127.0.0.1 (that is the container itself).
# Default: host LAN IP — same path as a remote slave reaching master on the network.
if [[ "${SLAVE_REGISTRY_URL:-}" == *127.0.0.1* ]]; then
  unset SLAVE_REGISTRY_URL
fi
if [[ "${SLAVE_ROUTER_URL:-}" == *127.0.0.1* ]]; then
  unset SLAVE_ROUTER_URL
fi
SLAVE_REGISTRY_URL_EFFECTIVE="${SLAVE_REGISTRY_URL:-http://${SLAVE_SIM_IP}:${REGISTRY_PORT}}"
SLAVE_ROUTER_URL_EFFECTIVE="${SLAVE_ROUTER_URL:-http://${SLAVE_SIM_IP}:${ROUTER_PORT}}"
echo "  effective SLAVE_REGISTRY_URL: ${SLAVE_REGISTRY_URL_EFFECTIVE}"
echo "  effective SLAVE_ROUTER_URL:   ${SLAVE_ROUTER_URL_EFFECTIVE}"
SLAVE_ADVERTISE_HOST="${SLAVE_ADVERTISE_HOST}" \
SLAVE_REGISTRY_URL="${SLAVE_REGISTRY_URL_EFFECTIVE}" \
SLAVE_ROUTER_URL="${SLAVE_ROUTER_URL_EFFECTIVE}" \
SLAVE_XIYAN_API_PORT="${SLAVE_XIYAN_API_PORT}" \
docker-compose up -d --force-recreate worker-slave-xiyan-qwencoder-8200

wait_slave_cg_capture

wait_registry_slave "${SLAVE_SIM_IP}"

check_router_reachability "${SLAVE_SIM_IP}"

log_step "Slave simulation ready"
echo ""
echo "Restore master GPU workers when done:"
echo "  cd ${CASE_DIR}"
echo "  docker-compose stop worker-slave-xiyan-qwencoder-8200   # frees port 8200"
echo "  docker-compose up -d worker-master-9g-8100 worker-master-qwen-paged-8200"
echo ""
echo "Run full validation:"
echo "  SLAVE_SIM_SKIP_START=1 ./bench/validate_slave_localhost.sh"
