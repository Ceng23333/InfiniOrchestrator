# Deprecate InfiniMetadata

InfiniMetadata is no longer pinned in InfiniTensorWorktree. Warehouse identity and gateway metrics moved into InfiniOrchestrator control-plane binaries.

## Ownership

| Concern | Owner | Endpoint / env |
|---------|--------|----------------|
| Server identity (`server_id`, build/runtime probes) | InfiniEntrypoint | `GET /metadata`, `GET /v1/metadata` on entrypoint port (`service_port+1`) |
| Request `srv_*` metrics (TTFT/ITL/e2e/req/tokens) | InfiniLoadBalancer | `GET /metrics` (Prometheus text, `infinilm_*` names) |
| Harness helpers (`frontend`, prom→row) | `bench_warehouse/` in bench-warehouse | no InfiniMetadata package |

## Harness env

- `INFERENCE_METADATA_URL` — Entrypoint base URL (default: derive from inference URL as `port+1`)
- `BENCH_METRICS_URL` — metrics scrape URL (default: `ROUTER_URL`)
- Direct-to-worker / no LB → set `BENCH_SKIP_SERVER_METRICS=1` (engine gauges are not collected)

## InfiniLM

InfiniLM sources are unchanged. Without the InfiniMetadata package installed it uses the existing ImportError / NoOp path; engine `/metadata` and `/metrics` may 503. Harness must not scrape the engine for warehouse linkage.

## Engine gauges

`srv_engine_*` columns are no longer populated by the LB path (gateway metrics only).
