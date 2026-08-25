#!/usr/bin/env bash
# Build, run entrypoint-wrapped vLLM, and validate-case (MetaX C550 alpha smoke).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

export BASE_IMAGE="${BASE_IMAGE:-cr.metax-tech.com/public-ai-release/maca/vllm-metax:0.17.0-maca.ai3.5.3.307-torch2.8-py312-ubuntu22.04-amd64}"
export IMAGE_TAG="${IMAGE_TAG:-vllm-metax-entrypoint:0.17.0-c550-9g}"
export CONTAINER_NAME="${CONTAINER_NAME:-9g-vllm-c550}"
export HOST_ID="${HOST_ID:-metax-node2}"
export GPU_MODEL="${GPU_MODEL:-metax-c550}"
export CASE_PATH="${CASE_PATH:-${SCRIPT_DIR}/case.toml}"

echo "== build-wrap-image =="
"${SCRIPT_DIR}/build-wrap-image.sh"

echo "== run-wrap =="
"${SCRIPT_DIR}/run-wrap.sh"

HOST="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_NAME}")"
export BENCH_TARGET_HOST="${HOST}"

echo "== validate-case =="
"${IO_ROOT}/harness/bin/validate-case" \
  --case-path "${CASE_PATH}" \
  --host "${HOST}" \
  --container "${CONTAINER_NAME}"
