---
name: performance-promotion-loop
description: >-
  Runs InfiniLM vs vLLM performance promotion loops: observe with harness/profiler
  tools, parse/analyze into a ranked backlog, then promote one lever and rebuild.
  Use when profiling InfiniLM against a vLLM baseline, ranking promotion paths
  (host/graph/COMMAND, RoPE/KV, fusion), running AIPerf dual gates, DLPTI or
  mcTracer matched captures, or deciding whether to tag an ITW pin / update an
  InfiniOrchestrator case after a surpass gate.
---

# Performance promotion loop

Closed loop for InfiniLM performance work integrated with InfiniOrchestrator
(harness + playground cases) and InfiniTensorWorktree (code/pin).

**Pattern (every turn):**

1. **Observe** — tools only (client wall + matched profiler)
2. **Parse / analyze** — host-aware compare → ranked `promotion_backlog`
3. **Promote / rebuild** — apply **one** top lever, rebuild serving pin, re-observe

Do not skip observe. Do not promote matrix/ITW/IO case until the **surpass gate**
passes on an **unprofiled** wall metric.

## When to use

- InfiniLM trails vLLM on decode tok/s, TTFT, or AIPerf `PROFILE_REGRESS`
- User asks for profile loop / promotion loop / DLPTI / mcTracer / host-graph
- Ranking next lever after fused-kernel or CUDA-graph work
- Shipping: refresh `GLOBAL_MATRIX`, tag ITW pin, update playground case worktree

## Roles (keep separated)

| Role | Owns | Does not |
|------|------|----------|
| **InfiniOrchestrator** | Client observe (`harness/adapters/aiperf`, bench runners), gates, playground cases, FINDINGS under suite dirs | InfiniLM kernel source |
| **InfiniTensorWorktree** | Lever code/env (`enable_graph`, `INFINI_CUDAGRAPH_POLICY`, QY blocks), rebuild image/worktree, ITW release tag | AIPerf dual recipe |
| **Host profiler kit** | Matched capture + summarize/compare/promote (DLPTI on Denglin/c610; mcTracer on MetaX/showroom) | Shipping IO cases alone |

Client wall (AIPerf / harness A/B) is the **KPI**. Profiler compare ranks **where**
to spend the next rebuild — it does not replace wall ratio.

## Loop checklist

Copy and tick each turn:

```
Turn N:
- [ ] Observe wall (vLLM baseline frozen first, then InfiniLM candidate)
- [ ] If behind / PROFILE_REGRESS → Observe matched profiler (same prompt/window)
- [ ] Parse → compare.json + promotion_backlog.json (host-first rules)
- [ ] Pick top_path only; write FINDINGS_iterationN.md
- [ ] Promote one lever in ITW / env; rebuild candidate
- [ ] Re-observe wall (unprofiled); update WALL_DECODE_RATIO
- [ ] Surpass? yes → ship (matrix/pin/case). no → next turn or NO-GO
```

## Phase 1 — Observe (tools)

### 1a. Client wall (always)

Prefer InfiniOrchestrator AIPerf dual when OpenAI endpoints are live:

```bash
harness/bin/run-aiperf-dual \
  --base-url-vllm "$BASE_URL_VLLM" \
  --base-url-infinilm "$BASE_URL_INFINILM" \
  --profile harness/adapters/aiperf/profiles/<profile>.yaml \
  --model "$MODEL" \
  --suite-dir "$SUITE_DIR"
```

Contract:

- **vLLM first** → `baseline/vllm/` (freeze; do not overwrite mid-campaign)
- **InfiniLM next** → `candidate/infinilm/`
- Compare → `compare.json` (`PASS` or `PROFILE_REGRESS`)
- Default gates: success_rate ≥ 0.99; tok/s ratio ≥ 0.50; TTFT p95 ratio ≤ 1.25

Adapter is **run-only**: it does not start GPUs/containers. Bring-up is host/case
ops. Use a fresh suite dir per campaign.

