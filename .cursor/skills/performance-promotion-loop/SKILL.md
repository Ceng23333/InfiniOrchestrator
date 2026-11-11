---
name: performance-promotion-loop
description: >-
  Runs InfiniLM vs vLLM performance promotion loops and reviews iteration facts
  on a portable HTML page. Use when observing/profiling InfiniLM against a vLLM
  baseline (AIPerf, DLPTI, mcTracer), ranking promotion paths, emitting suite
  facts.json / review/index.html, reviewing multi-iter wall and host signals,
  or deciding whether to tag an ITW pin / update an InfiniOrchestrator case
  after a surpass gate.
---

# Performance promotion loop

Closed loop for InfiniLM performance work integrated with InfiniOrchestrator
(harness + playground cases) and InfiniTensorWorktree (code/pin).

**Facts** are the durable product of each turn. **HTML review**
(`$SUITE_DIR/review/index.html`) is the universal surface for inspecting those
facts across iterations — not Cursor Canvas.

**Pattern (every turn):**

1. **Observe** — tools only (client wall + matched profiler when behind)
2. **Parse → facts** — host-aware compare → ranked backlog → envelope facts
3. **Promote / rebuild** — apply **one** top lever, rebuild candidate, re-observe
4. **Review** — regenerate HTML review; launch or report the URL when validating

Do not skip observe. Do not ship matrix/ITW/IO case until the **surpass gate**
passes on an **unprofiled** wall metric.

## When to use

- InfiniLM trails vLLM on decode tok/s, TTFT, or AIPerf `PROFILE_REGRESS`
- User asks for profile / promotion loop, fact review, or HTML iter review
- Ranking next lever after fused-kernel or CUDA-graph work
- Shipping: refresh matrix, tag ITW pin, update playground case worktree

## Roles (keep separated)

| Role | Owns | Does not |
|------|------|----------|
| **InfiniOrchestrator** | Client observe, gates, cases, suite facts + HTML review | InfiniLM kernel source |
| **InfiniTensorWorktree** | Lever code/env, rebuild image/worktree, ITW release tag | AIPerf dual recipe |
| **Host profiler kit** | Matched capture + summarize/compare/promote (DLPTI on c610; mcTracer on MetaX/showroom) | Shipping IO cases alone |

Client wall is the **KPI**. Profiler compare ranks **where** to spend the next
rebuild — it does not replace wall ratio.

## Fact families (index)

Converged format: [facts.md](facts.md) (`schema_version: promo-facts-1`).
Vendor DLPTI/mcTracer/AIPerf JSON is normalized **into** this envelope — not
used raw as the review/warehouse contract. Validate with
[scripts/parse_promo_facts.py](scripts/parse_promo_facts.py).

| Family | Purpose |
|--------|---------|
| `CampaignFact` | host, cell, pins, worktree/ITW tags, agent ids |
| `IterFact` | iter index, profiled?, lever applied |
| `WallFact` | unprofiled KPI + gate |
| `HostSignalFact` | optional diagnostic host ratios (review UI may omit) |
| `CuBucketFact` | material CU buckets |
| `BacklogFact` | `top_path`, ranked `path_id` (path leftover pies) |
| `ShipFact` | surpass + matrix/pin/case actions |

Multi-campaign review payload: `{ "schema_version": "promo-facts-1", "campaigns": [...] }`.

## Loop checklist

```
Turn N:
- [ ] Observe wall (vLLM baseline frozen first, then InfiniLM candidate)
- [ ] If behind / PROFILE_REGRESS → Observe matched profiler (same prompt/window)
- [ ] Parse → namespaced compare + promotion_backlog (host-first rules)
- [ ] Emit/update $SUITE_DIR/facts/ (envelope; never invent WALL_DECODE_RATIO)
- [ ] Pick top_path only; write FINDINGS_iterationN.md
- [ ] Promote one lever in ITW / env; rebuild candidate
- [ ] Re-observe wall (unprofiled); update WALL_DECODE_RATIO
- [ ] Regenerate $SUITE_DIR/review/index.html (+ facts.json); launch/report URL if validating
- [ ] Surpass? yes → ship (matrix/pin/case). no → next turn or NO-GO
```

