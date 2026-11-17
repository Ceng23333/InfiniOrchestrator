"""Compact warehouse emit for promo-facts-1 rows."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from adapters.promo_facts.parser_path import load_parser


PROMO_METRIC_KEYS = [
	"schema_version",
	"campaign_id",
	"iter",
	"host",
	"device_track",
	"vendor_profiler",
	"hw_profile_id",
	"hw_abbr",
	"case_id_baseline",
	"case_id_candidate",
	"be_abbr_baseline",
	"be_abbr_candidate",
	"pin_baseline",
	"pin_candidate",
	"primary_metric",
	"primary_ratio",
	"primary_gate",
	"profiled",
	"top_path",
	"surpass",
	"promo_payload",
]


def _utc_now() -> str:
	return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _primary_wall(iter_obj: Dict[str, Any]) -> Dict[str, Any]:
	parser = load_parser()
	wall = parser.primary_wall(iter_obj) or {}
	return wall


def iter_rows_from_document(doc: Dict[str, Any]) -> List[Dict[str, Any]]:
	rows: List[Dict[str, Any]] = []
	schema = str(doc.get("schema_version") or "promo-facts-1")
	for camp in doc.get("campaigns") or []:
		for it in camp.get("iters") or []:
			wall = _primary_wall(it)
			backlog = it.get("backlog") or {}
			ship = it.get("ship") or {}
			payload = {
				"campaign": {k: v for k, v in camp.items() if k != "iters"},
				"iter": it,
			}
			row = {
				"schema_version": schema,
				"campaign_id": camp.get("campaign_id", ""),
				"iter": str(it.get("iter", "")),
				"host": camp.get("host", ""),
				"device_track": camp.get("device_track", ""),
				"vendor_profiler": camp.get("vendor_profiler", ""),
				"hw_profile_id": camp.get("hw_profile_id", ""),
				"hw_abbr": camp.get("hw_abbr", ""),
				"case_id_baseline": camp.get("case_id_baseline", ""),
				"case_id_candidate": camp.get("case_id_candidate", ""),
				"be_abbr_baseline": camp.get("be_abbr_baseline", ""),
				"be_abbr_candidate": camp.get("be_abbr_candidate", ""),
				"pin_baseline": camp.get("pin_baseline", ""),
				"pin_candidate": camp.get("pin_candidate", ""),
				"primary_metric": wall.get("metric", ""),
				"primary_ratio": ""
				if wall.get("WALL_DECODE_RATIO") is None
				else str(wall.get("WALL_DECODE_RATIO")),
				"primary_gate": wall.get("gate", ""),
				"profiled": "1" if it.get("profiled") else "0",
				"top_path": backlog.get("top_path", ""),
				"surpass": "1" if ship.get("surpass") else "0",
				"promo_payload": json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
				"status": wall.get("gate") or "UNKNOWN",
				"model": camp.get("case_id_candidate") or camp.get("campaign_id") or "",
				"model_id": camp.get("case_id_candidate") or camp.get("campaign_id") or "",
			}
			rows.append(row)
	return rows


def write_staging(staging_dir: Path, rows: List[Dict[str, Any]]) -> Path:
	staging_dir.mkdir(parents=True, exist_ok=True)
	# One metrics JSON per emit batch; emit loop uses each row via --metrics-json.
	batch_path = staging_dir / "promo_facts_rows.json"
	batch_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
	(staging_dir / "summary.md").write_text(
		f"- started: {_utc_now()}\n- suite: promo_facts\n- rows: {len(rows)}\n",
		encoding="utf-8",
	)
	return batch_path


def emit_rows(
	rows: List[Dict[str, Any]],
	*,
	staging_dir: Path,
	repo_root: Path,
	server_id: str,
	host_id: str,
	platform: str,
	bench_id: str,
	dedupe: bool = True,
) -> List[Path]:
	from bench_warehouse.emit import append_row, build_row_from_staging

	written: List[Path] = []
	for i, metrics in enumerate(rows):
		row_staging = staging_dir / f"row_{i}"
		row_staging.mkdir(parents=True, exist_ok=True)
		metrics_path = row_staging / "metrics.json"
		# Only family metric keys in override; status/model handled separately.
		metric_payload = {k: metrics.get(k, "") for k in PROMO_METRIC_KEYS}
		metrics_path.write_text(
			json.dumps(metric_payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
		)
		(row_staging / "summary.md").write_text(
			f"- started: {_utc_now()}\n- MODEL: {metrics.get('model', '')}\n",
			encoding="utf-8",
		)
		row = build_row_from_staging(
			server_id=f"{server_id}__{metrics.get('campaign_id')}__{metrics.get('iter')}",
			host_id=host_id,
			platform=platform,
			bench_id=bench_id,
			staging_dir=row_staging,
			model=str(metrics.get("model") or ""),
			metrics_override=metric_payload,
		)
		# Preserve identity columns that build_row may not copy from override status-only path
		for k in PROMO_METRIC_KEYS:
			if metrics.get(k) not in (None, "") and not row.get(k):
				row[k] = metrics[k]
		if metrics.get("status"):
			row["status"] = metrics["status"]
		path = append_row(repo_root, bench_id, row, dedupe=dedupe)
		written.append(path)
	return written


def main(argv: Optional[Sequence[str]] = None) -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--suite-dir", type=Path, default=None)
	parser.add_argument("--facts", type=Path, default=None, help="promo-facts-1 JSON path")
	parser.add_argument("--staging-dir", type=Path, default=None)
	parser.add_argument("--repo-root", type=Path, default=None)
	parser.add_argument("--server-id", default=os.environ.get("INFERENCE_SERVER_ID", "promo-local"))
	parser.add_argument("--host-id", default=os.environ.get("HOST_ID", "local"))
	parser.add_argument("--platform", default=os.environ.get("PLATFORM", "hpcc"))
	parser.add_argument(
		"--bench-id",
		default=None,
		help="default: promo_facts__<campaign_or_model>",
	)
	parser.add_argument("--dry-run", action="store_true")
	parser.add_argument("--no-dedupe", action="store_true")
	args = parser.parse_args(argv)

	parser_mod = load_parser()
	facts_path: Optional[Path] = args.facts
	suite = args.suite_dir or (
		Path(os.environ["SUITE_DIR"]).expanduser() if os.environ.get("SUITE_DIR") else None
	)
	if facts_path is None and suite is not None:
		for cand in (
			suite / "facts" / "facts.json",
			suite / "facts",
			suite / "review" / "facts.json",
		):
			if cand.exists():
				facts_path = cand
				break
	if facts_path is None:
		print("[emit-promo-facts] --facts or --suite-dir with facts required", file=sys.stderr)
		return 2

	doc = parser_mod.parse_path(facts_path)
	rows = iter_rows_from_document(doc)
	if not rows:
		print("[emit-promo-facts] no iter rows to emit", file=sys.stderr)
		return 1

	staging = args.staging_dir or (
		(suite / "warehouse_staging") if suite is not None else Path("warehouse_staging_promo")
	)
	batch_path = write_staging(staging, rows)
	print(f"[emit-promo-facts] staging rows={len(rows)} → {batch_path}", file=sys.stderr)

	first = rows[0]
	bench_id = args.bench_id or f"promo_facts__{first.get('case_id_candidate') or first.get('campaign_id')}"
	if args.dry_run:
		print(json.dumps({"bench_id": bench_id, "rows": len(rows), "sample": rows[0]}, indent=2)[:2000])
		return 0

	repo = args.repo_root or Path(
		os.environ.get("BENCH_WAREHOUSE_REPO", "")
	).expanduser()
	if not repo or not repo.is_dir():
		print(
			"[emit-promo-facts] BENCH_WAREHOUSE_REPO / --repo-root required for emit",
			file=sys.stderr,
		)
		return 2

	# Ensure CASE_PATH points at candidate when available for CASE_META_COLUMNS.
	if first.get("case_id_candidate") and not os.environ.get("CASE_PATH"):
		io_root = Path(os.environ.get("IO_ROOT") or Path(__file__).resolve().parents[3])
		guess = io_root / "playground" / "Standalone" / str(first["case_id_candidate"]) / "case.toml"
		if guess.is_file():
			os.environ["CASE_PATH"] = str(guess)

	written = emit_rows(
		rows,
		staging_dir=staging,
		repo_root=repo,
		server_id=args.server_id,
		host_id=args.host_id,
		platform=args.platform,
		bench_id=bench_id,
		dedupe=not args.no_dedupe,
	)
	for path in sorted(set(written)):
		print(f"[emit-promo-facts] {path}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
