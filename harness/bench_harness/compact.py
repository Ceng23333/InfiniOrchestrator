"""Compact raw date partitions into compact/<model_id>/facts.tsv."""

from __future__ import annotations

import argparse
import csv
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from bench_harness.deploy_tier import backfill_deploy_tier
from bench_harness.ingest.parsers import parse_raw_rows_for_date
from bench_harness.partition import (
    compact_facts_path,
    glob_compact_model_ids,
    glob_raw_date_dirs,
    model_id_from_row,
    processed_keys_path,
    raw_ingest_key,
    slugify_segment,
)
from bench_harness.registry import warehouse_facts_columns

PROCESSED_FILE = "processed_raw_dates.jsonl"


def _load_processed(repo_root: Path) -> set[str]:
    path = processed_keys_path(repo_root)
    keys: set[str] = set()
    if not path.is_file():
        return keys
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            keys.add(line)
    return keys


def _append_processed(repo_root: Path, keys: list[str]) -> None:
    path = processed_keys_path(repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        for key in keys:
            fh.write(key + "\n")


def _read_tsv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def _write_tsv(
    path: Path,
    rows: list[dict[str, str]],
    columns: list[str] | None = None,
) -> None:
    if columns is None:
        columns = warehouse_facts_columns()
        for row in rows:
            for k in row:
                if k not in columns:
                    columns.append(k)
    if not columns:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def _row_model_id(row: dict[str, str]) -> str:
    try:
        return model_id_from_row(row)
    except ValueError:
        return slugify_segment(row.get("model", ""))


def _collect_raw_rows(repo_root: Path, date: str | None = None) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    if date is not None:
        rows.extend(parse_raw_rows_for_date(repo_root, date))
        return rows
    for date_dir in glob_raw_date_dirs(repo_root):
        rows.extend(parse_raw_rows_for_date(repo_root, date_dir.name))
    return rows


def compact_model(repo_root: Path, model_id: str) -> Path:
    """Idempotent rewrite of compact facts from all raw dates for ``model_id``."""
    target = slugify_segment(model_id)
    all_rows = backfill_deploy_tier(_collect_raw_rows(repo_root))
    model_rows = [r for r in all_rows if _row_model_id(r) == target]
    facts_path = compact_facts_path(repo_root, model_id)
    _write_tsv(facts_path, model_rows, warehouse_facts_columns())
    print(f"[compact] {facts_path} ({len(model_rows)} row(s))")
    return facts_path


def compact_all_models(repo_root: Path, *, date: str | None = None) -> list[Path]:
    rows = backfill_deploy_tier(
        _collect_raw_rows(repo_root, date) if date else _collect_raw_rows(repo_root)
    )
    model_ids = sorted({_row_model_id(r) for r in rows if _row_model_id(r)})
    if not model_ids and date is None:
        model_ids = glob_compact_model_ids(repo_root)
    written: list[Path] = []
    for mid in model_ids:
        written.append(compact_model(repo_root, mid))
    return written


def compact_date(repo_root: Path, date: str, force: bool = False) -> int:
    ingest_key = raw_ingest_key(date)
    processed = _load_processed(repo_root) if not force else set()
    if ingest_key in processed and not force:
        print(f"[compact] skip {ingest_key} (already processed)")
        return 0

    rows = parse_raw_rows_for_date(repo_root, date)
    if not rows and not force:
        print(f"[compact] no rows for {date}")
        return 0

    if rows:
        backfill_deploy_tier(rows)
        model_ids = sorted({_row_model_id(r) for r in rows if _row_model_id(r)})
        for mid in model_ids:
            compact_model(repo_root, mid)
        if not force:
            _append_processed(repo_root, [ingest_key])
        print(f"[compact] ingested {len(rows)} row(s) for {date} across {len(model_ids)} model(s)")
        return len(rows)

    if force:
        compact_all_models(repo_root, date=date)
    return 0


def resolve_date(arg: str) -> str:
    if arg == "yesterday":
        d = datetime.now(timezone.utc) - timedelta(days=1)
        return d.strftime("%Y-%m-%d")
    if arg == "today":
        return datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return arg


def resolve_date_range(anchor: str, days: int = 1) -> list[str]:
    if days < 1:
        raise ValueError(f"days must be >= 1, got {days}")
    end_dt = datetime.strptime(resolve_date(anchor), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    return [
        (end_dt - timedelta(days=offset)).strftime("%Y-%m-%d")
        for offset in range(days - 1, -1, -1)
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compact raw/<date>/data.tsv into compact/<model_id>/facts.tsv")
    parser.add_argument("--date", default="yesterday", help="YYYY-MM-DD, today, or yesterday")
    parser.add_argument(
        "--days",
        type=int,
        default=1,
        help="Compact N UTC calendar days ending at --date (inclusive; oldest first)",
    )
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument("--force", action="store_true", help="Re-process even if already ingested")
    parser.add_argument(
        "--all-models",
        action="store_true",
        help="Rewrite all compact/<model_id>/facts.tsv from entire raw tree",
    )
    parser.add_argument("--model-id", default=None, help="Compact one model_id only")
    args = parser.parse_args(argv)

    repo = args.repo_root or Path(
        os.environ.get("BENCH_WAREHOUSE_REPO", Path(__file__).resolve().parents[1])
    )

    if args.model_id:
        compact_model(repo, args.model_id)
        return 0

    if args.all_models:
        compact_all_models(repo)
        return 0

    dates = resolve_date_range(args.date, args.days)
    for date in dates:
        compact_date(repo, date, force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
