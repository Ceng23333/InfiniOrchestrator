# Continuous-profiling tooling survey (LLM inference stack)

Date: 2026-11-20  
Related: [performance-promotion-e2e.md](./performance-promotion-e2e.md),
promo kits under `harness/adapters/promo_facts/kits/` (`hctracer`, `dlpti`,
`chrome_trace_*.py`)

## 1. Problem frame

Continuous profiling for LLM inference is not a one-shot kernel microbench.
Under live serve (continuous batching, TP workers, graph capture/replay) a
useful tool chain must attribute time across **stack layers**:

| Layer | Examples | Why it matters |
|-------|----------|----------------|
| Request scheduler (CPU) | Admission, packing, preempt, waiting queues | Drives Tok/Iter and batch efficiency; often misread as “GPU slow” |
| Executor / step loop | `step`, model-runner forward, sample | Bridges schedule → device work |
| Runtime API + graphs | Launch, sync, memcpy, `GraphLaunch` / capture | Host-side COMMAND/API inflation; mid-segment sync |
| Device kernels | Attention, GEMM, collectives | True CU / bucket ranking |
| Client wall | Throughput, TTFT, ITL, Tok/Iter | Accept/reject and surpass gates |

**Promo Observe→Parse today (Mars / hcTracer path)** already covers wall
(EvalScope/AIPerf) plus host-signal families from Chrome-trace style dumps
(`driver` / `runtime` / `command` / `api` / `gap` / `graph`). It does **not**
rank LLM **scheduler effort**:

- Matched `hcTracer` attach dumps are GPU/runtime timelines (API + kernels).
- EvalScope `Avg Decoded Tok/Iter` exists in suite artifacts but is not a
  `HostSignalFamily` and is not consumed by `rank_paths`.
- InfiniLM does not emit HCTX spans around schedule / step / batch build, so
  even with `--hctx` the tracer cannot invent scheduler ranges that the app
  never recorded.

This survey states **feature requirements** for continuous profiling tools on
that stack, then deep-dives **Nsight vs hcTracer** and **CUPTI vs HCPTI**.

## 2. Feature-requirements matrix

Priority: **Must** = continuous attach path unusable without it; **Should** =
needed for promo rank or trustworthy human dig; **Later** = deep dive / viz.

| Requirement | Pri | Continuous | Promo rank | Human debug | Notes |
|-------------|-----|------------|------------|-------------|-------|
| Attach to long-lived serve PID without restart | Must | Yes | Yes | Yes | `hcTracer --attach` already used by Mars kit |
| Bounded overhead / duty-cycled capture windows | Must | Yes | Soft | Soft | Full P64 attach traces are hundreds of MB–GB |
| Correlated CPU + GPU timeline **or** engine annotations | Must* | Yes | Scheduler path | Yes | *Must for scheduler attribution; host-only timelines suffice for host_graph |
| Stable export parseable by kits (Chrome trace / protobuf) | Must | Yes | Yes | Yes | Kits already repair truncated `tracer_out*.json` |
| Family-normalized host signals (`api`/`command`/`gap`/…) | Should | Soft | Yes | Soft | Contract in performance-promotion-e2e |
| Annotation hooks (NVTX / HCTX) for schedule, batch, forward, sample | Should | Yes | Scheduler path | Yes | App instrumentation; tool alone is insufficient |
| Multi-rank TP awareness (per-worker attach) | Should | Yes | Soft | Yes | Matched attach prefers GPU worker PIDs |
| Optional kernel-metric deep dive (roofline / SOL) | Later | No | CU buckets | Yes | ncu / HCPTI Profiling API / mcProfiler-class; not continuous default |
| Safe failure on truncated / early-exit tracer | Must | Yes | Yes | Soft | See `chrome_trace_light.load_chrome_trace` |
| Client wall + Tok/Iter co-emitted with profile window | Should | Soft | Yes | Yes | Scheduler proxy short-term without HCTX |

Map for InfiniOrchestrator:

- **Continuous profiling product** needs Must rows + HCTX (or CPU) for
  scheduler-visible timelines.
