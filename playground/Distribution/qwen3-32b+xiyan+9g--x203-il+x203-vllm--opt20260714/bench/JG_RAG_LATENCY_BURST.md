# jg_rag latency spikes and degraded benchmark results

This note explains how to spot benchmark JSON runs that **look successful but are severely degraded**, lists common causes, and suggests a staged load plan.

## Symptoms: quick JSON checks for degradation

Even when **`completed == num_prompts`** and **`failed == 0`**, you can still see end-to-end queueing dominate, very short completions, or near-empty outputs still counted as success. Cross-check these fields:

| Signal | What it means |
|--------|----------------|
| **`total_output_tokens` tiny vs `num_prompts`** | If you expect ~`max_tokens` per request (e.g. 256), `total_output_tokens` should be on the order of `num_prompts × max_tokens`. Averaging only a few tokens per request (e.g. ~750 total for 160 prompts) is a red flag. |
| **TTFT stuck around ~10⁶ ms** | `median_ttft_ms`, `p99_ttft_ms`, or `mean_ttft_ms` staying near **~1e6 ms (~1000 s)** means time-to-first-token is dominated by queueing/backpressure, not normal inference latency. |
| **Very long `duration`, `output_throughput` ~0** | Total wall time can reach tens of thousands of seconds (hours); `output_throughput` may be far below a healthy baseline (e.g. &lt; 1 tok/s). |

### In-repo examples

- **Degraded signature (do not treat as a perf baseline)**: [`results/jg_rag-qwen3-2inst-c8-4x-1.0qps-concurrency8-Qwen3-32B-20260328-015758.json`](../results/jg_rag-qwen3-2inst-c8-4x-1.0qps-concurrency8-Qwen3-32B-20260328-015758.json) — 160 prompts, `total_output_tokens` ≈ 752, `median_ttft_ms` ≈ 1e6, `duration` ≈ 2e4 s (~5.6 h).  
- **Relatively healthy (40 prompts, concurrency 4)**: [`results/jg_rag-qwen3-2inst-1.0qps-concurrency4-Qwen3-32B-20260327-173050.json`](../results/jg_rag-qwen3-2inst-1.0qps-concurrency4-Qwen3-32B-20260327-173050.json) — 40 prompts, `total_output_tokens` ≈ 18580, TTFT in the sub-second to low-thousands-of-ms range.  
- **Same pattern on 9g model**: [`results/jg_rag-9g8b-c8-4x-1.0qps-concurrency8-9g_8b_thinking-20260328-073330.json`](../results/jg_rag-9g8b-c8-4x-1.0qps-concurrency8-9g_8b_thinking-20260328-073330.json).

## Common causes

1. **Load spikes**: high `MAX_CONCURRENCY` + Poisson `request_rate` + very long context → deep queues → TTFT and total time explode.  
2. **Replicas and session routing**: with multiple instances of the same model, session hashing can still concentrate load on a subset of workers (validate against your topology).  
3. **Path and timeouts**  
   - **vLLM benchmark client**: this fork uses `aiohttp.ClientTimeout(total=6*60*60)` (6 hours); see [`vllm/vllm/benchmarks/serve.py`](../../../../../vllm/vllm/benchmarks/serve.py).  
   - **InfiniOrchestrator router proxy**: `PROXY_TIMEOUT_SECONDS`; if unset, default is **1800 s (30 minutes)** — see `get_proxy_timeout()` in [`InfiniOrchestrator/rust/src/proxy/handler.rs`](../../../../rust/src/proxy/handler.rs). Also check fronting Nginx/Ingress and any inference-side timeouts on workers.

## Recommended load ladder (40 prompts first, then grow the dataset)

