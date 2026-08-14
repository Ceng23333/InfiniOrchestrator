#!/usr/bin/env bash
# Validate opt20260811 (Frontend health, InfiniLM workers, embeddings).
#
# Offline smoke: probes local compose endpoints only (no HuggingFace / PyPI pulls).
# Usage (from docker-compose/): ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh localhost

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preserve caller overrides (multinode sim ports) across .env sourcing.
_OV_WORKER_9G_API_PORT="${WORKER_9G_API_PORT-}"
_OV_WORKER_9G_BABYSITTER_PORT="${WORKER_9G_BABYSITTER_PORT-}"
_OV_WORKER_QWEN_API_PORT="${WORKER_QWEN_API_PORT-}"
_OV_WORKER_QWEN_BABYSITTER_PORT="${WORKER_QWEN_BABYSITTER_PORT-}"
_OV_EMBEDDING_PORT="${EMBEDDING_PORT-}"
_OV_SKIP_EMBEDDING="${SKIP_EMBEDDING-}"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env"
  set +a
fi

[[ -n "${_OV_WORKER_9G_API_PORT}" ]] && WORKER_9G_API_PORT="${_OV_WORKER_9G_API_PORT}"
[[ -n "${_OV_WORKER_9G_BABYSITTER_PORT}" ]] && WORKER_9G_BABYSITTER_PORT="${_OV_WORKER_9G_BABYSITTER_PORT}"
[[ -n "${_OV_WORKER_QWEN_API_PORT}" ]] && WORKER_QWEN_API_PORT="${_OV_WORKER_QWEN_API_PORT}"
[[ -n "${_OV_WORKER_QWEN_BABYSITTER_PORT}" ]] && WORKER_QWEN_BABYSITTER_PORT="${_OV_WORKER_QWEN_BABYSITTER_PORT}"
[[ -n "${_OV_EMBEDDING_PORT}" ]] && EMBEDDING_PORT="${_OV_EMBEDDING_PORT}"
[[ -n "${_OV_SKIP_EMBEDDING}" ]] && SKIP_EMBEDDING="${_OV_SKIP_EMBEDDING}"

export no_proxy="${no_proxy:-*}"
export NO_PROXY="${NO_PROXY:-*}"

usage() {
  echo "Usage:"
  echo "  $0 <FRONTEND_HOST>"
  echo ""
  echo "Dynamo Frontend + Workers: expects 9g_8b_thinking + Qwen3-32B + embeddings."
  echo ""
  echo "Examples:"
  echo "  $0 localhost"
  echo "  $0 192.168.163.151"
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

FRONTEND_HOST_ARG="${1:-localhost}"

REGISTRY_PORT="${REGISTRY_PORT:-18000}"
ROUTER_PORT="${ROUTER_PORT:-8800}"
EMBEDDING_PORT="${EMBEDDING_PORT:-20003}"
WORKER_9G_BABYSITTER_PORT="${WORKER_9G_BABYSITTER_PORT:-8101}"
WORKER_QWEN_BABYSITTER_PORT="${WORKER_QWEN_BABYSITTER_PORT:-8201}"
REGISTRY_URL="http://${FRONTEND_HOST_ARG}:${REGISTRY_PORT}"
ROUTER_URL="http://${FRONTEND_HOST_ARG}:${ROUTER_PORT}"
EMBEDDING_URL="http://${FRONTEND_HOST_ARG}:${EMBEDDING_PORT}"
QWEN_METADATA_URL="http://${FRONTEND_HOST_ARG}:${WORKER_QWEN_BABYSITTER_PORT}"
NINEG_METADATA_URL="http://${FRONTEND_HOST_ARG}:${WORKER_9G_BABYSITTER_PORT}"

CONTAINER_NAME="${CONTAINER_NAME:-infiniorch-frontend-opt-20260811}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

echo "=========================================="
echo "InfiniOrchestrator opt20260811 Validation"
echo "=========================================="
echo "Frontend host: ${FRONTEND_HOST_ARG}"
echo "Registry:      ${REGISTRY_URL}"
echo "Router:        ${ROUTER_URL}"
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

echo -e "${BLUE}[1b] LoadBalancer /metrics + Entrypoint /metadata${NC}"
echo -n "  Checking Router /metrics (infinilm_requests_total)... "
metrics_body="$(curl -s --connect-timeout 3 --noproxy "*" "${ROUTER_URL}/metrics" 2>/dev/null || echo '')"
if echo "${metrics_body}" | grep -q "infinilm_requests_total"; then
  echo -e "${GREEN}OK${NC}"
  PASSED=$((PASSED + 1))
else
  echo -e "${RED}FAIL${NC}"
  FAILED=$((FAILED + 1))
  if [ -z "${metrics_body}" ]; then
    echo "    empty /metrics response"
  else
    echo "    missing infinilm_requests_total (first 200 chars): ${metrics_body:0:200}"
  fi
fi

check_entrypoint_metadata() {
  local base_url=$1
  local name=$2
  echo -n "  Checking ${name} /metadata (server_id UUID)... "
  local body
  body="$(curl -s --connect-timeout 3 --noproxy "*" "${base_url}/metadata" 2>/dev/null || echo '')"
  if echo "${body}" | grep -Eq '"server_id"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"'; then
    echo -e "${GREEN}OK${NC}"
    PASSED=$((PASSED + 1))
    return 0
  else
    echo -e "${RED}FAIL${NC}"
    FAILED=$((FAILED + 1))
    echo "    Response: ${body}"
    return 1
  fi
}
check_entrypoint_metadata "${QWEN_METADATA_URL}" "Qwen Entrypoint (${WORKER_QWEN_BABYSITTER_PORT})"
check_entrypoint_metadata "${NINEG_METADATA_URL}" "9g Entrypoint (${WORKER_9G_BABYSITTER_PORT})"
echo ""

echo -e "${BLUE}[2] Service discovery${NC}"
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  services_json="$(docker exec "${CONTAINER_NAME}" curl -s --noproxy "*" "http://127.0.0.1:${REGISTRY_PORT}/services" 2>/dev/null || curl -s --noproxy "*" "${REGISTRY_URL}/services" 2>/dev/null || echo '{}')"
else
  services_json="$(curl -s --noproxy "*" "${REGISTRY_URL}/services" 2>/dev/null || echo '{}')"
fi
service_count="$(echo "${services_json}" | grep -o '"name"' | wc -l || echo "0")"
echo "  Found ${service_count} services"

expected_services=("master-9g_8b_thinking-server" "master-qwen3-32b-paged-server" "master-embeddings")
for svc in "${expected_services[@]}"; do
  if [[ "${SKIP_EMBEDDING:-0}" == "1" && "${svc}" == "master-embeddings" ]]; then
    echo -e "    ${YELLOW}SKIP${NC} ${svc} (SKIP_EMBEDDING=1)"
    continue
  fi
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
  user_content="Hello"
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

echo -e "${BLUE}[5] Embedding endpoint${NC}"
if [[ "${SKIP_EMBEDDING:-0}" == "1" ]]; then
  echo -e "  ${YELLOW}SKIP${NC} embeddings (SKIP_EMBEDDING=1)"
else
  embedding_registered=0
  if echo "${services_json}" | grep -q "\"name\":\"master-embeddings\""; then
    embedding_registered=1
  fi

  if [ "${embedding_registered}" -eq 0 ]; then
    echo -e "  ${YELLOW}WARN${NC} master-embeddings not found in /services, fallback to endpoint probe"
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