- **Promo rank** needs host families + wall; scheduler levers need a **new
  signal class**, not harder parsing of host `gap`/`command`.
- **Human debug** benefits from nsys-parity CPU stacks when available; Mars
  today relies on hcTracer + EvalScope + source reading.

## 3. Deep dive A — Nsight Systems / Compute vs hcTracer

### 3.1 Roles

| Dimension | Nsight Systems (`nsys`) | Nsight Compute (`ncu`) | hcTracer (HPCC, Mars) |
|-----------|------------------------|------------------------|------------------------|
| Role | System timeline | Per-kernel metrics | GPU/runtime timeline |
| Closest analogue | — | mcProfiler / HCPTI Profiling API class | **nsys-like, not ncu** |
| Typical export | `.nsys-rep` / SQLite / NVTX | Kernel reports | Chrome-trace JSON `tracer_out-*.json` |
| CPU stacks / OS runtime | Common when enabled | No | **Not present in current Mars matched-attach dumps** |
| Engine annotations | NVTX | N/A | HCTX if app instruments (`--hctx`); InfiniLM: none today |
| Attach live serve | Yes | Replay / kernel-centric | `--attach <pid>` (kit `attach_serve`) |
| Promo kit | Not wired | Not wired | `kits/hctracer` → `host_signals` |

Local CLI (HPCC 3.7): `hcTracer [--hctx] [--attach pid] [--odname] [--name]`.
Promo smoke/attach wrappers live in
`harness/adapters/promo_facts/kits/hctracer/run_promotion_loop_step.sh`.

### 3.2 What Mars hcTracer dumps actually contain

Evidence from suite matched-attach / baseline traces (Chrome `traceEvents`):

- Dominated by runtime API spans (`hcLaunchKernel`, `hcStreamSynchronize`,
  `hcGraphLaunch`, memcpy, device queries) and device kernels (GEMM, FA,
  RMSNorm, HCCL, …).
- Event fields: `ph`, `name`, `pid`, `tid`, `ts`, `dur`, `cat`, `args` (often
  `process_id` / `thread_id` on API records). Metadata is minimal (process
  name), not a full OS thread tree.
- No event names for continuous-batcher schedule / queue / admit / step_loop
  even when `--hctx` is enabled — because the **application did not push HCTX
  ranges**.

So hcTracer is the right **genre** of tool for continuous host+GPU timelines
on Mars, but **signal parity with a typical nsys+NVTX LLM dig is not there**.

### 3.3 Why “scheduler effort” digs work on Nsight Systems but not these dumps

People dig LLM scheduler effort from nsys by combining:

1. NVTX (or similar) ranges around schedule / step / batch build, and/or
2. CPU thread timelines + stacks on the scheduler/engine thread, and/or
3. OS runtime / context-switch views correlated with GPU bursts.

hcTracer can participate in (1) **if** InfiniLM (or the serve wrapper) emits
HCTX marks/ranges that HCPTI records and hcTracer exports. Current captures
lack (1)–(3). Host `gap` / `command` ratios from the same JSON measure
**GPU-host sync and launch overhead**, which correctly feed
`host_graph_command` ranking — they are **not** scheduler packing effort.

**Conclusion:** Failure to dig scheduler effort from hcTracer JSON is a
**missing instrumentation / CPU-layer gap**, not proof that “timeline tools
cannot.” Same family as nsys; thinner default signal set on Mars today.

## 4. Deep dive B — CUPTI vs HCPTI

### 4.1 Parallel APIs

