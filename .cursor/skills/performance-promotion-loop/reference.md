# Performance promotion loop — reference

Derived from Cursor agents:

- `926aff24-3b86-4c32-be1e-817ff73d73dd` @ c610 (DLPTI host-aware promote + graph A/B)
- `01229051-a881-4ebf-aef2-6d67110b7449` @ metax-showroom (AIPerf dual + mcTracer plan)

Fact envelope: [facts.md](facts.md).  
Normative pipe + harness/warehouse:
[`docs/design/performance-promotion-e2e.md`](../../../docs/design/performance-promotion-e2e.md).

## Observe→Parse SOP vs AI Promote

| Phase | Owner | Harness |
|-------|-------|---------|
| Observe wall (+ optional profiler) | SOP | `run-aiperf-dual`, kit roots |
| Parse / rank / emit `promo-facts-1` | SOP | `parse-promo-facts`, `rank-promotion`, `run-promotion-loop-step` |
| Pick one lever + rebuild | **AI** | not in SOP scripts |
| Warehouse compact emit | SOP (optional) | `emit-promo-facts` |

`run-promotion-loop-step` **exits before promote**.

## Device-track routing

| `device_track` | Wall | Profiler | Env |
|----------------|------|----------|-----|
| `denglin_qy` | harness / AIPerf | DLPTI | `DLPTI_ROOT` |
| `metax_qy` | `run-aiperf-dual` | mcTracer | `MCTRACER_ROOT` |
| `mars` | LongBench / harness / AIPerf | **none** until kit | — |
| `other` | as configured | as configured | — |

## Host tooling

### Denglin QY / DLPTI (`denglin_qy`)

- Kit: `llm_performace_benchmark/tools/dlpti/` (`summarize`, `compare`, `promote`, `timeline_facts`)
- IO wrapper: `harness/bin/run-promotion-loop-step` with `DEVICE_TRACK=denglin_qy`
- `WALL_DECODE_RATIO` / primary wall required (unprofiled)
- Results (examples): `result/host_graph_promo/`, `result/promo_16a3_tp2/`, `result/dlpti/`

### MetaX QY / showroom / AIPerf + mcTracer (`metax_qy`)

- Wall: InfiniOrchestrator `harness/bin/run-aiperf-dual` / `compare-aiperf` (run-only)
- Profile kit: `perf_mccl_loop/tools/profile/` (`parse_mctracer`, `compare`, `promote`, `write_findings`)
- Suites (examples): `results/aiperf_vllm_leg_*`, `results/peak_batch64_promotion/`
- Pin AIPerf `0.13.0` in Python ≥3.11; preflight `/v1/models`; escalate `PROFILE_REGRESS` to matched mcTracer — not more AIPerf knobs

### Mars (`mars`)

Wall A/B only until a matched profiler kit exists. Emit `walls[]` + empty backlog
when no profiler ran; `vendor_profiler` = `aiperf` or `none`.

## Lever map

Keep in sync with host promote `LEVER_MAP` when vendoring.

| path_id | Evidence | Typical lever |
|---------|----------|---------------|
| `host_graph_command` | Host API/COMMAND/CU-gap ≫; CU ≤ vLLM; wall ≪ | `INFINI_CUDAGRAPH_POLICY` / F&P / skip-tail / host sync |
| `rope` | rope us/flash ≫ | `INFINI_QY_ROPE_SMALL_BLOCK` |
| `kv_cache_reshape` | kv bucket ≫ | `INFINI_QY_KV_SMALL_BLOCK` |
| `residual_add_rmsnorm` | residual ≫ | `INFINI_QY_FUSED_ADD_RMSNORM=1` (deprioritize if CU already ≤) |
| `moe_fused` | MoE CU bucket ≫ (c610 16a3) | MoE fused / bf16 / warpnk / graph policy |
| `gated_delta_rule` | MetaX GDN path ranked | GDN / graph / triton levers |
| `batch_policy` | MetaX peak campaign | admission / MIXED / ladder policy |
| `gemm` / `attention` / `allreduce` / `other` | material CU or score | inspect kernels; map when static lever exists |

Unmapped buckets still rank by ratio with lever text
`inspect bucket kernels; no static lever mapped yet`.

## Graph / CG facts agents must not confuse

- `enable_graph=true` enables the **compiler**, not guaranteed per-step CG replay.
- Hits depend on shape/batch capture; misses fall back to eager.
- Prefill FULL CG often needs `INFINI_PREFILL_FULL_CG` (EM-gated).
- Sampling + D2H + `syncStream` after forward are typically **outside** the graph
  and show up in COMMAND / host timeline even when CU ≤ vLLM.

## AIPerf gate fields

From `harness/adapters/aiperf/compare.py` (dual):

| Field | Default | Fail reason |
|-------|---------|-------------|
| `success_rate` | ≥ 0.99 | baseline or candidate flaky |
| tok/s ratio (candidate/baseline) | ≥ 0.50 | `PROFILE_REGRESS` throughput (**not** surpass) |
| TTFT p95 ratio | ≤ 1.25 | `PROFILE_REGRESS` latency |

Normalize all three into `IterFact.walls[]` with tok/s **primary**. Escalate if
**any** wall is `PROFILE_REGRESS`.

**Surpass ship** is primary wall ratio &gt; 1.0 on the agreed unprofiled cell metric.

## Decision table

| Wall vs vLLM | Profiler top_path | Action |
|--------------|-------------------|--------|
| ≥ 1.0 unprofiled primary | any | **Ship** (matrix + ITW tag + IO case) |
| Improved, still &lt; 1.0 | same as last turn | New lever from re-rank; do not retune same dial blindly |
| Flat | `host_graph_command` | Host sync / COMMAND / sample D2H — not more F&P-only knobs |
| `PROFILE_REGRESS` only | none yet | Run matched profiler before code changes (not on mars) |
| Capture conflict on GPU | — | Non-destructive device / SKIP_STOP; never kill foreign jobs |

## Integration (IO harness)

| Bin | Role |
|-----|------|
| `harness/bin/run-aiperf` / `run-aiperf-dual` / `compare-aiperf` | Wall observe |
| `harness/bin/parse-promo-facts` | Validate / canonicalize envelope |
| `harness/bin/rank-promotion` | Host-first + CU/score backlog |
| `harness/bin/run-promotion-loop-step` | Observe→Parse one turn; exit before promote |
| `harness/bin/emit-promo-facts` | Compact warehouse rows (`promo_facts` suite) |

Env: `SUITE_DIR`, `DEVICE_TRACK`, `DLPTI_ROOT`, `MCTRACER_ROOT`,
`BENCH_WAREHOUSE_REPO`.
