"""Build IterFact.walls[] from suite compare.json / summaries."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional


def load_json(path: Path) -> Dict[str, Any]:
	if not path.is_file():
		return {}
	return json.loads(path.read_text(encoding="utf-8"))


def _ratio(candidate: Optional[float], baseline: Optional[float]) -> Optional[float]:
	if candidate is None or baseline is None:
		return None
	if baseline == 0:
		return None
	return float(candidate) / float(baseline)


def _gate_throughput(ratio: Optional[float], floor: float = 0.50) -> str:
	if ratio is None:
		return "NO_GO"
	if ratio > 1.0:
		return "SURPASS"
	if ratio < floor:
		return "PROFILE_REGRESS"
	return "PASS" if ratio >= floor else "NO_GO"


def _gate_ttft(ratio: Optional[float], max_ratio: float = 1.25) -> str:
	"""Higher TTFT is worse; ratio is candidate/baseline."""
	if ratio is None:
		return "NO_GO"
	if ratio > max_ratio:
		return "PROFILE_REGRESS"
	return "PASS"


def _gate_success(candidate: Optional[float], min_rate: float = 0.99) -> str:
	if candidate is None:
		return "NO_GO"
	if candidate < min_rate:
		return "PROFILE_REGRESS"
	return "PASS"


def walls_from_aiperf_compare(compare: Dict[str, Any], *, source: str = "aiperf") -> List[Dict[str, Any]]:
	"""Normalize AIPerf dual compare.json into walls[] (tok/s primary)."""
	baseline = compare.get("baseline") or {}
	candidate = compare.get("candidate") or {}
	tok_floor = float(compare.get("tok_s_floor") or 0.50)
	ttft_max = float(compare.get("ttft_p95_max_ratio") or 1.25)
	ok_min = float(compare.get("success_rate_min") or 0.99)

	walls: List[Dict[str, Any]] = []

	base_tok = baseline.get("tok_s")
	cand_tok = candidate.get("tok_s")
	tok_ratio = compare.get("tok_s_ratio")
	if tok_ratio is None:
		tok_ratio = _ratio(
			float(cand_tok) if cand_tok is not None else None,
			float(base_tok) if base_tok is not None else None,
		)
	if base_tok is not None and cand_tok is not None and tok_ratio is not None:
		status = str(compare.get("status") or "")
		gate = status if status in {"PASS", "PROFILE_REGRESS", "SURPASS", "NO_GO"} else _gate_throughput(
			float(tok_ratio), tok_floor
		)
		# Prefer metric-local gate for throughput; if overall status is PROFILE_REGRESS
		# only due to TTFT, still mark tok with its own floor gate.
		if float(tok_ratio) < tok_floor:
			gate = "PROFILE_REGRESS"
		elif float(tok_ratio) > 1.0:
			gate = "SURPASS"
		elif gate == "PROFILE_REGRESS" and float(tok_ratio) >= tok_floor:
			gate = "PASS"
		walls.append(
			{
				"metric": "output_token_throughput_per_sec",
				"baseline": float(base_tok),
				"candidate": float(cand_tok),
				"WALL_DECODE_RATIO": float(tok_ratio),
				"gate": gate,
				"source": source,
				"primary": True,
			}
		)

	base_ttft = baseline.get("ttft_p95_ms")
	cand_ttft = candidate.get("ttft_p95_ms")
	ttft_ratio = compare.get("ttft_p95_ratio")
	if ttft_ratio is None:
		ttft_ratio = _ratio(
			float(cand_ttft) if cand_ttft is not None else None,
			float(base_ttft) if base_ttft is not None else None,
		)
	if base_ttft is not None and cand_ttft is not None and ttft_ratio is not None:
		walls.append(
			{
				"metric": "ttft_p95_ms",
				"baseline": float(base_ttft),
				"candidate": float(cand_ttft),
				"WALL_DECODE_RATIO": float(ttft_ratio),
				"gate": _gate_ttft(float(ttft_ratio), ttft_max),
				"source": source,
				"primary": False,
			}
		)

	base_ok = baseline.get("success_rate")
	cand_ok = candidate.get("success_rate")
	if cand_ok is not None:
		sr_ratio = _ratio(
			float(cand_ok),
			float(base_ok) if base_ok not in (None, 0) else 1.0,
		)
		walls.append(
			{
				"metric": "success_rate",
				"baseline": float(base_ok) if base_ok is not None else 1.0,
				"candidate": float(cand_ok),
				"WALL_DECODE_RATIO": float(sr_ratio if sr_ratio is not None else cand_ok),
				"gate": _gate_success(float(cand_ok), ok_min),
				"source": source,
				"primary": False,
			}
		)

	return walls


def _is_aiperf_compare(compare: Dict[str, Any]) -> bool:
	if "tok_s_ratio" in compare or "ttft_p95_ratio" in compare:
		return True
	base = compare.get("baseline")
	cand = compare.get("candidate")
	return isinstance(base, dict) and isinstance(cand, dict)


def walls_from_suite(suite_dir: Path) -> List[Dict[str, Any]]:
	compare_path = suite_dir / "compare.json"
	compare = load_json(compare_path)
	if not compare:
		return []
	# AIPerf dual shape (nested baseline/candidate objects or explicit ratios)
	if _is_aiperf_compare(compare):
		explicit = str(compare.get("source") or "").lower()
		if explicit in {"aiperf", "harness", "evalscope"}:
			source = explicit
		else:
			source = "aiperf"
			if str(compare.get("baseline_backend") or "").lower() not in ("", "vllm"):
				source = "harness"
		return walls_from_aiperf_compare(compare, source=source)
	# Generic harness wall (scalar baseline/candidate + WALL_DECODE_RATIO)
	ratio = compare.get("WALL_DECODE_RATIO") or compare.get("wall_ratio")
	base = compare.get("baseline")
	cand = compare.get("candidate")
	if isinstance(base, dict):
		base = base.get("tok_s") or base.get("value")
	if isinstance(cand, dict):
		cand = cand.get("tok_s") or cand.get("value")
	if ratio is None and base is not None and cand is not None:
		ratio = _ratio(float(cand), float(base))
	if ratio is None or base is None or cand is None:
		return []
	gate = str(compare.get("status") or compare.get("gate") or _gate_throughput(float(ratio)))
	if gate not in {"PASS", "PROFILE_REGRESS", "SURPASS", "NO_GO"}:
		gate = _gate_throughput(float(ratio))
	return [
		{
			"metric": str(compare.get("metric") or "decode_tok_s"),
			"baseline": float(base),
			"candidate": float(cand),
			"WALL_DECODE_RATIO": float(ratio),
			"gate": gate,
			"source": str(compare.get("source") or "harness"),
			"primary": True,
		}
	]


def primary_ratio(walls: List[Dict[str, Any]]) -> Optional[float]:
	for w in walls:
		if w.get("primary") is True:
			return float(w["WALL_DECODE_RATIO"])
	if walls:
		return float(walls[0]["WALL_DECODE_RATIO"])
	return None


def any_profile_regress(walls: List[Dict[str, Any]]) -> bool:
	return any(w.get("gate") == "PROFILE_REGRESS" for w in walls)
