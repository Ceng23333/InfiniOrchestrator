# Performance promotion loop — HTML review

Universal visualization surface for iteration facts. Works on c610,
metax-showroom, local Windows, CI artifacts, and shared file drops — **no
Cursor Canvas, no IDE plugin, no CDN**.

## Contract

| Item | Rule |
|------|------|
| Path | `$SUITE_DIR/review/index.html` is the campaign review entry |
| Data | Embed JSON in `<script type="application/json" id="promo-facts">` (escape `<` as `\u003c`); sibling `facts.json` for HTTP fetch |
| Fetch config | `$SUITE_DIR/review/fetch-config.json` (`promo-facts-fetch-1`) lists source URLs for **Fetch latest** |
| Schema | Converged `promo-facts-1` — see [facts.md](facts.md) |
| Deps | Vanilla HTML + CSS + JS only |
| Hosts | Same page for all vendors; differences live in fact fields |
| Freshness | Initial paint uses embedded facts; use **Fetch latest** to reload from config sources (HTTP) |
| Multi-host | `campaigns[]` + host/campaign switcher when length &gt; 1 |

Template checked in at [examples/review/index.html](examples/review/index.html) +
[examples/review/fetch-config.json](examples/review/fetch-config.json).

### Fetch config (`promo-facts-fetch-1`)

```json
{
  "schema_version": "promo-facts-fetch-1",
  "default_source_id": "local",
  "cache_bust": true,
  "sources": [
    { "id": "local", "label": "review/facts.json", "url": "facts.json" },
    { "id": "suite-combined", "label": "suite facts/combined.json", "url": "../facts/combined.json" }
  ]
}
```

Browser load order:

1. Load `fetch-config.json` (fallback: built-in `facts.json` source)
2. Boot embedded `#promo-facts` if present
3. **Fetch latest** button (or empty embed) GETs the selected source URL with cache-bust query

Serve over HTTP so fetch works (`file://` cannot reload `facts.json` — the page
shows an explicit error if you click **Fetch latest** under `file://`).

Default `fetch-config.json` only lists **same-directory** `facts.json` so it works
when the server root is `review/`. Parent paths like `../facts/combined.json` 404
in that setup and should not be the default.

**metax-showroom example** (already used for e2e):

```bash
cd /home/metax/qy/InfiniOrchestrator/.cursor/skills/performance-promotion-loop/examples/e2e-dual-host/review
python3 -m http.server 8765 --bind 0.0.0.0
# open http://<metax-ip>:8765/  then click Fetch latest (source: facts.json)
```

## Page sections (omit empty)

Views: **Tables** (default) and **Charts** (`#charts`).

### Tables

Tables still list **all iters**. Headline / pin / worktree as before.

1. **Headline** — latest ratio/top_path summary + host/pin/**worktree**/ITW tag; campaign switcher when multi-campaign
2. **Wall timeline** — every iter × metric (table + CSS bars)
3. **Backlog** — per-iter ranked `path_id` blocks (exhausted marked)
4. **Ship** — per-iter gate / actions / FINDINGS paths
5. **Provenance footer** — suite path, agent ids, source paths, generated timestamp

Host-signal family tables are omitted from the review UI (redundant with path backlog / path leftover pies). `HostSignalFact` may still exist in the envelope for tooling.

### Charts

Pie charts only (no trend lines). **Displayed iters are configurable** — default is **latest only** (not all). Use the Chart iters checkboxes (or Latest / All / None) to choose which pies render.

1. **Wall leftover share** — achieved (`WALL_DECODE_RATIO`) vs leftover to parity (`max(0, 1 − ratio)`); surplus wedge if ratio ≥ 1
2. **Path leftover share** — ranked backlog `path_id` slices (weight = `score` if present, else `1/rank`)

## Agent emit + launch

1. Normalize suite artifacts → `$SUITE_DIR/facts/` (and `combined.json` when reviewing multiple hosts).
2. Write `$SUITE_DIR/review/facts.json` snapshot (`promo-facts-1`) and
   `fetch-config.json`.
3. Copy/fill the template → `$SUITE_DIR/review/index.html` with facts embedded in
   `#promo-facts` (keep `facts.json` in sync).
4. **Launch** when validating or when the user asks to review; use **Fetch latest**
   on the page after regenerating `facts.json`:

```bash
# Prefer HTTP so facts.json reload works:
python -m http.server 8765 --directory "$SUITE_DIR/review"
# open http://127.0.0.1:8765/  (Charts: http://127.0.0.1:8765/#charts)
```

On Windows PowerShell, `file://` also works if facts are embedded:

```powershell
Start-Process "$SUITE_DIR\review\index.html"
```

5. Report the URL/path. For dual-host e2e, confirm both campaigns appear via the switcher.

## Compact pull policy (for e2e / remote suites)

Pull **only** wall/profiler `compare.json` summaries, `promotion_backlog.json`,
and FINDINGS markdown. Prefer remote summarize → stdout over scp of vendor
trees. Soft cap ~2 MB per artifact. Reject raw traces (`.nsys`, Chrome traces,
fullcell dumps, multi-MB `OUT/`).

## Non-goals

- InfiniOrchestrator ops panel (`rust/panel`) or Grafana wiring
- React / npm review apps
- Cursor Canvas or `/visualize` as the campaign record (optional chat glance only)
- Auto-SSH on every review turn

## Dual-host e2e example

See [examples/e2e-dual-host/](examples/e2e-dual-host/) — normalized c610 +
metax-showroom envelopes, combined payload, and a launchable review page.
