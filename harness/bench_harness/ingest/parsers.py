"""Family dispatch for raw partition parsers."""

from __future__ import annotations

from pathlib import Path

from bench_harness.ingest import parse_raw_rows_for_date, read_data_tsv
from bench_harness.partition import glob_raw_harness_files, slugify_segment
from bench_harness.registry import bench_family, suite_prefix


def parse_raw_partition_path(tsv_path: Path) -> list[dict[str, str]]:
    """Load rows from one harness ``*.tsv`` path."""
    return read_data_tsv(tsv_path)


def parse_raw_partition(
    repo_root: Path,
    platform: str,
    bench_id: str,
    date: str,
) -> list[dict[str, str]]:
    """Locate rows for ``bench_id`` (+ optional platform) on ``date``."""
    harness = slugify_segment(suite_prefix(bench_id))
    out: list[dict[str, str]] = []

    for path in glob_raw_harness_files(repo_root, date):
        if path.stem != harness:
            continue
        for row in parse_raw_partition_path(path):
            if row.get("bench_id") != bench_id:
                continue
            plat = row.get("platform", "")
            if platform and plat and plat != platform:
                continue
            out.append(row)
    if out:
        return out

    # Fallback: scan all harness files for the date.
    for row in parse_raw_rows_for_date(repo_root, date):
        if row.get("bench_id") != bench_id:
            continue
        plat = row.get("platform", "")
        if platform and plat and plat != platform:
            continue
        out.append(row)
    return out


def parse_raw_partition_by_family(
    repo_root: Path,
    platform: str,
    bench_id: str,
    date: str,
) -> list[dict[str, str]]:
    _ = bench_family(bench_id)
    return parse_raw_partition(repo_root, platform, bench_id, date)
