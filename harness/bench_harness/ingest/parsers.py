"""Family dispatch for raw partition parsers."""

from __future__ import annotations

from pathlib import Path

from bench_harness.ingest import flatten_row, load_legacy_raw_partition, parse_raw_rows_for_date
from bench_harness.partition import glob_legacy_raw_partitions, glob_raw_partitions
from bench_harness.registry import bench_family


def parse_raw_partition_path(raw_dir: Path) -> list[dict[str, str]]:
    data_path = raw_dir / "data.tsv"
    if not data_path.is_file():
        return []
    manifest_path = raw_dir / "manifest.json"
    if manifest_path.is_file():
        manifest, rows = load_legacy_raw_partition(raw_dir)
        return [flatten_row(manifest, row) for row in rows]
    from bench_harness.ingest import read_data_tsv

    return read_data_tsv(data_path)


def parse_raw_partition(
    repo_root: Path,
    platform: str,
    bench_id: str,
    date: str,
) -> list[dict[str, str]]:
    """Locate rows for ``bench_id`` (+ optional platform) on ``date``."""
    rows = parse_raw_rows_for_date(repo_root, date)
    out: list[dict[str, str]] = []
    for row in rows:
        if row.get("bench_id") != bench_id:
            continue
        plat = row.get("platform", "")
        if platform and plat and plat != platform:
            continue
        out.append(row)
    if out:
        return out

    for raw_dir in glob_raw_partitions(repo_root, date):
        part_rows = parse_raw_partition_path(raw_dir)
        for row in part_rows:
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