| | CUPTI (NVIDIA) | HCPTI (HPCC, headers under `/opt/hpcc/include/hcpti/`) |
|--|----------------|--------------------------------------------------------|
| Purpose | Callbacks, activities, ranges, profiling metrics under CUDA tooling | Same structural role for HC/HPCC runtime |
| Activity path | `cuptiActivity*` kinds (memcpy, kernel, driver, runtime, marker, sync, graph, …) | `hcptiActivityEnable*` + `HCpti_ActivityKind` (memcpy, kernel, driver, runtime, marker, sync, graph_trace, overhead, …) |
| Callback / CBID | Runtime/driver/NVTX domains | Runtime CBID (`hcpti_runtime_cbid.h` / `hcr/`), compute CBID, **HCTX CBID** (`hcpti_hctx_cbid.h`: mark/range push-pop, domain, name thread/device/stream) |
| Annotation | NVTX | HCTX (`hctxRange*`, `hctxMark*`, domain APIs) — NVTX analogue |
| Metrics / ncu-like | CUPTI Profiling / Perfworks path | `hcpti_profiler_target.h`: `HCPTI_AutoRange` / `UserRange`, kernel/application/user replay |
| CLI consumers | nsys, ncu, custom agents | hcTracer (activity/timeline), profiler-target consumers for kernel metrics |

HCPTI activity kinds of note for LLM continuous profiling (from
`hcpti_type.h`): `RUNTIME`, `DRIVER`, `KERNEL` / `CONCURRENT_KERNEL`,
`MEMCPY` / `MEMSET`, `SYNCHRONIZATION`, `GRAPH_TRACE`, `MARKER` /
`MARKER_DATA`, `OVERHEAD`, plus extras. That surface is enough to feed
promo host families **and** annotated scheduler spans (via markers/HCTX) —
again, **markers need producers**.

### 4.2 What a continuous agent would call vs what hcTracer wraps

- **Continuous / attach (nsys-like):** enable activity kinds for runtime,
  kernel, memcpy, sync, graph, marker; buffer callbacks; export Chrome-trace
  or equivalent. Today InfiniOrchestrator does this via **`hcTracer` CLI**
  (smoke or `--attach`), not a first-party HCPTI agent inside IO.
- **Deep dive (ncu-like):** HCPTI Profiling API with auto/user ranges and
  replay modes — **orthogonal** to continuous attach; should not be the
  default Observe path (overhead, multipass).
- **Scheduler spans:** application calls HCTX range APIs around schedule/step;
  HCPTI records `MARKER` / HCTX CBIDs; tracer export must preserve them;
  promo parse must map named ranges → a future signal (not `gap`).

### 4.3 Gaps that block LLM-scheduler continuous signals

| Gap | Layer | Fix |
|-----|-------|-----|
| No InfiniLM HCTX around schedule/step/batch | App | Instrument engine; keep ranges cheap |
| hcTracer dumps without CPU stacks | Tool default / capture flags | Need CPU/OS layers or rely on HCTX only |
| Promo rank has no scheduler family | IO contract | New signal (Tok/Iter short-term; HCTX-derived medium-term) |
| Confusing host `gap`/`command` with scheduler | Semantics | Docs + ranker: host_graph ≠ batcher effort |
| Kernel profiling API used as continuous default | Process | Keep Profiling API as Later / human escalate |

## 5. Recommendations for InfiniOrchestrator

1. **Keep hcTracer** as the Mars **continuous / attach** host-timeline kit
   (`VendorProfiler=hctracer`). It is the correct nsys-class tool for this
   device track.
2. **Do not** treat host `gap` / `command` as scheduler effort. They remain
   inputs to `host_graph_command`.
3. **Scheduler-effort signal class (phased):**
   - Short-term: emit EvalScope (or engine) Tok/Iter / batch stats beside
     walls; optional backlog hint when packing ≪ target concurrency.
   - Medium-term: HCTX ranges in InfiniLM schedule/step + parse marker spans
     from hcTracer JSON into facts; extend `HostSignalFamily` or a sibling
     fact only after the contract is stable.
4. **HCPTI vs CUPTI mental model for contributors:** HCPTI ≈ CUPTI for HC;
   HCTX ≈ NVTX; hcTracer ≈ nsys CLI; HCPTI Profiling API ≈ ncu-class metrics.
5. **Viz** remains a consumer of validated facts
   ([continuous-profiling-viz.md](./continuous-profiling-viz.md) when present);
   this survey does not define Grafana panels.

## 6. Out of scope here

- Implementing InfiniLM HCTX instrumentation
- Shipping a new ranker path or `scheduler_effort` field in `promo-facts-1`
- AutoHelix engage / live FA-allowlist campaigns
