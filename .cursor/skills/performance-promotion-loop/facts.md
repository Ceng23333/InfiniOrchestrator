# Converged promotion facts spec

**Status:** target format for InfiniOrchestrator promotion-loop facts  
(suite `facts/`, warehouse compact rows; HTML review is a future consumer).  
**Schema id:** `promo-facts`  
**Current version:** `promo-facts-1`  
**Encoding:** UTF-8 JSON (no BOM preferred; readers SHOULD tolerate BOM)

**Normative design doc:**
[`docs/design/performance-promotion-e2e.md`](../../../docs/design/performance-promotion-e2e.md)

This document is the **converged** contract. Vendor artifacts (DLPTI /
mcTracer / AIPerf / EvalScope) are **sources**; they must be normalized into
this envelope before warehouse emit. Do not treat vendor `compare.json` shapes
as interchangeable with this schema.

### Template parser (in skill)

Stdlib parser/validator for this spec:

[`scripts/parse_promo_facts.py`](scripts/parse_promo_facts.py)

```bash
python .cursor/skills/performance-promotion-loop/scripts/parse_promo_facts.py validate path/to/facts.json
python .cursor/skills/performance-promotion-loop/scripts/parse_promo_facts.py canonicalize path/to/facts.json
python .cursor/skills/performance-promotion-loop/scripts/parse_promo_facts.py summarize path/to/facts.json
python .cursor/skills/performance-promotion-loop/scripts/parse_promo_facts.py load-suite path/to/$SUITE_DIR/facts
# or: harness/bin/parse-promo-facts <cmd> <path>
```

Use it after emitting suite facts. Importable API: `parse_path`,
`parse_document`, `load_suite_facts`, `PromoFactsError`, `primary_wall`.

---

## 1. Document roots

Three interchangeable layouts; all share the same object types.

### 1.1 Multi-campaign document (e2e / warehouse batch)

```json
{
  "schema_version": "promo-facts-1",
  "generated_at": "2026-11-10T02:57:15Z",
  "note": "optional free text",
  "campaigns": [ /* CampaignDocument */ ]
}
```

| Field | Type | Req | Notes |
|-------|------|----------|-------|
| `schema_version` | string | required | Exactly `promo-facts-1` for this revision |
| `generated_at` | string (ISO-8601 UTC) | recommended | When the envelope was emitted |
| `note` | string | optional | Human provenance |
| `campaigns` | CampaignDocument[] | required | Length ≥ 1 |

### 1.2 Single-campaign suite layout

```text
$SUITE_DIR/facts/
  campaign.json     # CampaignFact (+ optional iters[] inline)
  iters.jsonl       # one IterFact per line  (preferred stream form)
  # OR iter<N>.json # one IterFact per file
```

### 1.3 CampaignDocument

`CampaignDocument` = `CampaignFact` fields **plus**:

| Field | Type | Req | Notes |
|-------|------|----------|-------|
| `iters` | IterFact[] | required in 1.1 | Ordered by promotion turn; `iter` values need not be contiguous |

---

## 2. Naming and types

| Rule | Spec |
|------|------|
| Keys | `snake_case` ASCII; no vendor-prefixed duplicate keys at this layer |
| Numbers | JSON number (IEEE-754); ratios are dimensionless floats |
| Nulls | Prefer **omit** optional fields over `null` (except explicit clears) |
| Booleans | JSON boolean |
| Strings | UTF-8; paths use host-native absolute or repo-relative form as recorded |
| Arrays | Ordered; empty array means “known empty”, omit means “not collected” |
| Extensibility | Unknown keys MUST be ignored by readers; writers MUST NOT rely on them for gates |

### 2.1 Shared enums

**`WallGate`**

| Value | Meaning |
|-------|---------|
| `PASS` | Wall gate floor passed (e.g. AIPerf dual floor) — **not** surpass |
| `PROFILE_REGRESS` | Behind floor / regress detect → escalate profiler |
| `SURPASS` | Unprofiled primary **exceeds** frozen baseline (ratio &gt; 1.0) |
| `NO_GO` | Improved or flat but not surpass; no ship |

**`WallSource`:** `aiperf` \| `harness` \| `evalscope`  
(producer only — not the metric name; `WallFact.metric` is a free-form string)

**`VendorProfiler`:** `dlpti` \| `mctracer` \| `aiperf` \| `none`

**`DeviceTrack`:** `denglin_qy` \| `metax_qy` \| `mars` \| `other`

