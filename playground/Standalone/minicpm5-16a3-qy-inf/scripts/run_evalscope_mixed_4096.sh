#!/usr/bin/env bash
# EvalScope mixed-4096 against minicpm5-16a3-qy-inf (port 18182).
# Served id is the directory basename minicpm5-16a3; checkpoint is minicpm5.16a3.v0314
# (same weights as the vLLM leg, which serves minicpm5.16a3.v0314).
set -euo pipefail

IO_ROOT="${IO_ROOT:-/home/qinyiqun/workspace/InfiniOrchestrator}"
CASE="${CASE:-${IO_ROOT}/playground/Standalone/minicpm5-16a3-qy-inf}"
LOG_DIR="${CASE}/logs"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/evalscope-mixed-4096-$(date +%Y%m%d-%H%M%S).log"

# Optional env helpers
# shellcheck disable=SC1091
source "${IO_ROOT}/scripts/worktree_env.sh" 2>/dev/null || true

export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-/home/qinyiqun/workspace/hardware-profile}"
export BENCH_WAREHOUSE_REPO="${BENCH_WAREHOUSE_REPO:-/home/qinyiqun/workspace/bench-warehouse}"

export CASE_ID=minicpm5-16a3-qy-inf
export CASE_PATH="${CASE}/case.toml"
export BENCH_BACKEND=infinilm
export DEV_CONTAINER_NAME="${DEV_CONTAINER_NAME:-DISABLED_NO_SUCH_CONTAINER}"
export DEV_PORT=18182
export BENCH_TARGET_URL=http://127.0.0.1:18182
# Host client talks to the published port. In-container client OOM-kills next to 28GiB MoE weights.
unset BENCH_CTN_URL || true
# Must match /v1/models. Checkpoint identity minicpm5.16a3.v0314 is recorded in case.toml and CAMPAIGN.md.
export MODEL=minicpm5-16a3

export MINICPM5_TOKENIZER_DIR="${MINICPM5_TOKENIZER_DIR:-${IO_ROOT}/playground/Standalone/minicpm5-x203-vllm/vllm_minicpm5/tokenizer_bytelevel}"
export TOKENIZER_DIR="${TOKENIZER_DIR:-${MINICPM5_TOKENIZER_DIR}}"
export MONOREPO_WORK="${MONOREPO_WORK:-/home/qinyiqun/workspace}"
export CONTAINER_REPO="${CONTAINER_REPO:-/host_ws}"

# Same fairness knobs as the vLLM leg (harness MiniCPM5 defaults).
export MIN_PROMPT_LENGTH="${MIN_PROMPT_LENGTH:-4096}"
export MAX_PROMPT_LENGTH="${MAX_PROMPT_LENGTH:-4096}"
export MIN_TOKENS="${MIN_TOKENS:-1024}"
export MAX_TOKENS="${MAX_TOKENS:-1024}"
export PARALLEL="${PARALLEL:-1}"
export NUMBER="${NUMBER:-10}"
export PARALLEL_SET=1
export NUMBER_SET=1

export HOST_ID="${HOST_ID:-denglin-qy}"
export PLATFORM="${PLATFORM:-denglin}"
export ARCH="${ARCH:-x86_64}"
export GPU_MODEL="${GPU_MODEL:-ks38}"

# Host client imports Denglin-patched torch (libcurt).
if [[ -d /usr/local/denglin/sdk/lib ]]; then
  export LD_LIBRARY_PATH="/usr/local/denglin/sdk/lib:${LD_LIBRARY_PATH:-}"
fi

echo "=== preflight ===" | tee "${LOG}"
curl -sf --max-time 10 --noproxy '*' "${BENCH_TARGET_URL}/v1/models" | tee -a "${LOG}"
echo | tee -a "${LOG}"
docker ps --filter "name=minicpm5-16a3-qy-inf" --format '{{.Names}} {{.Status}} {{.Ports}}' | tee -a "${LOG}"
test -d "${TOKENIZER_DIR}"
test -f "${TOKENIZER_DIR}/tokenizer_config.json"
command -v evalscope >/dev/null

echo "=== evalscope-mixed-4096 MODEL=${MODEL} checkpoint=minicpm5.16a3.v0314 PARALLEL=${PARALLEL} NUMBER=${NUMBER} prompt=${MIN_PROMPT_LENGTH} gen=${MAX_TOKENS} backend=${BENCH_BACKEND} ===" | tee -a "${LOG}"
set -x
"${IO_ROOT}/harness/run_bench_client.sh" evalscope-mixed-4096 2>&1 | tee -a "${LOG}"
ec=${PIPESTATUS[0]}
set +x
echo "EXIT=${ec}" | tee -a "${LOG}"
echo "LOG=${LOG}"
exit "${ec}"
