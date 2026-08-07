# Unexpected behavior (client harness)

Fault-injection scenarios against a live inference endpoint. Requires only HTTP access.

## Env

- `BENCH_TARGET_URL` — inference server base URL (`GET /metadata`, `GET /metrics`)
- `BENCH_METRICS_URL` — metrics URL (defaults to `INFERENCE_SERVER_BASE_URL`; use when router ≠ worker)
- `ROUTER_URL` — traffic URL when using `--via-router` (defaults to `BENCH_TARGET_URL`)
- `MODEL` — model name (default `9g_8b_thinking`)
- `SCENARIOS` — comma-separated list (default: all five)

## Run

```bash
export BENCH_WAREHOUSE_REPO=/path/to/bench-warehouse
export BENCH_TARGET_URL=http://host:8102
export MODEL=9g_8b_thinking

"${BENCH_WAREHOUSE_REPO}/harness/run_unexpected_behavior_bench.sh"
```

Via router:

```bash
export ROUTER_URL=http://router:8800
export INFERENCE_SERVER_BASE_URL=http://worker:8102
export BENCH_METRICS_URL="${INFERENCE_SERVER_BASE_URL}"
"${BENCH_WAREHOUSE_REPO}/harness/run_unexpected_behavior_bench.sh" --via-router
```
