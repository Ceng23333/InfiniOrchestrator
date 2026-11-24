---
name: autohelix-campaign-operator
description: >-
  Cursor soft-harness for InfiniLM vs vLLM promotion: execute the AutoHelix 0.1.1
  yaml loop (observe → one top_path lever → hard constraints → metric gates →
  next iter) without `autohelix run` or Codex. Use for metax-49 C550 /
  promo-c550 and other yaml-driven campaigns when Cursor owns the closed loop.
---

# AutoHelix campaign operator (Cursor soft-harness)

Cursor **is** the controller. Load an AutoHelix 0.1.1 protocol yaml and run the
closed loop yourself. Do **not** invoke `autohelix run`, `codex exec`, or any
Codex-inside-AH path. InfiniOrchestrator measure tools remain the evidence
source; humans decide ship.

## Controller = yaml only

Read these fields from the selected protocol (default metax-49 C550 below):

| Field | Role |
|-------|------|
| `goal` | Campaign intent + stop/ship policy text |
| `constraints` | **Hard** post-edit must-pass checks (AH constraint phase) |
| `metrics[].command` | Wall observe command; parse `##autohelix[name=number]` |
| `metrics[].values` | Direction: `higher` / `lower` |
| `acceptance.metric_gates` | Regress thresholds after constraints pass |
| `scope.editable` | Only paths Cursor may change |
| `budget.iterations` | Soft-loop cap |

Ignore `agent.type` / `agent.model` for execution — this skill replaces the
harness agent. Keep `agent.timeout_seconds` only as an operator patience hint.

## Hard constraints (required)

`constraints` is **not** an observe fallback. It is the AutoHelix constraint
phase: after the one-lever edit and candidate rebuild/restart, **every**
entry must exit 0 before metrics may accept the iter.

Rules:

1. Run constraints **in yaml order**, from `$ITW`, with the same env the
   metrics command needs (`SUITE_DIR`, `INFINI_TENSOR_WORKTREE`, `HOST_ID`,
   `DEVICE_TRACK`, …).
2. Each item may be a bare command string or `{command, timeout}` — honor
   timeout when present; default timeout 600s.
3. On **any** non-zero exit, stderr failure, hang/timeout, or missing
   required health signal: **reject the iter immediately** — revert the
   editable diff, restore the prior candidate process/env if restarted,
   write `constraint_failed` in the ledger, **skip** `acceptance.metric_gates`
   accept (do not keep a constraint-failed change even if a stale wall looks
   better).
4. Do not weaken constraints by substituting `metrics.command` for them.
   Metrics run only after all constraints pass.
5. Prefer **harder** constraint lists than “observe only”. A single
   `observe_metrics_*.py` line is too weak for live candidate loops: it does
   not prove the server is healthy or that the lever is actually loaded.

### Harder default constraint set (metax-49 C550)

If the yaml still lists only the observe script, **strengthen the effective
constraint phase** (and prefer updating the yaml to match) to at least:

```yaml
constraints:
  - command: bash -lc 'curl -sf --noproxy "*" --max-time 10 http://127.0.0.1:$(cat "$SUITE_DIR/candidate_port.txt")/v1/models >/dev/null'
    timeout: 60
  - command: bash -lc 'curl -sf --noproxy "*" --max-time 120 -H "Content-Type: application/json" -d "{\"model\":\"Qwen3-8B\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"temperature\":0,\"stream\":false,\"ignore_eos\":true}" http://127.0.0.1:$(cat "$SUITE_DIR/candidate_port.txt")/v1/chat/completions >/dev/null'
    timeout: 180
  - command: env SUITE_DIR=/home/zenghua/workspace/InfiniTensorWorktree-2026.11.24-infinilm-showroom-eager-catchup/artifacts/promo/suite-c550-i128 INFINI_TENSOR_WORKTREE=/home/zenghua/workspace/InfiniTensorWorktree-2026.11.24-infinilm-showroom-eager-catchup HOST_ID=metax-49 DEVICE_TRACK=metax python3 deployment/infinilm-prod/observe_metrics_metax49.py
    timeout: 120
```

