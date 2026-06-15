#!/usr/bin/env bash
# Validate infinilm-metax-deployment-opt-20260611 (registry, router, master backends, optional XiYan slave)

set -e

usage() {
  echo "Usage:"
  echo "  $0 <REGISTRY_IP> [SLAVE_IP]"
  echo ""
  echo "Examples:"
  echo "  $0 192.168.163.151"
  echo "  $0 192.168.163.151 192.168.163.152"
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

REGISTRY_IP="${1:-localhost}"
SLAVE_IP="${2:-}"

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

expected_services=("master-9g_8b_thinking" "master-qwen3-32b-paged" "master-embeddings")
if [ -n "${SLAVE_IP}" ]; then
  expected_services+=("slave-xiyan-qwencoder-32b")
fi
for svc in "${expected_services[@]}"; do
  if echo "${services_json}" | grep -q "\"name\":\"${svc}\""; then
    echo -e "    ${GREEN}OK${NC} ${svc}"
  else
    echo -e "    ${YELLOW}missing${NC} ${svc}"
  fi
done
echo ""

expected_models=("9g_8b_thinking" "Qwen3-32B")
if [ -n "${SLAVE_IP}" ]; then
  expected_models+=("XiYanSQL-QwenCoder-32B-2504")
fi

echo -e "${BLUE}[3] Model aggregation${NC}"
models_json="$(curl -s --noproxy "*" "${ROUTER_URL}/models" 2>/dev/null || echo '{}')"
model_ids="$(echo "${models_json}" | grep -o '"id":"[^"]*"' | sed 's/"id":"\([^"]*\)"/\1/' | tr '\n' ' ' || echo '')"
for model_id in "${expected_models[@]}"; do
  if echo "${models_json}" | grep -q "\"id\":\"${model_id}\""; then
    echo -e "  ${GREEN}OK${NC} model: ${model_id}"
  else
    echo -e "  ${RED}missing${NC} model: ${model_id}"
    FAILED=$((FAILED + 1))
  fi
done
if [ -z "${model_ids}" ] || [ "${model_ids}" = " " ]; then
  if [ "${#expected_models[@]}" -eq 0 ]; then
    echo -e "  ${RED}No models found${NC}"
    FAILED=$((FAILED + 1))
  fi
else
  for model_id in ${model_ids}; do
    found=0
    for expected in "${expected_models[@]}"; do
      if [ "${model_id}" = "${expected}" ]; then
        found=1
        break
      fi
    done
    if [ "${found}" -eq 0 ]; then
      echo "  Extra model: ${model_id}"
    fi
  done
fi
echo ""

echo -e "${BLUE}[4] Chat completions via router${NC}"
test_models=""
append_test_model() {
  local model_id="$1"
  case "${model_id}" in
    modelperm-*|"") return 0 ;;
  esac
  for existing in ${test_models}; do
    if [ "${existing}" = "${model_id}" ]; then
      return 0
    fi
  done
  test_models="${test_models} ${model_id}"
}
for model_id in "${expected_models[@]}"; do
  append_test_model "${model_id}"
done
if [ -n "${model_ids}" ] && [ "${model_ids}" != " " ]; then
  for model_id in ${model_ids}; do
    append_test_model "${model_id}"
  done
fi
test_models="${test_models# }"
if [ -z "${test_models}" ]; then
  test_models="9g_8b_thinking"
fi
for test_model in ${test_models}; do
  echo -n "  Testing model: ${test_model}... "
  if [ "${test_model}" = "XiYanSQL-QwenCoder-32B-2504" ]; then
    user_content="SELECT 1"
    curl_max_time=120
  else
    user_content="Hello"
    curl_max_time=60
  fi
  request_data="{\"model\": \"${test_model}\", \"messages\": [{\"role\": \"user\", \"content\": \"${user_content}\"}], \"stream\": false, \"max_tokens\": 32}"
  resp="$(curl -s --max-time "${curl_max_time}" -X POST --noproxy "*" "${ROUTER_URL}/v1/chat/completions" -H "Content-Type: application/json" -d "${request_data}" 2>/dev/null || echo '{}')"
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
