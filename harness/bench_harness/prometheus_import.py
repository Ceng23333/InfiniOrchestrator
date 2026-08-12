"""Parse Prometheus text exposition into warehouse JSON snapshot shape."""

from __future__ import annotations

import re
import time
from typing import Any

_LABEL_RE = re.compile(r'(\w+)="((?:\\.|[^"\\])*)"')

# Prom metric base name -> json_snapshot histogram key.
_HISTOGRAM_BASES = {
    "infinilm_request_ttft_seconds": "request_ttft_seconds",
    "infinilm_request_e2e_seconds": "request_e2e_seconds",
    "infinilm_request_itl_seconds": "request_itl_seconds",
}


def _parse_labels(label_str: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    for match in _LABEL_RE.finditer(label_str):
        key = match.group(1)
        value = match.group(2).replace('\\"', '"').replace("\\\\", "\\")
        labels[key] = value
    return labels


def _parse_sample_line(line: str) -> tuple[str, dict[str, str], float] | None:
    line = line.strip()
    if not line or line.startswith("#"):
        return None

    if "{" in line:
        name, rest = line.split("{", 1)
        label_part, value_part = rest.split("}", 1)
        labels = _parse_labels(label_part)
        value_token = value_part.strip().split()[0]
        return name.strip(), labels, float(value_token)

    parts = line.split()
    if len(parts) < 2:
        return None
    return parts[0], {}, float(parts[1])


def prometheus_text_to_json_snapshot(
    text: str,
    *,
    server_id: str | None = None,
    scraped_at: str | None = None,
) -> dict[str, Any]:
    """Convert ``GET /metrics`` Prometheus text to the legacy JSON snapshot shape."""
    counters: dict[str, float] = {}
    histograms: dict[str, dict[str, float]] = {
        key: {} for key in _HISTOGRAM_BASES.values()
    }
    gauges: dict[str, float] = {}

    for line in text.splitlines():
        parsed = _parse_sample_line(line)
        if parsed is None:
            continue
        name, labels, value = parsed

        if name == "infinilm_requests_total":
            status = labels.get("status")
            if status:
                # Sum across optional server_id labels (LB gateway metrics).
                if server_id and labels.get("server_id") not in ("", None, server_id):
                    continue
                key = f"requests_total_{status}"
                counters[key] = counters.get(key, 0.0) + value
            continue

        if name == "infinilm_request_tokens_total":
            kind = labels.get("kind")
            if kind:
                if server_id and labels.get("server_id") not in ("", None, server_id):
                    continue
                key = f"tokens_{kind}_total"
                counters[key] = counters.get(key, 0.0) + value
            continue

        if name == "infinilm_engine_free_blocks":
            gauges["engine_free_blocks"] = value
            continue

        if name == "infinilm_engine_used_blocks":
            gauges["engine_used_blocks"] = value
            continue

        if name == "infinilm_engine_queue_size" and labels.get("state") == "waiting":
            gauges["engine_queue_waiting"] = value
            continue

        for prom_base, hist_key in _HISTOGRAM_BASES.items():
            for suffix, field in (
                ("_count", "count"),
                ("_sum", "sum"),
                ("_p50", "p50"),
                ("_p99", "p99"),
            ):
                if name == f"{prom_base}{suffix}":
                    histograms[hist_key][field] = value
                    break

    return {
        "server_id": server_id,
        "scraped_at": scraped_at
        or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "counters": counters,
        "histograms": histograms,
        "gauges": gauges,
    }
