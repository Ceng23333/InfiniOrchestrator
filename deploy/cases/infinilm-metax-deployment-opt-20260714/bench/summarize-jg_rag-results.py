#!/usr/bin/env python3
"""
Aggregate jg_rag benchmark JSON results into a single markdown summary.

Designed to work with vLLM --save-result output (one JSON object per run).
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable


def _parse_datetime_from_date_str(date_str: str) -> datetime | None:
    """
    vLLM results commonly store:
      - date: 'YYYYMMDD-HHMMSS' (e.g. '20260326-205213')
    """
    if not date_str:
        return None
    date_str = date_str.strip()
    for fmt in ("%Y%m%d-%H%M%S", "%Y-%m-%d_%H%M%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(date_str, fmt)
        except ValueError:
            pass
    return None


def _format_duration(seconds: float | int | None) -> str:
    if seconds is None:
        return "N/A"
    try:
        s = float(seconds)
    except (TypeError, ValueError):
        return "N/A"
    if s >= 60:
        return f"{s / 60:.1f} min"
    return f"{s:.2f} s"


def _safe_get(d: dict[str, Any], key: str) -> Any:
    return d.get(key, None)


@dataclass(frozen=True)
class Run:
    path: Path
    payload: dict[str, Any]
    sort_dt: datetime
    sort_label: str  # formatted date for display


def _iter_result_json_files(results_dir: Path, pattern: str) -> Iterable[Path]:
    # Keep deterministic ordering for stable markdown output.
    yield from sorted(results_dir.glob(pattern))


def _load_json_object(path: Path) -> dict[str, Any] | None:
    try:
        with path.open("r", encoding="utf-8") as f:
            obj = json.load(f)
        if isinstance(obj, dict):
            return obj
    except Exception:
        return None
    return None


def _extract_runs(
    results_dir: Path,
    pattern: str,
    label: str | None,
) -> tuple[list[Run], set[str]]:
    label_set: set[str] = set()
    runs: list[Run] = []

    for p in _iter_result_json_files(results_dir, pattern):
        obj = _load_json_object(p)
        if not obj:
            continue

        obj_label = str(obj.get("label", "")).strip()
        if obj_label:
            label_set.add(obj_label)

        if label is not None:
            # Primary filter: JSON field.
            if obj_label != label:
                continue

        date_str = str(obj.get("date", "")).strip()
        dt = _parse_datetime_from_date_str(date_str)
        if dt is None:
            # Fall back to file mtime so that "Latest" is still meaningful.
            try:
                dt = datetime.fromtimestamp(p.stat().st_mtime)
            except OSError:
                dt = datetime.min

        sort_label = date_str or dt.strftime("%Y-%m-%d %H:%M:%S")

        runs.append(Run(path=p, payload=obj, sort_dt=dt, sort_label=sort_label))

    # Sort by datetime to make "Latest" deterministic.
    runs.sort(key=lambda r: (r.sort_dt, r.path.name))
    return runs, label_set


def _pick_effective_label(runs: list[Run], label_set: set[str], requested: str | None) -> str:
    if requested:
        return requested
    if len(label_set) == 1:
        return next(iter(label_set))
    if not label_set and runs:
        # Very unlikely, but keep something usable.
        return str(runs[0].payload.get("label", "unknown")).strip() or "unknown"
    # If multiple labels exist and user didn't specify, we no longer error out.
    # Callers can choose to render a combined report.
    return ""


def _format_value(v: Any) -> str:
    if v is None:
        return "N/A"
    if isinstance(v, float):
        # Keep lots of metrics readable but stable.
        return f"{v:.6g}"
    return str(v)


def _metrics_table_rows(payload: dict[str, Any]) -> list[tuple[str, str]]:
    completed = payload.get("completed", None)
    failed = payload.get("failed", None)
    total = None
    try:
        if completed is not None or failed is not None:
            total = float(completed or 0) + float(failed or 0)
    except (TypeError, ValueError):
        total = None

    success_rate = None
    if total and total > 0:
        try:
            success_rate = (float(completed or 0) / total) * 100.0
        except (TypeError, ValueError):
            success_rate = None

    return [
        ("Completed", _format_value(completed)),
        ("Failed", _format_value(failed)),
        ("Success Rate", f"{success_rate:.2f}%" if success_rate is not None else "N/A"),
        ("Duration", _format_duration(payload.get("duration", None))),
        ("Mean TTFT (ms)", _format_value(payload.get("mean_ttft_ms", None))),
        ("Median TTFT (ms)", _format_value(payload.get("median_ttft_ms", None))),
        ("P99 TTFT (ms)", _format_value(payload.get("p99_ttft_ms", None))),
        ("Mean TPOT (ms)", _format_value(payload.get("mean_tpot_ms", None))),
        ("Median TPOT (ms)", _format_value(payload.get("median_tpot_ms", None))),
        ("P99 TPOT (ms)", _format_value(payload.get("p99_tpot_ms", None))),
        ("Output Throughput (tok/s)", _format_value(payload.get("output_throughput", None))),
        ("Total Token Throughput (tok/s)", _format_value(payload.get("total_token_throughput", None))),
    ]


def _render_markdown(
    label: str,
    runs: list[Run],
    output_filename: str,
) -> str:
    header = [
        "# jg_rag Benchmark Results Summary",
        "",
        f"Benchmark label: `{label}`",
        f"Result files: {len(runs)}",
        "",
    ]

    if not runs:
        header.extend(
            [
                "## No Results Found",
                "",
                f"No JSON results matched the given pattern. Output path: `{output_filename}`",
                "",
            ]
        )
        return "\n".join(header)

    latest = runs[-1]
    latest_name = latest.path.name

    sections: list[str] = []
    sections.append(f"## Results Overview (Latest: {latest.sort_label}; `{latest_name}`)")
    sections.append("")
    sections.append("| Metric | Value |")
    sections.append("| --- | --- |")
    for k, v in _metrics_table_rows(latest.payload):
        sections.append(f"| **{k}** | {v} |")
    sections.append("")

    # Always list all run files to make it easy to find the raw data.
    sections.append("## Result Files")
    sections.append("")
    sections.append("| Date | File |")
    sections.append("| --- | --- |")
    for r in runs:
        sections.append(f"| {r.sort_label} | `{r.path.name}` |")
    sections.append("")

    # If multiple runs exist, add a compact "Latest" recap already above; keep the rest simple.
    return "\n".join(header + sections)


def _render_markdown_multi(
    labels: list[str],
    runs_all: list[Run],
    output_filename: str,
) -> str:
    header = [
        "# jg_rag Benchmark Results Summary",
        "",
        f"Result files: {len(runs_all)}",
        "",
    ]
    if not runs_all:
        header.extend(
            [
                "## No Results Found",
                "",
                f"No JSON results matched the given pattern. Output path: `{output_filename}`",
                "",
            ]
        )
        return "\n".join(header)

    body: list[str] = []
    body.append("## Labels")
    body.append("")
    for lb in labels:
        body.append(f"- `{lb}`")
    body.append("")

    # Group runs by label and render each section.
    for lb in labels:
        group = [r for r in runs_all if str(r.payload.get("label", "")).strip() == lb]
        if not group:
            continue
        # Reuse the single-label renderer and just splice out the global header.
        md = _render_markdown(label=lb, runs=group, output_filename=output_filename)
        # Drop the first header block (first 4 lines) to avoid repeated H1.
        md_lines = md.splitlines()
        body.append(f"## Label: `{lb}`")
        body.append("")
        body.extend(md_lines[4:])
        body.append("")

    return "\n".join(header + body)


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    case_dir = script_dir.parent
    default_results_dir = case_dir / "results"
    default_output = default_results_dir / "jg_rag-benchmark-summary.md"

    parser = argparse.ArgumentParser(
        description="Aggregate jg_rag benchmark JSON results into a markdown summary."
    )
    parser.add_argument("--results-dir", default=str(default_results_dir), help="Path to case results/")
    parser.add_argument("--output", default=str(default_output), help="Markdown output file")
    parser.add_argument("--pattern", default="jg_rag-*.json", help="Glob pattern under results-dir")
    parser.add_argument("--label", default=None, help="Filter by JSON field 'label'")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    output_path = Path(args.output)

    if not results_dir.is_dir():
        print(f"Error: results dir does not exist: {results_dir}", file=sys.stderr)
        return 2

    runs, label_set = _extract_runs(
        results_dir=results_dir,
        pattern=args.pattern,
        label=args.label,
    )

    effective_label = _pick_effective_label(runs=runs, label_set=label_set, requested=args.label)
    if args.label or (effective_label and effective_label.strip()):
        md = _render_markdown(
            label=effective_label or (args.label or "unknown"),
            runs=runs,
            output_filename=str(output_path),
        )
    else:
        md = _render_markdown_multi(
            labels=sorted(label_set),
            runs_all=runs,
            output_filename=str(output_path),
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(md, encoding="utf-8")

    print(f"Wrote summary: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
