"""Parse raw/<YYYY-MM-DD>/<harness>.tsv ingest files."""

from __future__ import annotations

import csv
from pathlib import Path

from bench_harness.partition import glob_raw_harness_files


def read_data_tsv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        return [dict(row) for row in reader]


def parse_raw_rows_for_date(repo_root: Path, date: str) -> list[dict[str, str]]:
    """Read all ``raw/<date>/<harness>.tsv`` files for ``date``."""
    rows: list[dict[str, str]] = []
    for path in glob_raw_harness_files(repo_root, date):
        rows.extend(read_data_tsv(path))
    return rows
