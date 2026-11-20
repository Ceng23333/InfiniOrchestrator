#!/usr/bin/env python3
"""Light-parse dlpti_tools JSON export → DLPTI-shaped compare + host_signals.

Produces enough structure for Grafana profile_categories / device_totals / top_apis
under model=Qwen3-8B. Dual merge fills InfiniLM-over-vLLM ratios when both roles exist.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def _load_export(raw_dir: Path) -> Tuple[Optional[Dict[str, Any]], List[Path]]:
	paths = sorted(raw_dir.rglob("export*.json")) + sorted(raw_dir.rglob("*.json"))
	seen = set()
	uniq: List[Path] = []
	for p in paths:
		if p in seen or not p.is_file():
			continue
		seen.add(p)
		uniq.append(p)
	for p in uniq:
		try:
			doc = json.loads(p.read_text(encoding="utf-8"))
		except (OSError, json.JSONDecodeError):
			continue
		if isinstance(doc, dict) and "activities" in doc:
			return doc, uniq
	return None, uniq


def _activity_name(act: Dict[str, Any]) -> str:
	return str(act.get("name") or act.get("api_name") or act.get("kind") or "unknown")


def _activity_ms(act: Dict[str, Any]) -> float:
	for key in ("duration", "dur", "elapsed_us", "time_us", "end_time"):
		if key not in act:
			continue
		try:
			val = float(act[key])
		except (TypeError, ValueError):
			continue
		# Heuristic: values that look like µs → ms
		if key.endswith("_us") or (key == "duration" and val > 1000):
			return val / 1000.0
		if key in ("duration", "dur") and val < 1000:
			return val
		if key == "end_time" and "start_time" in act:
			try:
				return max(0.0, (float(act["end_time"]) - float(act["start_time"])) / 1000.0)
			except (TypeError, ValueError):
				continue
		return val
	# start/end pair in ns/us
	if "start" in act and "end" in act:
		try:
			return max(0.0, (float(act["end"]) - float(act["start"])) / 1000.0)
		except (TypeError, ValueError):
			pass
	return 0.0


def _bucket_for(name: str, kind: str) -> str:
	n = name.lower()
	k = str(kind or "").lower()
	if "memcpy" in n or "copy" in n:
		return "memcpy"
	if "launch" in n or "kernel" in n or k in ("kernel", "cu"):
		return "attention" if "attn" in n or "flash" in n else "gemm"
	if "graph" in n:
		return "graph"
	if "alloc" in n or "malloc" in n or "free" in n:
		return "runtime_alloc"
	if k in ("cmd", "command"):
		return "command"
	if k in ("curt", "runtime", "driver"):
		return "runtime_api"
	return "other"


def summarize_activities(doc: Dict[str, Any]) -> Dict[str, Any]:
	acts = [a for a in (doc.get("activities") or []) if isinstance(a, dict)]
	by_bucket: Dict[str, float] = defaultdict(float)
	by_api: Dict[str, Dict[str, float]] = {}
	cu_ms = tu_ms = memcpy_ms = command_ms = 0.0
	for a in acts:
		name = _activity_name(a)
		kind = str(a.get("kind") or "")
		ms = _activity_ms(a)
		bucket = _bucket_for(name, kind)
		by_bucket[bucket] += ms
		k = kind.lower()
		if k in ("cu", "kernel") or "kernel" in name.lower():
			cu_ms += ms
		elif "memcpy" in name.lower() or "copy" in name.lower():
			memcpy_ms += ms
		elif k in ("cmd", "command") or "launch" in name.lower():
			command_ms += ms
		else:
			tu_ms += ms
		api = by_api.setdefault(name, {"sum_ms": 0.0, "count": 0.0})
		api["sum_ms"] += ms
		api["count"] += 1.0

	top_apis = []
	for name, st in sorted(by_api.items(), key=lambda kv: -kv[1]["sum_ms"])[:12]:
		count = max(1.0, st["count"])
		top_apis.append(
			{
				"name": name,
				"sum_ms": st["sum_ms"],
				"count": int(st["count"]),
				"mean_us": (st["sum_ms"] * 1000.0) / count,
			}
		)

	categories = []
	for bucket, ms in sorted(by_bucket.items(), key=lambda kv: -kv[1]):
		categories.append(
			{
				"bucket": bucket,
				"infinilm_us_per_flash": ms * 1000.0,  # absolute proxy until dual merge
				"vllm_us_per_flash": None,
				"infinilm_over_vllm": None,
			}
		)

	side = {
		"host_totals": {
			"driver_api_count": sum(1 for a in acts if "driver" in str(a.get("kind") or "").lower()),
			"runtime_api_count": len(acts),
			"driver_api_ms": tu_ms,
			"runtime_api_ms": tu_ms + command_ms,
			"command_count": sum(1 for a in acts if str(a.get("kind") or "").lower() in ("cmd", "command")),
			"command_ms": command_ms,
		},
		"timeline": {
			"cu_count": sum(1 for a in acts if str(a.get("kind") or "").lower() in ("cu", "kernel")),
			"cu_busy_ms": cu_ms,
			"cu_gap_count": 0,
			"cu_gap_sum_ms": max(0.0, (tu_ms + command_ms) - cu_ms),
			"cu_gap_p50_us": 0.0,
			"cu_gap_p95_us": 0.0,
			"cu_span_ms": cu_ms + memcpy_ms + command_ms,
			"cu_idle_fraction": 0.0,
		},
		"top_runtime_api": top_apis,
	}

	device_totals = {
		"infinilm": {
			"cu_ms": cu_ms,
			"tu_ms": tu_ms,
			"memcpy_ms": memcpy_ms,
			"command_ms": command_ms,
		},
		"vllm": {},
		"infinilm_over_vllm": {},
	}

	family_totals_us = {
		"api": (tu_ms + command_ms) * 1000.0,
		"command": command_ms * 1000.0,
		"gap": max(0.0, (tu_ms + command_ms) - cu_ms) * 1000.0,
		"driver": tu_ms * 1000.0,
		"runtime": tu_ms * 1000.0,
		"graph": float(by_bucket.get("graph") or 0.0) * 1000.0,
	}

	return {
		"device_totals": device_totals,
		"categories": categories,
		"host": {"infinilm": side, "vllm": {}},
		"family_totals_us": family_totals_us,
		"activity_count": len(acts),
	}


def write_summary(
	out_dir: Path,
	*,
	model: str = "Qwen3-8B",
	role: str = "candidate",
	side_label: Optional[str] = None,
) -> Dict[str, Any]:
	raw_dir = out_dir / "raw"
	doc, paths = _load_export(raw_dir)
	side_label = side_label or ("vllm" if role == "baseline" else "infinilm")
	if doc is None:
		payload = {
			"source": "dlpti_light (no export)",
			"vendor_profiler": "dlpti",
			"parser": "dlpti_light",
			"model": model,
			"role": role,
			"host_signals": [],
			"device_totals": {},
			"categories": [],
			"host": {},
			"capture_provenance": {"raw_dir": str(raw_dir), "exports": [str(p) for p in paths]},
		}
	else:
		parsed = summarize_activities(doc)
		# Role-aware host block: baseline → vllm side, candidate → infinilm side
		host_blk = {"infinilm": {}, "vllm": {}}
		dt = {"infinilm": {}, "vllm": {}, "infinilm_over_vllm": {}}
		if side_label == "vllm":
			host_blk["vllm"] = parsed["host"]["infinilm"]
			dt["vllm"] = parsed["device_totals"]["infinilm"]
			# categories store absolute under vllm_us_per_flash for baseline role
			cats = []
			for c in parsed["categories"]:
				cats.append(
					{
						"bucket": c["bucket"],
						"infinilm_us_per_flash": None,
						"vllm_us_per_flash": c["infinilm_us_per_flash"],
						"infinilm_over_vllm": None,
					}
				)
		else:
			host_blk["infinilm"] = parsed["host"]["infinilm"]
			dt["infinilm"] = parsed["device_totals"]["infinilm"]
			cats = parsed["categories"]

		signals = []
		for fam, us in (parsed.get("family_totals_us") or {}).items():
			if not us:
				continue
			signals.append(
				{
					"family": fam,
					"baseline": float(us),
					"candidate": float(us),
					"ratio": 1.0,
					"mapped_from": "dlpti",
					"note": "single-role absolute; dual merge fills ratio",
				}
			)
		payload = {
			"source": "dlpti_tools capture + parse_dlpti_light",
			"vendor_profiler": "dlpti",
			"parser": "dlpti_light",
			"model": model,
			"role": role,
			"labels": {"a": "infinilm", "b": "vllm"},
			"device_totals": dt,
			"categories": cats,
			"host": host_blk,
			"host_signals": signals,
			"family_totals_us": parsed.get("family_totals_us") or {},
			"capture_provenance": {
				"raw_dir": str(raw_dir),
				"exports": [str(p) for p in paths],
				"activity_count": parsed.get("activity_count"),
			},
		}

	(out_dir / "host_signals.json").write_text(
		json.dumps(
			{
				"source": payload["source"],
				"vendor_profiler": "dlpti",
				"parser": "dlpti_host_signals",
				"model": model,
				"role": role,
				"host_signals": payload.get("host_signals") or [],
				"family_totals_us": payload.get("family_totals_us") or {},
				"capture_provenance": payload.get("capture_provenance"),
			},
			indent=2,
		)
		+ "\n",
		encoding="utf-8",
	)
	(out_dir / "compare.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
	return payload


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--out-dir", type=Path, default=None)
	ap.add_argument("--model", default=os.environ.get("MODEL", "Qwen3-8B"))
	ap.add_argument("--role", default=os.environ.get("ROLE", "candidate"))
	args = ap.parse_args()
	out_dir = (args.out_dir or Path(os.environ.get("OUT_DIR", "."))).expanduser().resolve()
	payload = write_summary(out_dir, model=args.model, role=args.role)
	n_cat = len(payload.get("categories") or [])
	n_sig = len(payload.get("host_signals") or [])
	print(f"[dlpti-light] wrote {out_dir}/compare.json categories={n_cat} host_signals={n_sig}")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
