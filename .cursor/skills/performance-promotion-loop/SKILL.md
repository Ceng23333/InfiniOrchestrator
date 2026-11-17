---
name: performance-promotion-loop
description: >-
  Runs InfiniLM vs vLLM performance promotion loops. Use when observing/profiling
  InfiniLM against a vLLM baseline (AIPerf, DLPTI, mcTracer), ranking promotion
  paths, emitting suite promo-facts-1, or deciding whether to tag an ITW pin /
  update an InfiniOrchestrator case after a surpass gate. Observe→Parse is a
  deterministic SOP; Promote is AI-led.
---

# Performance promotion loop

Closed loop for InfiniLM performance work integrated with InfiniOrchestrator
(harness + playground cases) and InfiniTensorWorktree (code/pin).

**Facts** (`promo-facts-1`) are the durable product of each Observe→Parse turn.
**Promote** (one lever + rebuild) is **AI-led** and outside harness SOP scripts.
HTML review / Canvas visualization is **out of current scope** (future consumer
of the same envelope).

**Normative design:**
[`docs/design/performance-promotion-e2e.md`](../../../docs/design/performance-promotion-e2e.md)

**Pattern (every turn):**

1. **Observe** — tools only (client wall + matched profiler when behind)
2. **Parse → facts** — host-aware compare → ranked backlog → envelope facts
3. **Stop for AI** — SOP / harness exits; do not auto-apply levers
4. **Promote / rebuild** — AI applies **one** top lever, rebuilds candidate, re-observes

Do not skip observe. Do not ship matrix/ITW/IO case until the **surpass gate**
passes on an **unprofiled primary** wall metric.

## When to use

- InfiniLM trails vLLM on decode tok/s, TTFT, or AIPerf `PROFILE_REGRESS`
- User asks for profile / promotion loop or fact emit/validate
- Ranking next lever after fused-kernel or CUDA-graph work
- Shipping: refresh matrix, tag ITW pin, update playground case worktree

## Roles (keep separated)

| Role | Owns | Does not |
|------|------|----------|
| **InfiniOrchestrator** | Client observe, gates, cases, suite facts, harness SOP | InfiniLM kernel source; auto-promote |
| **InfiniTensorWorktree** | Lever code/env, rebuild image/worktree, ITW release tag | AIPerf dual recipe |
| **Host profiler kit** | Matched capture + summarize/compare/promote (DLPTI on Denglin QY; mcTracer on MetaX QY/showroom) | Shipping IO cases alone |

Client wall is the **KPI**. Profiler compare ranks **where** to spend the next
rebuild — it does not replace wall ratio.

## Fact families (index)

Converged format: [facts.md](facts.md) (`schema_version: promo-facts-1`).
Vendor DLPTI/mcTracer/AIPerf JSON is normalized **into** this envelope — not
used raw as the warehouse contract. Validate with
[scripts/parse_promo_facts.py](scripts/parse_promo_facts.py) or
`harness/bin/parse-promo-facts`.

| Family | Purpose |
|--------|---------|
| `CampaignFact` | host, `device_track`, case/hw identity, pins, optional `engine` |
| `IterFact` | iter index, profiled?, `walls[]` (+ legacy `wall`), lever applied |
| `WallFact` | metric + unprofiled ratio + gate; exactly one `primary` in `walls[]` |
| `HostSignalFact` | optional diagnostic host ratios |
| `CuBucketFact` | material CU buckets |
| `BacklogFact` | `top_path`, ranked `path_id` |
| `ShipFact` | surpass + matrix/pin/case actions |

Multi-campaign payload: `{ "schema_version": "promo-facts-1", "campaigns": [...] }`.

## Observe→Parse SOP (deterministic)

Harness-scriptable; do not improvise gates or invent ratios.

```
Turn N (SOP):
- [ ] Observe wall (vLLM baseline frozen first, then InfiniLM candidate)
- [ ] Write $SUITE_DIR/compare.json; record multi-metric walls (tok/s + TTFT + success_rate when AIPerf)
- [ ] If behind / any PROFILE_REGRESS → Observe matched profiler (same prompt/window)
      · denglin_qy → DLPTI_ROOT
      · metax_qy → MCTRACER_ROOT
      · mars → wall-only (skip profiler until kit exists)
- [ ] Parse → namespaced profile/<run_id>/compare.json + promotion_backlog
- [ ] Emit/update $SUITE_DIR/facts/ (promo-facts-1; never invent WALL_DECODE_RATIO)
- [ ] STOP — print backlog; leave Promote to AI
```

