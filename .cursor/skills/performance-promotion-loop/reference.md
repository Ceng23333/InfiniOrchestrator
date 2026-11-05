# Performance promotion loop — reference

Derived from Cursor agents:

- `926aff24-3b86-4c32-be1e-817ff73d73dd` @ c610 (DLPTI host-aware promote + graph A/B)
- `01229051-a881-4ebf-aef2-6d67110b7449` @ metax-showroom (AIPerf dual + mcTracer plan)

## Source patterns

### c610 / DLPTI (observe → promote tooling)

1. Extend summarize/compare with first-class **host** overhead (DRIVER/RUNTIME
   counts+ms, COMMAND, graph, idle/gap proxy).
2. `tools.dlpti promote` + `scripts/run_promotion_loop_step.sh`:
   matched capture → compare → `promotion_backlog.json`.
3. Iteration 0: re-parse fused fullcell → top path `host_graph_command`.
4. H1–H3 env/policy A/B with unprofiled harness; DLPTI re-rank after best arm.
5. Surpass no-go: decode improved but below vLLM → no matrix/pin/IO update.

Illustrative step script contract (lives in the host DLPTI kit, not necessarily
vendored into IO yet):

```bash
# MODE=fullcell|reduced|skip-capture
# WALL_DECODE_RATIO from latest unprofiled A/B (required)
# REUSE_VLLM_JSON=... optional InfiniLM-only recapture
MODE=reduced WALL_DECODE_RATIO=0.60 \
  bash scripts/run_promotion_loop_step.sh
```

`skip-capture` re-ranks an existing `OUT/` that already has traces or
`compare.json`.

### metax-showroom / AIPerf (client observe + gate)

1. InfiniOrchestrator `harness/adapters/aiperf`: run-only mooncake/agentic/long-prefix.
2. Dual recipe: vLLM baseline → InfiniLM candidate → `compare-aiperf` gates.
3. Live kickoff: install pinned `aiperf==0.13.0` in a Python ≥3.11 venv; preflight
   `/v1/models`; smoke then replay.
4. `PROFILE_REGRESS` (e.g. tok/s ratio ≪ floor, TTFT p95 ≫) → escalate to
   **mcTracer** dual profile against the same pin (`promoted-tool-fix-…` /
   `vYYYY.MM.DD-…`), not more AIPerf knobs.
5. Adapter does not own container lifecycle; restore host services after candidate runs.

## Lever map (initial)

Keep in sync with host `tools.dlpti.promote.LEVER_MAP` when vendoring.

| path_id | Evidence | Typical lever |
|---------|----------|---------------|
| `host_graph_command` | Host API/COMMAND/CU-gap ≫; CU ≤ vLLM; wall ≪ | `INFINI_CUDAGRAPH_POLICY` / F&P / skip-tail / host sync |
| `rope` | rope us/flash ≫ | `INFINI_QY_ROPE_SMALL_BLOCK` |
| `kv_cache_reshape` | kv bucket ≫ | `INFINI_QY_KV_SMALL_BLOCK` |
| `residual_add_rmsnorm` | residual ≫ | `INFINI_QY_FUSED_ADD_RMSNORM=1` (deprioritize if CU already ≤) |

Unmapped CU buckets still rank by ratio with lever text
`inspect bucket kernels; no static lever mapped yet`.

## Graph / CG facts agents must not confuse

- `enable_graph=true` enables the **compiler**, not guaranteed per-step CG replay.
- Hits depend on shape/batch capture; misses fall back to eager.
- Prefill FULL CG often needs an extra EM-gated flag (`INFINI_PREFILL_FULL_CG`);
  decode-heavy cells may not move much from that lever.
- Sampling + D2H + `syncStream` after forward are typically **outside** the graph
  and show up in COMMAND / host timeline even when CU ≤ vLLM.

## AIPerf gate fields

From `harness/adapters/aiperf/compare.py` (dual):

| Field | Default | Fail reason |
|-------|---------|-------------|
| `success_rate` | ≥ 0.99 | baseline or candidate flaky |
| tok/s ratio (candidate/baseline) | ≥ 0.50 | `PROFILE_REGRESS` throughput |
| TTFT p95 ratio | ≤ 1.25 | `PROFILE_REGRESS` latency |

Run-only single-leg runner (`run-aiperf`) also checks version pin, request
counts, and optional profile `gates.max_*_p95_ms`.

## Integration sketch in InfiniOrchestrator

Near-term (skill + existing bins):

- Observe wall: `harness/bin/run-aiperf` / `run-aiperf-dual` / `compare-aiperf`
- Cases: `playground/Standalone/*-{vllm,inf}--*` with documented pin
- FINDINGS: write under suite dir; link from campaign notes

Follow-on (optional harness work, not required to use the skill):

- Vendor or wrap host `promote` CLI as `harness/bin/rank-promotion` consuming
  profiler `compare.json` + `--wall-decode-ratio`
- Thin `harness/bin/run-promotion-loop-step` that shells to vendor capture scripts
  via env (`DLPTI_ROOT`, `MCTRACER_ROOT`) without baking vendor binaries into IO
- Warehouse emit of `promotion_backlog.json` beside AIPerf `summary.json`

## Decision table

| Wall vs vLLM | Profiler top_path | Action |
|--------------|-------------------|--------|
| ≥ 1.0 unprofiled | any | **Ship** (matrix + ITW tag + IO case) |
| Improved, still < 1.0 | same as last turn | New lever from re-rank; do not retune same dial blindly |
| Flat | `host_graph_command` | Host sync / COMMAND / sample D2H — not more F&P-only knobs |
| `PROFILE_REGRESS` only | none yet | Run matched profiler before code changes |
| Capture conflict on GPU | — | Non-destructive device / SKIP_STOP; never kill foreign jobs |

## Example turn (compressed)

```text
Observe: AIPerf dual → PROFILE_REGRESS tok_s_ratio=0.05
Observe: mcTracer/DLPTI matched → compare.json
Analyze: promote → top_path=host_graph_command (CU≤1, COMMAND≥2×, wall=0.60)
Promote: set full_and_piecewise + skip-tail; rebuild candidate image
Observe: unprofiled decode 6.2→8.7 tok/s (still < 14.4)
Analyze: re-rank; COMMAND still ~3× → stay on host_graph_command
Ship: NO-GO; FINDINGS_surpass_nogo.md
```
