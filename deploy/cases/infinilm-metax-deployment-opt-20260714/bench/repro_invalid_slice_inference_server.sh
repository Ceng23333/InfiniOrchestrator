#!/usr/bin/env bash
# Repro: PagedCompiler block_tables width vs runtime (Invalid slice) via inference_server.
# Run inside dev2; uses fla-support PYTHONPATH if InfiniCore is not built in svc-refactor.
set -euo pipefail

REPO_FLA="${REPO_FLA:-/home/zenghua/workspace/fla-support}"
REPO_SVC="${REPO_SVC:-/home/zenghua/workspace/infinilm-svc-refactor}"
PAYLOAD="${REPO_SVC}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260714/results/repro-slice-payload.json"
MODEL="${MODEL:-/data-aisoft/zenghua/models/9g_8b_thinking_llama}"
PORT="${PORT:-18080}"
LOG="${LOG:-${REPO_SVC}/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260714/results/repro-inference-server-$(date -u +%Y%m%d-%H%M%SZ).log}"

export PYTHONPATH="${REPO_FLA}/InfiniLM/python:${REPO_FLA}/InfiniCore/python:${PYTHONPATH:-}"
export TORCH_LIB="$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "lib"))')"
export LD_LIBRARY_PATH="${TORCH_LIB}:/root/.infini/lib:${LD_LIBRARY_PATH:-}"

if [[ ! -f "$PAYLOAD" ]]; then
  echo "Missing payload: $PAYLOAD" >&2
  exit 1
fi

exec > >(tee -a "$LOG") 2>&1
echo "=== repro_invalid_slice_inference_server $(date -u -Iseconds) ==="
echo "LOG=$LOG PORT=$PORT MODEL=$MODEL"

fuser -k "${PORT}/tcp" 2>/dev/null || true
sleep 1

cd "${REPO_FLA}/InfiniLM/python"
python3 -m infinilm.server.inference_server \
  --metax \
  --model_path="$MODEL" \
  --enable-graph \
  --cache_type paged \
  --num_blocks 512 \
  --max_batch_size 8 \
  --block_size 256 \
  --port "$PORT" \
  --max_tokens 32 \
  --attn default \
  --log_level INFO &
SRV_PID=$!

cleanup() {
  kill "$SRV_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "Waiting for /health on :$PORT ..."
for i in $(seq 1 240); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
    echo "healthy after ${i}s"
    break
  fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "server exited early" >&2
    wait "$SRV_PID" || true
    exit 1
  fi
  sleep 2
done

if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
  echo "server never became healthy" >&2
  exit 1
fi

echo "Firing 8 concurrent /v1/chat/completions (long context) ..."
for j in 1 2 3 4 5 6 7 8; do
  curl -sS --max-time 600 -H "Content-Type: application/json" \
    -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -d @"$PAYLOAD" -o "/tmp/repro-curl-$j.out" &
done
wait || true

echo "=== curl exit summary ==="
for j in 1 2 3 4 5 6 7 8; do
  if [[ -f "/tmp/repro-curl-$j.out" ]]; then
    head -c 200 "/tmp/repro-curl-$j.out" | tr '\n' ' '
    echo " (job $j)"
  fi
done

echo "=== grep slice / error (server log is this file) ==="
grep -E "Invalid slice|narrow|view\.cc|ERROR|Exception" "$LOG" || echo "(no slice pattern in tee log yet — check above console)"

echo "=== done $(date -u -Iseconds) ==="
