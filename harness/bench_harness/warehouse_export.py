"""Flatten /metrics JSON snapshots into warehouse srv_* TSV columns."""

from __future__ import annotations

from typing import Any

WAREHOUSE_HISTOGRAM_SRV_COLS = [
    "srv_ttft_p50_ms",
    "srv_ttft_p99_ms",
    "srv_e2e_p50_ms",
    "srv_itl_p50_ms",
]

WAREHOUSE_COUNTER_SRV_COLS = [
    "srv_req_total_ok",
    "srv_tokens_prompt_total",
    "srv_tokens_completion_total",
]

WAREHOUSE_PERIOD_SUFFIXES = ("_mean", "_median", "_p99")

WAREHOUSE_GAUGE_SRV_COLS = [
    "srv_engine_free_blocks",
    "srv_engine_used_blocks",
    "srv_engine_queue_waiting",
]

WAREHOUSE_SNAPSHOT_SRV_COLS = [
    "srv_req_total_ok",
    "srv_req_total_error",
    "srv_req_total_canceled",
    "srv_ttft_p50_ms",
    "srv_ttft_p99_ms",
    "srv_e2e_p50_ms",
    "srv_itl_p50_ms",
    "srv_itl_p99_ms",
]


def _period_histogram_columns() -> list[str]:
    cols: list[str] = []
    for base in WAREHOUSE_HISTOGRAM_SRV_COLS:
        for suffix in WAREHOUSE_PERIOD_SUFFIXES:
            cols.append(f"{base}{suffix}")
    return cols


WAREHOUSE_SERVER_METRIC_COLUMNS = [
    *WAREHOUSE_SNAPSHOT_SRV_COLS,
    *_period_histogram_columns(),
    "srv_tokens_prompt_total",
    "srv_tokens_completion_total",
    *WAREHOUSE_GAUGE_SRV_COLS,
]


def json_snapshot_to_warehouse_row(metrics: dict[str, Any]) -> dict[str, str]:
    """Flatten server metrics JSON into srv_* TSV columns."""
    counters = metrics.get("counters") or {}
    histograms = metrics.get("histograms") or {}
    gauges = metrics.get("gauges") or {}

    ttft = histograms.get("request_ttft_seconds") or {}
    e2e = histograms.get("request_e2e_seconds") or {}
    itl = histograms.get("request_itl_seconds") or {}

    row: dict[str, str] = {}
    for key, col in (
        ("requests_total_ok", "srv_req_total_ok"),
        ("requests_total_error", "srv_req_total_error"),
        ("requests_total_canceled", "srv_req_total_canceled"),
        ("tokens_prompt_total", "srv_tokens_prompt_total"),
        ("tokens_completion_total", "srv_tokens_completion_total"),
    ):
        val = counters.get(key)
        if val is not None:
            row[col] = str(val)

    if ttft.get("p50") is not None:
        row["srv_ttft_p50_ms"] = str(float(ttft["p50"]) * 1000.0)
    if ttft.get("p99") is not None:
        row["srv_ttft_p99_ms"] = str(float(ttft["p99"]) * 1000.0)
    if e2e.get("p50") is not None:
        row["srv_e2e_p50_ms"] = str(float(e2e["p50"]) * 1000.0)
    if itl.get("p50") is not None:
        row["srv_itl_p50_ms"] = str(float(itl["p50"]) * 1000.0)
    if itl.get("p99") is not None:
        row["srv_itl_p99_ms"] = str(float(itl["p99"]) * 1000.0)

    for src, col in (
        ("engine_free_blocks", "srv_engine_free_blocks"),
        ("engine_used_blocks", "srv_engine_used_blocks"),
        ("engine_queue_waiting", "srv_engine_queue_waiting"),
    ):
        val = gauges.get(src)
        if val is not None:
            row[col] = str(val)

    return row
