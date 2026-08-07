#!/usr/bin/env bash
# Full single-host XiYan slave validation: simulate + validate.sh + registry gate + summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../../" && pwd)"

if [[ -f "${CASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env" && set +a
fi
if [[ -f "${CASE_DIR}/.env.slave-sim" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env.slave-sim" && set +a
fi

REGISTRY_PORT="${REGISTRY_PORT:-18000}"
ROUTER_PORT="${ROUTER_PORT:-8800}"
EMBEDDING_PORT="${EMBEDDING_PORT:-20003}"
SLAVE_XIYAN_API_PORT="${SLAVE_XIYAN_API_PORT:-8200}"

TS="$(date +%Y%m%d_%H%M%S)"
SUMMARY_DIR="${SUMMARY_DIR:-${REPO_ROOT}/bench_results/slave_sim_${TS}}"
mkdir -p "${SUMMARY_DIR}"
SUMMARY_FILE="${SUMMARY_DIR}/summary.md"

resolve_slave_sim_ip() {
  if [[ -n "${SLAVE_SIM_IP:-}" ]]; then
    echo "${SLAVE_SIM_IP}"
    return 0
  fi
  hostname -I 2>/dev/null | awk '{print $1}'
}

record_step() {
  local name="$1"
  local status="$2"
  local detail="${3:-}"
  echo "- **${name}**: ${status}" >> "${SUMMARY_FILE}"
  if [[ -n "${detail}" ]]; then
    echo "  - ${detail}" >> "${SUMMARY_FILE}"
  fi
}

SLAVE_SIM_IP="$(resolve_slave_sim_ip)"
export SLAVE_SIM_IP

{
  echo "# Slave localhost simulation ${TS}"
  echo ""
  echo "- Case: infinilm-metax-deployment-opt-20260714"
  echo "- SLAVE_SIM_IP: ${SLAVE_SIM_IP}"
  echo "- Router: http://localhost:${ROUTER_PORT}"
  echo "- Registry: http://localhost:${REGISTRY_PORT}"
  echo ""
} > "${SUMMARY_FILE}"

FAILED=0

if [[ "${SLAVE_SIM_SKIP_START:-0}" != "1" ]]; then
  echo "=========================================="
  echo "[1] simulate_slave_localhost.sh"
  echo "=========================================="
  sim_log="${SUMMARY_DIR}/simulate_slave_localhost.log"
  if "${SCRIPT_DIR}/simulate_slave_localhost.sh" 2>&1 | tee "${sim_log}"; then
    record_step "simulate_slave_localhost" "PASS"
  else
    record_step "simulate_slave_localhost" "FAIL" "see ${sim_log}"
    FAILED=1
  fi
else
  echo "Skipping simulate (SLAVE_SIM_SKIP_START=1)"
  record_step "simulate_slave_localhost" "SKIP" "SLAVE_SIM_SKIP_START=1"
fi

if [[ "${FAILED}" -eq 0 ]]; then
  echo ""
  echo "=========================================="
  echo "[2] validate.sh (xiyan)"
  echo "=========================================="
  val_log="${SUMMARY_DIR}/validate.log"
  if env ROUTER_PORT="${ROUTER_PORT}" EMBEDDING_PORT="${EMBEDDING_PORT}" \
    "${CASE_DIR}/validate.sh" localhost "${SLAVE_SIM_IP}" xiyan 2>&1 | tee "${val_log}"; then
    record_step "validate.sh xiyan" "PASS"
  else
    record_step "validate.sh xiyan" "FAIL" "see ${val_log}"
    FAILED=1
  fi
fi

if [[ "${FAILED}" -eq 0 ]]; then
  echo ""
  echo "=========================================="
  echo "[3] Registry URL sanity (LAN IP:8200)"
  echo "=========================================="
  services_json="$(curl -s --noproxy "*" "http://127.0.0.1:${REGISTRY_PORT}/services" 2>/dev/null || echo '{}')"
  reg_log="${SUMMARY_DIR}/registry_services.json"
  echo "${services_json}" > "${reg_log}"

  if echo "${services_json}" | grep -q "\"host\":\"${SLAVE_SIM_IP}\"" \
    && echo "${services_json}" | grep -q '"name":"slave-xiyan-qwencoder-32b"' \
    && echo "${services_json}" | grep -q "\"port\":${SLAVE_XIYAN_API_PORT}"; then
    record_step "registry LAN IP" "PASS" "slave @ ${SLAVE_SIM_IP}:${SLAVE_XIYAN_API_PORT}"
  else
    record_step "registry LAN IP" "FAIL" "see ${reg_log}"
    FAILED=1
  fi
fi

echo "" >> "${SUMMARY_FILE}"
if [[ "${FAILED}" -eq 0 ]]; then
  echo "**Overall: PASS**" >> "${SUMMARY_FILE}"
  echo ""
  echo "Validation PASS — summary: ${SUMMARY_FILE}"
  exit 0
else
  echo "**Overall: FAIL**" >> "${SUMMARY_FILE}"
  echo ""
  echo "Validation FAIL — summary: ${SUMMARY_FILE}"
  exit 1
fi
