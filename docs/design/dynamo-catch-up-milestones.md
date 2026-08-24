# InfiniOrchestrator Milestones: Case-Diagnostic Promotion Path

Date: 2026-08-24
Upstream baseline: `main` at `76c38c3` (`split harness into data and client`), checked against [Ceng23333/InfiniOrchestrator](https://github.com/Ceng23333/InfiniOrchestrator).

## Goal

Use the existing case-driven deployment workflow as the source of truth. First make a pure HTTP load balancer reliable, observable, and diagnosable for every current case. Then promote capabilities one at a time toward Dynamo-like orchestration: dynamic discovery, lifecycle control, disaggregation, KV-aware routing, and scaling.

The orchestrator does not replace InfiniLM, vLLM, SGLang, MindIE, or their internal schedulers. It owns case composition, HTTP traffic, worker identity, health, routing, and eventually fleet control.

## Current upstream state

The upstream repository is a deployment-focused skeleton with a working HTTP data path and case/benchmark tooling. It is not yet a generic deployment controller.

Present today:

- Rust `infini-entrypoint` process manager with health, metadata, probes, and service lifecycle handling.
- Rust `infini-loadbalancer` with OpenAI-compatible HTTP proxying, streaming, health/status/stats/services/models/metrics endpoints, backend health checks, and model/session/prompt routing helpers.
- Playground `Standalone` and `Distribution` cases, Docker/offline packaging, validation scripts, and benchmark harness integration.
- etcd lease registration and keepalive in the entrypoint, plus list/watch synchronization in the load balancer. This is useful infrastructure, but it is not yet a desired-state deployment controller.
- Operations-panel projection and benchmark/warehouse metadata paths.
- Cancellation and unexpected-behavior test scenarios in the harness.

Not yet present or only skeletal:

- No case-diagnostic contract that makes the actual topology, HTTP endpoints, backend identity, and failure evidence machine-readable.
- No typed deployment/workergroup API, desired-state store, reconciliation loop, rollout controller, or replacement scheduler.
- No first-class prefill/decode pools or request state machine for KV handoff.
- `infini-sharepool` exposes `/health` only and is not launched by playground cases.
- No cache-block event protocol, KV index, KV-aware placement, or production transfer abstraction.
- No distributed tracing or complete cross-hop request correlation.
- No planner, autoscaling loop, scale-to-zero controller, or Kubernetes-neutral deployment adapter.

## Promotion rules

- A case is the unit of delivery. Every milestone must add or update a runnable `Standalone` or `Distribution` case.
- HTTP behavior comes before control-plane promotion. A capability is not promoted until the pure HTTP path has a diagnostic baseline.
- Each case must emit topology, endpoint, backend, health, request, and performance evidence that can be compared across revisions.
- The load balancer remains backend-agnostic. Backend-specific behavior belongs in case configuration or an adapter.
- Aggregated HTTP serving remains the fallback while P/D or KV capabilities are unavailable.

## Benchmark strategy

Use the repository's case harness as the source of identity and evidence, with `llm-d-benchmark` as an optional compatibility layer for system-level comparison. `llm-d-benchmark` should exercise an already-running InfiniOrchestrator HTTP endpoint and collect comparable router, queue, replica, cache, host, and accelerator metrics; it must not start or own the server lifecycle.

The benchmark split is:

- Case-diagnostic harness: mandatory for M0 and M1. It validates endpoints, routing, streaming, cancellation, health, and evidence completeness.
- `llm-d-benchmark` adapter: introduced in M1 in minimal run-only mode for repeatable HTTP load profiles and core system metrics, then expanded in M2 while preserving `CASE_PATH`, `server_id`, and warehouse emission.
- Agentic/cache-sensitive workloads: introduced with M5/M6 to evaluate P/D and KV-aware behavior. They are workload inputs, not a replacement for case diagnostics.
- Benchmark result ownership remains `InfiniOrchestrator/harness` for runners and `bench-warehouse` for emitted raw rows and compact facts.

The benchmark adapter is optional because pure HTTP LB performance must remain testable on a minimal host with only the current case, HTTP endpoint, and standard client dependencies.

## Milestones

### M0 - Case-diagnostic contract

Make every deployment case self-describing and diagnosable before expanding runtime behavior.

Deliverables:

- Extend `case.toml` with explicit case identity, topology, service roles, backend, model, accelerator, endpoint URLs, and expected health/metadata routes.
- Define a diagnostic manifest containing case revision, image/build identity, process IDs or generations, route topology, environment/flags, and dependency versions.
- Standardize probes for load balancer, entrypoint/babysitter, inference backend, registry/etcd when used, and optional sharepool.
- Standardize evidence directories for startup logs, health snapshots, `/services`, `/models`, `/stats`, `/metrics`, `/metadata`, and client results.
- Make validation fail with a categorized diagnosis: configuration, process startup, endpoint reachability, backend readiness, routing, streaming, cancellation, or performance.
- Keep benchmark warehouse emission linked to the case manifest so a result can be reproduced from the case alone.

Current status: Not implemented as a unified contract. The repository has case schemas, validation scripts, harness output, and panel projections, but they are not one diagnostic model.

Exit criteria: one command validates a standalone and a distribution case; failures identify the failing layer and include the relevant evidence paths; two runs of the same case can be compared without manually reconstructing topology.

### M1 - Pure HTTP load balancer baseline

Make the current `infini-loadbalancer` path the stable first product surface.

Scope: no P/D, no KV-aware routing, no autoscaling, and no requirement for etcd. A static service list and direct HTTP backend are valid.

Deliverables:

- Stable OpenAI-compatible HTTP proxy for `/v1/models`, chat/completions, completions, embeddings where supported, and streaming responses.
- Deterministic static backend selection for a case, with explicit model matching and clear 404/503 behavior.
- Health-aware backend admission: startup, ready, unhealthy, draining, and removed states must be visible through `/services` and diagnostics.
- Request ID, backend ID, case ID, and route decision in structured logs and response-safe metrics.
- Correct client disconnect, timeout, cancellation, and upstream error propagation for HTTP streaming.
- `/health`, `/status`, `/stats`, `/services`, `/models`, and `/metrics` documented as the diagnostic surface.
- A minimal pure-HTTP case and a multi-backend HTTP case with repeatable smoke and failure tests.
- A diagnostic result schema aligned with the metrics needed by the future `llm-d-benchmark` adapter: request rate, success/error rate, p50/p95/p99 latency, TTFT, ITL/TPOT, endpoint distribution, queue depth when exposed, and router overhead.
- A minimal `llm-d-benchmark` run-only adapter against the already-running HTTP endpoint. It must not start or stop case services.
- Adapter output mapped into the case diagnostic manifest, including benchmark profile, client version, server/case revision, and collection configuration.

Current status: Partially implemented. The load balancer already has HTTP proxying, streaming, health checks, service/model/status/metrics handlers, and routing helpers. The native diagnostic path exists only in pieces; the M1 `llm-d-benchmark` run-only adapter is not implemented.

Exit criteria: a pure HTTP case can be started, validated, benchmarked, and diagnosed without etcd; one `llm-d-benchmark` run-only profile can target that live endpoint; backend loss, backend recovery, client disconnect, timeout, and malformed model routing have deterministic results; the diagnostic manifest links every result to the exact route and backend.

### M2 - HTTP load balancer hardening and case matrix

Promote the baseline from one working case to a reliable case family.

Deliverables:

- Case matrix covering direct backend, one load balancer plus one backend, and one load balancer plus multiple backends.
- Explicit routing policies: round-robin, weighted, model-pinned, and session/prompt-affinity where supported.
- Admission limits, per-backend concurrency, queue/request accounting, and bounded retry behavior.
- Contract tests for HTTP status, JSON errors, SSE streaming, token usage, cancellation, and deadlines.
- Golden diagnostic snapshots for `/services`, `/models`, `/stats`, and `/metrics`.
- Regression thresholds for request success, TTFT, ITL, throughput, and routing overhead.
- Expand the M1 adapter to cover multiple routing policies, backend replicas, queue pressure, and the full `llm-d-benchmark` metrics collection profile.
- Add the complete HTTP load-balancer conformance matrix and compare native case diagnostics against `llm-d-benchmark` output.

Current status: Partial. Existing harness and unexpected-behavior scenarios provide useful pieces, but there is no complete HTTP load-balancer conformance matrix and the M1 adapter has not yet been expanded to the full profile.

Exit criteria: all supported HTTP cases pass the same diagnostic and conformance suite; every routing policy has a reproducible test; no retry duplicates an in-generation request.

### M3 - Discovery promotion

Promote dynamic discovery only after the pure HTTP contract is stable.

Deliverables:

- Versioned worker/service registration payload with model, backend, accelerator, role, capabilities, endpoint, generation, and case namespace.
- Preserve etcd leases, keepalive, list, and watch behavior while adding stale-generation fencing and snapshot diagnostics.
- Static configuration and etcd discovery use the same load-balancer service model.
- Discovery failures degrade explicitly to the configured policy: fail closed, retain last snapshot, or use static fallback.
- Diagnostic evidence records discovery revision, worker generation, and route snapshot.

Current status: Discovery foundation is implemented in the current source, but the contract is not yet versioned and the README/design wording is inconsistent with the code.

Exit criteria: a distribution case can switch between static and etcd discovery without changing HTTP semantics; stale workers are never selected; discovery loss and recovery are visible in case diagnostics.

### M4 - Lifecycle, drain, and reconciliation

Turn discovered services into managed workers without coupling the first HTTP path to a specific scheduler.

Deliverables:

- Desired versus observed state for case services and worker groups.
- Worker states: `Pending`, `Starting`, `Ready`, `Draining`, `Unhealthy`, `Stopping`, and `Failed`.
- Idempotent start, stop, restart, drain, and replacement operations with bounded retries.
- Drain protocol that stops new HTTP admissions, preserves active streams, and has a forced-cancel deadline.
- Rollout generation, audit events, and recovery tests for kill, duplicate registration, delayed heartbeat, and partial startup.

Current status: Entrypoint process management and health/probe behavior exist; the desired-state controller and safe replacement loop do not.

Exit criteria: a case can replace one backend without losing healthy traffic; active streams finish or are explicitly cancelled; every lifecycle transition is visible in diagnostics.

### M5 - Prefill/decode promotion

Add Dynamo-like disaggregation as a new case capability, while retaining aggregated HTTP fallback.

Deliverables:

- `PrefillPool` and `DecodePool` case resources with independent replica and placement settings.
- Request state machine: admitted -> decode reservation -> prefill -> KV handoff -> decode stream -> completed/aborted.
- Reservation expiry, backpressure, cancellation cleanup, and aggregated fallback.
- Backend-neutral bootstrap and KV-transfer interfaces, implemented first for the available Infini path and then for compatible SGLang-style backends.
- Case diagnostics for each stage, transfer setup, transfer completion, and fallback reason.

Current status: Distribution cases demonstrate multiple services, but the orchestrator has no P/D protocol or KV handoff state machine.

Exit criteria: a diagnostic P/D case completes one request through separate prefill and decode workers and produces evidence for every transition; failure falls back or fails with a categorized reason.

### M6 - KV-aware routing and shared pool

Promote cache locality only after P/D behavior is diagnosable.

Deliverables:

- Cache block identity scoped by model, tokenizer, page size, and worker generation.
- Worker cache events for create, reuse, delete, eviction, and invalidation.
- Router cache index with bounded memory, stale-event fencing, and prefix-overlap scoring.
- Shared-pool interface for GPU, host, and remote tiers; replace the current health-only `infini-sharepool` placeholder behind this interface.
- Route diagnostics for cache score, queue score, transfer cost, cache hit/miss, and fallback.

Current status: Not implemented. Current session/prompt affinity helpers are not KV block awareness.

Exit criteria: a prefix-reuse case shows cache-aware placement beating load-only placement, and a router restart reconstructs safe routing state.

### M7 - Observability, planner, and scaling promotion

Use the diagnostic evidence to control the fleet.

Deliverables:

- OpenTelemetry context across frontend, workers, P/D stages, and KV transfer.
- Standard metrics for admission, queueing, TTFT, ITL, errors, cancellations, route decisions, cache transfer, and SLO burn.
- Offline profiling by case, backend, accelerator, TP/PP shape, and P/D ratio.
- Explainable planner recommendations with dry-run output.
- Separate prefill/decode scaling with bounds, cooldowns, hysteresis, and rollback.
- Canary, rolling upgrade, and scale-to-zero behavior represented as cases.

Current status: Gateway metrics, health endpoints, operations-panel projection, and warehouse scrapes exist. Tracing, planner, autoscaling, and rollout control are absent; the operations-panel design explicitly defers the planner/autoscaler UI.

Exit criteria: a recorded case workload produces a recommendation and a traceable scaling decision; autoscaling improves SLO compliance without oscillation; failed promotion rolls back to the last healthy case generation.

### M8 - Deployment portability and conformance

Package the promoted capabilities for non-NVIDIA environments.

Deliverables:

- Standard deployment intent mapped to Compose/playground first, then Kubernetes, Slurm, and bare metal adapters.
- No NVIDIA Dynamo or NVIDIA operator runtime dependency.
- Backend matrix covering InfiniLM, vLLM, SGLang, and at least one NPU-serving backend.
- End-to-end conformance cases for HTTP, discovery, lifecycle, cancellation, P/D, KV, scaling, and recovery.

Current status: Compose/offline packaging and playground cases exist; generic deployment intent and cross-accelerator conformance do not.

Exit criteria: the same diagnostic case intent runs on at least two accelerator families and two inference backends, with comparable evidence and versioned results.

## Recommended sequencing

```text
M0(case diagnostics)
        |
M1(pure HTTP LB) -> M2(HTTP case matrix) -> M3(discovery)
                                               |
                                      M4(lifecycle/drain)
                                               |
                                      M5(P/D) -> M6(KV)
                                               |
                                      M7(observe/scale) -> M8(portability)
```

M7 instrumentation should begin during M1 and M5, but planner/autoscaling must wait for stable diagnostics, lifecycle semantics, and queue/cache signals.

## Priority definition

- P0: M0. Establish the diagnostic contract and case evidence model.
- P0: M1. Make pure HTTP load balancing the reliable current-state baseline.
- P1: M2. Turn the baseline into a conformance-tested case family.
- M1 establishes the minimal `llm-d-benchmark` compatibility path; M2 expands it to the full case matrix. It remains a client/metrics adapter, not a runtime dependency.
- P1: M3 and M4. Promote dynamic discovery and safe lifecycle management.
- P1 performance: M5 and M6. Add P/D and KV only with case-level evidence.
- P2: M7. Planner, tracing, and autoscaling follow trustworthy signals.
- P2: M8. Productize portability after capability conformance exists.

## Explicit non-goals

- Replacing SGLang, vLLM, or InfiniLM schedulers inside a worker.
- Reimplementing CUDA/NCCL or vendor-specific collective kernels in the orchestrator.
- Making every backend expose identical KV internals; capability negotiation and aggregated fallback are required.
- Treating Kubernetes as the control plane. Kubernetes is one deployment adapter; the case and HTTP contracts must remain usable elsewhere.

## Definition of catch-up

InfiniOrchestrator is at Dynamo-level for a deployment class when a case can be diagnosed and operated through pure HTTP, then promoted to dynamic discovery, safe lifecycle control, independent prefill/decode pools, KV-aware routing, end-to-end observability, and controlled scaling, using at least one non-NVIDIA accelerator path and without NVIDIA Dynamo as a runtime dependency.

## Reference comparison

The comparison uses the referenced `Choose InfiniOrchestrator benchmark` and `Compare SGLang Dynamo deployments` tasks, upstream `main` at `76c38c3`, and the current source/design files. The selected benchmark strategy is `llm-d-benchmark` as the system-level comparison framework, with native case diagnostics as the required first path. Dynamo's SGLang documentation describes role-specific workers, KV events, disaggregated prefill/decode coordination, health/metrics/traces, and planner/autoscaling capabilities:

- [`llm-d-benchmark` repository](https://github.com/llm-d/llm-d-benchmark)
- [`llm-d-benchmark` metrics collection](https://github.com/llm-d/llm-d-benchmark/blob/main/docs/metrics_collection.md)
- [Dynamo SGLang reference guide](https://docs.nvidia.com/dynamo/backends/sg-lang/reference-guide)
- [Dynamo SGLang disaggregation](https://docs.nvidia.com/dynamo/dev/knowledge-base/modular-components/backends/sg-lang/disaggregation)
- [Dynamo observability](https://docs.nvidia.com/dynamo/kubernetes/operations/observability)
- [Dynamo autoscaling](https://docs.nvidia.com/dynamo/dev/knowledge-base/kubernetes/kubernetes-operator/autoscaling)
