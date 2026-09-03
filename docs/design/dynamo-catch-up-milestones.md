# InfiniOrchestrator Milestones: Case-Diagnostic Promotion Path

Date: 2026-08-25
Upstream baseline: `main` at `8308873` (`define spec contract`), checked against [Ceng23333/InfiniOrchestrator](https://github.com/Ceng23333/InfiniOrchestrator).

## Goal

Use the existing case-driven deployment workflow as the source of truth. First make a pure HTTP load balancer reliable, observable, and diagnosable for every current case. Then promote capabilities one at a time toward Dynamo-like orchestration: dynamic discovery, lifecycle control, disaggregation, KV-aware routing, and scaling.

The orchestrator does not replace InfiniLM, vLLM, SGLang, MindIE, or their internal schedulers. It owns case composition, HTTP traffic, worker identity, health, routing, and eventually fleet control.

## Current upstream state

The upstream repository is a deployment-focused skeleton with a working HTTP data path and case/benchmark tooling. It is not yet a generic deployment controller.

Present today:

- Rust `infini-entrypoint` process manager with health, metadata, probes, and service lifecycle handling.
- Rust `infini-loadbalancer` with OpenAI-compatible HTTP proxying, streaming, health/status/stats/services/models/metrics endpoints, backend health checks, and model/session/prompt routing helpers.
- Playground `Standalone` and `Distribution` cases, Docker/offline packaging, validation scripts, and benchmark harness integration.
- Case-diagnostic **alpha**: `case.toml [spec]` (topology, roles, endpoints, probes), `harness/bin/validate-case`, `diagnostic-manifest.json` + evidence trees; see [`case-diagnostic-contract.md`](case-diagnostic-contract.md). Live Standalone C550 entrypoint-wrap pilot (`9g_8b_thinking-c550-vllm`) validated **pass** on 2026-08-25.
- etcd lease registration and keepalive in the entrypoint, plus list/watch synchronization in the load balancer. This is useful infrastructure, but it is not yet a desired-state deployment controller.
- Operations-panel projection and benchmark/warehouse metadata paths.
- Cancellation and unexpected-behavior test scenarios in the harness.

Not yet present or only skeletal:

- Full M0 hardening: migrate all playground cases to `[spec]`, streaming/cancellation/performance failure categories, sharepool probes, richer PID/generation identity, and warehouse columns for `diagnostic_manifest_path` / `topology_fingerprint`.
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

Current status: **Alpha landed**; M1 may start. Detail in [`case-diagnostic-contract.md`](case-diagnostic-contract.md).

**Done (alpha):**

- Spec/status contract: `case.toml [spec]` vs `diagnostic-manifest.json`
- Live categories: configuration, endpoint_reachability, backend_readiness, routing
- Evidence under `diagnostics/<case_id>_<ts>/`; CLI `validate-case` (+ `diff`); Distribution `validate.sh` delegates to `validate-case`
- Pilots: `Standalone/9g_8b_thinking-c550-vllm` (`entrypoint_wrap`) live **pass** 2026-08-25; `Distribution/qwen3-32b+9g--x203-inf--opt20260811` (`frontend_workers`) has `[spec]` in tree

**Partial:**

- Distribution end-to-end live validate against compose not yet recorded as pass (command exists; last dry run was reachability fail without a live stack)
- Warehouse: `DIAGNOSTIC_MANIFEST` passthrough in `emit_bench.sh`; bench-warehouse columns still future

**Remaining (full M0 / later):**

- Migrate remaining playground cases; reserved categories process_startup, streaming, cancellation, performance
- Sharepool probes; richer build/PID identity; optional panel `has_spec`

Exit criteria: one command validates a standalone and a distribution case; failures identify the failing layer and include the relevant evidence paths; two runs of the same case can be compared without manually reconstructing topology.

Alpha note: Standalone side of the exit criteria is met for the C550 entrypoint-wrap pilot; Distribution side has the one-command path, with a live compose pass still pending. Full M0 is not a blocker for starting M1.

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

Current status: **TJ M1 case baseline passed; full M1 milestone remains open.** The load balancer has HTTP proxying, streaming, health checks, service/model/status/metrics handlers, and routing helpers. The `qwen3-32b+qwen3-32b--tj-vllm--m1` Distribution case was launched and validated on 2026-08-26 with two Qwen3-32B X203 workers in TP4 graph mode. Its M1 case gate passed: `/health` and `/v1/models` returned successfully, direct and load-balanced completions succeeded, streaming client cancellation succeeded, worker loss drained the LB to `1/1`, worker recovery returned it to `2/2`, and bounded smoke-load at concurrency 4 and 8 completed with zero request errors. The daemon process-group stop fix and the accepted case evidence are recorded in the case documentation.

Delivered for M1: the minimal run-only `llm-d-benchmark` adapter, bounded `m1_http_smoke` profile, core result metrics, and diagnostic-manifest `bench` linkage. The HTTP compatibility driver was validated against the live metax-9 Qwen3-32B router on 2026-09-01 with 10/10 successful streaming requests and zero request errors. The upstream planner-backed driver is prepared but not live-validated because metax-9 provides Python 3.9 and the optional planner install on metax-49 was blocked by GitHub TLS.

Still missing for the full M1 exit: a first-class etcd-free pure-HTTP case, completion of the native diagnostic result schema and conformance coverage, and deterministic timeout/malformed-model tests tied into the diagnostic manifest. The TJ case uses etcd-backed discovery and a custom smoke-load probe, so it remains the reference operational case but does not by itself satisfy those remaining full-M1 deliverables.

Exit criteria: a pure HTTP case can be started, validated, benchmarked, and diagnosed without etcd; one `llm-d-benchmark` run-only profile can target that live endpoint; backend loss, backend recovery, client disconnect, timeout, and malformed model routing have deterministic results; the diagnostic manifest links every result to the exact route and backend.

### M2 - HTTP load balancer hardening and case matrix

Promote the baseline from one working case to a reliable case family.

Deliverables:

- Case matrix covering direct backend, one load balancer plus one backend, and one load balancer plus multiple backends.
- Supported routing policies for M2: round-robin and explicit model matching. Weighted, model-pinned, and session/prompt-affinity routing are deprecated as M2 requirements; they are not part of the conformance gate unless a later case adds a documented implementation and owner.
- Admission limits, per-backend concurrency, queue/request accounting, and bounded retry behavior.
- Contract tests for HTTP status, JSON errors, SSE streaming, token usage, cancellation, and deadlines.
- Golden diagnostic snapshots for `/services`, `/models`, `/stats`, and `/metrics`.
- Regression thresholds for request success, TTFT, ITL, throughput, and routing overhead.
- Expand the M1 adapter to cover the supported routing policies, backend replicas, queue pressure, and the full `llm-d-benchmark` metrics collection profile.
- Add the complete HTTP load-balancer conformance matrix and compare native case diagnostics against `llm-d-benchmark` output.

Current status: Partial. The direct, single-backend, and two-replica round-robin paths have been exercised, including a vLLM two-replica baseline on metax-9. Existing harness and unexpected-behavior scenarios provide useful pieces, but there is no complete HTTP load-balancer conformance matrix and the M1 adapter has not yet been expanded to the full profile.

Remaining plan:

1. Freeze the M2 case matrix around direct HTTP, one backend behind the load balancer, and multiple backends behind the load balancer; use round-robin and explicit model matching as the only supported policy gates.
2. Add admission-limit, per-backend concurrency, queue-accounting, and bounded-retry probes, including a test that proves an in-generation request is never duplicated.
3. Build one shared HTTP conformance suite for status/JSON errors, SSE streaming, token usage, cancellation, deadlines, and model selection; run it against every matrix case.
4. Capture golden `/services`, `/models`, `/stats`, and `/metrics` snapshots and define regression thresholds for success rate, TTFT, ITL, throughput, and routing overhead.
5. Expand the M1 `llm-d-benchmark` adapter to emit the full metrics profile and compare its results with native case diagnostics; keep this as the final M2 integration gate.

Exit criteria: all supported HTTP cases pass the same diagnostic and conformance suite; round-robin and explicit model matching each have a reproducible test; admission, queue, retry, and deadline behavior meet the thresholds; and no retry duplicates an in-generation request.

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

- M0 alpha: **landed** (hardening continues in parallel; not a blocker for M1).
- Active P0: **M1 remaining exit work**. Complete the etcd-free pure-HTTP case, diagnostic result schema/conformance coverage, and deterministic failure tests; the minimal run-only benchmark adapter is delivered.
- Delivered M1 case baseline: TJ Qwen3-32B TP4 graph deployment is validated and operational; keep it as the reference multi-backend case while the full M1 exit work lands.
- P0 residual: M0 full hardening (case matrix migration, reserved failure categories, warehouse columns) where it does not block M1.
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

The comparison uses the referenced `Choose InfiniOrchestrator benchmark` and `Compare SGLang Dynamo deployments` tasks, upstream `main` at `8308873`, and the current source/design files. The selected benchmark strategy is `llm-d-benchmark` as the system-level comparison framework, with native case diagnostics as the required first path. Dynamo's SGLang documentation describes role-specific workers, KV events, disaggregated prefill/decode coordination, health/metrics/traces, and planner/autoscaling capabilities:

- [`llm-d-benchmark` repository](https://github.com/llm-d/llm-d-benchmark)
- [`llm-d-benchmark` metrics collection](https://github.com/llm-d/llm-d-benchmark/blob/main/docs/metrics_collection.md)
- [Dynamo SGLang reference guide](https://docs.nvidia.com/dynamo/backends/sg-lang/reference-guide)
- [Dynamo SGLang disaggregation](https://docs.nvidia.com/dynamo/dev/knowledge-base/modular-components/backends/sg-lang/disaggregation)
- [Dynamo observability](https://docs.nvidia.com/dynamo/kubernetes/operations/observability)
- [Dynamo autoscaling](https://docs.nvidia.com/dynamo/dev/knowledge-base/kubernetes/kubernetes-operator/autoscaling)

## Appendix A: llm-d and `llm-d-benchmark` usage

### What llm-d is

[llm-d](https://llm-d.ai/) is a Kubernetes-native distributed LLM inference stack built above model servers such as vLLM and SGLang. It targets production patterns including LLM-aware / prefix-cache-aware routing, prefill/decode disaggregation, distributed KV / tiered cache, and autoscaling on Kubernetes primitives (Gateway API Inference Extension, LeaderWorkerSet, and related operators).

[`llm-d-benchmark`](https://github.com/llm-d/llm-d-benchmark) is the companion benchmarking workflow (standup → run harness → collect metrics → teardown). Upstream it can stand up an `llm-d` or standalone stack; InfiniOrchestrator does **not** adopt that full lifecycle.

### Role in the InfiniOrchestrator target matrix

llm-d the serving stack is **not** a runtime target or control-plane dependency. What belongs in the HTTP case / LB conformance matrix is **`llm-d-benchmark` as an optional, run-only client/metrics adapter** against an already-running InfiniOrchestrator OpenAI-compatible HTTP endpoint.

| Role | Policy |
|------|--------|
| Allowed | Optional system-level comparison layer for repeatable load profiles and comparable metrics |
| Not allowed | Runtime dependency, deployment controller, or owner of server lifecycle |
| Identity / evidence owner | `InfiniOrchestrator/harness` and `bench-warehouse` |
| Adapter duty | Hit a live Infini endpoint; collect router, queue, replica, cache, host, and accelerator metrics when available |

Rules of engagement:

1. Case harness and native diagnostics remain mandatory (M0/M1); `llm-d-benchmark` is optional so pure HTTP LB stays testable on a minimal host.
2. Use **run-only** mode: do not start or stop case services.
3. Preserve Infini identity (`CASE_PATH`, `server_id`, warehouse emission) and map adapter output into the diagnostic manifest (profile, client version, case/server revision, collection config).
4. Keep the load balancer backend-agnostic; backend specifics stay in case config or adapters.

Timeline in the matrix:

```text
M0  native case diagnostics (mandatory)
 ↓
M1  pure HTTP LB baseline + minimal llm-d-benchmark run-only profile
 ↓
M2  HTTP case / conformance matrix + full metrics profile
    + compare native diagnostics vs llm-d-benchmark output
 ↓
M5/M6  agentic/cache-sensitive workloads as inputs (not a diagnostic replacement)
```

### Spec to pick

Pick the **`llm-d-benchmark` client/metrics contract**, not the llm-d serving stack.

| Layer | Pick | Skip |
|-------|------|------|
| Project | `llm-d-benchmark` | llm-d K8s stack, modelservice, EPP/Gateway standup |
| Mode | `run` only against a live Infini HTTP endpoint | `standup` / `teardown` / stack ownership |
| Contract source | [metrics collection](https://github.com/llm-d/llm-d-benchmark/blob/main/docs/metrics_collection.md) + harness load profiles | Hard dependency on llm-d pod labels, EPP scrapers, or K8s replica APIs |
| Version pin | A released `llm-d-benchmark` tag (e.g. **v0.8.0**, bundled with llm-d **v0.9.0**), recorded in the diagnostic manifest | Floating `main` without recording client version |

**M1 — minimal core client metrics:** request rate; success/error rate; p50/p95/p99 latency; TTFT; ITL/TPOT; endpoint distribution; queue depth when exposed; router overhead. One run-only profile against one pure-HTTP case is enough for M1 exit.

**M2 — full metrics collection profile**, mapped onto Infini surfaces (not copied as vLLM/EPP-only names): harness latency/token timings across the case matrix; router overhead from LB route decisions; queue/running requests from LB or backend exposure; replica/endpoint distribution via `/services`; cache/prefix metrics only when M6-class signals exist; host/accelerator scrapes optional and non-blocking for minimal hosts. Do not require EPP `inference_extension_*` or K8s replica APIs.

Decision rule: compatibility is OpenAI-compatible HTTP plus comparable metric semantics; native diagnostics win when the two disagree; pin and record `llm-d-benchmark` version and harness choice so warehouse rows stay reproducible.
