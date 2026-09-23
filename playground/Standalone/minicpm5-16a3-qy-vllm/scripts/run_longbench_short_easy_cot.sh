#!/usr/bin/env bash
# LongBench-v2 short+easy+CoT against minicpm5-16a3-qy-vllm (port 18181).
set -euo pipefail

IO_ROOT="${IO_ROOT:-/home/qinyiqun/workspace/InfiniOrchestrator}"
CASE="${CASE:-${IO_ROOT}/playground/Standalone/minicpm5-16a3-qy-vllm}"
LOG_DIR="${CASE}/logs"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/longbench-short-easy-cot-$(date +%Y%m%d-%H%M%S).log"

# Optional env helpers
# shellcheck disable=SC1091
source "${IO_ROOT}/scripts/worktree_env.sh" 2>/dev/null || true

export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO:-/home/qinyiqun/workspace/hardware-profile}"
export BENCH_WAREHOUSE_REPO="${BENCH_WAREHOUSE_REPO:-/home/qinyiqun/workspace/bench-warehouse}"

export CASE_ID=minicpm5-16a3-qy-vllm
export CASE_PATH="${CASE}/case.toml"
export BENCH_BACKEND=vllm
export DEV_CONTAINER_NAME="${DEV_CONTAINER_NAME:-DISABLED_NO_SUCH_CONTAINER}"
export DEV_PORT=18181
export BENCH_TARGET_URL=http://127.0.0.1:18181
# Do not set BENCH_CTN_URL — host client talks to published port directly.
# In-container client OOM-killed next to 28GiB MoE weights; host (or CPU sidecar) is safer.
unset BENCH_CTN_URL || true
export MODEL=minicpm5.16a3.v0314

# Host-visible bytelevel tokenizer (maps into container via MONOREPO_WORK→CONTAINER_REPO)
export MINICPM5_TOKENIZER_DIR="${MINICPM5_TOKENIZER_DIR:-${IO_ROOT}/playground/Standalone/minicpm5-x203-vllm/vllm_minicpm5/tokenizer_bytelevel}"
export TOKENIZER_DIR="${TOKENIZER_DIR:-${MINICPM5_TOKENIZER_DIR}}"
export MONOREPO_WORK="${MONOREPO_WORK:-/home/qinyiqun/workspace}"
export CONTAINER_REPO="${CONTAINER_REPO:-/host_ws}"

export LONGBENCH_PRESET="${LONGBENCH_PRESET:-short_easy_cot}"
# Serve max_model_len=8192; leave headroom for CoT gen (~1024)
export MAX_INPUT_TOKENS="${MAX_INPUT_TOKENS:-7000}"
export MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"

export HOST_ID="${HOST_ID:-denglin-qy}"
export PLATFORM="${PLATFORM:-denglin}"
export ARCH="${ARCH:-x86_64}"
export GPU_MODEL="${GPU_MODEL:-ks38}"

echo "=== preflight ===" | tee "${LOG}"
curl -sf --max-time 10 --noproxy '*' "${BENCH_TARGET_URL}/v1/models" | tee -a "${LOG}"
echo | tee -a "${LOG}"
docker ps --filter "name=${DEV_CONTAINER_NAME}" --format '{{.Names}} {{.Status}} {{.Ports}}' | tee -a "${LOG}"
test -d "${TOKENIZER_DIR}"
test -f "${TOKENIZER_DIR}/tokenizer_config.json"

echo "=== longbench ${LONGBENCH_PRESET} MAX_INPUT=${MAX_INPUT_TOKENS} conc=${MAX_CONCURRENCY} ===" | tee -a "${LOG}"
set -x
"${IO_ROOT}/harness/run_bench_client.sh" longbench 2>&1 | tee -a "${LOG}"
ec=${PIPESTATUS[0]}
set +x
echo "EXIT=${ec}" | tee -a "${LOG}"
echo "LOG=${LOG}"
exit "${ec}"
