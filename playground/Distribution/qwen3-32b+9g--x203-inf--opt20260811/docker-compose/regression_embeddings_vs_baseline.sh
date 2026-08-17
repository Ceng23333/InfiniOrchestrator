#!/usr/bin/env bash
# Embedding quality A/B: live candidate (bge-m3) vs ephemeral TF4 MiniCPM baseline.
#
# Gate: candidate finite / L2≈1 / self-cosine / capital ranking (beijing > shanghai).
# Pass: gate OK AND pairwise ranking agreement ≥ AGREE_THRESHOLD (default 0.75).
#
# Does NOT replace validate.sh (keep smoke fast). Usage (from docker-compose/):
#   ./validate.sh localhost
#   ./regression_embeddings_vs_baseline.sh
#
# Env overrides:
#   EMBEDDING_PORT (default 20002)  BASELINE_PORT (21002)
#   BASELINE_IMAGE (infini-orchestrator-metax:local)
#   BASELINE_GPU (2)  AGREE_THRESHOLD (0.75)
#   EMBEDDING_MODEL_DIR  BASELINE_WAIT_SEC (600)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPARE_PY="${SCRIPT_DIR}/regression_embeddings_compare.py"
BASELINE_NAME="${BASELINE_NAME:-emb-baseline-minicpm}"

# Preserve caller overrides across .env sourcing.
_OV_EMBEDDING_PORT="${EMBEDDING_PORT-}"
_OV_EMBEDDING_MODEL_DIR="${EMBEDDING_MODEL_DIR-}"
_OV_BASELINE_PORT="${BASELINE_PORT-}"
_OV_BASELINE_IMAGE="${BASELINE_IMAGE-}"
_OV_BASELINE_GPU="${BASELINE_GPU-}"
_OV_AGREE_THRESHOLD="${AGREE_THRESHOLD-}"

if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env"
  set +a
fi

[[ -n "${_OV_EMBEDDING_PORT}" ]] && EMBEDDING_PORT="${_OV_EMBEDDING_PORT}"
[[ -n "${_OV_EMBEDDING_MODEL_DIR}" ]] && EMBEDDING_MODEL_DIR="${_OV_EMBEDDING_MODEL_DIR}"
[[ -n "${_OV_BASELINE_PORT}" ]] && BASELINE_PORT="${_OV_BASELINE_PORT}"
[[ -n "${_OV_BASELINE_IMAGE}" ]] && BASELINE_IMAGE="${_OV_BASELINE_IMAGE}"
[[ -n "${_OV_BASELINE_GPU}" ]] && BASELINE_GPU="${_OV_BASELINE_GPU}"
[[ -n "${_OV_AGREE_THRESHOLD}" ]] && AGREE_THRESHOLD="${_OV_AGREE_THRESHOLD}"

export no_proxy="${no_proxy:-*}"
export NO_PROXY="${NO_PROXY:-*}"

EMBEDDING_PORT="${EMBEDDING_PORT:-20002}"
BASELINE_PORT="${BASELINE_PORT:-21002}"
BASELINE_IMAGE="${BASELINE_IMAGE:-infini-orchestrator-metax:local}"
BASELINE_GPU="${BASELINE_GPU:-2}"
AGREE_THRESHOLD="${AGREE_THRESHOLD:-0.75}"
EMBEDDING_MODEL_DIR="${EMBEDDING_MODEL_DIR:-/root/zenghua/models}"
BASELINE_WAIT_SEC="${BASELINE_WAIT_SEC:-600}"
CANDIDATE_URL="${CANDIDATE_URL:-http://127.0.0.1:${EMBEDDING_PORT}}"
BASELINE_URL="http://127.0.0.1:${BASELINE_PORT}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-${CASE_ROOT}/results/embeddings-regression-${TS}}"
mkdir -p "${OUT_DIR}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
  local ec=$?
  if docker inspect "${BASELINE_NAME}" >/dev/null 2>&1; then
    echo -e "${YELLOW}Stopping baseline container ${BASELINE_NAME}...${NC}"
    docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1 || true
  fi
  exit "${ec}"
}
trap cleanup EXIT

if [[ ! -f "${COMPARE_PY}" ]]; then
  echo -e "${RED}Missing ${COMPARE_PY}${NC}" >&2
  exit 1
fi
if [[ ! -d "${EMBEDDING_MODEL_DIR}" ]]; then
  echo -e "${RED}EMBEDDING_MODEL_DIR missing: ${EMBEDDING_MODEL_DIR}${NC}" >&2
  exit 1
fi
if ! docker image inspect "${BASELINE_IMAGE}" >/dev/null 2>&1; then
  echo -e "${RED}Baseline image not found: ${BASELINE_IMAGE}${NC}" >&2
  exit 1
fi