Harness bins: `parse-promo-facts`, `rank-promotion`, `run-promotion-loop-step`
(exits before promote), `emit-promo-facts`.

## Promote / rebuild (AI-led; not SOP)

1. Apply **only** `top_path` (or explicit user override). One lever per turn.
2. Change lives in ITW (env/policy/code) or case env — not AIPerf profiles.
3. Rebuild/restart **candidate**; keep vLLM frozen.
4. Re-observe unprofiled wall; update facts.
5. Re-rank if still behind (do not assume prior `top_path`).

**Surpass / ship:** unprofiled **primary** KPI **exceeds** frozen vLLM
(ratio &gt; 1.0). Then matrix + ITW tag + IO case. If improved but not surpass →
`FINDINGS_surpass_nogo.md`; do not retag.

## Observe (condensed)

**Wall (always):** Prefer `harness/bin/run-aiperf-dual` when OpenAI endpoints are
live. Freeze vLLM → `baseline/vllm/`; InfiniLM → `candidate/infinilm/`; gate via
`compare.json` (`PASS` | `PROFILE_REGRESS`). Defaults: success_rate ≥ 0.99;
tok/s ratio ≥ 0.50 (**regress detect**, not ship); TTFT p95 ratio ≤ 1.25.
Normalize into `walls[]` with tok/s **primary**. Unprofiled harness A/B is
equally valid — record `WALL_DECODE_RATIO = infinilm / vllm` per metric.

**Profiler (when behind):** Matched window on both backends.

| `device_track` | Tool | Host signals |
|----------------|------|--------------|
| `denglin_qy` | DLPTI | DRIVER/RUNTIME/COMMAND + CU gap + buckets |
| `metax_qy` | mcTracer | api_*/inter_kernel_gap + post-load GPU |
| `mars` | none until kit | wall-only |

Never rank from a single-backend trace. Never mix prompt shapes in one compare.

## Parse → facts (condensed)

1. Summarize traces (CU buckets + **host** overhead) when profiler ran.
2. Write profiler `profile/<run_id>/compare.json` (do not overwrite wall compare).
3. Rank → `promotion_backlog.json` (`harness/bin/rank-promotion`).
4. Require unprofiled primary `WALL_DECODE_RATIO` (do not invent).
5. Normalize into envelope under `$SUITE_DIR/facts/` per [facts.md](facts.md).

**Host-first:** fire `host_graph_command` when CU ≤ vLLM **and** primary wall &lt; 0.9
**and** (DRIVER/RUNTIME or api count ≥ 2× **or** COMMAND/api_ms ≥ 2× **or**
gap ≥ 1.5×). Else rank material CU buckets via the lever map in
[reference.md](reference.md).

## Anti-patterns

- Promoting from profiled (instrumented) wall numbers
- Changing multiple levers before re-observe
- Overwriting vLLM baseline mid-loop
- Inventing `WALL_DECODE_RATIO` or reviewing prose FINDINGS when JSON facts exist
- Conflating AIPerf floor (0.50) with surpass (1.0)
- Auto-promote inside harness SOP
- Treating `enable_graph=true` as guaranteed per-step CG replay
- Shipping EM-gated levers without an explicit quality gate
- Killing unrelated GPU jobs

## Artifact layout

```text
$SUITE_DIR/
  baseline/vllm/summary.json
  candidate/infinilm/summary.json
  compare.json                      # wall gate (AIPerf / harness / evalscope)
  facts/
    campaign.json
    iters.jsonl                     # or facts/iterN.json
  profile/<run_id>/
    compare.json                    # profiler compare (namespaced)
    promotion_backlog.json
    FINDINGS_iterationN.md
  FINDINGS_surpass_nogo.md          # if ship blocked
```

## References

- Design doc: [`docs/design/performance-promotion-e2e.md`](../../../docs/design/performance-promotion-e2e.md)
- Fact envelope + host maps: [facts.md](facts.md)
- Levers, gates, host tooling: [reference.md](reference.md)
- HTML review (future): [review.md](review.md)
- AIPerf adapter: `harness/adapters/aiperf/README.md`
- Case validate: `harness/bin/validate-case`
- Worktree env: `scripts/worktree_env.sh`
