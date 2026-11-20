"""One Observe→Parse promotion turn. Measure backend for AutoHelix (or legacy)."""

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


def _parse_exhausted(raw: Optional[str]) -> List[str]:
	"""PROMO_EXHAUSTED: JSON list or comma-separated path ids."""
	if not raw or not str(raw).strip():
		return []
	text = str(raw).strip()
	if text.startswith("["):
		try:
			data = json.loads(text)
		except json.JSONDecodeError:
			data = None
		if isinstance(data, list):
			return [str(x).strip() for x in data if str(x).strip()]
	return [x.strip() for x in text.split(",") if x.strip()]


def _parse_agent_ids(raw: Optional[str]) -> Optional[List[str]]:
	"""PROMO_AGENT_IDS: JSON list or comma-separated ids."""
	ids = _parse_exhausted(raw)
	return ids or None


def _controller_mode() -> str:
	"""autohelix when AUTOHELIX_RUN_ID (or explicit PROMO_CONTROLLER) is set."""
	explicit = os.environ.get("PROMO_CONTROLLER", "").strip().lower()
	if explicit in {"autohelix", "ai_led", "legacy"}:
		return "autohelix" if explicit == "autohelix" else "ai_led"
	if os.environ.get("AUTOHELIX_RUN_ID", "").strip():
		return "autohelix"
	return "autohelix"  # default: AutoHelix-owned iteration; no AI_LED_NEXT stop


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


def _profiler_env_name(device_track: str) -> str:
	if device_track == "qy":
		return "DLPTI_ROOT"
	if device_track == "metax":
		return "MCTRACER_ROOT"
	if device_track == "mars":
		return "HCTRACER_ROOT"
	return "PROFILER_ROOT"


def _profiler_root(device_track: str) -> Optional[Path]:
	if device_track == "qy":
		raw = os.environ.get("DLPTI_ROOT", "").strip()
		return Path(raw).expanduser() if raw else None
	if device_track == "metax":
		raw = os.environ.get("MCTRACER_ROOT", "").strip()
		return Path(raw).expanduser() if raw else None
	if device_track == "mars":
		raw = os.environ.get("HCTRACER_ROOT", "").strip()
		return Path(raw).expanduser() if raw else None
	return None


def _io_kit_root(device_track: str) -> Optional[Path]:
	"""InfiniOrchestrator-owned light kits (docker-exec path)."""
	kits = Path(__file__).resolve().parent / "kits"
	mapping = {"qy": "dlpti", "metax": "mctracer", "mars": "hctracer"}
	name = mapping.get(device_track)
	if not name:
		return None
	root = kits / name
	return root if (root / "run_promotion_loop_step.sh").is_file() else None


def _profiler_had_signals(out_dir: Path) -> bool:
	for name in ("host_signals.json", "compare.json"):
		path = out_dir / name
		if not path.is_file():
			continue
		try:
			doc = json.loads(path.read_text(encoding="utf-8"))
		except (OSError, json.JSONDecodeError):
			continue
		if not isinstance(doc, dict):
			continue
		hs = doc.get("host_signals")
		if isinstance(hs, list) and any(
			isinstance(x, dict) and x.get("family") is not None and x.get("ratio") is not None
			for x in hs
		):
			return True
		cats = doc.get("categories")
		if isinstance(cats, list) and cats:
			return True
		dt = doc.get("device_totals")
		if isinstance(dt, dict) and (
			(isinstance(dt.get("infinilm"), dict) and dt.get("infinilm"))
			or (isinstance(dt.get("vllm"), dict) and dt.get("vllm"))
			or (isinstance(dt.get("infinilm_over_vllm"), dict) and dt.get("infinilm_over_vllm"))
		):
			return True
	return False


