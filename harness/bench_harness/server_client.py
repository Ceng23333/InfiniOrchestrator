"""Fetch /metadata and /metrics from InfiniLM inference_server (HTTP client touchpoints)."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench_harness.registry import HISTOGRAM_SRV_COLS, PERIOD_HISTOGRAM_SUFFIXES

json_snapshot_to_warehouse_row = None
prometheus_text_to_json_snapshot = None
summarize_period_samples = None
WAREHOUSE_COUNTER_SRV_COLS = None

try:
    from infinimetadata.aggregation import summarize_period_samples as _summarize_period_samples
    from infinimetadata.prometheus_import import (
        prometheus_text_to_json_snapshot as _prometheus_text_to_json_snapshot,
    )
    from infinimetadata.warehouse_export import (
        WAREHOUSE_COUNTER_SRV_COLS as _WAREHOUSE_COUNTER_SRV_COLS,
        json_snapshot_to_warehouse_row as _json_snapshot_to_warehouse_row,
    )

    summarize_period_samples = _summarize_period_samples
    prometheus_text_to_json_snapshot = _prometheus_text_to_json_snapshot
    json_snapshot_to_warehouse_row = _json_snapshot_to_warehouse_row
    WAREHOUSE_COUNTER_SRV_COLS = _WAREHOUSE_COUNTER_SRV_COLS
except ImportError:
    pass

COUNTER_SRV_COLS = WAREHOUSE_COUNTER_SRV_COLS or [
    "srv_req_total_ok",
    "srv_tokens_prompt_total",
    "srv_tokens_completion_total",
]


def skip_server_metrics() -> bool:
    """True when srv_* scrape/conversion should be skipped (non-Infini backends)."""
    flag = os.environ.get("BENCH_SKIP_SERVER_METRICS", "").strip().lower()
    if flag in ("1", "true", "yes"):
        return True
    backend = os.environ.get("BENCH_BACKEND", "infinilm").strip().lower()
    return backend in ("vllm", "openai")


def resolve_server_base_url(
    base_url: str | None = None,
    *,
    inference_server_base_url: str | None = None,
) -> str:
    url = (
        inference_server_base_url
        or os.environ.get("INFERENCE_SERVER_BASE_URL")
        or base_url
        or os.environ.get("BENCH_TARGET_URL")
        or os.environ.get("BASE_URL")
        or ""
    ).rstrip("/")
    if not url:
        raise ValueError("base_url or INFERENCE_SERVER_BASE_URL required")
    return url


def _http_get_json(url: str, timeout: float = 30.0) -> dict[str, Any]:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _http_get_text(url: str, timeout: float = 30.0) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read().decode("utf-8")


def fetch_metadata(base_url: str, timeout: float = 30.0) -> dict[str, Any]:
    url = f"{base_url.rstrip('/')}/metadata"
    meta = _http_get_json(url, timeout=timeout)
    server_id = meta.get("server_id")
    if not server_id or not re.match(
        r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        str(server_id),
        re.I,
    ):
        raise ValueError(f"invalid server_id in metadata: {server_id!r}")
    return meta


def scrape_metrics_prometheus(base_url: str, timeout: float = 30.0) -> str:
    url = f"{base_url.rstrip('/')}/metrics"
    return _http_get_text(url, timeout=timeout)


def scrape_metrics_json(
    base_url: str,
    *,
    server_id: str | None = None,
    timeout: float = 30.0,
    prom_text: str | None = None,
) -> dict[str, Any]:
    if prometheus_text_to_json_snapshot is None:
        raise RuntimeError("infinimetadata is required for metrics JSON conversion")
    prom = prom_text if prom_text is not None else scrape_metrics_prometheus(base_url, timeout=timeout)
    return prometheus_text_to_json_snapshot(prom, server_id=server_id)


def metrics_json_to_row(metrics: dict[str, Any]) -> dict[str, str]:
    if not metrics:
        return {}
    if json_snapshot_to_warehouse_row is None:
        raise RuntimeError("infinimetadata is required for metrics flattening")
    return json_snapshot_to_warehouse_row(metrics)


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def summarize_period_metrics(samples: list[dict[str, str]]) -> dict[str, str]:
    if summarize_period_samples is None:
        raise RuntimeError("infinimetadata is required for period metrics summarization")
    return summarize_period_samples(
        samples,
        histogram_cols=HISTOGRAM_SRV_COLS,
        counter_cols=COUNTER_SRV_COLS,
        period_suffixes=PERIOD_HISTOGRAM_SUFFIXES,
    )


def write_period_summary(
    out_dir: Path,
    samples: list[dict[str, str]],
    *,
    started_at: str,
    finished_at: str,
    poll_interval_sec: float,
    write_raw_jsonl: bool = False,
) -> Path:
    """Write metrics_period_summary.json (and optional raw jsonl)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    if samples:
        summary = summarize_period_metrics(samples)
    else:
        summary = {}
    summary.update(
        {
            "sample_count": str(len(samples)),
            "started_at": started_at,
            "finished_at": finished_at,
            "poll_interval_sec": str(poll_interval_sec),
        }
    )
    summary_path = out_dir / "metrics_period_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    if write_raw_jsonl and samples:
        raw_path = out_dir / "metrics_period.jsonl"
        with raw_path.open("w", encoding="utf-8") as fh:
            for sample in samples:
                fh.write(json.dumps(sample) + "\n")
    return summary_path


