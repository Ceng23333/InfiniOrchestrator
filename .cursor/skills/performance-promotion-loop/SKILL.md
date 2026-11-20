---
name: performance-promotion-loop
description: >-
  Runs InfiniLM vs vLLM performance promotion loops under AutoHelix. Use when
  observing/profiling InfiniLM against a vLLM baseline, ranking promotion paths,
  emitting suite promo-facts-1, or applying one top_path lever inside an
  AutoHelix iteration. Observe→Parse is deterministic (InfiniOrchestrator);
  iteration/accept/reject is AutoHelix; Codex applies one lever; surpass/ship is human.
---

# Performance promotion loop

Closed loop for InfiniLM performance work integrated with InfiniOrchestrator
(harness + playground cases), InfiniTensorWorktree (code/pin), and **AutoHelix**.

**Facts** (`promo-facts-1`) are the durable product of each Observe→Parse turn.
**Iteration / accept / reject / budget** is owned by **AutoHelix**.
**Codex** (this agent) applies **one** `top_path` lever per accepted iteration.
**Surpass / ship** is **human** after `scripts/promo/stop_surpass.py`.
Grafana publish is **deferred** — use `autohelix watch`.

**Normative design:** InfiniOrchestrator
`docs/design/performance-promotion-e2e.md`; ITW `autohelix/promo-unified-metax9.yaml`.

**Pattern (every turn):**

1. **Observe** — AutoHelix runs `scripts/promo/observe.py` → IO loop_step
2. **Parse → facts** — compare → ranked backlog → envelope facts
3. **AutoHelix gate** — constraints + metric gates decide accept/reject
4. **Promote / rebuild** — Codex applies **one** top lever under `deployment/infinilm-prod/` only

Do not skip observe. Do not invent `WALL_DECODE_RATIO`. Do not edit
`scripts/promo/` or `autohelix/`. Do not ship matrix/ITW/IO case until human
confirms surpass.

## When to use

- InfiniLM trails vLLM on decode tok/s, TTFT, or AIPerf `PROFILE_REGRESS`
- User asks for profile / promotion loop or fact emit/validate
- Ranking next lever after fused-kernel or CUDA-graph work
- Shipping: refresh matrix, tag ITW pin, update playground case worktree

## Roles (keep separated)

| Role | Owns | Does not |
|------|------|----------|
| **InfiniOrchestrator** | Client observe, gates, cases, suite facts, harness measure | InfiniLM kernel source; auto-promote; iteration budget |
| **AutoHelix** | Iteration / accept / reject / budget / watch UI | Applying levers; inventing ratios |
| **Codex (agent)** | One `top_path` lever under `deployment/infinilm-prod/` | Editing `scripts/promo/` / `autohelix/`; ship |
| **InfiniTensorWorktree** | Lever code/env, rebuild image/worktree, ITW release tag | AIPerf dual recipe |
| **Host profiler kit** | Matched capture + summarize/compare (DLPTI / mcTracer / hcTracer) | Shipping IO cases alone |

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
      · qy → DLPTI_ROOT
      · metax → MCTRACER_ROOT
      · mars → wall-only (skip profiler until kit exists)
- [ ] Parse → namespaced profile/<run_id>/compare.json + promotion_backlog
- [ ] Emit/update $SUITE_DIR/facts/ (promo-facts-1; never invent WALL_DECODE_RATIO)
- [ ] Return to AutoHelix (`controller: autohelix`); Codex applies one lever if accepted
```

Harness bins: `parse-promo-facts`, `rank-promotion`, `run-promotion-loop-step`
(measure backend), `emit-promo-facts`. ITW: `scripts/promo/observe.py`,
`gate_correctness.py`, `stop_surpass.py`.

## Promote / rebuild (Codex inside AutoHelix)

1. Read backlog (`artifacts/promo/suite/promotion_backlog.json` or profile run dir).
2. Apply **only** `top_path` (or explicit user override). One lever per turn.
3. Editable scope: **`deployment/infinilm-prod/` only** — not AIPerf profiles,
   not `scripts/promo/`, not `autohelix/`.
4. Rebuild/restart **candidate**; keep vLLM frozen.
5. Exit cleanly so AutoHelix re-observes; do not assume prior `top_path`.

**Surpass / ship:** human runs `python scripts/promo/stop_surpass.py` (exit 0
when primary wall ratio &gt; 1.0), then matrix + ITW tag + IO case. Agent does
**not** ship.

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
| `qy` | DLPTI | DRIVER/RUNTIME/COMMAND + CU gap + buckets |
| `metax` | mcTracer | api_*/inter_kernel_gap + post-load GPU |
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