**`HostSignalFamily`:** `driver` \| `runtime` \| `command` \| `api` \| `gap` \| `graph`

**`HostSignalMappedFrom`:** `dlpti` \| `mctracer`

**`ShipAction`:** `matrix` \| `itw_tag` \| `io_case` \| `none`  
(comma-join only in FINDINGS prose; in JSON use a single primary action —
**v1 uses one string**.)

---

## 3. Object specs

### 3.1 CampaignFact

Identity of one promotion campaign on one host/cell, including Standalone case
linkage.

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `campaign_id` | string | yes | Stable id, kebab-case recommended |
| `host` | string | yes | e.g. `c610`, `metax-showroom` |
| `device_track` | DeviceTrack | yes | SOP routing (`denglin_qy` / `metax_qy` / `mars` / `other`) |
| `vendor_profiler` | VendorProfiler | yes | Primary profiler kit (use `aiperf` / `none` if wall-only) |
| `hw_profile_id` | string | yes | From playground `case.toml` / hardware-profile |
| `hw_abbr` | string | recommended | e.g. `qy`, `x203` |
| `case_id_baseline` | string | recommended | Standalone folder id (vLLM) |
| `case_id_candidate` | string | yes | Standalone folder id (InfiniLM) |
| `be_abbr_baseline` | string | recommended | Usually `vllm` |
| `be_abbr_candidate` | string | yes | Usually `inf` |
| `cell` | string | yes | Human cell description (model / TP / workload) |
| `pin_baseline` | string | yes | Frozen baseline serving/matrix pin label |
| `pin_candidate` | string | yes | Candidate serving pin label |
| `worktree_baseline` | string | no | Baseline IO/ITW worktree path or name |
| `worktree_candidate` | string | no | Candidate worktree path or name |
| `itw_tag_baseline` | string | no | ITW tag if distinct from `pin_baseline` |
| `itw_tag_candidate` | string | no | ITW tag if distinct from `pin_candidate` |
| `engine` | EngineFact | no | Compact serving knobs; omit unknowns |
| `agent_ids` | string[] | no | Cursor/Codex agent ids that produced the campaign |
| `source_paths` | string[] | no | Compact provenance paths (compare/backlog/FINDINGS) |

**`EngineFact`** (optional; no invented values)

| Field | Type | Notes |
|-------|------|-------|
| `tp` | number | tensor parallel |
| `device` | string | e.g. `mars`, `metax`, `qy` |
| `graph_policy` | string | env/policy label if known |
| `batch_limit` | number | if known |
| `max_output_tokens` | number | if known |
| `extra` | object | free sparse knobs already recorded on case |

### 3.2 IterFact

One Observe→Parse turn (Promote is AI-led after facts emit).

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `iter` | number \| string | yes | Turn index or label (`0`, `2`, `"H2"` allowed as string) |
| `suite_dir` | string | no | Suite root if not implied by document location |
| `profile_run_id` | string | no | Profiler run id / OUT folder name |
| `lever_applied` | string | no | Lever taken **after** this observe (or env key); null/omit if observe-only |
| `profiled` | boolean | yes | Whether wall numbers in this iter came under profiler |
| `walls` | WallFact[] | recommended | All metrics from this observe; exactly one `primary: true` |
| `wall` | WallFact | no | **Legacy** mirror of the primary wall |
| `host_signals` | HostSignalFact[] | no | Optional diagnostic |
| `cu_buckets` | CuBucketFact[] | no | Material CU/path buckets |
| `backlog` | BacklogFact | no | Ranked promotion paths for this turn |
| `ship` | ShipFact | no | Surpass / ship decision at this turn |

**`walls` rules:** non-empty ⇒ exactly one `primary: true`. Escalate profiler if
**any** wall is `PROFILE_REGRESS`. Surpass uses **only** the primary wall
(unprofiled). If both `walls` and legacy `wall` are present, primary in `walls`
wins.

### 3.3 WallFact

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `metric` | string | yes | e.g. `decode_tok_s`, `output_token_throughput_per_sec`, `ttft_p95_ms`, `success_rate` |
| `baseline` | number | yes | Frozen baseline value |
| `candidate` | number | yes | Candidate value |
| `WALL_DECODE_RATIO` | number | yes | `candidate / baseline` from **unprofiled** A/B |
| `gate` | WallGate | yes | Decision for this wall snapshot |
| `source` | WallSource | yes | Client wall producer |
| `primary` | boolean | no | Ship / host-first KPI when true |

