"""Daily platform report generation (join latest per server_id)."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench_harness.registry import (
    BENCH_RUN_META_COLUMNS,
    HISTOGRAM_SRV_COLS,
    PERIOD_HISTOGRAM_SUFFIXES,
    SERVER_META_COLUMNS,
    warehouse_facts_columns,
)

IDENTITY_COLS = list(SERVER_META_COLUMNS)


def _ordered_unique(columns: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for col in columns:
        if col not in seen:
            seen.add(col)
            out.append(col)
    return out


BENCH_META_COLS = {
    "bench_id",
    "bench_family",
    "date",
    "started_at",
    "finished_at",
    "suite_started_at",
    "status",
}
REPORT_BENCH_META_COLUMNS = _ordered_unique(
    ["date", "bench_family"] + list(BENCH_RUN_META_COLUMNS)
)
METRIC_COLS = [
    "status",
    "gate_pass",
    "step_loop_fatal",
    "ceval_em",
    "ceval_limit",
    "lb_em",
    "lb_n",
    "lb_limit",
    "ttft_p50_ms",
    "ttft_p99_ms",
    "ttft_mean_ms",
    "tpot_p50_ms",
    "tpot_mean_ms",
    "itl_p50_ms",
    "itl_p99_ms",
    "itl_mean_ms",
    "req_per_s",
    "output_tok_per_s",
    "total_tok_per_s",
]

LATENCY_BENCH_PREFIXES = (
    "deploy_throughput__",
    "mctracer_throughput__",
    "deploy_longbench_v2__",
)

BEST_ON_CLIENT_METRICS = [
    "ttft_p50_ms",
    "ttft_p99_ms",
    "ttft_mean_ms",
    "tpot_p50_ms",
    "tpot_mean_ms",
    "itl_p50_ms",
    "itl_p99_ms",
    "itl_mean_ms",
    "req_per_s",
    "output_tok_per_s",
    "total_tok_per_s",
]

BEST_ON_SRV_PERIOD_METRICS = [
    f"{base}{suffix}"
    for base in HISTOGRAM_SRV_COLS
    for suffix in PERIOD_HISTOGRAM_SUFFIXES
]

BEST_ON_SRV_SNAPSHOT_METRICS = list(HISTOGRAM_SRV_COLS)

BEST_ON_METRICS = (
    BEST_ON_CLIENT_METRICS + BEST_ON_SRV_PERIOD_METRICS + BEST_ON_SRV_SNAPSHOT_METRICS
)

METRIC_DIRECTION: dict[str, str] = {
    "ceval_em": "higher",
    "lb_em": "higher",
    "gate_pass": "higher",
    "ttft_p50_ms": "lower",
    "ttft_p99_ms": "lower",
    "ttft_mean_ms": "lower",
    "tpot_p50_ms": "lower",
    "tpot_mean_ms": "lower",
    "itl_p50_ms": "lower",
    "itl_p99_ms": "lower",
    "itl_mean_ms": "lower",
    "req_per_s": "higher",
    "output_tok_per_s": "higher",
    "total_tok_per_s": "higher",
}
for col in BEST_ON_SRV_PERIOD_METRICS + BEST_ON_SRV_SNAPSHOT_METRICS:
    METRIC_DIRECTION[col] = "lower"

BEST_ON_HEAD_COLS = ["platform", "model", "best_on", "value", "server_id", "bench_id"]


# Required bench/server metadata + metric context on every best-on model report row.
BEST_ON_REPORT_COLUMNS = _ordered_unique(
    BEST_ON_HEAD_COLS
    + [c for c in SERVER_META_COLUMNS if c not in BEST_ON_HEAD_COLS]
    + REPORT_BENCH_META_COLUMNS
    + METRIC_COLS
    + BEST_ON_METRICS
)


def project_report_row(row: dict[str, str], columns: list[str]) -> dict[str, str]:
    return {col: row.get(col, "") for col in columns}


def _parse_metric_value(val: str | None) -> float | None:
    if val is None or val == "":
        return None
    try:
        return float(val)
    except (TypeError, ValueError):
        return None


def is_valid_best_on_value(metric: str, val: float) -> bool:
    """Reject non-positive latency/throughput values for best-on selection."""
    if metric in ("gate_pass", "ceval_limit", "lb_n", "lb_limit", "lb_pool_n", "lb_truncated_n", "lb_length", "lb_difficulty", "workload_scale"):
        return val >= 0
    if metric in ("ceval_em", "lb_em"):
        return 0 <= val <= 1
    if val <= 0:
        return False
    if metric.startswith(("ttft_", "tpot_", "itl_", "srv_")):
        return val > 0.001
    if metric in ("req_per_s", "output_tok_per_s", "total_tok_per_s"):
        return val > 0
    return True


def is_latency_bench(bench_id: str) -> bool:
    return bench_id.startswith(LATENCY_BENCH_PREFIXES)


def best_on_metrics_for_bench(bench_id: str) -> list[str]:
    if not is_latency_bench(bench_id):
        return []
    return list(BEST_ON_METRICS)


def metric_better(metric: str, candidate: float, incumbent: float) -> bool:
    direction = METRIC_DIRECTION.get(metric, "lower")
    if direction == "higher":
        return candidate > incumbent
    return candidate < incumbent


def _metric_better(metric: str, candidate: float, incumbent: float) -> bool:
    return metric_better(metric, candidate, incumbent)


def parse_metric_value(val: str | None) -> float | None:
    return _parse_metric_value(val)


def comparable_metrics_for_row(row: dict[str, str]) -> list[str]:
    """Metrics to compare in daily review for one bench row."""
    bench_id = row.get("bench_id", "")
    metrics: list[str] = list(best_on_metrics_for_bench(bench_id))
    family = row.get("bench_family", "")
    if family == "accuracy":
        metrics.append("ceval_em")
    elif family == "quality_dyn":
        metrics.append("lb_em")
    elif family == "resilience":
        metrics.append("gate_pass")
    elif family == "correctness":
        metrics.append("gate_pass")
    seen: set[str] = set()
    out: list[str] = []
    for m in metrics:
        if m not in seen and row.get(m, "") not in ("", None):
            seen.add(m)
            out.append(m)
    return out


_REMOVED = "removed in refactor"


def write_model_best_reports(*args: Any, **kwargs: Any) -> list[Path]:
    raise NotImplementedError(_REMOVED)


def write_partition_reports(*args: Any, **kwargs: Any) -> list[Path]:
    raise NotImplementedError(_REMOVED)


def write_platform_reports(*args: Any, **kwargs: Any) -> tuple[Path | None, Path | None]:
    raise NotImplementedError(_REMOVED)


def build_best_metric_rows(*args: Any, **kwargs: Any) -> list[dict[str, str]]:
    raise NotImplementedError(_REMOVED)


def build_historical_best_index(*args: Any, **kwargs: Any) -> dict[tuple[str, str, str, str], tuple[str, str, str]]:
    raise NotImplementedError(_REMOVED)


def _pick_winner(
    rows: list[dict[str, str]],
    metric: str,
) -> dict[str, str] | None:
    winner: dict[str, str] | None = None
    winner_val: float | None = None
    for row in rows:
        val = _parse_metric_value(row.get(metric))
        if val is None or not is_valid_best_on_value(metric, val):
            continue
        if winner is None or winner_val is None:
            winner, winner_val = row, val
            continue
        if _metric_better(metric, val, winner_val):
            winner, winner_val = row, val
            continue
        if val == winner_val:
            cand_started = row.get("started_at", "")
            win_started = winner.get("started_at", "")
            if cand_started > win_started:
                winner, winner_val = row, val
            elif cand_started == win_started:
                cand_sid = row.get("server_id", "")
                win_sid = winner.get("server_id", "")
                if cand_sid > win_sid:
                    winner, winner_val = row, val
    return winner


def latest_per_server_bench(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    """Keep latest row per (server_id, bench_id) by started_at."""
    latest: dict[tuple[str, str], dict[str, str]] = {}
    for row in rows:
        sid = row.get("server_id", "")
        bid = row.get("bench_id", "")
        key = (sid, bid)
        prev = latest.get(key)
        if prev is None or row.get("started_at", "") > prev.get("started_at", ""):
            latest[key] = row
    return sorted(latest.values(), key=lambda r: (r.get("server_id", ""), r.get("bench_id", "")))


def build_wide_by_server(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    """One row per server_id with bench metrics joined as ``{bench_id}.{metric}`` columns."""
    by_server: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        sid = row.get("server_id", "")
        by_server.setdefault(sid, []).append(row)

    wide_rows: list[dict[str, str]] = []
    for sid in sorted(by_server):
        bench_rows = latest_per_server_bench(by_server[sid])
        if not bench_rows:
            continue
        # Identity from the row with the latest started_at on this server.
        anchor = max(bench_rows, key=lambda r: r.get("started_at", ""))
        out: dict[str, str] = {"report_scope": "latest", "report_date": anchor.get("date", "")}
        for col in IDENTITY_COLS:
            out[col] = anchor.get(col, "")
        out["latest_started_at"] = anchor.get("started_at", "")

        for brow in bench_rows:
            bid = brow.get("bench_id", "")
            if not bid:
                continue
            for m in METRIC_COLS:
                val = brow.get(m, "")
                if val:
                    out[f"{bid}.{m}"] = val
        wide_rows.append(out)
    return wide_rows

