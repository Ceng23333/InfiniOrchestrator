"""Path builders for flat raw/<date>/<harness>.tsv and compact/ warehouse layout."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from infinimetadata.frontend import FRONTEND_METADATA_KEY
from infinimetadata.frontend import frontend_path_part as _im_frontend_path_part

from bench_harness.registry import suite_prefix

HW_PROFILE_COLUMNS = ["platform", "arch", "gpu_model", "gpu_driver"]

_HARNESS_FRONTEND_EXTRA = frozenset({"vLLM", "OpenAI"})

MODEL_IN_BENCH_ID_PREFIXES = frozenset(
    {
        "random-fixed-length",
        "ceval",
        "longbench_v2",
        "mctracer_throughput",
        "validation",
    }
)

RAW_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")

# raw/<YYYY-MM-DD>/<harness>.tsv  (harness = suite_prefix / slug; not data.tsv)
INGEST_FILE_RE = re.compile(
    r"^raw/[0-9]{4}-[0-9]{2}-[0-9]{2}/(?!data\.tsv$)[A-Za-z0-9][A-Za-z0-9._-]*\.tsv$"
)


def slugify_segment(value: str) -> str:
    """Filesystem-safe path segment; empty → ``_unknown``."""
    text = str(value or "").strip()
    if not text:
        return "_unknown"
    text = text.replace("/", "_").replace("\\", "_")
    text = re.sub(r"[\x00-\x1f]", "", text)
    return text or "_unknown"


def frontend_path_part(value: str) -> str:
    """Filesystem path segment for frontend; empty or invalid → ``_unknown``."""
    text = str(value or "").strip()
    part = _im_frontend_path_part(text)
    if part != "_unknown":
        return part
    if text in _HARNESS_FRONTEND_EXTRA:
        return text
    return "_unknown"


def frontend_path_part_from_row(row: dict[str, Any]) -> str:
    return frontend_path_part(str(row.get(FRONTEND_METADATA_KEY, "") or ""))


def parse_bench_model(bench_id: str, row_model: str) -> tuple[str, str]:
    """Split ``bench_id`` into ``(bench, model)`` segments."""
    prefix = suite_prefix(bench_id)
    if prefix in MODEL_IN_BENCH_ID_PREFIXES and "__" in bench_id:
        return prefix, bench_id.split("__", 1)[1]
    model = (row_model or "").strip()
    if not model:
        raise ValueError(f"model required for bench_id={bench_id!r}")
    return bench_id, model


def hw_profile_dict(row: dict[str, Any]) -> dict[str, str]:
    return {col: str(row.get(col, "") or "") for col in HW_PROFILE_COLUMNS}


def hw_profile_path_parts(row: dict[str, Any]) -> list[str]:
    return [slugify_segment(hw_profile_dict(row)[col]) for col in HW_PROFILE_COLUMNS]


def hw_profile_json(row: dict[str, Any]) -> str:
    return json.dumps(hw_profile_dict(row), sort_keys=True, separators=(",", ":"))


def raw_dir(repo_root: Path, date: str) -> Path:
    """``raw/<YYYY-MM-DD>/`` date partition."""
    if not RAW_DATE_RE.match(date):
        raise ValueError(f"invalid raw date partition: {date!r}")
    return repo_root / "raw" / date


def raw_data_path(repo_root: Path, date: str, harness: str) -> Path:
    """``raw/<YYYY-MM-DD>/<harness>.tsv`` for one suite_prefix family file."""
    return raw_dir(repo_root, date) / f"{slugify_segment(harness)}.tsv"


def compact_dir(repo_root: Path, model_id: str) -> Path:
    """``compact/<model_id>/`` compact partition."""
    return repo_root / "compact" / slugify_segment(model_id)


def compact_facts_path(repo_root: Path, model_id: str) -> Path:
    return compact_dir(repo_root, model_id) / "facts.tsv"


def processed_keys_path(repo_root: Path) -> Path:
    return repo_root / "compact" / "processed_raw_dates.jsonl"


def date_from_row(row: dict[str, Any]) -> str:
    started_at = str(row.get("started_at", ""))
    if len(started_at) >= 10 and RAW_DATE_RE.match(started_at[:10]):
        return started_at[:10]
    date = str(row.get("date", "") or "")
    if RAW_DATE_RE.match(date):
        return date
    raise ValueError(f"started_at or date required for partition: started_at={started_at!r}")


def model_id_from_row(row: dict[str, Any]) -> str:
    mid = str(row.get("model_id", "") or row.get("model", "") or "").strip()
    if not mid:
        raise ValueError("model_id or model required on row")
    return mid


def raw_ingest_key(date: str, harness: str) -> str:
    return f"raw/{date}/{slugify_segment(harness)}.tsv"


def harness_from_bench_id(bench_id: str) -> str:
    """Filesystem harness slug = ``suite_prefix(bench_id)``."""
    return slugify_segment(suite_prefix(bench_id))


def glob_raw_harness_files(repo_root: Path, date: str | None = None) -> list[Path]:
    """Return ``raw/<YYYY-MM-DD>/<harness>.tsv`` paths (not ``data.tsv``)."""
    raw_root = repo_root / "raw"
    if not raw_root.is_dir():
        return []
    found: list[Path] = []
    for child in sorted(raw_root.iterdir()):
        if not child.is_dir():
            continue
        if not RAW_DATE_RE.match(child.name):
            continue
        if date is not None and child.name != date:
            continue
        for tsv in sorted(child.glob("*.tsv")):
            if tsv.name == "data.tsv":
                continue
            if INGEST_FILE_RE.match(f"raw/{child.name}/{tsv.name}"):
                found.append(tsv)
    return found


def glob_raw_date_dirs(repo_root: Path, date: str | None = None) -> list[Path]:
    """Return flat ``raw/<YYYY-MM-DD>/`` dirs that contain at least one harness ``*.tsv``."""
    dates = {p.parent for p in glob_raw_harness_files(repo_root, date)}
    return sorted(dates, key=lambda p: p.name)


def glob_compact_facts(
    repo_root: Path,
    *,
    model_id: str | None = None,
) -> list[Path]:
    """Return ``compact/<model_id>/facts.tsv`` paths."""
    compact_root = repo_root / "compact"
    if not compact_root.is_dir():
        return []
    paths: list[Path] = []
    for facts in sorted(compact_root.rglob("facts.tsv")):
        rel = facts.parent.relative_to(compact_root)
        if len(rel.parts) != 1:
            continue
        if model_id is not None and rel.parts[0] != slugify_segment(model_id):
            continue
        paths.append(facts)
    return paths


def glob_compact_model_ids(repo_root: Path) -> list[str]:
    return sorted({p.parent.name for p in glob_compact_facts(repo_root)})