### 3.4 HostSignalFact (optional diagnostic)

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `family` | HostSignalFamily | yes | Normalized family |
| `baseline` | number | no | Absolute baseline when known |
| `candidate` | number | no | Absolute candidate when known |
| `ratio` | number | yes | InfiniLM / vLLM (or mapped proxy) |
| `mapped_from` | HostSignalMappedFrom | yes | Vendor mapping |

### 3.5 CuBucketFact

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `bucket` | string | yes | e.g. `rope`, `moe_fused`, `kv_cache_reshape` |
| `us_or_ms_per_norm` | number | no | Per-flash or campaign norm unit |
| `ratio` | number | yes | InfiniLM / vLLM |
| `material` | boolean | yes | Ranker “material” flag |

### 3.6 BacklogFact

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `top_path` | string | yes | Selected / top `path_id` |
| `host_first_fired` | boolean | yes | Host-first rule fired |
| `ranked` | RankedPath[] | yes | May be empty if unknown |
| `exhausted` | string[] | no | `path_id`s excluded as exhausted |

**RankedPath**

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `path_id` | string | yes | Lever path id (`host_graph_command`, `gemm`, …) |
| `rank` | number | no | 1-based rank |
| `score` | number | no | Vendor score when available (MetaX) |
| `priority_rule` | number \| string | no | Rule id when available (DLPTI) |
| `reasons` | string[] | no | Short evidence strings |
| `lever` | string | no | Human / env lever text |
| `exhausted` | boolean | no | Per-entry exhausted flag (optional; list also on parent) |

### 3.7 ShipFact

| Field | Type | Req | Description |
|-------|------|-----|-------------|
| `surpass` | boolean | yes | True only if unprofiled **primary** wall ratio &gt; 1.0 and ship allowed |
| `actions` | ShipAction | yes | Primary ship action taken or `none` |
| `findings_path` | string | no | Path to FINDINGS markdown |

---

## 4. Integrity invariants (normative)

1. **Primary ship KPI MUST come from unprofiled A/B.** If `profiled: true`,
   writers MUST NOT present that wall as the ship KPI unless a separate
   unprofiled primary is also recorded.
2. **Namespaced compares outside this envelope:**
   - wall gate file: `$SUITE_DIR/compare.json`
   - profiler compare: `$SUITE_DIR/profile/<run_id>/compare.json`  
   These are **inputs**, not substitutes for `promo-facts-1`.
3. **Host-first rule** (ranker, shared thresholds): fire `host_graph_command`
   when primary wall &lt; 0.9 **and** CU (or gpu post-load proxy) ≤ 1.0× **and**
   (count ≥ 2× **or** command/api_ms ≥ 2× **or** gap ≥ 1.5×).
4. **Surpass** ⇔ primary `WALL_DECODE_RATIO > 1.0` (unprofiled). AIPerf tok/s floor
   0.50 is `PROFILE_REGRESS` detect only.
5. **Escalate** on **any** `PROFILE_REGRESS` in `walls[]` (or legacy `wall`).
6. **No invented ratios.** Missing evidence ⇒ omit field / omit object.
7. **Compact provenance only** in `source_paths` (compare, backlog, FINDINGS).
   No raw traces in the facts tree.

---

## 5. Minimal valid example (multi-metric)

