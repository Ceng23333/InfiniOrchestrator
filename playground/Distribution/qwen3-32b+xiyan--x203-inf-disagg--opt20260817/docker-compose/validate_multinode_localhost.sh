#!/usr/bin/env bash
# Validate fake multi-node (LAN IP advertise path) for opt20260811.
#
# Prerequisites: ./simulate_multinode_localhost.sh succeeded.
# Usage (from docker-compose/): ./validate_multinode_localhost.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env"
  set +a
fi
if [[ -f "${SCRIPT_DIR}/.env.workers" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env.workers"
  set +a
fi
if [[ -f "${SCRIPT_DIR}/.env.workers-sim" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env.workers-sim"
  set +a
elif [[ -f "${SCRIPT_DIR}/.env.workers-sim.example" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env.workers-sim.example"
  set +a
fi

export no_proxy="${no_proxy:-*}"
export NO_PROXY="${NO_PROXY:-*}"

resolve_sim_ip() {
  if [[ -n "${MULTINODE_SIM_IP:-}" ]]; then
    echo "${MULTINODE_SIM_IP}"
    return 0
  fi
  if [[ -n "${ADVERTISE_HOST:-}" && "${ADVERTISE_HOST}" != "127.0.0.1" ]]; then
    echo "${ADVERTISE_HOST}"
    return 0
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

SIM_IP="$(resolve_sim_ip)"
if [[ -z "${SIM_IP}" || "${SIM_IP}" == "127.0.0.1" ]]; then
  echo "Error: set MULTINODE_SIM_IP to the LAN IP used by simulate_multinode_localhost.sh" >&2
  exit 1
fi

ROUTER_PORT="${ROUTER_PORT:-8800}"
REGISTRY_PORT="${REGISTRY_PORT:-18000}"
EMBEDDING_PORT="${EMBEDDING_PORT:-20002}"
WORKER_QWEN_API_PORT="${WORKER_QWEN_API_PORT:-8200}"
WORKER_9G_API_PORT="${WORKER_9G_API_PORT:-8100}"
WORKER_QWEN_BABYSITTER_PORT="${WORKER_QWEN_BABYSITTER_PORT:-8201}"
WORKER_9G_BABYSITTER_PORT="${WORKER_9G_BABYSITTER_PORT:-8101}"

FRONTEND_CONTAINER="${FRONTEND_CONTAINER:-infiniorch-frontend-opt-20260811}"
WORKER_9G_CONTAINER="${WORKER_9G_CONTAINER:-infiniorch-worker-9g-8100-20260811}"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
PASSED=0
FAILED=0

pass() { echo -e "  ${GREEN}OK${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAILED=$((FAILED + 1)); }

echo "=========================================="
echo "Multinode validation (LAN path)"
echo "=========================================="
echo "SIM_IP=${SIM_IP}"
echo ""

echo -e "${BLUE}[1] Base Frontend smoke (validate.sh; SKIP_EMBEDDING=${SKIP_EMBEDDING:-0})${NC}"
if CONTAINER_NAME="${FRONTEND_CONTAINER}" \
  ROUTER_PORT="${ROUTER_PORT}" EMBEDDING_PORT="${EMBEDDING_PORT}" \
  SKIP_EMBEDDING="${SKIP_EMBEDDING:-0}" \
  ./validate.sh "${SIM_IP}"; then
  pass "validate.sh ${SIM_IP}"
else
  fail "validate.sh ${SIM_IP}"
fi
echo ""

echo -e "${BLUE}[2] Registry advertise host == LAN IP${NC}"
services_json="$(curl -s --noproxy "*" "http://${SIM_IP}:${REGISTRY_PORT}/services" 2>/dev/null || echo '{}')"
# Prefer openai-api managed names (*-server); also accept babysitter parent name.
for svc in master-9g_8b_thinking-server master-qwen3-32b-paged-server master-embeddings-server; do
  if [[ "${SKIP_EMBEDDING:-0}" == "1" && "${svc}" == "master-embeddings-server" ]]; then
    echo -e "  ${GREEN}SKIP${NC} ${svc} (SKIP_EMBEDDING=1)"
    continue
  fi
  if echo "${services_json}" | grep -q "${svc}"; then
    # Extract a nearby host field: loose check that SIM_IP appears with this service block
    if echo "${services_json}" | tr '{' '\n' | grep -F "${svc}" | grep -q "${SIM_IP}"; then
      pass "${svc} host contains ${SIM_IP}"
    else
      # Fallback: whole JSON has SIM_IP and service name (same-host DNS would be worker-*)
      if echo "${services_json}" | grep -q "${SIM_IP}" && ! echo "${services_json}" | grep -q "worker-9g-8100"; then
        pass "${svc} present; SIM_IP in /services (no docker-dns worker-9g-8100)"
      elif echo "${services_json}" | grep -q "\"host\":\"${SIM_IP}\""; then
        pass "${svc} registered; host=${SIM_IP} seen in /services"
      else
        fail "${svc} missing host=${SIM_IP} (got docker DNS?). Snippet: $(echo "${services_json}" | head -c 400)"
      fi
    fi
  else
    fail "${svc} missing from /services"
  fi
done
echo ""

echo -e "${BLUE}[3] Frontend container → worker LAN ports${NC}"
if docker ps --format '{{.Names}}' | grep -qx "${FRONTEND_CONTAINER}"; then
  if docker exec "${FRONTEND_CONTAINER}" curl -sf --connect-timeout 3 --noproxy "*" \
    "http://${SIM_IP}:${WORKER_QWEN_API_PORT}/v1/models" >/dev/null 2>&1; then
    pass "frontend → ${SIM_IP}:${WORKER_QWEN_API_PORT}/v1/models"
  else
    fail "frontend → ${SIM_IP}:${WORKER_QWEN_API_PORT}/v1/models (check ip_forward / bridge)"
  fi
  if docker exec "${FRONTEND_CONTAINER}" curl -sf --connect-timeout 3 --noproxy "*" \
    "http://${SIM_IP}:${WORKER_9G_API_PORT}/v1/models" >/dev/null 2>&1; then
    pass "frontend → ${SIM_IP}:${WORKER_9G_API_PORT}/v1/models"
  else
    fail "frontend → ${SIM_IP}:${WORKER_9G_API_PORT}/v1/models"
  fi
  if [[ "${SKIP_EMBEDDING:-0}" != "1" ]]; then
    if docker exec "${FRONTEND_CONTAINER}" curl -sf --connect-timeout 3 --noproxy "*" \
      "http://${SIM_IP}:${EMBEDDING_PORT}/v1/models" >/dev/null 2>&1; then
      pass "frontend → ${SIM_IP}:${EMBEDDING_PORT}/v1/models"
    else
      fail "frontend → ${SIM_IP}:${EMBEDDING_PORT}/v1/models"
    fi
  fi
else
  fail "frontend container ${FRONTEND_CONTAINER} not running"
fi
echo ""

echo -e "${BLUE}[4] Worker container → Frontend LAN health${NC}"
if docker ps --format '{{.Names}}' | grep -qx "${WORKER_9G_CONTAINER}"; then
  if docker exec "${WORKER_9G_CONTAINER}" curl -sf --connect-timeout 3 --noproxy "*" \
    "http://${SIM_IP}:${ROUTER_PORT}/health" >/dev/null 2>&1; then
    pass "worker-9g → ${SIM_IP}:${ROUTER_PORT}/health"
  else
    fail "worker-9g → ${SIM_IP}:${ROUTER_PORT}/health"
  fi
else
  fail "worker container ${WORKER_9G_CONTAINER} not running"
fi
echo ""

echo "=========================================="
echo "Multinode validation complete"
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
echo "=========================================="

if [[ "${FAILED}" -gt 0 ]]; then
  exit 1
fi