## Observe (condensed)

**Wall (always):** Prefer `harness/bin/run-aiperf-dual` when OpenAI endpoints are
live. Freeze vLLM → `baseline/vllm/`; InfiniLM → `candidate/infinilm/`; gate via
`compare.json` (`PASS` | `PROFILE_REGRESS`). Defaults: success_rate ≥ 0.99;
tok/s ratio ≥ 0.50 (**regress detect**, not ship); TTFT p95 ratio ≤ 1.25.
Unprofiled harness A/B is equally valid — record
`WALL_DECODE_RATIO = infinilm_decode / vllm_decode`.

**Profiler (when behind):** Matched window on both backends.

| Host | Tool | Host signals |
|------|------|--------------|
| Denglin / c610 | DLPTI | DRIVER/RUNTIME/COMMAND + CU gap + buckets |
| MetaX / showroom | mcTracer | api_*/inter_kernel_gap + post-load GPU |

Never rank from a single-backend trace. Never mix prompt shapes in one compare.

## Parse → facts (condensed)

1. Summarize traces (CU buckets + **host** overhead).
2. Write profiler `profile/<run_id>/compare.json` (do not overwrite wall compare).
3. Rank → `promotion_backlog.json`.
4. Require unprofiled `WALL_DECODE_RATIO` (do not invent).
5. Normalize into envelope under `$SUITE_DIR/facts/` per [facts.md](facts.md).

**Host-first:** fire `host_graph_command` when CU ≤ vLLM **and** wall &lt; 0.9
**and** (DRIVER/RUNTIME or api count ≥ 2× **or** COMMAND/api_ms ≥ 2× **or**
gap ≥ 1.5×). Else rank material CU buckets via the lever map in
[reference.md](reference.md).

## Promote / rebuild (condensed)

1. Apply **only** `top_path` (or explicit user override). One lever per turn.
2. Change lives in ITW (env/policy/code) or case env — not AIPerf profiles.
3. Rebuild/restart **candidate**; keep vLLM frozen.
4. Re-observe unprofiled wall; update facts + HTML review.
5. Re-rank if still behind (do not assume prior `top_path`).

**Surpass / ship:** unprofiled KPI **exceeds** frozen vLLM (ratio &gt; 1.0). Then
matrix + ITW tag + IO case. If improved but not surpass →
`FINDINGS_surpass_nogo.md`; do not retag.

## Review (HTML)

Canonical surface: `$SUITE_DIR/review/index.html` (vanilla HTML+JS; embed facts
for `file://`). Procedure and page sections: [review.md](review.md). Template:
[examples/review/index.html](examples/review/index.html). Dual-host e2e example:
[examples/e2e-dual-host/](examples/e2e-dual-host/).

When validating, launch a static server on `review/` (or open the file) and
report the URL. Do not treat Cursor Canvas / `/visualize` as the campaign record.

## Anti-patterns

- Promoting from profiled (instrumented) wall numbers
- Changing multiple levers before re-observe
- Overwriting vLLM baseline mid-loop
- Inventing `WALL_DECODE_RATIO` or reviewing prose FINDINGS when JSON facts exist
- Conflating AIPerf floor (0.50) with surpass (1.0)
- Cursor-only viz as the durable campaign record; skipping HTML regen after an iter
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
  review/
    index.html                      # universal HTML review
    facts.json                      # snapshot for HTTP reload
  FINDINGS_surpass_nogo.md          # if ship blocked
```

## References

- Fact envelope + host maps: [facts.md](facts.md)
- HTML review + launch: [review.md](review.md)
- Levers, gates, host tooling: [reference.md](reference.md)
- AIPerf adapter: `harness/adapters/aiperf/README.md`
- Case validate: `harness/bin/validate-case`
- Worktree env: `scripts/worktree_env.sh`