```json
{
  "schema_version": "promo-facts-1",
  "generated_at": "2026-11-17T00:00:00Z",
  "campaigns": [
    {
      "campaign_id": "example-tp1-decode",
      "host": "c610",
      "device_track": "denglin_qy",
      "vendor_profiler": "dlpti",
      "hw_profile_id": "denglin-qy-ks38",
      "hw_abbr": "qy",
      "case_id_baseline": "minicpm5-2b-qy-vllm-perf",
      "case_id_candidate": "minicpm5-2b-qy-inf-perf",
      "be_abbr_baseline": "vllm",
      "be_abbr_candidate": "inf",
      "cell": "Model TP1 decode",
      "pin_baseline": "vllm-frozen",
      "pin_candidate": "v2026.11.03-example",
      "worktree_candidate": "case-example-inf-perf",
      "itw_tag_candidate": "v2026.11.03-example",
      "engine": { "tp": 1, "device": "qy" },
      "agent_ids": ["00000000-0000-0000-0000-000000000000"],
      "source_paths": ["/path/to/promotion_backlog.json"],
      "iters": [
        {
          "iter": 0,
          "profiled": false,
          "lever_applied": null,
          "walls": [
            {
              "metric": "decode_tok_s",
              "baseline": 14.4,
              "candidate": 8.67,
              "WALL_DECODE_RATIO": 0.602,
              "gate": "NO_GO",
              "source": "harness",
              "primary": true
            },
            {
              "metric": "ttft_p95_ms",
              "baseline": 40.0,
              "candidate": 42.0,
              "WALL_DECODE_RATIO": 1.05,
              "gate": "PASS",
              "source": "harness",
              "primary": false
            },
            {
              "metric": "success_rate",
              "baseline": 1.0,
              "candidate": 1.0,
              "WALL_DECODE_RATIO": 1.0,
              "gate": "PASS",
              "source": "harness",
              "primary": false
            }
          ],
          "wall": {
            "metric": "decode_tok_s",
            "baseline": 14.4,
            "candidate": 8.67,
            "WALL_DECODE_RATIO": 0.602,
            "gate": "NO_GO",
            "source": "harness",
            "primary": true
          },
          "backlog": {
            "top_path": "host_graph_command",
            "host_first_fired": true,
            "ranked": [
              {
                "rank": 1,
                "path_id": "host_graph_command",
                "priority_rule": 1,
                "reasons": ["COMMAND us/flash ≥ 2×"],
                "lever": "INFINI_CUDAGRAPH_POLICY"
              }
            ],
            "exhausted": []
          },
          "ship": {
            "surpass": false,
            "actions": "none",
            "findings_path": "/path/to/FINDINGS_surpass_nogo.md"
          }
        }
      ]
    }
  ]
}
```

---

## 6. Versioning

| Change type | Rule |
|-------------|------|
| Additive optional fields | Stay on `promo-facts-1` if old readers can ignore them |
| Rename / remove / semantic break | Bump to `promo-facts-2` and keep a mapper |
| Enum extension | Additive OK on v1 if unknown values are ignored safely |

Warehouse rows store identity columns (`schema_version`, `campaign_id`, `iter`,
case/hw fields, primary wall summary) plus `promo_payload` JSON — see design doc
§5.

---

## 7. Vendor maps (informative)

Normalize **into** §3; do not leak vendor key names into the envelope.

### 7.1 Denglin QY / DLPTI (`device_track: denglin_qy`)

| Envelope | DLPTI source |
|----------|--------------|
| HostSignal `driver`/`runtime`/`command`/`gap`/`graph` | `host.*` totals / per-flash / timeline / over ratios |
| `CuBucketFact` | `categories[]` |
| `BacklogFact` | `promotion_backlog.json` |
| `WallFact` / `walls[]` | suite/harness `WALL_DECODE_RATIO` (+ aux metrics) |

### 7.2 MetaX QY / showroom / mcTracer (`device_track: metax_qy`)

| Envelope | Source |
|----------|--------|
| HostSignal `api`/`gap` (+ CU proxy) | `api_*_ratio`, `inter_kernel_gap_*`, `gpu_kernel_ms_post_load_ratio` |
| `BacklogFact.ranked[].score` | MetaX promote scores |
| Wall AIPerf | `aiperf-m1` / dual → `walls[]` (`PROFILE_REGRESS` / `PASS`) |
| Wall peak | EvalScope `turnN` / suite compare |

### 7.3 Mars (`device_track: mars`)

Wall-only until a matched profiler kit exists. `vendor_profiler` SHOULD be
`aiperf` or `none` with empty `backlog` / `host_signals` when no kit ran.

### 7.4 AIPerf dual (any track)

Emit multi-metric `walls[]` (tok/s primary + TTFT + success_rate) from
`compare.json`; escalate if **any** gate is `PROFILE_REGRESS`.

---

## 8. Compact worked examples (informative)

### c610 MiniCPM5-2B TP1 host_graph (`926aff24`)

| Iter | Ratio | Notes |
|------|------:|-------|
| 0 | ~0.43 | Host-first → `host_graph_command` |
| best ~H2 | 0.60 | skip-tail; COMMAND still high |
| final | 0.60 | `NO_GO` |

### c610 MiniCPM5.16a3 TP2 MoE

| Iter | Ratio | Top path |
|------|------:|----------|
| 0 | 0.151 | MoE policy |
| 3 | 0.558 | tiles/align |
| 4 | **1.009** | `moe_fused` — **SURPASS** |

### metax AIPerf dual (`01229051`)

`tok_s_ratio=0.051` → `PROFILE_REGRESS`.

### metax peak_batch64

Best ~0.720 (`batch_policy`); ended `NO_GO` / surpass_nogo.
