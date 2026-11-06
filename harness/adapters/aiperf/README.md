# Run-only NVIDIA AIPerf adapter (mooncake_trace)

Client-only load adapter for an already-running InfiniOrchestrator / OpenAI-compatible
endpoint. It never starts or stops the target case, Docker Compose, etcd, or workers.

Pinned client: **aiperf==0.13.0** (requires **Python ≥ 3.11**). Install with:

```bash
python3.11 -m pip install -r harness/adapters/aiperf/requirements.txt
# or: export AIPERF_BIN=/path/to/aiperf
```

## Workload

Profiles under `profiles/` drive:

```bash
aiperf profile \
  --model "$MODEL" \
  --endpoint-type chat \
  --streaming \
  --url "$BASE_URL" \
  --input-file "$TRACE_JSONL" \
  --custom-dataset-type mooncake_trace \
  --fixed-schedule \
  --artifact-dir "$OUT_DIR/aiperf_artifacts"
```

| Profile | Trace | Use |
|---------|-------|-----|
| `profiles/ci_mooncake_replay.yaml` | `traces/ci_mooncake_short.jsonl` | Default dual-run / regression |
| `profiles/ci_mooncake_smoke.yaml` | `traces/ci_mooncake_smoke.jsonl` | Short dry-run |

Trace provenance and regen notes: [`traces/README.md`](traces/README.md).

## Single endpoint

```bash
harness/bin/run-aiperf \
  --base-url "$BASE_URL" \
  --profile harness/adapters/aiperf/profiles/ci_mooncake_smoke.yaml \
  --case-path "$CASE_PATH" \
  --model Qwen3.8-27B \
  --role single \
  --output-dir "$BENCH_RESULTS_ROOT/aiperf_smoke"
```

Optional: `--manifest "$DIAGNOSTIC_MANIFEST"` updates the diagnostic `bench` block.

## Dual-run contract (vLLM baseline → InfiniLM candidate)

Order is fixed:

1. Preflight both URLs (`/health` soft, `/v1/models` required).
2. AIPerf against **vLLM** → `suite/baseline/vllm/` (abort here on failure).
3. AIPerf against **InfiniLM** → `suite/candidate/infinilm/`.
4. `compare.py` gates candidate vs frozen baseline → `suite/compare.json`.

```bash
harness/bin/run-aiperf-dual \
  --base-url-vllm "$BASE_URL_VLLM" \
  --base-url-infinilm "$BASE_URL_INFINILM" \
  --profile harness/adapters/aiperf/profiles/ci_mooncake_replay.yaml \
  --case-path-vllm playground/Standalone/qwen38-27b-qy-vllm--prod-qwen38-tp4/case.toml \
  --case-path-infinilm playground/Standalone/qwen38-27b-qy-inf--prod-qwen38-tp4/case.toml \
  --model Qwen3.8-27B
```

Standalone case docs:

- `playground/Standalone/qwen38-27b-qy-vllm--prod-qwen38-tp4/`
- `playground/Standalone/qwen38-27b-qy-inf--prod-qwen38-tp4/` (pin `v2026.10.29-infinilm-prod-qwen38-tp4`)

### Gates (defaults)

| Gate | Threshold |
|------|-----------|
| Both `success_rate` | ≥ 0.99 |
| InfiniLM / vLLM output throughput (`tok_s`) | ≥ **0.50** |
| InfiniLM TTFT p95 / vLLM TTFT p95 | ≤ **1.25** |

Standalone compare:

```bash
harness/bin/compare-aiperf \
  --baseline suite/baseline/vllm/summary.json \
  --candidate suite/candidate/infinilm/summary.json \
  -o suite/compare.json
```

`compare.json` always records `baseline_backend: vllm` and `candidate_backend: infinilm`.

## Warehouse

Optional: when `BENCH_WAREHOUSE_REPO` is configured, operators may emit via
`harness/lib/emit_bench.sh` after a dual-run. Warehouse is **not** required for the
local recipe or gates.

## Layout

```
adapters/aiperf/
  runner.py          # single-endpoint aiperf + summary.json
  dual.py            # vLLM then InfiniLM + compare
  compare.py         # regression gates
  manifest_map.py
  profile.py
  profiles/
  traces/
  requirements.txt
```

Bin wrappers: `harness/bin/run-aiperf`, `run-aiperf-dual`, `compare-aiperf`.
