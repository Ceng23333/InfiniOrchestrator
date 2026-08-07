"""Parse raw/<YYYY-MM-DD>/data.tsv and legacy deep partitions."""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any

from bench_harness.partition import (
    glob_legacy_raw_partitions,
    glob_raw_date_dirs,
    hw_profile_json,
)
from bench_harness.registry import FRONTEND_METADATA_KEY, bench_family


def read_data_tsv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        return [dict(row) for row in reader]


def read_manifest(raw_dir: Path) -> dict[str, Any]:
    path = raw_dir / "manifest.json"
    if not path.is_file():
        raise FileNotFoundError(f"missing manifest: {path}")
    return json.loads(path.read_text(encoding="utf-8"))


def load_legacy_raw_partition(raw_dir: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    manifest = read_manifest(raw_dir)
    rows = read_data_tsv(raw_dir / "data.tsv")
    return manifest, rows


def flatten_row(manifest: dict[str, Any], row: dict[str, str]) -> dict[str, str]:
    """Merge legacy manifest metadata with a data.tsv row."""
    bench_id = manifest.get("bench_id", "")
    bench = manifest.get("bench", "")
    if not bench:
        from bench_harness.partition import parse_bench_model

        bench, _ = parse_bench_model(bench_id, row.get("model", ""))
    out: dict[str, str] = {
        "bench_id": bench_id,
        "bench": bench,
        "model": manifest.get("model", row.get("model", "")),
        FRONTEND_METADATA_KEY: manifest.get(FRONTEND_METADATA_KEY, row.get(FRONTEND_METADATA_KEY, "")),
        "bench_family": manifest.get("bench_family", bench_family(bench_id)),
        "platform": manifest.get("platform", row.get("platform", "")),
        "date": manifest.get("date", ""),
        "hw_profile": manifest.get("hw_profile", ""),
        "model_id": manifest.get("model_id", row.get("model_id", manifest.get("model", row.get("model", "")))),
    }
    if isinstance(out["hw_profile"], dict):
        out["hw_profile"] = json.dumps(out["hw_profile"], sort_keys=True, separators=(",", ":"))
    if not out["hw_profile"]:
        merged = dict(row)
        merged.setdefault("platform", out["platform"])
        out["hw_profile"] = hw_profile_json(merged)
    for key, val in row.items():
        out[key] = val
    if not out.get("model_id"):
        out["model_id"] = out.get("model", "")
    return out


def parse_raw_rows_for_date(repo_root: Path, date: str) -> list[dict[str, str]]:
    """Read flat ``raw/<date>/data.tsv`` plus legacy deep partitions for ``date``."""
    rows: list[dict[str, str]] = []

    for date_dir in glob_raw_date_dirs(repo_root, date):
        rows.extend(read_data_tsv(date_dir / "data.tsv"))

    for legacy_dir in glob_legacy_raw_partitions(repo_root, date):
        manifest, part_rows = load_legacy_raw_partition(legacy_dir)
        rows.extend(flatten_row(manifest, row) for row in part_rows)

    return rows
