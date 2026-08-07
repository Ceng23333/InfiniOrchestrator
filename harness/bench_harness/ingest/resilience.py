"""Resilience family ingest (unexpected_behavior__)."""

from __future__ import annotations

from pathlib import Path

from bench_harness.ingest.parsers import parse_raw_partition


def parse_partition(
    repo_root: Path,
    platform: str,
    bench_id: str,
    date: str,
) -> list[dict[str, str]]:
    return parse_raw_partition(repo_root, platform, bench_id, date)
