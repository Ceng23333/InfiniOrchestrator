# E2E dual-host HTML review

Compact `promo-facts-1` envelopes pulled from:

| Host | Source campaigns |
|------|------------------|
| **c610** | `host_graph` MiniCPM5-2B (`926aff24`) + `promo_16a3_tp2` MoE surpass |
| **metax-showroom** | `peak_batch64_promotion` + AIPerf dual `aiperf_vllm_leg_*` (`01229051`) |

## Pull policy

Remote summarize only (`compare.json`, `promotion_backlog.json`, FINDINGS).
No raw DLPTI/mcTracer traces. Soft cap ~2 MB per artifact.

## Layout

```text
facts/c610/campaigns.json
facts/metax-showroom/campaigns.json
facts/combined.json
review/facts.json
review/index.html          # embedded facts; open via HTTP or file://
```

## Relaunch

```powershell
cd .cursor/skills/performance-promotion-loop/examples/e2e-dual-host/review
python -m http.server 8765
# open http://127.0.0.1:8765/
# use Facts source + "Fetch latest" to reload facts.json (see fetch-config.json)
```

Regenerate HTML after refreshing host JSON:

```powershell
python ../_emit_review.py
```

`fetch-config.json` defaults to `facts.json`. The `suite-combined` entry needs the
HTTP root above `review/` (or a proxy) so `../facts/combined.json` is reachable.

## Pass criteria

- Page loads without CDN
- Campaign switcher shows both `c610` and `metax-showroom`
- Wall timeline + host signals or backlog populated per rich campaign
- Provenance cites remote source paths
- No invented wall ratios beyond values present in pulled JSON / FINDINGS
