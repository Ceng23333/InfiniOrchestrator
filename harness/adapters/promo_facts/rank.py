"""Deterministic host-first + CU/score promotion ranker."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from adapters.promo_facts.walls import load_json, primary_ratio, walls_from_suite

# Shared host-first thresholds (design doc / facts.md).
WALL_HOST_FIRST = 0.9
CU_MAX = 1.0
COUNT_MIN = 2.0
COMMAND_MIN = 2.0
GAP_MIN = 1.5

LEVER_MAP = {
	"host_graph_command": "INFINI_CUDAGRAPH_POLICY / F&P / skip-tail / host sync",
	"rope": "INFINI_QY_ROPE_SMALL_BLOCK",
	"kv_cache_reshape": "INFINI_QY_KV_SMALL_BLOCK",
	"residual_add_rmsnorm": "INFINI_QY_FUSED_ADD_RMSNORM=1",
	"moe_fused": "MoE fused / bf16 / warpnk / graph policy",
	"gated_delta_rule": "GDN / graph / triton levers",
	"batch_policy": "admission / MIXED / ladder policy",
	"gemm": "inspect GEMM kernels",
	"attention": "inspect attention kernels",
	"allreduce": "inspect allreduce path",
	"other": "inspect bucket kernels; no static lever mapped yet",
}


def _num(v: Any) -> Optional[float]:
	if v is None or isinstance(v, bool):
		return None
	if isinstance(v, (int, float)):
		return float(v)
	try:
		return float(v)
	except (TypeError, ValueError):
		return None


def _host_signal_map(compare: Dict[str, Any]) -> Dict[str, float]:
	"""Extract family → ratio from profiler compare shapes (DLPTI / mcTracer)."""
	out: Dict[str, float] = {}
	# Prefer host_signals when present. Some dual payloads set host=hostname str,
	# which must not shadow the real signal list/map (rank would see empty host).
	host = compare.get("host_signals")
	if host is None:
		host = compare.get("host")
	if isinstance(host, str):
		host = compare.get("host_signals") or {}
	if host is None:
		host = {}
	if isinstance(host, list):
		for item in host:
			if not isinstance(item, dict):
				continue
			fam = str(item.get("family") or "").lower()
			ratio = _num(item.get("ratio"))
			if fam and ratio is not None:
				out[fam] = ratio
		return out
	if isinstance(host, dict):
		for key, val in host.items():
			fam = str(key).lower()
			if isinstance(val, dict):
				ratio = _num(val.get("ratio") or val.get("over") or val.get("value"))
			else:
				ratio = _num(val)
			if ratio is not None:
				out[fam] = ratio
	# Flat keys used by some kits
	for fam, keys in (
		("driver", ("driver_ratio", "DRIVER_ratio")),
		("runtime", ("runtime_ratio", "RUNTIME_ratio")),
		("command", ("command_ratio", "COMMAND_ratio", "api_ms_ratio")),
		("api", ("api_count_ratio", "api_ratio")),
		("gap", ("gap_ratio", "inter_kernel_gap_ratio", "cu_gap_ratio")),
		("graph", ("graph_ratio",)),
	):
		if fam in out:
			continue
		for k in keys:
			ratio = _num(compare.get(k))
			if ratio is not None:
				out[fam] = ratio
				break
	return out


def _cu_buckets(compare: Dict[str, Any]) -> List[Dict[str, Any]]:
	raw = compare.get("categories") or compare.get("cu_buckets") or compare.get("buckets") or []
	out: List[Dict[str, Any]] = []
	if not isinstance(raw, list):
		return out
	for item in raw:
		if not isinstance(item, dict):
			continue
		bucket = str(item.get("bucket") or item.get("name") or item.get("path_id") or "")
		ratio = _num(item.get("ratio") or item.get("over"))
		if not bucket or ratio is None:
			continue
		material = item.get("material")
		if material is None:
			material = ratio > 1.05
		out.append(
			{
				"bucket": bucket,
				"ratio": float(ratio),
				"material": bool(material),
				"us_or_ms_per_norm": _num(item.get("us_or_ms_per_norm") or item.get("us_per_flash")),
				"score": _num(item.get("score")),
				"path_id": str(item.get("path_id") or bucket),
			}
		)
	return out


def _cu_proxy(compare: Dict[str, Any], buckets: List[Dict[str, Any]]) -> Optional[float]:
	for key in (
		"cu_ratio",
		"gpu_kernel_ms_post_load_ratio",
		"gpu_post_load_ratio",
		"total_cu_ratio",
	):
		ratio = _num(compare.get(key))
		if ratio is not None:
			return ratio
	if buckets:
		# Conservative: max material bucket as CU pressure proxy when total missing.
		mats = [b["ratio"] for b in buckets if b.get("material")]
		if mats:
			return max(mats)
	return None


def host_first_fired(
	wall_ratio: Optional[float],
	host: Dict[str, float],
	cu_ratio: Optional[float],
) -> bool:
	if wall_ratio is None or wall_ratio >= WALL_HOST_FIRST:
		return False
	if cu_ratio is not None and cu_ratio > CU_MAX:
		return False
	count_hit = max(host.get("driver", 0.0), host.get("runtime", 0.0), host.get("api", 0.0)) >= COUNT_MIN
	command_hit = max(host.get("command", 0.0), host.get("api", 0.0)) >= COMMAND_MIN
	# Prefer explicit api_ms if present under command
	gap_hit = host.get("gap", 0.0) >= GAP_MIN
	return count_hit or command_hit or gap_hit


def rank_paths(
	*,
	wall_ratio: Optional[float],
	compare: Dict[str, Any],
	exhausted: Optional[Sequence[str]] = None,
) -> Dict[str, Any]:
	exhausted_set = {str(x) for x in (exhausted or [])}
	host = _host_signal_map(compare)
	buckets = _cu_buckets(compare)
	cu_ratio = _cu_proxy(compare, buckets)
	fired = host_first_fired(wall_ratio, host, cu_ratio)

	ranked: List[Dict[str, Any]] = []
	if fired and "host_graph_command" not in exhausted_set:
		reasons = []
		if host.get("command", 0) >= COMMAND_MIN:
			reasons.append(f"COMMAND/api_ms ratio {host.get('command'):.3f} ≥ {COMMAND_MIN}×")
		if max(host.get("driver", 0), host.get("runtime", 0), host.get("api", 0)) >= COUNT_MIN:
			reasons.append("DRIVER/RUNTIME/api count ≥ 2×")
		if host.get("gap", 0) >= GAP_MIN:
			reasons.append(f"gap ratio {host.get('gap'):.3f} ≥ {GAP_MIN}×")
		if wall_ratio is not None:
			reasons.append(f"primary wall {wall_ratio:.3f} < {WALL_HOST_FIRST}")
		ranked.append(
			{
				"rank": 1,
				"path_id": "host_graph_command",
				"priority_rule": 1,
				"reasons": reasons or ["host-first rule"],
				"lever": LEVER_MAP["host_graph_command"],
			}
		)

	# Score-first (MetaX) then material CU ratio.
	scored = [b for b in buckets if b.get("score") is not None and b["path_id"] not in exhausted_set]
	scored.sort(key=lambda b: float(b["score"]), reverse=True)
	material = [
		b
		for b in buckets
		if b.get("material") and b.get("score") is None and b["path_id"] not in exhausted_set
	]
	material.sort(key=lambda b: float(b["ratio"]), reverse=True)

	seen = {r["path_id"] for r in ranked}
	for b in scored + material:
		pid = str(b["path_id"])
		if pid in seen:
			continue
		seen.add(pid)
		entry: Dict[str, Any] = {
			"rank": len(ranked) + 1,
			"path_id": pid,
			"reasons": [f"ratio={b['ratio']:.3f}"],
			"lever": LEVER_MAP.get(pid, LEVER_MAP["other"]),
		}
		if b.get("score") is not None:
			entry["score"] = float(b["score"])
			entry["reasons"] = [f"score={b['score']:.3f}", f"ratio={b['ratio']:.3f}"]
		ranked.append(entry)

	if not ranked:
		ranked.append(
			{
				"rank": 1,
				"path_id": "other",
				"reasons": ["no host-first or material CU evidence"],
				"lever": LEVER_MAP["other"],
			}
		)

	return {
		"top_path": ranked[0]["path_id"],
		"host_first_fired": fired,
		"ranked": ranked,
		"exhausted": sorted(exhausted_set),
	}


def find_profiler_compare(suite_dir: Path, run_id: Optional[str] = None) -> Path | None:
	profile_root = suite_dir / "profile"
	if run_id:
		cand = profile_root / run_id / "compare.json"
		return cand if cand.is_file() else None
	if not profile_root.is_dir():
		return None
	matches = sorted(profile_root.glob("*/compare.json"))
	return matches[-1] if matches else None


def write_backlog(path: Path, backlog: Dict[str, Any]) -> None:
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(json.dumps(backlog, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv: Optional[Sequence[str]] = None) -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument(
		"--suite-dir",
		type=Path,
		default=None,
		help="Suite root (default: $SUITE_DIR)",
	)
	parser.add_argument("--profile-run-id", default=None, help="profile/<run_id>/compare.json")
	parser.add_argument(
		"--compare",
		type=Path,
		default=None,
		help="Explicit profiler compare.json (overrides --profile-run-id)",
	)
	parser.add_argument(
		"--wall-ratio",
		type=float,
		default=None,
		help="Override primary wall ratio (otherwise from suite compare/facts)",
	)
	parser.add_argument(
		"--out",
		type=Path,
		default=None,
		help="Output promotion_backlog.json (default: under profile run or suite)",
	)
	parser.add_argument(
		"--exhausted",
		default="",
		help="Comma-separated path_ids to exclude",
	)
	args = parser.parse_args(argv)

	import os

	suite = args.suite_dir or Path(os.environ.get("SUITE_DIR", "")).expanduser()
	if not suite or str(suite) in (".", ""):
		print("[rank-promotion] --suite-dir or SUITE_DIR required", file=sys.stderr)
		return 2
	suite = suite.resolve()
	if not suite.is_dir():
		print(f"[rank-promotion] suite dir not found: {suite}", file=sys.stderr)
		return 2

	walls = walls_from_suite(suite)
	wall_ratio = args.wall_ratio if args.wall_ratio is not None else primary_ratio(walls)

	compare_path = args.compare
	if compare_path is None:
		compare_path = find_profiler_compare(suite, args.profile_run_id)
	compare = load_json(compare_path) if compare_path else {}

	exhausted = [x.strip() for x in str(args.exhausted).split(",") if x.strip()]
	backlog = rank_paths(wall_ratio=wall_ratio, compare=compare, exhausted=exhausted)

	out = args.out
	if out is None:
		if compare_path is not None:
			out = compare_path.parent / "promotion_backlog.json"
		else:
			out = suite / "promotion_backlog.json"
	write_backlog(out, backlog)
	print(json.dumps(backlog, indent=2, sort_keys=True))
	print(f"[rank-promotion] wrote {out}", file=sys.stderr)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
