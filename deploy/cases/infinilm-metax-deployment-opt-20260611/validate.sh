#!/usr/bin/env bash
# Validate infinilm-metax-deployment-opt-20260611 (registry, router, master backends, optional slave)

set -e

usage() {
  echo "Usage:"
  echo "  $0 <REGISTRY_IP> [SLAVE_IP] [SLAVE_PRESET] [MASTER_PRESET]"
  echo ""
  echo "SLAVE_PRESET (when SLAVE_IP given): xiyan (default), fla, 2static(compat), 1static1vllm, 3vllm, or 1paged2vllm"
  echo "MASTER_PRESET (optional): when 3vllm, expect master-3vllm-vllm-1 instead of master-qwen3-32b-paged"
  echo ""
  echo "Examples:"
  echo "  $0 192.168.163.151"
  echo "  $0 192.168.163.151 192.168.163.152"
  echo "  $0 192.168.163.151 192.168.163.152 xiyan"
  echo "  $0 192.168.163.151 192.168.163.152 fla"
  echo "  $0 192.168.163.151 192.168.163.152 1static1vllm"
  echo "  $0 192.168.163.151 192.168.163.152 3vllm 3vllm"
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

REGISTRY_IP="${1:-localhost}"
SLAVE_IP="${2:-}"
SLAVE_PRESET="${3:-${SLAVE_PRESET:-xiyan}}"
MASTER_PRESET="${4:-${MASTER_PRESET:-}}"

REGISTRY_PORT="${REGISTRY_PORT:-18000}"
ROUTER_PORT="${ROUTER_PORT:-8000}"
EMBEDDING_PORT="${EMBEDDING_PORT:-20002}"
REGISTRY_URL="http://${REGISTRY_IP}:${REGISTRY_PORT}"
ROUTER_URL="http://${REGISTRY_IP}:${ROUTER_PORT}"
EMBEDDING_URL="http://${REGISTRY_IP}:${EMBEDDING_PORT}"

CONTAINER_NAME="${CONTAINER_NAME:-infiniorch-master-opt-20260611}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

echo "=========================================="
echo "InfiniOrchestrator infinilm-metax-deployment-opt-20260611 Validation"
echo "=========================================="
echo "Registry IP:  ${REGISTRY_IP}"
echo "Slave IP:     ${SLAVE_IP:-none}"
echo "Slave preset:  ${SLAVE_PRESET:-n/a}"
echo "Master preset: ${MASTER_PRESET:-default}"
echo "Registry:     ${REGISTRY_URL}"
echo "Router:      ${ROUTER_URL}"
echo ""

check() {
  local url=$1
  local name=$2
  echo -n "  Checking ${name}... "
  if curl -s -f --connect-timeout 3 --noproxy "*" "${url}" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
    PASSED=$((PASSED + 1))
    return 0
  else
    echo -e "${RED}FAIL${NC}"
    FAILED=$((FAILED + 1))
    return 1
  fi
}

echo -e "${BLUE}[1] Core health${NC}"
check "${REGISTRY_URL}/health" "Registry /health"
check "${ROUTER_URL}/health" "Router /health"
echo ""

echo -e "${BLUE}[2] Service discovery${NC}"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  services_json="$(docker exec "${CONTAINER_NAME}" curl -s --noproxy "*" "http://127.0.0.1:${REGISTRY_PORT}/services" 2>/dev/null || curl -s --noproxy "*" "${REGISTRY_URL}/services" 2>/dev/null || echo '{}')"
else
  services_json="$(curl -s --noproxy "*" "${REGISTRY_URL}/services" 2>/dev/null || echo '{}')"
fi
service_count="$(echo "${services_json}" | grep -o '"name"' | wc -l || echo "0")"
echo "  Found ${service_count} services"

# Expected master services: depend on MASTER_PRESET
if [ "${MASTER_PRESET}" = "3vllm" ]; then
  expected_services=("master-9g_8b_thinking" "master-3vllm-vllm-1")
else
  expected_services=("master-9g_8b_thinking" "master-qwen3-32b-paged" "master-embeddings")
fi
# Optional slave preset services
if [ -n "${SLAVE_IP}" ]; then
  case "${SLAVE_PRESET}" in
    xiyan)
      expected_services+=("slave-xiyan-qwencoder-32b")
      ;;
    fla)
      expected_services+=("slave-fla-9g" "slave-fla-qwen-paged")
      ;;
    2static)
      expected_services+=("slave-fla-9g" "slave-fla-qwen-paged")
      ;;
    1static1vllm)
      expected_services+=("slave-1static1vllm-static-1" "slave-1static1vllm-vllm-1")
      ;;
    3vllm)
      expected_services+=("slave-3vllm-vllm-1" "slave-3vllm-vllm-2")
      ;;
    1paged2vllm)
      expected_services+=("slave-3vllm-vllm-1" "slave-3vllm-vllm-2")
      ;;
    *)
      echo "  Warning: Unknown SLAVE_PRESET '${SLAVE_PRESET}'; expecting xiyan, fla, 2static, 1static1vllm, 3vllm, or 1paged2vllm"
      ;;
  esac