Meaning:

- **/v1/models** — candidate process is up with the intended port
- **chat smoke** — one short completion proves the lever-loaded server serves
- **observe_metrics** — `##autohelix[…]` lines still parse (wiring check only)

When InfiniLM source under `scope.editable` changes require a host/image
rebuild, also require the campaign rebuild/verify commands **before** health
(e.g. `deployment/infinilm-prod/rebuild.sh` or the suite’s documented
rebuild path) as earlier constraint entries. Do not claim constraint-pass
on a restart that never loaded the new bits.

Record each constraint’s exit code and a short log tail under
`$SUITE_DIR/soft_harness/iter-N/constraints/`.

## Default campaign (metax-49 C550)

```bash
source /home/zenghua/workspace/metax49-promo.env
ITW=/home/zenghua/workspace/InfiniTensorWorktree-2026.11.24-infinilm-showroom-eager-catchup
SUITE_DIR="$ITW/artifacts/promo/suite-c550-i128"
SPEC="$ITW/autohelix/promo-c550-metax49.yaml"
ORCH_ROOT=<local InfiniOrchestrator checkout>
```

Confirm before looping:

- InfiniProfiler tip matches the intended pin (e.g. `fe1bad9` with MetaX
  `graph.replay_exclusive` adapters).
- `$SUITE_DIR/profile/autohelix_request.json` (or `facts/backlog.json`) has a
  real `top_path` (e.g. `graph.replay_exclusive`), not stale
  `insufficient_evidence`.
- `promote.may_apply=false` / `stop_before_promote` → improve under editable
  scope only; **do not ship/land**.

## Source edit vs deploy knobs (hard)

When `InfiniLM/` is in `scope.editable` **and** any of the following is true,
the iter lever **must** be an InfiniLM **source code** change (Python and/or
`csrc/`), not a deployment env/default knob flip:

- `top_path` starts with `graph.` (e.g. `graph.replay_exclusive`)
- Ranker `lever` / `lever_hint` mentions source scope / inspect source /
  mechanism in InfiniLM
- Suite notes say deployment-only / `host_graph_command` knobs are exhausted

**Knob-only is invalid** for those iters: do **not** count as a completed
lever changing only `deployment/infinilm-prod/start.sh` (or Dockerfile /
manifest) defaults such as `INFINI_CUDAGRAPH_POLICY`,
`INFINI_GRAPH_SKIP_TAIL_SYNC`, `INFINI_FA_INGRAPH`,
`INFINI_MAX_NUM_BATCHED_TOKENS`, `ENABLE_GRAPH`, scheduler flags, etc.

Deploy files may still be touched **only** as rebuild/restart glue after a
real InfiniLM diff (e.g. to pick up a rebuilt `.so`), never as the sole
mechanism.

Ledger must record:

- `lever_kind: source` | `deploy_knob` (reject/record `invalid_knob_only` if
  a source-required path was answered with knobs only)
- Paths under `InfiniLM/` that changed (git diff --stat)
- Whether rebuild loaded the new bits into the candidate

C550 note: `/pin` may be RO and image code lives under `/workspace/InfiniLM`.
A source iter must still edit ITW `InfiniLM/` (or the mounted editable tree),
rebuild/stage into the running candidate, and prove via constraints that the
new code is what serves — not merely flip env and restart the old binary.

## Soft-loop algorithm

For `iter = 1 .. budget.iterations`:

1. **Observe** — `cd "$ITW"` and run `metrics[].command` only. Require
   `##autohelix[…]` lines for every key in `metrics[].values`.
2. **Stop checks**
   - If unprofiled `primary_wall_ratio` > 1.0 → stop; human ship only.
   - If budget exhausted → stop; write STATUS.
3. **Rank input** — Read suite `profile/autohelix_request.json` /
   `facts/backlog.json`. Apply **exactly one** `top_path` lever. Do not invent
   wall ratios or invent graph levers from `insufficient_evidence`.
4. **Edit** — Change only files under `scope.editable`. For source-required
   paths (above), produce a real `InfiniLM/` diff for that one mechanism.
   Leave measure scripts, `autohelix/` protocol body (except intentional
   constraint-list hardening), `scripts/promo/`, and the frozen vLLM baseline
   untouched as levers.