echo "=========================================="
echo "Embeddings regression vs TF4 MiniCPM"
echo "=========================================="
echo "Candidate:  ${CANDIDATE_URL}"
echo "Baseline:   ${BASELINE_IMAGE} → ${BASELINE_URL} (GPU ${BASELINE_GPU})"
echo "Models dir: ${EMBEDDING_MODEL_DIR}"
echo "Threshold:  pairwise ≥ ${AGREE_THRESHOLD}"
echo "Artifacts:  ${OUT_DIR}"
echo

echo -e "${YELLOW}[A] Capture candidate (bge-m3) from live worker...${NC}"
python3 "${COMPARE_PY}" capture \
  --base-url "${CANDIDATE_URL}" \
  --model bge-m3 \
  --role candidate \
  --out "${OUT_DIR}/candidate.json"

echo -e "${YELLOW}[A] Candidate self-gate...${NC}"
python3 "${COMPARE_PY}" gate --candidate "${OUT_DIR}/candidate.json" --out "${OUT_DIR}/candidate-gate.json"

echo -e "${YELLOW}[B] Start ephemeral MiniCPM baseline (${BASELINE_IMAGE})...${NC}"
# Remove any leftover name without waiting for trap.
docker rm -f "${BASELINE_NAME}" >/dev/null 2>&1 || true

# No --rm so we can dump logs if startup fails; trap always removes the container.
docker run -d --name "${BASELINE_NAME}" --privileged \
  --device /dev/dri --device /dev/htcd --device /dev/infiniband \
  --group-add video --security-opt apparmor=unconfined \
  -e HPCC_VISIBLE_DEVICES="${BASELINE_GPU}" \
  -e CUDA_VISIBLE_DEVICES="${BASELINE_GPU}" \
  -p "${BASELINE_PORT}:20002" \
  -v "${SCRIPT_DIR}/embeddings_server.py:/app/embeddings_server.py:ro" \
  -v "${EMBEDDING_MODEL_DIR}:/workspace/models:ro" \
  --entrypoint /opt/conda/bin/python \
  "${BASELINE_IMAGE}" /app/embeddings_server.py \
  >"${OUT_DIR}/baseline-docker.cid"

echo -e "${YELLOW}[B] Waiting for baseline /v1/models (up to ${BASELINE_WAIT_SEC}s)...${NC}"
deadline=$((SECONDS + BASELINE_WAIT_SEC))
ready=0
while (( SECONDS < deadline )); do
  if curl -sf --noproxy '*' "${BASELINE_URL}/v1/models" 2>/dev/null | grep -q 'minicpm-embedding'; then
    ready=1
    break
  fi
  # Surface early container death.
  status="$(docker inspect -f '{{.State.Status}}' "${BASELINE_NAME}" 2>/dev/null || echo missing)"
  if [[ "${status}" != "running" ]]; then
    echo -e "${RED}Baseline container not running (status=${status}). Logs:${NC}" >&2
    docker logs "${BASELINE_NAME}" 2>&1 | tee "${OUT_DIR}/baseline-docker.log" | tail -120 >&2 || true
    exit 1
  fi
  sleep 3
done
if [[ "${ready}" != "1" ]]; then
  echo -e "${RED}Timed out waiting for minicpm-embedding on ${BASELINE_URL}${NC}" >&2
  docker logs "${BASELINE_NAME}" 2>&1 | tee "${OUT_DIR}/baseline-docker.log" | tail -120 >&2 || true
  exit 1
fi
curl -s --noproxy '*' "${BASELINE_URL}/v1/models" | tee "${OUT_DIR}/baseline-models.json" >/dev/null
echo -e "${GREEN}Baseline ready.${NC}"

echo -e "${YELLOW}[B] Capture baseline (minicpm-embedding)...${NC}"
python3 "${COMPARE_PY}" capture \
  --base-url "${BASELINE_URL}" \
  --model minicpm-embedding \
  --role baseline \
  --out "${OUT_DIR}/baseline.json"

echo -e "${YELLOW}[C] Compare rankings...${NC}"
set +e
python3 "${COMPARE_PY}" compare \
  --baseline "${OUT_DIR}/baseline.json" \
  --candidate "${OUT_DIR}/candidate.json" \
  --out "${OUT_DIR}/report.json" \
  --agree-threshold "${AGREE_THRESHOLD}"
cmp_ec=$?
set -e

if [[ "${cmp_ec}" -eq 0 ]]; then
  echo -e "${GREEN}PASS${NC} embeddings regression (self-gate + pairwise ≥ ${AGREE_THRESHOLD})"
else
  echo -e "${RED}FAIL${NC} embeddings regression (see ${OUT_DIR}/report.json)"
fi
echo "Artifacts: ${OUT_DIR}/{baseline.json,candidate.json,report.json}"
exit "${cmp_ec}"