Unprofiled harness A/B (decode tok/s) is equally valid for Layer-A / fixed-IO
cells; record `WALL_DECODE_RATIO = infinilm_decode / vllm_decode` explicitly.

### 1b. Matched profiler (when behind)

Same workload window on both backends. Prefer reuse of frozen vLLM trace when
only InfiniLM changed.

| Host / vendor | Observe tool | Notes |
|---------------|--------------|-------|
| Denglin / c610 | DLPTI matched fullcell or reduced | `tools.dlpti`; host DRIVER/RUNTIME/COMMAND + CU buckets |
| MetaX / showroom | mcTracer dual capture | `perf_mccl_loop` profile tools; parse → summary |

Never rank promotions from a single-backend trace. Never mix different prompt
shapes between A and B in one compare.

## Phase 2 — Parse and analyze

1. Summarize each trace (device CU buckets + **host** overhead).
2. Compare InfiniLM over vLLM → `compare.json` / `compare.txt`.
3. Run promote ranker → `promotion_backlog.json` + `PROMOTION_BACKLOG.md`.
4. Require `WALL_DECODE_RATIO` from the latest **unprofiled** A/B (do not invent).

**Host-first rule** (priority 1): fire `host_graph_command` when

- CU us/flash ≤ vLLM, **and**
- wall decode ratio < 0.9, **and**
- at least one of: DRIVER/RUNTIME count ≥ 2×, COMMAND us/flash ≥ 2×, CU-gap ≥ 1.5×

Else rank material CU buckets by us/flash ratio (rope, kv_cache_reshape,
residual_add_rmsnorm, …) via the static lever map.

Write `FINDINGS_iterationN.md` in the suite/out dir: wall numbers, top_path,
signals, chosen lever, keep/no-go for each A/B arm.

## Phase 3 — Promote and rebuild

1. Apply **only** `top_path` (or explicit user override). One lever per turn.
2. Change lives in InfiniTensorWorktree (env default, policy, or code) or case
   env passthrough — not in AIPerf profiles.
3. Rebuild / restart **candidate** serving pin. Keep vLLM baseline frozen.
4. Re-run Phase 1a unprofiled. Update `WALL_DECODE_RATIO`.
5. Re-run Phase 1b+2 if still behind (re-rank; do not assume prior top_path).

### Surpass / ship gate

Ship only when unprofiled KPI **exceeds** the frozen vLLM baseline for the
agreed cell (e.g. decode tok/s > vLLM on Layer-A TP1).

Then:

1. Refresh matrix / campaign record for that cell
2. Tag ITW pin (`InfiniTensorWorktree` release scripts; IO `pin_worktree.sh` is a redirect)
3. Point InfiniOrchestrator playground case / image at the new pin

If improved but not surpass → document `FINDINGS_surpass_nogo.md`; **do not**
retag or rewrite the IO case. Leave next lever from the latest backlog.

## Anti-patterns

- Promoting from profiled (instrumented) wall numbers
- Changing multiple levers before re-observe
- Overwriting vLLM baseline mid-loop
- Treating `enable_graph=true` as “full CG every step” (compiler on ≠ always graph hit; sampling/D2H often outside graph)
- Shipping EM-gated levers (e.g. full-prefill CG) without an explicit quality gate
- Killing unrelated GPU jobs; prefer a free device / non-destructive harness path

## Artifact layout

```text
$SUITE_DIR/
  baseline/vllm/summary.json          # frozen wall
  candidate/infinilm/summary.json
  compare.json                        # AIPerf or harness gate
  profile/<run_id>/                   # DLPTI or mcTracer
    compare.json
    promotion_backlog.json
    PROMOTION_BACKLOG.md
    FINDINGS_iterationN.md
  FINDINGS_surpass_nogo.md            # if ship blocked
```

## References

- Tool contracts and lever map: [reference.md](reference.md)
- AIPerf adapter: `harness/adapters/aiperf/README.md`
- Case validate: `harness/bin/validate-case`
- Worktree env: `scripts/worktree_env.sh`
