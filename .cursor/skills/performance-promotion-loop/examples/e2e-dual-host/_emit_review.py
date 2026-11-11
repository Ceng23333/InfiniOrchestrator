import json
from datetime import datetime, timezone
from pathlib import Path

base = Path(__file__).resolve().parent
skill = base.parent.parent


def load(p: Path):
	text = p.read_text(encoding="utf-8-sig")
	return json.loads(text)


c610 = load(base / "facts" / "c610" / "campaigns.json")
metax = load(base / "facts" / "metax-showroom" / "campaigns.json")

wanted = [
	"c610-minicpm5-2b-tp1-host-graph",
	"metax-peak-batch64-promotion",
	"c610-minicpm5-16a3-tp2-moe",
	"metax-aiperf-vllm-leg-20231123",
]
by_id = {}
for blob in (c610, metax):
	for c in blob.get("campaigns") or []:
		by_id[c["campaign_id"]] = c
campaigns = [by_id[i] for i in wanted if i in by_id]

combined = {
	"schema_version": "promo-facts-1",
	"generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
	"note": "e2e dual-host compact envelopes from c610 + metax-showroom",
	"campaigns": campaigns,
}
(base / "facts" / "combined.json").write_text(json.dumps(combined, indent=2), encoding="utf-8")
(base / "review" / "facts.json").write_text(json.dumps(combined, indent=2), encoding="utf-8")

# Fetch config for the review page (Fetch latest button).
# Default to same-directory facts.json so Fetch latest works when
# `python -m http.server` is started with --directory review/.
fetch_cfg = {
	"schema_version": "promo-facts-fetch-1",
	"default_source_id": "local",
	"cache_bust": True,
	"sources": [
		{
			"id": "local",
			"label": "facts.json (same directory)",
			"url": "facts.json",
		},
	],
}
(base / "review" / "fetch-config.json").write_text(
	json.dumps(fetch_cfg, indent=2) + "\n", encoding="utf-8"
)
# Keep skill template copy in sync for greenfield suites.
(skill / "examples" / "review" / "fetch-config.json").write_text(
	json.dumps(fetch_cfg, indent=2) + "\n", encoding="utf-8"
)

template = (skill / "examples" / "review" / "index.html").read_text(encoding="utf-8")
marker = '<script type="application/json" id="promo-facts">'
start = template.find(marker)
if start < 0:
	raise SystemExit("template missing promo-facts json script")
body_start = start + len(marker)
body_end = template.find("</script>", body_start)
if body_end < 0:
	raise SystemExit("template promo-facts script not closed")

# Escape < so HTML parsers cannot treat JSON as markup.
payload = json.dumps(combined, ensure_ascii=False).replace("<", "\\u003c")
new_html = template[:body_start] + "\n" + payload + "\n  " + template[body_end:]
(base / "review" / "index.html").write_text(new_html, encoding="utf-8")

# Sanity: json script must parse, and app script must still exist.
opens = new_html.count("<script")
if opens < 2:
	raise SystemExit(f"expected >=2 script tags, got {opens}")
i0 = new_html.find(marker) + len(marker)
i1 = new_html.find("</script>", i0)
json.loads(new_html[i0:i1].strip())

assert "c610" in new_html and "metax-showroom" in new_html
print("campaigns", [c["campaign_id"] for c in campaigns])
print("combined_bytes", (base / "facts" / "combined.json").stat().st_size)
print("html_bytes", (base / "review" / "index.html").stat().st_size)
for p in sorted(base.rglob("*")):
	if p.is_file() and p.name.startswith("_"):
		continue
	if p.is_file():
		sz = p.stat().st_size
		if sz > 2_000_000:
			raise SystemExit(f"too large: {p} {sz}")
		print(f"{sz:8d} {p.relative_to(base)}")
