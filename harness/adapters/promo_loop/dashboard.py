"""Minimal HTML dashboard: iteration table + primary metric chart."""

from __future__ import annotations

import html
import json


def render(campaign_path: str, host_key: str, history: list[dict], directions: dict[str, str]) -> str:
    primary = next((m for m, d in directions.items() if d == "higher"), None) or (
        next(iter(directions), "") if directions else "")
    rows = []
    for r in history:
        m = r.get("metrics") or {}
        cells = "".join(
            f"<td>{html.escape(str(m.get(k, '-')))}</td>" for k in directions
        )
        badge = "acc" if r.get("accepted") else "rej"
        rows.append(
            f"<tr class='{badge}'><td>{html.escape(str(r.get('iteration')))}</td>"
            f"<td><span class='badge {badge}'>{badge}</span></td>{cells}"
            f"<td class='reason'>{html.escape(str(r.get('reason') or '')[:90])}</td></tr>"
        )
    pts = []
    lo = hi = None
    for r in history:
        v = (r.get("metrics") or {}).get(primary)
        if isinstance(v, (int, float)):
            pts.append((int(r["iteration"]), float(v)))
            lo = v if lo is None else min(lo, v)
            hi = v if hi is None else max(hi, v)
    svg = ""
    if len(pts) >= 2 and hi and hi > lo:
        w, h, pad = 560, 120, 12
        span = hi - lo
        coords = " ".join(
            f"{pad + (i * (w - 2 * pad) / max(1, len(pts) - 1)):.1f},"
            f"{h - pad - ((v - lo) / span) * (h - 2 * pad):.1f}"
            for i, (_, v) in enumerate(pts)
        )
        svg = (f"<svg class='chart' viewBox='0 0 {w} {h}' preserveAspectRatio='none'>"
               f"<polyline fill='none' stroke='#58a6ff' stroke-width='2' points='{coords}'/></svg>")
    dirs_js = json.dumps(directions)
    return f"""<!DOCTYPE html><html><head><meta charset='utf-8'>
<title>promo loop - {html.escape(host_key)}</title><style>
body{{background:#0d1117;color:#e6ed3;font-family:system-ui;margin:24px;color:#e6edf3}}
table{{border-collapse:collapse;font-family:ui-monospace;font-size:13px;margin-top:12px}}
td,th{{border-bottom:1px solid #30363d;padding:6px 12px;text-align:left}}
.badge{{padding:1px 8px;border-radius:4px;font-size:11px}}
.acc{{background:rgba(63,185,80,.15);color:#3fb950}} .rej{{background:rgba(248,81,73,.15);color:#f85149}}
.chart{{width:100%;max-width:560px;background:#161b22;border:1px solid #30363d;border-radius:6px;margin-top:12px}}
.reason{{color:#8b949e}} h1{{font-size:18px}} .sub{{color:#8b949e;font-size:13px}}
</style></head><body>
<h1>promotion loop - {html.escape(host_key)}</h1>
<div class='sub'>{html.escape(campaign_path)} - {len(history)} iterations - best {html.escape(primary)}: {hi if hi is not None else '-'}</div>
{svg}
<table><tr><th>iter</th><th></th><th>{'</th><th>'.join(html.escape(k) for k in directions)}</th><th>reason</th></tr>
{''.join(rows)}</table></body></html>"""


def publish(out_path, publish_dir, host_key) -> None:
    import shutil
    if not publish_dir:
        return
    dest = publish_dir / host_key
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(out_path, dest / "dashboard.html")