1. **Hold the run to ~40 requests** (matches the default generator: `gen-jg_rag-benchmark.py` with `--num-conversations 10 --messages-per-conv 4`). If you already have a 160-line `jg_rag_benchmark.jsonl`, set **`NUM_PROMPTS=40`** to send only the first 40 lines without deleting the file (see [`run-jg_rag-benchmark-remote.sh`](run-jg_rag-benchmark-remote.sh)).  
2. **Keep `REQUEST_RATE` at 1.0** initially (or lower if the cluster struggles), and sweep **`MAX_CONCURRENCY`** — e.g. 4 → 8 → 12 → 16 — while watching `total_output_tokens`, TTFT percentiles, and throughput.  
3. After metrics look healthy, raise **`DATASET_NUM_CONVERSATIONS`** to 40 (160 lines) or step through 20 / 40 conversations.

### Example (remote router)

From this case’s `bench` directory:

```bash
export QWEN3_32B_DIR=/path/to/tokenizer-or-model-dir
NUM_PROMPTS=40 MAX_CONCURRENCY=8 LABEL=jg_rag-qwen3-c8 \
  ./run-jg_rag-benchmark-remote.sh <ROUTER_HOST>
```

See the script’s `usage()` for the full env surface.

## Phase 2 — correlate “stuck” completions with `/health` staying 200

Goal: while load is running, show that **chat completions can be hung or extremely slow** while **`GET /health` on the inference port and on the babysitter (`inference_port + 1`) still returns HTTP 200** — the observability gap described in the worker-stuck diagnosis plan.

### Procedure

1. Pick endpoints you can reach from the machine that runs the stress client:
   - **On-host / in-container** (best): inference `http://127.0.0.1:8100/health` (9g) and `http://127.0.0.1:8200/health` (Qwen), plus babysitter **8101 / 8201** (router’s LB probes these).
   - **From LAN only**: often only the **router** `http://<master>:8000/health` is reachable; worker inference/babysitter ports may be unpublished or blocked by firewall unless explicitly published.

2. Run the health logger + stress wrapper [`stress-health-correlation.sh`](stress-health-correlation.sh):
   - **jg_rag via router** (same as [`run-jg_rag-benchmark-remote.sh`](run-jg_rag-benchmark-remote.sh)): raise `MAX_CONCURRENCY` until TTFT/latency explodes (see load ladder above).

```bash
# From this repository: InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan+9g--x203-il+x203-vllm--opt20260714/bench

export HEALTH_ENDPOINTS="http://127.0.0.1:8100/health http://127.0.0.1:8101/health"
# Optional: add router:  export HEALTH_ENDPOINTS="$HEALTH_ENDPOINTS http://192.168.163.151:8000/health"

export QWEN3_32B_DIR=/path/to/tokenizer-or-model-dir
NUM_PROMPTS=40 MAX_CONCURRENCY=16 LABEL=phase2-stress \
  ./stress-health-correlation.sh -- ./run-jg_rag-benchmark-remote.sh 192.168.163.151
```

3. Inspect the TSV log under `../results/phase2-health-<UTC>.log`: columns are **timestamp**, **URL**, **http_code or ERR**, **curl time_total**. If benchmark JSON shows **median TTFT ~ 10⁶ ms** or **near-zero throughput** while every poll line still shows **200** for inference/babysitter, you have reproduced the gap.

4. **Lightweight alternative** (parallel `curl` to `/v1/chat/completions`, no vLLM bench):

```bash
./stress-health-correlation.sh curl-burst \
  --health-endpoint http://127.0.0.1:8100/health \
  --health-endpoint http://127.0.0.1:8101/health \
  --base-url http://127.0.0.1:8100 \
  --model Qwen3-32B \
  --parallel 32 --requests 200 --max-time 300
```

Env: `HEALTH_POLL_INTERVAL_SEC`, `LOG_FILE` (override log path).

### What “success” looks like for this repro

Not a passing benchmark — a **documented correlation**: slow or stalled completions (bench log or `curl` timings) **with** stable `200` rows in the health log until/unless the engine throws and `is_healthy()` flips (Phase 4 InfiniLM fix).

## Related docs

- Offline deploy overview (Chinese): [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](../OFFLINE_DEPLOY_GUIDE_ZH_CN.md).