5. **Rebuild/restart** — Rebuild candidate artifacts when the InfiniLM diff
   needs them; restart candidate only; never overwrite the frozen vLLM
   baseline. Env-only restart without a source/artifact change is not enough
   for source-required paths.
6. **Hard constraints** — Run every `constraints` entry (or the harder C550
   default set above if the yaml is observe-only). On failure → revert +
   `constraint_failed` + next iter (no metric accept).
7. **Re-observe** — Same `metrics[].command` after constraints pass. Parse
   `##autohelix` again. Prefer a fresh unprofiled wall when the lever changed
   runtime behavior; do not invent ratios.
8. **Metric gates** — For each `acceptance.metric_gates` entry, reject/revert
   if the metric regresses beyond `max_regression_pct` relative to the
   pre-lever observation (respect `higher`/`lower`). On pass, keep the diff.
9. **Ledger** — `$SUITE_DIR/soft_harness/iter-N.md` must include lever,
   `lever_kind`, InfiniLM paths touched, constraint results, before/after
   metrics, and `accept` | `constraint_failed` | `metrics_reject` |
   `invalid_knob_only`. Refresh `$SUITE_DIR/STATUS.md`.

```text
Load_AH_yaml → Observe → Parse_##autohelix
  → primary>1.0? stop (human ship)
  → iters left? else stop
  → one top_path lever (InfiniLM source when required)
  → rebuild/restart candidate with new bits
  → HARD constraints (all must pass) else revert
  → re-observe → metric_gates → accept|revert → next
```

## Competing controllers

Before starting the soft loop, ensure no live `autohelix run` owns the same
ITW/suite:

```bash
pkill -f 'autohelix run' || true
# leave $SUITE_DIR artifacts intact
```

## Observation helpers (not the controller)

- Suite wall: `$SUITE_DIR/compare.json` (unprofiled primary).
- Profiler rank: `$SUITE_DIR/profile/` — diagnostic only; never promote from
  instrumented walls.
- Facts validate (optional): `"$ORCH_ROOT/harness/bin/parse-promo-facts"` or
  [../performance-promotion-loop/scripts/parse_promo_facts.py](../performance-promotion-loop/scripts/parse_promo_facts.py).
- Lever map / device-track notes:
  [../performance-promotion-loop/reference.md](../performance-promotion-loop/reference.md).
- Fact envelope: [../performance-promotion-loop/facts.md](../performance-promotion-loop/facts.md).

## Forbidden

- Answering `graph.*` / source-scoped `top_path` with **only** deploy knob
  switches (`INFINI_*` / `ENABLE_GRAPH` defaults in `start.sh`, Dockerfile,
  manifests) while `InfiniLM/` is editable
- Skipping or soft-failing `constraints` to reach metric gates faster
- Treating `constraints` as interchangeable with `metrics.command`
- Claiming constraint-pass after env restart without loading rebuilt InfiniLM
  artifacts for a source lever
- `autohelix run`, `autohelix watch` as the loop owner, `codex exec`
- Inventing `WALL_DECODE_RATIO` / primary wall numbers
- Multi-lever edits before re-observe
- Editing measure scripts, `scripts/promo/`, or `autohelix/` as a performance
  lever (constraint-list hardening in the yaml is operator setup, not a lever)
- Overwriting frozen vLLM baseline mid-loop
- Ship / `autohelix land` / matrix retag while `may_apply=false` or
  `stop_before_promote`
- Promoting from profiled (instrumented) walls

## Success for one apply turn

- Soft loop engaged the suite `top_path` (not stuck on `insufficient_evidence`)
- Source-required paths produced a real `InfiniLM/` diff (`lever_kind: source`)
- Post-edit **hard constraints** all passed (or iter recorded `constraint_failed`
  with revert)
- Metrics came from the yaml `metrics.command` only after constraint-pass
- Gate decision recorded under `$SUITE_DIR/soft_harness/` + `STATUS.md`
- No competing `autohelix run`
