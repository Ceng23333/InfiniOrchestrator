"""Merge strategies for conflicting raw ingest data.tsv partitions."""

from __future__ import annotations

import argparse
import csv
import json
import subprocess
import sys
from pathlib import Path
from typing import Iterable

TSV = "\t"


def dedupe_key(row: dict[str, str]) -> tuple[str, str]:
    return (str(row.get("server_id", "")), str(row.get("started_at", "")))


def read_tsv_text(text: str) -> list[dict[str, str]]:
    text = text.strip()
    if not text:
        return []
    lines = text.splitlines()
    reader = csv.DictReader(lines, delimiter=TSV)
    return [dict(row) for row in reader]


def read_tsv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    return read_tsv_text(path.read_text(encoding="utf-8"))


def _columns_for_rows(*row_sets: Iterable[dict[str, str]]) -> list[str]:
    from bench_harness.registry import warehouse_facts_columns

    columns = list(warehouse_facts_columns())
    for rows in row_sets:
        for row in rows:
            for key in row:
                if key not in columns:
                    columns.append(key)
    return columns


def _row_rank(row: dict[str, str]) -> tuple[str, str]:
    return (str(row.get("finished_at", "")), str(row.get("started_at", "")))


def merge_data_tsv_rows(*row_sets: Iterable[dict[str, str]]) -> list[dict[str, str]]:
    """Union rows; dedupe by (server_id, started_at), keep latest finished_at."""
    merged: dict[tuple[str, str], dict[str, str]] = {}
    for rows in row_sets:
        for row in rows:
            key = dedupe_key(row)
            if not key[0] or not key[1]:
                continue
            prev = merged.get(key)
            if prev is None or _row_rank(row) >= _row_rank(prev):
                merged[key] = dict(row)
    return sorted(
        merged.values(),
        key=lambda r: (r.get("started_at", ""), r.get("server_id", "")),
    )


def write_tsv(path: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter=TSV, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def _git_show(stage: int, path: str, *, cwd: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "show", f":{stage}:{path}"],
            cwd=cwd,
            text=True,
        )
    except subprocess.CalledProcessError:
        return ""


def merge_data_tsv_from_git(path: str, *, repo_root: Path) -> list[dict[str, str]]:
    """Build merged rows from git merge stages (1=base, 2=ours, 3=theirs)."""
    sets: list[list[dict[str, str]]] = []
    for stage in (1, 2, 3):
        text = _git_show(stage, path, cwd=repo_root)
        if text.strip():
            sets.append(read_tsv_text(text))
    if not sets:
        return read_tsv(repo_root / path)
    return merge_data_tsv_rows(*sets)


def resolve_data_tsv_conflict(path: str, *, repo_root: Path) -> Path:
    rel = path
    full = repo_root / rel
    merged = merge_data_tsv_from_git(rel, repo_root=repo_root)
    columns = _columns_for_rows(merged)
    write_tsv(full, columns, merged)
    return full


def resolve_all_conflicts(*, repo_root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=U"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        check=False,
    )
    unresolved = [p.strip() for p in result.stdout.splitlines() if p.strip()]
    if not unresolved:
        return []

    resolved: list[str] = []
    for path in unresolved:
        if path.endswith("/data.tsv") or path.endswith("data.tsv"):
            resolve_data_tsv_conflict(path, repo_root=repo_root)
            subprocess.run(["git", "add", "--", path], cwd=repo_root, check=True)
            resolved.append(path)
        elif path.endswith("/manifest.json") or path.endswith("manifest.json"):
            subprocess.run(
                ["git", "checkout", "--theirs", "--", path],
                cwd=repo_root,
                check=True,
            )
            subprocess.run(["git", "add", "--", path], cwd=repo_root, check=True)
            resolved.append(path)
    return resolved


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Resolve ingest data.tsv merge conflicts")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_all = sub.add_parser("resolve-conflicts", help="Resolve all unmerged paths in repo")
    p_all.add_argument("--repo-root", type=Path, default=None)

    p_file = sub.add_parser("resolve-file", help="Resolve one data.tsv using git stages")
    p_file.add_argument("path", help="path to data.tsv under repo root")
    p_file.add_argument("--repo-root", type=Path, default=None)

    args = parser.parse_args(argv)
    repo = args.repo_root or Path(
        __import__("os").environ.get("BENCH_WAREHOUSE_REPO", Path(__file__).resolve().parents[1])
    )

    if args.cmd == "resolve-conflicts":
        paths = resolve_all_conflicts(repo_root=repo)
        if not paths:
            print("[merge_ingest] no unresolved conflicts", file=sys.stderr)
            return 1
        for path in paths:
            print(f"[merge_ingest] resolved {path}")
        remaining = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=U"],
            cwd=repo,
            capture_output=True,
            text=True,
            check=False,
        )
        if remaining.stdout.strip():
            print("[merge_ingest] unresolved paths remain:", file=sys.stderr)
            print(remaining.stdout, file=sys.stderr)
            return 1
        return 0

    if args.cmd == "resolve-file":
        out = resolve_data_tsv_conflict(args.path, repo_root=repo)
        rows = read_tsv(out)
        print(f"[merge_ingest] {out} ({len(rows)} rows)")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
