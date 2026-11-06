#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER:-sudo docker}"
SERVING="${SCRIPT_DIR%/minicpm5-2b-qy-vllm-perf}/minicpm5-2b-qy-vllm"
if [[ -x "${SERVING}/stop-wrap.sh" ]]; then
  "${SERVING}/stop-wrap.sh" || true
fi
${DOCKER} rm -f minicpm5-2b-perf-harness minicpm5-2b-qy-vllm >/dev/null 2>&1 || true
echo "stopped minicpm5-2b-qy-vllm-perf harness/wrap"
