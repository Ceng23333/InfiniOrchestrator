"""One Observe→Parse promotion turn. Exits before AI Promote."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from adapters.promo_facts.identity import campaign_identity_from_cases
from adapters.promo_facts.parser_path import load_parser
from adapters.promo_facts.rank import find_profiler_compare, rank_paths, write_backlog
from adapters.promo_facts.walls import (
	any_profile_regress,
	load_json,
	primary_ratio,
	walls_from_suite,
)


def _utc_now() -> str:
	return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _run(cmd: List[str], *, cwd: Optional[Path] = None) -> int:
	print(f"[loop-step] exec: {' '.join(cmd)}", file=sys.stderr)
	proc = subprocess.run(cmd, cwd=str(cwd) if cwd else None)
	return int(proc.returncode)


def _maybe_run_wall(suite_dir: Path, args: argparse.Namespace) -> int:
	if args.reuse_wall:
		if not (suite_dir / "compare.json").is_file():
			print("[loop-step] --reuse-wall but compare.json missing", file=sys.stderr)
			return 1
		print("[loop-step] reusing existing compare.json", file=sys.stderr)
		return 0
	if not args.run_wall:
		if (suite_dir / "compare.json").is_file():
			print("[loop-step] using existing compare.json (pass --run-wall to refresh)", file=sys.stderr)
			return 0
		print(
			"[loop-step] no compare.json; pass --run-wall with AIPerf URLs or --reuse-wall",
			file=sys.stderr,
		)
		return 2

	harness_bin = Path(__file__).resolve().parents[2] / "bin" / "run-aiperf-dual"
	cmd = [str(harness_bin), "--suite-dir", str(suite_dir)]
	if args.base_url_vllm:
		cmd += ["--base-url-vllm", args.base_url_vllm]
	if args.base_url_infinilm:
		cmd += ["--base-url-infinilm", args.base_url_infinilm]
	if args.profile:
		cmd += ["--profile", args.profile]
	if args.model:
		cmd += ["--model", args.model]
	if args.case_vllm:
		cmd += ["--case-vllm", args.case_vllm]
	if args.case_infinilm:
		cmd += ["--case-infinilm", args.case_infinilm]
	return _run(cmd)


def _profiler_root(device_track: str) -> Optional[Path]:
	if device_track == "denglin_qy":
		raw = os.environ.get("DLPTI_ROOT", "").strip()
		return Path(raw).expanduser() if raw else None
	if device_track == "metax_qy":
		raw = os.environ.get("MCTRACER_ROOT", "").strip()
		return Path(raw).expanduser() if raw else None
	return None


def _maybe_run_profiler(
	suite_dir: Path,
	*,
	device_track: str,
	walls: List[Dict[str, Any]],
	args: argparse.Namespace,
) -> Optional[str]:
	"""Return profile run_id if a compare was produced/found; never auto-promote."""
	if device_track == "mars":
		print("[loop-step] device_track=mars → wall-only (skip profiler)", file=sys.stderr)
		return None
	if args.skip_profiler:
		return None
	need = any_profile_regress(walls) or (
		(primary_ratio(walls) is not None) and primary_ratio(walls) < 0.9  # type: ignore[operator]
	)
	if not need and not args.force_profiler:
		print("[loop-step] wall not behind / no PROFILE_REGRESS → skip profiler", file=sys.stderr)
		existing = find_profiler_compare(suite_dir, args.profile_run_id)
		return existing.parent.name if existing else None

	root = _profiler_root(device_track)
	run_id = args.profile_run_id or _utc_now().replace(":", "").replace("-", "")
	out_dir = suite_dir / "profile" / run_id
	out_dir.mkdir(parents=True, exist_ok=True)

	if root is None or not root.is_dir():
		env_name = "DLPTI_ROOT" if device_track == "denglin_qy" else "MCTRACER_ROOT"
		print(
			f"[loop-step] profiler escalate requested but {env_name} unset/missing; "
			"continuing wall-only parse",
			file=sys.stderr,
		)
		# Keep empty dir as placeholder; ranker will use empty compare.
		(out_dir / "COMPARE_SKIPPED.txt").write_text(
			f"profiler kit not available ({env_name})\n", encoding="utf-8"
		)
		return run_id

	# Kits own capture; SOP only documents the hand-off. Prefer existing helper scripts.
	helper = None
	for name in ("run_promotion_loop_step.sh", "scripts/run_promotion_loop_step.sh"):
		cand = root / name
		if cand.is_file():
			helper = cand
			break
	if helper is None:
		print(
			f"[loop-step] no run_promotion_loop_step.sh under {root}; "
			"expect operator-provided profile/<run_id>/compare.json",
			file=sys.stderr,
		)
		return run_id

	env = os.environ.copy()
	env["SUITE_DIR"] = str(suite_dir)
	env["OUT_DIR"] = str(out_dir)
	env["MODE"] = args.profiler_mode
	print(f"[loop-step] invoking profiler helper {helper}", file=sys.stderr)
	proc = subprocess.run(["bash", str(helper)], cwd=str(root), env=env)
	if proc.returncode != 0:
		print(f"[loop-step] profiler helper exit {proc.returncode} (continuing)", file=sys.stderr)
	return run_id


def _load_or_init_campaign(suite_dir: Path, args: argparse.Namespace) -> Dict[str, Any]:
	facts_dir = suite_dir / "facts"
	campaign_path = facts_dir / "campaign.json"
	if campaign_path.is_file():
		return json.loads(campaign_path.read_text(encoding="utf-8"))

	ident = campaign_identity_from_cases(
		case_baseline=args.case_vllm,
		case_candidate=args.case_infinilm,
		device_track=args.device_track or os.environ.get("DEVICE_TRACK"),
		host=args.host or os.environ.get("HOST_ID"),
		vendor_profiler=args.vendor_profiler,
	)
	campaign_id = args.campaign_id or os.environ.get("CAMPAIGN_ID") or suite_dir.name
	cell = args.cell or os.environ.get("PROMO_CELL") or campaign_id
	camp: Dict[str, Any] = {
		"campaign_id": campaign_id,
		"host": ident.get("host") or args.host or "unknown",
		"device_track": ident.get("device_track") or args.device_track or "other",
		"vendor_profiler": ident.get("vendor_profiler") or args.vendor_profiler or "none",
		"hw_profile_id": ident.get("hw_profile_id") or "unknown",
		"case_id_candidate": ident.get("case_id_candidate") or campaign_id,
		"be_abbr_candidate": ident.get("be_abbr_candidate") or "inf",
		"cell": cell,
		"pin_baseline": ident.get("pin_baseline") or "vllm-frozen",
		"pin_candidate": ident.get("pin_candidate") or "candidate",
	}
	for key in (
		"hw_abbr",
		"case_id_baseline",
		"be_abbr_baseline",
		"worktree_baseline",
		"worktree_candidate",
		"itw_tag_baseline",
		"itw_tag_candidate",
	):
		if key in ident:
			camp[key] = ident[key]
	return camp


def _next_iter_index(facts_dir: Path) -> int:
	jsonl = facts_dir / "iters.jsonl"
	if not jsonl.is_file():
		return 0
	n = 0
	for line in jsonl.read_text(encoding="utf-8").splitlines():
		if line.strip():
			n += 1
	return n


def _emit_facts(
	suite_dir: Path,
	*,
	campaign: Dict[str, Any],
	walls: List[Dict[str, Any]],
	backlog: Dict[str, Any],
	profile_run_id: Optional[str],
	iter_index: int,
) -> Path:
	parser = load_parser()
	facts_dir = suite_dir / "facts"
	facts_dir.mkdir(parents=True, exist_ok=True)

	primary = next((w for w in walls if w.get("primary")), walls[0] if walls else None)
	ratio = primary.get("WALL_DECODE_RATIO") if primary else None
	surpass = bool(ratio is not None and float(ratio) > 1.0)
	iter_obj: Dict[str, Any] = {
		"iter": iter_index,
		"suite_dir": str(suite_dir),
		"profiled": False,
		"lever_applied": None,
		"walls": walls,
		"backlog": backlog,
		"ship": {
			"surpass": surpass,
			"actions": "none",
		},
	}
	if primary is not None:
		iter_obj["wall"] = dict(primary)
	if profile_run_id:
		iter_obj["profile_run_id"] = profile_run_id

	# Validate via skill parser
	parsed_iter = parser.parse_iter(iter_obj, "loop_step.iter")
	camp_for_parse = {k: v for k, v in campaign.items() if k != "iters"}
	camp_for_parse["iters"] = [parsed_iter]
	parsed_camp = parser.parse_campaign(camp_for_parse, "loop_step.campaign", require_iters=True)

	# Persist suite layout
	campaign_out = {k: v for k, v in parsed_camp.items() if k != "iters"}
	(facts_dir / "campaign.json").write_text(
		json.dumps(campaign_out, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
	)
	jsonl = facts_dir / "iters.jsonl"
	with jsonl.open("a", encoding="utf-8") as fh:
		fh.write(json.dumps(parsed_iter, ensure_ascii=False) + "\n")

	doc = {
		"schema_version": parser.SCHEMA_VERSION,
		"generated_at": _utc_now(),
		"campaigns": [parsed_camp],
	}
	(facts_dir / "facts.json").write_text(
		json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
	)
	return facts_dir


def main(argv: Optional[Sequence[str]] = None) -> int:
	parser = argparse.ArgumentParser(
		description="Observe→Parse one promotion turn; exit before Promote"
	)
	parser.add_argument("--suite-dir", type=Path, default=None)
	parser.add_argument("--device-track", default=os.environ.get("DEVICE_TRACK"))
	parser.add_argument("--host", default=None)
	parser.add_argument("--campaign-id", default=None)
	parser.add_argument("--cell", default=None)
	parser.add_argument("--vendor-profiler", default=None)
	parser.add_argument("--reuse-wall", action="store_true")
	parser.add_argument("--run-wall", action="store_true")
	parser.add_argument("--skip-profiler", action="store_true")
	parser.add_argument("--force-profiler", action="store_true")
	parser.add_argument("--profile-run-id", default=None)
	parser.add_argument("--profiler-mode", default="skip-capture")
	parser.add_argument("--base-url-vllm", default=None)
	parser.add_argument("--base-url-infinilm", default=None)
	parser.add_argument("--profile", default=None)
	parser.add_argument("--model", default=None)
	parser.add_argument("--case-vllm", default=None)
	parser.add_argument("--case-infinilm", default=None)
	parser.add_argument("--iter", type=int, default=None)
	args = parser.parse_args(argv)

	suite = args.suite_dir or Path(os.environ.get("SUITE_DIR", "")).expanduser()
	if not suite or str(suite) in (".", ""):
		print("[loop-step] --suite-dir or SUITE_DIR required", file=sys.stderr)
		return 2
	suite = suite.resolve()
	suite.mkdir(parents=True, exist_ok=True)

	rc = _maybe_run_wall(suite, args)
	if rc != 0:
		return rc

	walls = walls_from_suite(suite)
	if not walls:
		print("[loop-step] could not derive walls[] from compare.json", file=sys.stderr)
		return 1

	campaign = _load_or_init_campaign(suite, args)
	device_track = str(args.device_track or campaign.get("device_track") or "other")
	campaign["device_track"] = device_track

	run_id = _maybe_run_profiler(suite, device_track=device_track, walls=walls, args=args)
	compare_path = find_profiler_compare(suite, run_id or args.profile_run_id)
	compare = load_json(compare_path) if compare_path else {}
	if compare_path and run_id is None:
		run_id = compare_path.parent.name

	backlog = rank_paths(
		wall_ratio=primary_ratio(walls),
		compare=compare,
		exhausted=[],
	)
	if compare_path is not None:
		backlog_path = compare_path.parent / "promotion_backlog.json"
	else:
		backlog_path = suite / "promotion_backlog.json"
	write_backlog(backlog_path, backlog)

	facts_dir = suite / "facts"
	iter_index = args.iter if args.iter is not None else _next_iter_index(facts_dir)
	_emit_facts(
		suite,
		campaign=campaign,
		walls=walls,
		backlog=backlog,
		profile_run_id=run_id,
		iter_index=iter_index,
	)

	print(
		json.dumps(
			{
				"status": "observe_parse_complete",
				"suite_dir": str(suite),
				"iter": iter_index,
				"device_track": device_track,
				"primary_ratio": primary_ratio(walls),
				"top_path": backlog.get("top_path"),
				"backlog_path": str(backlog_path),
				"facts_dir": str(facts_dir),
				"promote": "AI_LED_NEXT",
			},
			indent=2,
			sort_keys=True,
		)
	)
	print(
		"[loop-step] Observe→Parse done; exiting before Promote (AI-led)",
		file=sys.stderr,
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