def run_period_poll(
    base_url: str,
    out_dir: Path,
    *,
    poll_interval_sec: float = 10.0,
    write_raw_jsonl: bool = False,
    timeout: float = 30.0,
) -> None:
    """Poll /metrics in a loop until SIGTERM; summarize on exit."""
    out_dir.mkdir(parents=True, exist_ok=True)
    if skip_server_metrics():
        started = _utc_now_iso()
        write_period_summary(
            out_dir,
            [],
            started_at=started,
            finished_at=started,
            poll_interval_sec=poll_interval_sec,
            write_raw_jsonl=False,
        )
        print("[server_client] period poll skipped (BENCH_SKIP_SERVER_METRICS)", file=sys.stderr)
        return

    pid_path = out_dir / ".metrics_period.pid"
    pid_path.write_text(str(os.getpid()), encoding="utf-8")

    samples: list[dict[str, str]] = []
    started_at = _utc_now_iso()
    stop_requested = False

    def _handle_sigterm(signum: int, frame: Any) -> None:
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGTERM, _handle_sigterm)
    signal.signal(signal.SIGINT, _handle_sigterm)

    while not stop_requested:
        try:
            metrics = scrape_metrics_json(base_url, timeout=timeout)
            samples.append(metrics_json_to_row(metrics))
        except (urllib.error.URLError, ValueError, TimeoutError, RuntimeError) as exc:
            print(f"[server_client] period poll WARN: {exc}", file=sys.stderr)
        deadline = time.monotonic() + poll_interval_sec
        while not stop_requested and time.monotonic() < deadline:
            time.sleep(0.2)

    finished_at = _utc_now_iso()
    path = write_period_summary(
        out_dir,
        samples,
        started_at=started_at,
        finished_at=finished_at,
        poll_interval_sec=poll_interval_sec,
        write_raw_jsonl=write_raw_jsonl,
    )
    pid_path.unlink(missing_ok=True)
    print(f"[server_client] period summary → {path} ({len(samples)} samples)")


def save_metrics_snapshot(
    base_url: str,
    out_dir: Path,
    label: str,
    timeout: float = 30.0,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    if skip_server_metrics():
        empty: dict[str, Any] = {}
        (out_dir / f"metrics_{label}.prom").write_text("", encoding="utf-8")
        (out_dir / f"metrics_{label}.json").write_text("{}\n", encoding="utf-8")
        return empty
    meta = fetch_metadata(base_url, timeout=timeout)
    prom = scrape_metrics_prometheus(base_url, timeout=timeout)
    (out_dir / f"metrics_{label}.prom").write_text(prom, encoding="utf-8")
    metrics = scrape_metrics_json(
        base_url,
        server_id=str(meta.get("server_id") or ""),
        timeout=timeout,
        prom_text=prom,
    )
    (out_dir / f"metrics_{label}.json").write_text(
        json.dumps(metrics, indent=2) + "\n", encoding="utf-8"
    )
    return metrics


def preflight(base_url: str, timeout: float = 30.0) -> dict[str, Any]:
    return fetch_metadata(base_url, timeout=timeout)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="InfiniLM server metadata/metrics client")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_pref = sub.add_parser("preflight", help="GET /metadata and print JSON")
    p_pref.add_argument("--base-url", required=True)
    p_pref.add_argument("--timeout", type=float, default=30.0)

    p_scrape = sub.add_parser("scrape", help="Scrape /metrics to directory")
    p_scrape.add_argument("--base-url", required=True)
    p_scrape.add_argument("--out-dir", type=Path, required=True)
    p_scrape.add_argument("--label", default="after")
    p_scrape.add_argument("--timeout", type=float, default=30.0)

    p_period = sub.add_parser("period-poll", help="Poll /metrics until SIGTERM; write period summary")
    p_period.add_argument("--base-url", required=True)
    p_period.add_argument("--out-dir", type=Path, required=True)
    p_period.add_argument("--poll-interval-sec", type=float, default=10.0)
    p_period.add_argument("--write-raw-jsonl", action="store_true")
    p_period.add_argument("--timeout", type=float, default=30.0)

    args = parser.parse_args(argv)
    try:
        if args.cmd == "preflight":
            meta = preflight(args.base_url, timeout=args.timeout)
            print(json.dumps(meta, indent=2))
            return 0
        if args.cmd == "scrape":
            metrics = save_metrics_snapshot(
                args.base_url, args.out_dir, args.label, timeout=args.timeout
            )
            print(json.dumps(metrics_json_to_row(metrics), indent=2))
            return 0
        if args.cmd == "period-poll":
            run_period_poll(
                args.base_url,
                args.out_dir,
                poll_interval_sec=args.poll_interval_sec,
                write_raw_jsonl=args.write_raw_jsonl,
                timeout=args.timeout,
            )
            return 0
    except (urllib.error.URLError, ValueError, TimeoutError, RuntimeError) as exc:
        print(f"[server_client] ERROR: {exc}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
