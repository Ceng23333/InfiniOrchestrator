# Playground: Qwen3-32B + InfiniLM AR-split (Mars / metax-9)

**Candidate** InfiniLM backend for AIPerf dual-run against the local vLLM phytium baseline (`qwen3-32b-x203-vllm--phytium`).

Case id: `qwen3-32b-x203-inf--prod-ar-split` (`case.toml`).

## Production pin

| Item | Value |
|------|-------|
| ITW tag | `v2026.11.16-infinilm-prod-qwen38-tp4-ar-split` |
| Host | `172.31.1.9` / `metax-x203-hpcc-metax9` (Phytium + HPCC/Mars) |
| Device | `--device mars` only (`WITH_MARS`; no MetaX/`MACA_*` alias) |
| Model | `/root/zenghua/models/Qwen3-32B` → `/models/Qwen3-32B` |
| TP | 4 (exercises AR-split AllReduce) |
| API port | `8200` |
| Workspace | `deploy20261113/InfiniTensorWorktree` + sibling InfiniOrchestrator |

Treat results as a **host Mars baseline**, not MetaX P64 parity.

This case documents bring-up only. The InfiniOrchestrator harness is **client-only** and never starts or stops InfiniLM.

## Mars rebuild (outside harness)

From the deploy worktree (linked to the AR-split tag):

```bash
# Inside infinilm-dev-ar-split-mars (HPCC devices /dev/dri + /dev/htcd)
export HPCC_PATH=/opt/hpcc INFINI_ROOT=/workspace/prefix-mars
unset MACA_PATH MACA_HOME MACA_ROOT
source /workspace/scripts/mars/hpcc-env.sh
# InfiniRT → InfiniOps → InfiniCCL → InfiniLM (see scripts/mars/build-mars-stack.sh)
```

Serve (prod-like knobs when Mars supports them):

```bash
export INFINI_PREFILL_CHUNKED=1 INFINI_MAX_NUM_BATCHED_TOKENS=2048
export ENABLE_GRAPH=1 INFINI_CUDAGRAPH_POLICY=legacy INFINI_FA_INGRAPH=decode
python3 python/infinilm/server/inference_server.py \
  --device mars --model /models/Qwen3-32B --dtype bfloat16 \
  --host 0.0.0.0 --port 8200 --tp 4 \
  --disable-prefix-caching --enable-paged-attn --enable-graph
```

Requires InfiniOps Mars rebuilt with `WITH_LINKED=ON` / `WITH_TORCH=ON` so FlashAttn@16 is in `libinfiniops.so` (`scripts/mars/build-infiniops-mars.sh`).

Helper: `InfiniTensorWorktree/scripts/mars/run-inference-server.sh` (CONTAINER_NAME=`infinilm-dev-ar-split-mars`).

Preflight:

```bash
curl -sf http://127.0.0.1:8200/health
curl -sf http://127.0.0.1:8200/v1/models | head
```

## Dual-run vs vLLM phytium

vLLM baseline wrap defaults to host port `18180` (override with `API_PORT=8000` if needed). InfiniLM stays on `8200`. TP4 may need exclusive cards — run vLLM first, stop it, then InfiniLM, or sequence via AIPerf dual-run order.

```bash
cd InfiniOrchestrator
harness/bin/run-aiperf-dual \
  --base-url-vllm http://127.0.0.1:18180 \
  --base-url-infinilm http://127.0.0.1:8200 \
  --profile harness/adapters/aiperf/profiles/ci_mooncake_smoke_qwen32.yaml \
  --case-path-vllm playground/Standalone/qwen3-32b-x203-vllm--phytium/case.toml \
  --case-path-infinilm playground/Standalone/qwen3-32b-x203-inf--prod-ar-split/case.toml \
  --model Qwen3-32B
```

Escalate to `ci_mooncake_replay.yaml` only if smoke dual-run is healthy.

Default gates: InfiniLM / vLLM throughput ≥ 0.50×; TTFT p95 ≤ 1.25×; success_rate ≥ 0.99. See `harness/adapters/aiperf/README.md`.
