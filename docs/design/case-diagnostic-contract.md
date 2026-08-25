# Case Diagnostic Contract (M0 Alpha)

Date: 2026-08-24  
Milestone: [dynamo-catch-up-milestones.md](./dynamo-catch-up-milestones.md) M0

## Overview

Every playground case can declare a **`[spec]`** block in `case.toml` describing topology, HTTP endpoints, and probes. Running `harness/bin/validate-case` against a live deployment produces a **`diagnostic-manifest.json`** (observed status) and a standardized evidence tree.

This follows a **spec / status** split familiar from Kubernetes: the case declares intent; the validator records observation.

## Spec (`case.toml`)

Identity fields (`case_id`, `category`, `n`, …) are unchanged and still drive warehouse emit. The optional `[spec]` section adds:

| Field | Purpose |
|-------|---------|
| `version` | Spec schema rev (alpha: `"0.1"`) |
| `topology` | `direct`, `entrypoint_wrap`, `frontend_workers`, `frontend_workers_etcd` |
| `host_env` | Env var for default `--host` |
| `[[spec.services]]` | Endpoint base URLs + probe list |

URL interpolation:

- `{host}` — replaced by `--host` or `host_env` value
- `${VAR:-default}` — shell-style env substitution

See [`playground/case.schema.toml`](../../playground/case.schema.toml) for the full field contract.

## Status (`diagnostic-manifest.json`)

Written under `${BENCH_RESULTS_ROOT}/diagnostics/<case_id>_<timestamp>/`:

```text
diagnostics/<case_id>_<ts>/
  diagnostic-manifest.json
  summary.md
  evidence/
    configuration/
    startup/
    health/
    metadata/
    services.json
    models.json
    stats.json
    metrics.prom
    client/          # reserved for M1 client-smoke
```

Manifest includes: case identity, topology fingerprint, probe results with categories, build hints, and failure diagnosis.

## Failure categories

| Category | Alpha | Description |
|----------|-------|-------------|
| `configuration` | yes | Invalid case.toml, dirname mismatch |
| `endpoint_reachability` | yes | HTTP/TCP unreachable |
| `backend_readiness` | yes | `/metadata` UUID, `/models` empty |
| `routing` | yes | `/services` names, chat smoke |
| `process_startup` | reserved | Container/PID checks (later) |
| `streaming` | reserved | M1 harness client |
| `cancellation` | reserved | M1 harness client |
| `performance` | reserved | M2 thresholds |

## CLI

```bash
# Standalone entrypoint wrap (MetaX C550 pilot)
export CASE_PATH=playground/Standalone/9g_8b_thinking-c550-vllm/case.toml
harness/bin/validate-case --host <container-ip>

# Distribution frontend + workers
export CASE_PATH=playground/Distribution/qwen3-32b+9g--x203-inf--opt20260811/case.toml
harness/bin/validate-case --host localhost --env-file playground/Distribution/.../docker-compose/.env

# Compare two runs
harness/bin/validate-case diff prev/diagnostic-manifest.json curr/diagnostic-manifest.json
```

Exit codes: `0` pass, `1` diagnostic failure, `2` configuration/usage error.

## Pilot cases (alpha)

| Case | Topology | Host |
|------|----------|------|
| `Standalone/9g_8b_thinking-c550-vllm` | `entrypoint_wrap` | node2 MetaX C550 |
| `Distribution/qwen3-32b+9g--x203-inf--opt20260811` | `frontend_workers` | compose localhost |

## Warehouse linkage (future)

Set `DIAGNOSTIC_MANIFEST` before harness emit; `emit_bench.sh` forwards `--diagnostic-manifest` when bench-warehouse supports it. Rows should eventually carry `diagnostic_manifest_path` and `topology_fingerprint` for reproducibility.

## Manual smoke checklist

1. **C550 entrypoint wrap:** `cd playground/Standalone/9g_8b_thinking-c550-vllm && ./smoke-wrap.sh`
2. **Distribution:** compose up → `validate-case --host localhost --env-file docker-compose/.env`
3. **Failure injection:** stop router → expect `endpoint_reachability` with evidence paths
4. **Diff:** run smoke twice → `validate-case diff run1/manifest run2/manifest`
