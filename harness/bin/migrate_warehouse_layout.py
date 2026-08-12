#!/usr/bin/env python3
"""Split flat raw/<date>/data.tsv into per-harness raw/<date>/<suite_prefix>.tsv."""

from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import defaultdict
from pathlib import Path

from bench_warehouse.compact import compact_all_models, ingest_keys_for_date, reset_processed_keys
from bench_warehouse.ingest import read_data_tsv
from bench_warehouse.partition import (
    RAW_DATE_RE,
    glob_raw_date_dirs,
    raw_data_path,
    slugify_segment,
)
from bench_warehouse.registry import harness_raw_columns, suite_prefix

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


def _assert_no_deep_raw(repo_root: Path) -> None:
    raw_root = repo_root / "raw"
    if not raw_root.is_dir():
        return
    deep: list[str] = []
    for child in sorted(raw_root.iterdir()):
        if not child.is_dir():
            continue
        if RAW_DATE_RE.match(child.name):
            continue
        if child.name.startswith("."):
            continue
        deep.append(child.name)
    if deep:
        raise SystemExit(
            "ERROR: deep legacy raw/ trees still present (not migrated):\n  "
            + "\n  ".join(deep)
            + "\nDelete them before splitting flat data.tsv → per-harness files."
        )


def split_flat_data_tsv(
    repo_root: Path,
    date: str | None = None,
    *,
    dry_run: bool = False,
) -> dict[str, dict[str, int]]:
    """Split ``raw/<date>/data.tsv`` into ``raw/<date>/<suite_prefix>.tsv``."""
    _assert_no_deep_raw(repo_root)
    raw_root = repo_root / "raw"
    if not raw_root.is_dir():
        print("[migrate] no raw/ directory")
        return {}

    date_dirs: list[Path] = []
    for child in sorted(raw_root.iterdir()):
        if not child.is_dir() or not RAW_DATE_RE.match(child.name):
            continue
        if date is not None and child.name != date:
            continue
        if (child / "data.tsv").is_file():
            date_dirs.append(child)

    if not date_dirs:
        print("[migrate] no flat raw/<date>/data.tsv files found")
        return {}

    counts: dict[str, dict[str, int]] = {}
    for date_dir in date_dirs:
        flat = date_dir / "data.tsv"
        rows = read_data_tsv(flat)
        by_harness: dict[str, list[dict[str, str]]] = defaultdict(list)
        for row in rows:
            bench_id = str(row.get("bench_id", "") or "")
            if not bench_id:
                raise SystemExit(f"ERROR: row missing bench_id in {flat}")
            harness = slugify_segment(suite_prefix(bench_id))
            by_harness[harness].append(row)

        counts[date_dir.name] = {}
        for harness, harness_rows in sorted(by_harness.items()):
            target = raw_data_path(repo_root, date_dir.name, harness)
            existing = read_data_tsv(target) if target.is_file() else []
            merged = _merge_rows(existing, harness_rows)
            # Use first row's bench_id for column family (same suite_prefix).
            sample_bench = merged[0].get("bench_id") or harness
            columns = harness_raw_columns(sample_bench)
            counts[date_dir.name][harness] = len(harness_rows)
            if dry_run:
                print(
                    f"[migrate] would write {target} "
                    f"({len(merged)} rows, +{len(harness_rows)} from data.tsv)"
                )
                continue
            _write_tsv(target, merged, columns)
            print(f"[migrate] wrote {target} ({len(merged)} rows)")

        if dry_run:
            print(f"[migrate] would remove {flat}")
        else:
            flat.unlink()
            print(f"[migrate] removed {flat}")

    return counts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Split flat raw/<date>/data.tsv into per-harness .tsv files"
    )
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument("--date", default=None, help="Limit to one YYYY-MM-DD date dir")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-compact", action="store_true")
    args = parser.parse_args(argv)

    repo = args.repo_root
    if repo is None:
        env = os.environ.get("BENCH_WAREHOUSE_REPO", "").strip()
        if env:
            repo = Path(env)
        else:
            # Script lives at <warehouse>/harness/bin/migrate_warehouse_layout.py
            repo = Path(__file__).resolve().parents[2]
    if not repo.is_dir():
        print(f"ERROR: repo not found: {repo}", file=sys.stderr)
        return 1

    (repo / "raw").mkdir(parents=True, exist_ok=True)
    (repo / "compact").mkdir(parents=True, exist_ok=True)

    try:
        split_flat_data_tsv(repo, args.date, dry_run=args.dry_run)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if not args.skip_compact and not args.dry_run:
        print("[migrate] compacting all model_id partitions …")
        compact_all_models(repo)
        keys: list[str] = []
        for date_dir in glob_raw_date_dirs(repo):
            keys.extend(ingest_keys_for_date(repo, date_dir.name))
        reset_processed_keys(repo, keys)
        print(f"[migrate] processed keys reset ({len(keys)} file(s))")

    flat_dates = glob_raw_date_dirs(repo)
    print(f"[migrate] harness raw date dirs: {len(flat_dates)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
