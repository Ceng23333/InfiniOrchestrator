# Run-only llm-d-benchmark adapter

This adapter is an M1 compatibility path for an already-running
InfiniOrchestrator OpenAI-compatible endpoint. It never starts or stops the
target case, etcd, load balancer, workers, Docker Compose, Kubernetes, or
systemd services.

## Pinned upstream client

The reference checkout is `llm-d-benchmark` v0.8.0 at commit
`87d03da11e057e7eb5acf97f2cc01d79a35c7858`. Upstream's Python package requires
Python 3.11 or newer and its CLI also imports `llm-d-planner` v0.1.0. Keep this
checkout external to InfiniOrchestrator; do not vendor it into this repository.

The upstream command is run-only endpoint mode with `run --methods nok8s
--endpoint-url`. `nok8s` here permits the upstream benchmark harness container
to run locally; it does not authorize serving-case lifecycle operations.

## Usage

```bash
harness/bin/run-llmd-bench \
  --driver http \
  --base-url "$BASE_URL" \
  --profile harness/adapters/llm_d_benchmark/profiles/m1_http_smoke.yaml \
  --case-path "$CASE_PATH" \
  --model "$MODEL" \
  --output-dir "$BENCH_RESULTS_ROOT/diagnostics/llmd_m1_smoke" \
  --manifest "$DIAGNOSTIC_MANIFEST"
```

Use `--driver upstream --upstream-root /path/to/llm-d-benchmark-v0.8.0` when
the pinned upstream CLI and its planner dependency are installed. The `http`
driver is the deterministic compatibility fallback for a host without the
upstream Kubernetes/planner runtime; it uses the same bounded profile and
manifest contract.

The output contains `llmd_raw.json`, `summary.json`, Prometheus before/after
captures, and an updated diagnostic manifest `bench` block.
