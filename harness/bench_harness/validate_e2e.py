"""E2E validation assertions for warehouse pipeline gate."""

from __future__ import annotations

import argparse
import csv
import os
import sys
from pathlib import Path

from bench_harness.ingest import parse_raw_rows_for_date
from bench_harness.partition import compact_facts_path, glob_compact_facts


def _read_tsv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh, delimiter="\t"))


def validate(
    repo_root: Path,
    date: str,
    expect_bench_ids: list[str],
    expect_model: str,
    expect_platform: str,
) -> list[str]:
    errors: list[str] = []

    raw_rows = parse_raw_rows_for_date(repo_root, date)
    raw_by_bench: dict[str, list[dict[str, str]]] = {}
    for row in raw_rows:
        bid = row.get("bench_id", "")
        if bid:
            raw_by_bench.setdefault(bid, []).append(row)

    for bench_id in expect_bench_ids:
        rows = raw_by_bench.get(bench_id, [])
        if not rows:
            errors.append(f"missing raw rows for bench_id={bench_id} date={date}")
            continue

        for row in rows:
            if row.get("model") != expect_model and row.get("model_id") != expect_model:
                errors.append(f"{bench_id}: model={row.get('model')} != {expect_model}")
            if not row.get("server_id"):
                errors.append(f"{bench_id}: missing server_id")
            if not row.get("started_at"):
                errors.append(f"{bench_id}: missing started_at")
            if row.get("gate_pass") != "1":
                errors.append(f"{bench_id}: gate_pass != 1 (status={row.get('status')})")
            if not row.get("image_tag"):
                errors.append(f"{bench_id}: missing image_tag")
            if not row.get("host_id"):
                errors.append(f"{bench_id}: missing host_id")
            if row.get("platform") != expect_platform:
                errors.append(f"{bench_id}: platform={row.get('platform')} != {expect_platform}")

        keys = [(r.get("server_id"), r.get("started_at")) for r in rows]
        if len(keys) != len(set(keys)):
            errors.append(f"{bench_id}: duplicate (server_id, started_at) in raw data")

    compact_path = compact_facts_path(repo_root, expect_model)
    facts = _read_tsv(compact_path)
    if not facts:
        errors = errors or []
        errors.append(f"missing compact facts for model={expect_model} at {compact_path}")

    fact_bench_ids = {r.get("bench_id") for r in facts}
    for bench_id in expect_bench_ids:
        if bench_id not in fact_bench_ids:
            errors.append(f"compact facts missing bench_id={bench_id}")

    matching_facts = [r for r in facts if r.get("bench_id") in expect_bench_ids]
    if len(matching_facts) < len(expect_bench_ids):
        errors.append(
            f"compact facts has {len(matching_facts)} rows for expected ids, want {len(expect_bench_ids)}"
        )

    for row in matching_facts:
        if row.get("bench_family") != "resilience":
            errors.append(f"compact facts {row.get('bench_id')}: bench_family != resilience")
        if not row.get("gpu_model") and not row.get("host_id"):
            errors.append(f"compact facts {row.get('bench_id')}: host cols empty")

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate warehouse E2E artifacts")
    parser.add_argument("--date", required=True)
    parser.add_argument("--expect-bench-ids", required=True, help="comma-separated")
    parser.add_argument("--expect-model", required=True)
    parser.add_argument("--expect-platform", default="hpcc")
    parser.add_argument("--repo-root", type=Path, default=None)
    args = parser.parse_args(argv)

    repo = args.repo_root or Path(
        os.environ.get("BENCH_WAREHOUSE_REPO", Path(__file__).resolve().parents[1])
    )
    bench_ids = [b.strip() for b in args.expect_bench_ids.split(",") if b.strip()]
    errors = validate(repo, args.date, bench_ids, args.expect_model, args.expect_platform)

    if errors:
        print("[validate_e2e] FAIL:")
        for e in errors:
            print(f"  - {e}")
        return 1

    print("[validate_e2e] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
