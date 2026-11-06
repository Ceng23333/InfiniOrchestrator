#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/run_layer_a.sh"
bash "${SCRIPT_DIR}/run_layer_b.sh"
echo "Complete matrix vLLM 2B finished (Layer A reused)."