fi
for svc in "${expected_services[@]}"; do
  if echo "${services_json}" | grep -q "\"name\":\"${svc}\""; then
    echo -e "    ${GREEN}OK${NC} ${svc}"
  else
    echo -e "    ${YELLOW}missing${NC} ${svc}"
  fi
done
echo ""

echo -e "${BLUE}[3] Model aggregation${NC}"
models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/models" 2>/dev/null || echo '{}')"
model_ids="$(echo "${models_json}" | grep -o '"id":"[^"]*"' | sed 's/"id":"\([^"]*\)"/\1/' | tr '\n' ' ' || echo '')"
if [ -z "${model_ids}" ] || [ "${model_ids}" = " " ]; then
  echo -e "  ${RED}No models found${NC}"
else
  for model_id in ${model_ids}; do
    echo "  Found model: ${model_id}"
  done
fi
echo ""

echo -e "${BLUE}[4] Chat completions via router${NC}"
# Test all models from step 3 (skip permission-style ids like modelperm-*)
test_models="9g_8b_thinking"
if [ -n "${model_ids}" ] && [ "${model_ids}" != " " ]; then
  test_models=""
  for model_id in ${model_ids}; do
    case "${model_id}" in
      modelperm-*) ;;
      *) test_models="${test_models} ${model_id}" ;;
    esac
  done
  test_models="${test_models# }"
fi
if [ -z "${test_models}" ]; then
  test_models="9g_8b_thinking"
fi
for test_model in ${test_models}; do
  echo -n "  Testing model: ${test_model}... "
  if [ "${test_model}" = "XiYanSQL-QwenCoder-32B-2504" ]; then
    user_content="SELECT 1"
  else
    user_content="Hello"
  fi
  request_data="{\"model\": \"${test_model}\", \"messages\": [{\"role\": \"user\", \"content\": \"${user_content}\"}], \"stream\": false, \"max_tokens\": 32}"
  resp="$(curl -s -X POST --noproxy "*" "${ROUTER_URL}/v1/chat/completions" -H "Content-Type: application/json" -d "${request_data}" 2>/dev/null || echo '{}')"
  if echo "${resp}" | grep -q '"object"'; then
    echo -e "${GREEN}OK${NC}"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}FAIL${NC}"
    FAILED=$((FAILED + 1))
    echo "    Response: ${resp}"
  fi
done
echo ""

echo -e "${BLUE}[5] Embedding endpoint (required)${NC}"
embedding_registered=0
if echo "${services_json}" | grep -q "\"name\":\"master-embeddings\""; then
  embedding_registered=1
fi

if [ "${embedding_registered}" -eq 0 ]; then
  echo -e "  ${YELLOW}WARN${NC} master-embeddings-server not found in /services, fallback to endpoint probe"
fi

echo -n "  Testing embeddings: ${EMBEDDING_URL}/v1/embeddings ... "
emb_req='{"model":"text-embedding-ada-002","input":"hello"}'
emb_resp="$(curl -s -X POST --noproxy "*" "${EMBEDDING_URL}/v1/embeddings" -H "Content-Type: application/json" -d "${emb_req}" 2>/dev/null || echo '{}')"
if echo "${emb_resp}" | grep -Eq '"object"[[:space:]]*:[[:space:]]*"list"'; then
  echo -e "${GREEN}OK${NC}"
  PASSED=$((PASSED + 1))
else
  echo -e "${RED}FAIL${NC}"
  FAILED=$((FAILED + 1))
  echo "    Response: ${emb_resp}"
fi
echo ""

echo "=========================================="
echo "Validation complete"
echo "=========================================="
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"

if [ "${FAILED}" -gt 0 ]; then
  exit 1
fi
