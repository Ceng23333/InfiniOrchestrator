"""Query compact warehouse metrics with pandas (no DuckDB required)."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Optional

import pandas as pd

from bench_harness.partition import (
    compact_facts_path,
    glob_compact_facts,
    glob_raw_date_dirs,
    slugify_segment,
)
from bench_harness.ingest import parse_raw_rows_for_date


def _repo_root(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit
    return Path(os.environ.get("BENCH_WAREHOUSE_REPO", Path(__file__).resolve().parents[1]))


def load_compact(
    repo_root: Path,
    *,
    model_id: str | None = None,
) -> pd.DataFrame:
    paths = glob_compact_facts(repo_root, model_id=model_id)
    if not paths:
        return pd.DataFrame()
    frames = [pd.read_csv(p, sep="\t", dtype=str) for p in paths]
    df = pd.concat(frames, ignore_index=True)
    if "started_at" in df.columns:
        df["started_at"] = pd.to_datetime(df["started_at"], utc=True, errors="coerce")
    return df


def load_facts(
    repo_root: Path,
    dates: Optional[str] = None,
    *,
    model_id: str | None = None,
) -> pd.DataFrame:
    """Load compact facts, optionally filtered to rows whose ``date`` is in ``dates``."""
    df = load_compact(repo_root, model_id=model_id)
    if df.empty:
        return df
    if dates:
        wanted = {d.strip() for d in dates.split(",") if d.strip()}
        if "date" in df.columns:
            df = df[df["date"].isin(wanted)]
    return df


def load_raw(
    repo_root: Path,
    date: str | None = None,
    *,
    model_id: str | None = None,
) -> pd.DataFrame:
    if date:
        rows = parse_raw_rows_for_date(repo_root, date)
    else:
        rows = []
        for date_dir in glob_raw_date_dirs(repo_root):
            rows.extend(parse_raw_rows_for_date(repo_root, date_dir.name))
    if not rows:
        return pd.DataFrame()
    if model_id:
        target = slugify_segment(model_id)
        rows = [
            r
            for r in rows
            if slugify_segment(r.get("model_id", "") or r.get("model", "")) == target
        ]
    df = pd.DataFrame(rows)
    if "started_at" in df.columns:
        df["started_at"] = pd.to_datetime(df["started_at"], utc=True, errors="coerce")
    return df


def _parse_ts(s: str) -> pd.Timestamp:
    return pd.to_datetime(s, utc=True)


def apply_filters(
    df: pd.DataFrame,
    *,
    bench_id: Optional[str] = None,
    bench_id_prefix: Optional[str] = None,
    model: Optional[str] = None,
    model_id: Optional[str] = None,
    server_id: Optional[str] = None,
    host_id: Optional[str] = None,
    platform: Optional[str] = None,
    since: Optional[str] = None,
    until: Optional[str] = None,
    columns: Optional[str] = None,
) -> pd.DataFrame:
    if df.empty:
        return df
    out = df.copy()
    if bench_id:
        out = out[out["bench_id"] == bench_id]
    if bench_id_prefix:
        out = out[out["bench_id"].str.startswith(bench_id_prefix, na=False)]
    mid = model_id or model
    if mid:
        if "model_id" in out.columns:
            out = out[(out["model_id"] == mid) | (out["model"] == mid)]
        elif "model" in out.columns:
            out = out[out["model"] == mid]
    if server_id and "server_id" in out.columns:
        out = out[out["server_id"] == server_id]
    if host_id and "host_id" in out.columns:
        out = out[out["host_id"] == host_id]
    if platform and "platform" in out.columns:
        out = out[out["platform"] == platform]
    if since and "started_at" in out.columns:
        out = out[out["started_at"] >= _parse_ts(since)]
    if until and "started_at" in out.columns:
        out = out[out["started_at"] <= _parse_ts(until)]
    if columns:
        cols = [c.strip() for c in columns.split(",") if c.strip()]
        keep = [c for c in cols if c in out.columns]
        if keep:
            out = out[keep]
    return out


def format_output(df: pd.DataFrame, fmt: str) -> str:
    if df.empty:
        return "(no rows)"
    display = df.copy()
    if "started_at" in display.columns:
        display["started_at"] = display["started_at"].astype(str)
    if fmt == "csv":
        return display.to_csv(index=False, sep="\t")
    if fmt == "json":
        return display.to_json(orient="records", indent=2)
    return display.to_string(index=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Query bench-warehouse compact metrics with pandas")
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument(
        "--source",
        choices=["compact", "facts", "raw"],
        default="compact",
    )
    parser.add_argument("--platform", default=None, help="filter by platform")
    parser.add_argument("--bench-id", default=None)
    parser.add_argument("--bench-id-prefix", default=None)
    parser.add_argument("--model", default=None, help="alias for --model-id")
    parser.add_argument("--model-id", default=None)
    parser.add_argument("--server-id", default=None)
    parser.add_argument("--host-id", default=None)
    parser.add_argument("--since", default=None, help="ISO date or timestamp")
    parser.add_argument("--until", default=None)
    parser.add_argument("--dates", default=None, help="comma-separated YYYY-MM-DD filter for compact/facts")
    parser.add_argument("--date", default=None, help="single date for --source raw")
    parser.add_argument("--columns", default=None)
    parser.add_argument("--format", choices=["table", "csv", "json"], default="table")
    args = parser.parse_args(argv)

    repo = _repo_root(args.repo_root)
    model_id = args.model_id or args.model

    if args.source == "raw":
        df = load_raw(repo, args.date or args.dates, model_id=model_id)
    elif args.source in ("compact", "facts"):
        df = load_facts(repo, args.dates, model_id=model_id)
    else:
        df = pd.DataFrame()

    df = apply_filters(
        df,
        bench_id=args.bench_id,
        bench_id_prefix=args.bench_id_prefix,
        model_id=model_id,
        server_id=args.server_id,
        host_id=args.host_id,
        platform=args.platform,
        since=args.since,
        until=args.until,
        columns=args.columns,
    )

    print(format_output(df, args.format))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
