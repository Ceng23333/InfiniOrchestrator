#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER:-sudo docker}"
SERVING="${SCRIPT_DIR%/minicpm5-16a3-qy-inf-perf}/minicpm5-16a3-qy-inf"
if [[ -x "${SERVING}/stop-wrap.sh" ]]; then
  "${SERVING}/stop-wrap.sh" || true
fi
${DOCKER} rm -f minicpm5-16a3-inf-perf-harness minicpm5-16a3-qy-inf >/dev/null 2>&1 || true
echo "stopped minicpm5-16a3-qy-inf-perf harness/wrap"
