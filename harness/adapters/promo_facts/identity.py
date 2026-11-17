"""Lift Standalone case.toml identity into CampaignFact fields."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, Optional


def parse_case_toml(path: Path) -> Dict[str, str]:
	out: Dict[str, str] = {}
	if not path.is_file():
		return out
	for line in path.read_text(encoding="utf-8").splitlines():
		line = line.strip()
		if not line or line.startswith("#") or line.startswith("["):
			continue
		if "=" not in line:
			continue
		key, _, val = line.partition("=")
		key = key.strip()
		val = val.strip().strip('"').strip("'")
		if key:
			out[key] = val
	return out


def resolve_case_path(raw: Optional[str] = None) -> Optional[Path]:
	candidate = (raw or os.environ.get("CASE_PATH") or "").strip()
	if not candidate:
		return None
	path = Path(candidate).expanduser()
	if path.is_dir():
		toml = path / "case.toml"
		return toml if toml.is_file() else None
	return path if path.is_file() else None


def campaign_identity_from_cases(
	*,
	case_baseline: Optional[str] = None,
	case_candidate: Optional[str] = None,
	device_track: Optional[str] = None,
	host: Optional[str] = None,
	vendor_profiler: Optional[str] = None,
) -> Dict[str, Any]:
	"""Build CampaignFact identity fields from case.toml paths / env."""
	base_path = resolve_case_path(case_baseline or os.environ.get("CASE_PATH_BASELINE"))
	cand_path = resolve_case_path(
		case_candidate or os.environ.get("CASE_PATH_CANDIDATE") or os.environ.get("CASE_PATH")
	)
	base = parse_case_toml(base_path) if base_path else {}
	cand = parse_case_toml(cand_path) if cand_path else {}

	track = (
		device_track
		or os.environ.get("DEVICE_TRACK")
		or _infer_track(cand.get("hw_profile_id") or base.get("hw_profile_id") or "")
	)
	out: Dict[str, Any] = {
		"device_track": track,
		"host": host or os.environ.get("HOST_ID") or os.environ.get("PROMO_HOST") or "",
		"vendor_profiler": vendor_profiler
		or os.environ.get("VENDOR_PROFILER")
		or _default_profiler(track),
		"hw_profile_id": cand.get("hw_profile_id")
		or base.get("hw_profile_id")
		or os.environ.get("HW_PROFILE_ID")
		or "",
		"hw_abbr": cand.get("hw_abbr") or base.get("hw_abbr") or os.environ.get("HW_ABBR") or "",
		"case_id_baseline": base.get("case_id") or "",
		"case_id_candidate": cand.get("case_id") or os.environ.get("CASE_ID") or "",
		"be_abbr_baseline": base.get("be_abbr") or "vllm",
		"be_abbr_candidate": cand.get("be_abbr") or "inf",
		"pin_baseline": base.get("worktree") or os.environ.get("PIN_BASELINE") or "vllm-frozen",
		"pin_candidate": cand.get("worktree")
		or os.environ.get("PIN_CANDIDATE")
		or os.environ.get("ITW_TAG")
		or "",
	}
	if cand.get("worktree"):
		out["worktree_candidate"] = cand["worktree"]
		out["itw_tag_candidate"] = cand["worktree"]
	if base.get("worktree"):
		out["worktree_baseline"] = base["worktree"]
		out["itw_tag_baseline"] = base["worktree"]
	return {k: v for k, v in out.items() if v not in (None, "")}


def _infer_track(hw_profile_id: str) -> str:
	hid = hw_profile_id.lower()
	if "denglin" in hid or "qy-ks" in hid:
		return "denglin_qy"
	if "metax" in hid:
		return "metax_qy"
	if "mars" in hid or "phytium" in hid or "hygon" in hid:
		return "mars"
	return os.environ.get("DEVICE_TRACK", "other")


def _default_profiler(track: str) -> str:
	return {
		"denglin_qy": "dlpti",
		"metax_qy": "mctracer",
		"mars": "none",
	}.get(track, "none")