def _maybe_run_profiler(
	suite_dir: Path,
	*,
	device_track: str,
	walls: List[Dict[str, Any]],
	args: argparse.Namespace,
) -> Optional[str]:
	"""Return profile run_id if a compare was produced/found; never auto-promote."""
	if args.skip_profiler:
		return None
	profiler_ctn = os.environ.get("PROFILER_CONTAINER", "").strip()
	root = _profiler_root(device_track)
	io_kit = _io_kit_root(device_track)
	if device_track == "mars" and not root and not profiler_ctn and not io_kit:
		print(
			"[loop-step] device_track=mars → wall-only (HCTRACER_ROOT unset)",
			file=sys.stderr,
		)
		return None
	need = any_profile_regress(walls) or (
		(primary_ratio(walls) is not None) and primary_ratio(walls) < 0.9  # type: ignore[operator]
	)
	if not need and not args.force_profiler:
		print("[loop-step] wall not behind / no PROFILE_REGRESS → skip profiler", file=sys.stderr)
		existing = find_profiler_compare(suite_dir, args.profile_run_id)
		return existing.parent.name if existing else None

	run_id = args.profile_run_id or _utc_now().replace(":", "").replace("-", "")
	out_dir = suite_dir / "profile" / run_id
	out_dir.mkdir(parents=True, exist_ok=True)

	# Prefer in-container docker-exec path when PROFILER_CONTAINER is set.
	if profiler_ctn:
		kit = None
		# Explicit *_ROOT may already point at IO kits; otherwise use IO kit.
		if root is not None and (root / "run_promotion_loop_step.sh").is_file():
			kit = root
		elif root is not None and (root / "scripts" / "run_promotion_loop_step.sh").is_file():
			# Host vendor kit — still prefer IO light kit for docker-exec smoke.
			kit = io_kit or root / "scripts"
		else:
			kit = io_kit
		if kit is None:
			env_name = _profiler_env_name(device_track)
			print(
				f"[loop-step] PROFILER_CONTAINER set but no kit for {device_track} "
				f"({env_name} / IO kits missing)",
				file=sys.stderr,
			)
			(out_dir / "COMPARE_SKIPPED.txt").write_text(
				f"profiler kit not available for docker-exec ({env_name})\n",
				encoding="utf-8",
			)
			return run_id

		# If kit dir is scripts/, use parent when helper is under scripts/
		helper = kit / "run_promotion_loop_step.sh"
		if not helper.is_file() and kit.name != "scripts":
			helper = kit / "scripts" / "run_promotion_loop_step.sh"
			if helper.is_file():
				kit = helper.parent
		docker_helper = Path(__file__).resolve().parents[3] / "scripts" / "docker_exec_profiler.sh"
		if not docker_helper.is_file():
			# harness/adapters/promo_facts → parents[3] is IO root
			docker_helper = Path(__file__).resolve().parents[3] / "scripts" / "docker_exec_profiler.sh"
		env = os.environ.copy()
		env["SUITE_DIR"] = str(suite_dir)
		env["OUT_DIR"] = str(out_dir)
		env["PROFILER_CONTAINER"] = profiler_ctn
		env["PROFILER_KIT_DIR"] = str(kit if (kit / "run_promotion_loop_step.sh").is_file() else helper.parent)
		env["MODE"] = args.profiler_mode
		# Prefer explicit PROFILER_MODE from dual-profile / operator (attach_serve|smoke).
		profiler_mode = (
			os.environ.get("PROFILER_MODE")
			or getattr(args, "profiler_mode", None)
			or "smoke"
		)
		if profiler_mode in ("skip-capture", ""):
			profiler_mode = os.environ.get("PROFILER_MODE") or "smoke"
		env["PROFILER_MODE"] = profiler_mode
		if os.environ.get("ENGINE"):
			env["ENGINE"] = os.environ["ENGINE"]
		if os.environ.get("ATTACH_PID"):
			env["ATTACH_PID"] = os.environ["ATTACH_PID"]
		if os.environ.get("CLIENT_WINDOW_CMD"):
			env["CLIENT_WINDOW_CMD"] = os.environ["CLIENT_WINDOW_CMD"]
		for k in (
			"ATTACH_CHATS",
			"ATTACH_MAX_TOKENS",
			"API_PORT_CANDIDATES",
			"ROLE",
			"MODEL",
			"LIGHT_DROP_RAW",
			"NON_SMOKE_GATE",
			"ATTACH_READY_SECS",
			"ATTACH_STOP_SECS",
			"DOCKER_BIN",
		):
			if os.environ.get(k):
				env[k] = os.environ[k]
		print(
			f"[loop-step] docker-exec profiler ctn={profiler_ctn} kit={env['PROFILER_KIT_DIR']} "
			f"mode={env['PROFILER_MODE']}",
			file=sys.stderr,
		)
		proc = subprocess.run(["bash", str(docker_helper)], env=env)
		if proc.returncode == 42:
			print("[loop-step] profiler SKIPPED (in-container tool missing)", file=sys.stderr)
		elif proc.returncode != 0:
			print(f"[loop-step] docker-exec profiler exit {proc.returncode} (continuing)", file=sys.stderr)
		return run_id

	if root is None or not root.is_dir():
		# Fall back to IO kit on host (still not preferred; docker-exec is the fair path).
		if io_kit is not None:
			root = io_kit
		else:
			env_name = _profiler_env_name(device_track)
			print(
				f"[loop-step] profiler escalate requested but {env_name} unset/missing; "
				"continuing wall-only parse",
				file=sys.stderr,
			)
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
		camp = json.loads(campaign_path.read_text(encoding="utf-8"))
		# Overlay CLI/env identity so kicks can promote wall-only → hctracer etc.
		if args.vendor_profiler:
			camp["vendor_profiler"] = args.vendor_profiler
		elif os.environ.get("VENDOR_PROFILER"):
			camp["vendor_profiler"] = os.environ["VENDOR_PROFILER"]
		if args.device_track:
			camp["device_track"] = args.device_track
		if args.host:
			camp["host"] = args.host
		return camp

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
	lever_applied: Optional[str] = None,
	agent_ids: Optional[List[str]] = None,
) -> Path:
	parser = load_parser()
	facts_dir = suite_dir / "facts"
	facts_dir.mkdir(parents=True, exist_ok=True)

	primary = next((w for w in walls if w.get("primary")), walls[0] if walls else None)
	ratio = primary.get("WALL_DECODE_RATIO") if primary else None
	surpass = bool(ratio is not None and float(ratio) > 1.0)
	profiled = False
	host_signals: Optional[List[Dict[str, Any]]] = None
	if profile_run_id:
		prof_dir = suite_dir / "profile" / profile_run_id
		profiled = _profiler_had_signals(prof_dir)
		for name in ("host_signals.json", "compare.json"):
			path = prof_dir / name
			if not path.is_file():
				continue
			try:
				doc = json.loads(path.read_text(encoding="utf-8"))
			except (OSError, json.JSONDecodeError):
				continue
			if isinstance(doc, dict) and isinstance(doc.get("host_signals"), list):
				host_signals = [x for x in doc["host_signals"] if isinstance(x, dict)]
				break
	iter_obj: Dict[str, Any] = {
		"iter": iter_index,
		"suite_dir": str(suite_dir),
		"profiled": profiled,
		"lever_applied": lever_applied,
		"walls": walls,
		"backlog": backlog,
		"ship": {
			"surpass": surpass,
			"actions": "none",
		},
	}
	if agent_ids:
		iter_obj["agent_ids"] = agent_ids
	if host_signals:
		iter_obj["host_signals"] = host_signals
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
		description="Observe→Parse one promotion turn (AutoHelix measure backend)"
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

	exhausted = _parse_exhausted(os.environ.get("PROMO_EXHAUSTED"))
	lever_applied = os.environ.get("PROMO_LEVER_APPLIED", "").strip() or None
	agent_ids = _parse_agent_ids(os.environ.get("PROMO_AGENT_IDS"))
	autohelix_run_id = os.environ.get("AUTOHELIX_RUN_ID", "").strip() or None
	controller = _controller_mode()

	backlog = rank_paths(
		wall_ratio=primary_ratio(walls),
		compare=compare,
		exhausted=exhausted,
	)
	if compare_path is not None:
		backlog_path = compare_path.parent / "promotion_backlog.json"
	else:
		backlog_path = suite / "promotion_backlog.json"
	write_backlog(backlog_path, backlog)

	facts_dir = suite / "facts"
	iter_index = args.iter if args.iter is not None else _next_iter_index(facts_dir)
	if agent_ids:
		campaign = dict(campaign)
		campaign["agent_ids"] = agent_ids
	if autohelix_run_id:
		campaign = dict(campaign)
		campaign["autohelix_run_id"] = autohelix_run_id

	_emit_facts(
		suite,
		campaign=campaign,
		walls=walls,
		backlog=backlog,
		profile_run_id=run_id,
		iter_index=iter_index,
		lever_applied=lever_applied,
		agent_ids=agent_ids,
	)

	payload: Dict[str, Any] = {
		"status": "observe_parse_complete",
		"suite_dir": str(suite),
		"iter": iter_index,
		"device_track": device_track,
		"primary_ratio": primary_ratio(walls),
		"top_path": backlog.get("top_path"),
		"backlog_path": str(backlog_path),
		"facts_dir": str(facts_dir),
		"controller": controller,
		"lever_applied": lever_applied,
		"exhausted": exhausted,
	}
	if autohelix_run_id:
		payload["autohelix_run_id"] = autohelix_run_id
	if agent_ids:
		payload["agent_ids"] = agent_ids
	print(json.dumps(payload, indent=2, sort_keys=True))
	print(
		f"[loop-step] Observe→Parse done; controller={controller} (no auto-apply)",
		file=sys.stderr,
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
