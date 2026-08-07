#!/usr/bin/env python3
"""Migrate legacy deep raw/ + warehouse/ layout to flat raw/<date> + compact/<model_id>."""

from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import defaultdict
from pathlib import Path

from bench_harness.compact import compact_all_models
from bench_harness.ingest import flatten_row, load_legacy_raw_partition, read_data_tsv
from bench_harness.partition import (
    glob_legacy_raw_partitions,
    glob_raw_date_dirs,
    legacy_raw_dir,
    raw_data_path,
)
from bench_harness.registry import warehouse_facts_columns

TSV = "\t"


def _dedupe_key(row: dict[str, str]) -> tuple[str, str]:
    return (str(row.get("server_id", "")), str(row.get("started_at", "")))


def _write_tsv(path: Path, rows: list[dict[str, str]], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter=TSV, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def _merge_rows(existing: list[dict[str, str]], new_rows: list[dict[str, str]]) -> list[dict[str, str]]:
    merged: dict[tuple[str, str], dict[str, str]] = {}
    for row in existing + new_rows:
        key = _dedupe_key(row)
        if key[0] and key[1]:
            merged[key] = row
    return sorted(merged.values(), key=lambda r: (r.get("started_at", ""), r.get("server_id", "")))


def collect_legacy_rows(repo_root: Path) -> dict[str, list[dict[str, str]]]:
    by_date: dict[str, list[dict[str, str]]] = defaultdict(list)
    for legacy_dir in glob_legacy_raw_partitions(repo_root):
        manifest, part_rows = load_legacy_raw_partition(legacy_dir)
        date = legacy_dir.name
        for row in part_rows:
            by_date[date].append(flatten_row(manifest, row))
    return by_date


def migrate_raw(repo_root: Path, *, dry_run: bool = False) -> dict[str, int]:
    """Flatten legacy deep raw partitions into ``raw/<date>/data.tsv``."""
    by_date = collect_legacy_rows(repo_root)
    counts: dict[str, int] = {}
    columns = warehouse_facts_columns()

    for date, legacy_rows in sorted(by_date.items()):
        target = raw_data_path(repo_root, date)
        existing = read_data_tsv(target) if target.is_file() else []
        merged = _merge_rows(existing, legacy_rows)
        counts[date] = len(legacy_rows)
        if dry_run:
            print(f"[migrate] would write {target} ({len(merged)} rows, +{len(legacy_rows)} legacy)")
            continue
        _write_tsv(target, merged, columns)
        print(f"[migrate] wrote {target} ({len(merged)} rows)")

    if not by_date:
        print("[migrate] no legacy raw partitions found")
    return counts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Migrate bench-warehouse to flat raw + compact layout")
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-compact", action="store_true")
    args = parser.parse_args(argv)

    repo = args.repo_root or Path(
        os.environ.get("BENCH_WAREHOUSE_REPO", Path(__file__).resolve().parents[1])
    )
    if not repo.is_dir():
        print(f"ERROR: repo not found: {repo}", file=sys.stderr)
        return 1

    (repo / "raw").mkdir(parents=True, exist_ok=True)
    (repo / "compact").mkdir(parents=True, exist_ok=True)

    migrate_raw(repo, dry_run=args.dry_run)

    if not args.skip_compact and not args.dry_run:
        print("[migrate] compacting all model_id partitions …")
        compact_all_models(repo)

    legacy_wh = repo / "warehouse"
    if legacy_wh.is_dir():
        print(f"[migrate] legacy warehouse/ retained at {legacy_wh} (not regenerated)")

    flat_dates = glob_raw_date_dirs(repo)
    print(f"[migrate] flat raw date dirs: {len(flat_dates)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
