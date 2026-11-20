#!/usr/bin/env python3
"""Heavy DLPTI export parse — full activity histogram + CU categories.

Extends light parse with real activity-name histogram (not family-only smoke).
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
	from parse_dlpti_light import (  # type: ignore
		_activity_ms,
		_activity_name,
		_bucket_for,
		_load_export,
		summarize_activities,
	)
except ImportError:  # pragma: no cover
	from adapters.promo_facts.kits.dlpti.parse_dlpti_light import (  # type: ignore
		_activity_ms,
		_activity_name,
		_bucket_for,
		_load_export,
		summarize_activities,
	)


def histogram_activities(
	doc: Dict[str, Any], top_n: int = 40
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
	by_name: Dict[str, float] = defaultdict(float)
	by_count: Dict[str, int] = defaultdict(int)
	by_bucket: Dict[str, float] = defaultdict(float)
	for a in doc.get("activities") or []:
		if not isinstance(a, dict):
			continue
		name = _activity_name(a)
		kind = str(a.get("kind") or "")
		ms = _activity_ms(a)
		bucket = _bucket_for(name, kind)
		by_name[name] += ms
		by_count[name] += 1
		by_bucket[bucket] += ms
	ranked = sorted(by_name.items(), key=lambda kv: kv[1], reverse=True)
	hist = [
		{
			"name": name,
			"total_ms": ms,
			"count": by_count[name],
			"bucket": _bucket_for(name, ""),
		}
		for name, ms in ranked[:top_n]
	]
	total = sum(by_bucket.values()) or 1.0
	cats = []
	for bucket, ms in sorted(by_bucket.items(), key=lambda kv: kv[1], reverse=True):
		share = ms / total
		cats.append(
			{
				"bucket": bucket,
				"path_id": bucket,
				"total_ms": ms,
				"share": share,
				"ratio": 1.0,
				"material": share >= 0.05 and bucket not in ("other", "memcpy", "runtime_api"),
			}
		)
	return hist, cats


def write_summary(
	out_dir: Path,
	*,
	model: str = "Qwen3-8B",
	role: str = "candidate",
) -> Dict[str, Any]:
	raw_dir = out_dir / "raw"
	doc, paths = _load_export(raw_dir)
	if doc is None:
		payload = {
			"source": "dlpti_heavy",
			"vendor_profiler": "dlpti",
			"parser": "dlpti_heavy",
			"model": model,
			"role": role,
			"host_signals": [],
			"categories": [],
			"note": "no export.json activities found",
			"capture_provenance": {"raw_dir": str(raw_dir), "exports": [str(p) for p in paths]},
		}
		(out_dir / "host_signals.json").write_text(
			json.dumps(payload, indent=2) + "\n", encoding="utf-8"
		)
		return payload

	light = summarize_activities(doc)
	hist, cats = histogram_activities(doc)
	# Promote light family signals when present.
	family = light.get("family_totals_us") or light.get("family_totals") or {}
	signals = light.get("host_signals") or []
	if not signals and isinstance(family, dict):
		for fam, us in family.items():
			try:
				val = float(us)
			except (TypeError, ValueError):
				continue
			if val <= 0:
				continue
			signals.append(
				{
					"family": fam,
					"baseline": val,
					"candidate": val,
					"ratio": 1.0,
					"mapped_from": "dlpti",
					"note": "single-role absolute; dual merge fills ratio",
				}
			)
	payload = {
		"source": "dlpti_tools capture + parse_dlpti_heavy",
		"vendor_profiler": "dlpti",
		"parser": "dlpti_heavy",
		"model": model,
		"role": role,
		"host_signals": signals,
		"family_totals_us": family or light.get("family_totals_us"),
		"categories": cats,
		"device_totals": {"self_ms": sum(float(c["total_ms"]) for c in cats)},
		"activity_histogram": hist,
		"capture_provenance": {
			"raw_dir": str(raw_dir),
			"exports": [str(p) for p in paths],
			"activity_count": len(doc.get("activities") or []),
		},
	}
	# Merge any extra light fields (top_apis etc.)
	for k in ("top_apis", "cu_ms", "memcpy_ms", "command_ms"):
		if k in light:
			payload[k] = light[k]
	(out_dir / "host_signals.json").write_text(
		json.dumps(payload, indent=2) + "\n", encoding="utf-8"
	)
	compare = {
		"ok": True,
		"status": "HEAVY",
		"vendor_profiler": "dlpti",
		"parser": "dlpti_heavy",
		"model": model,
		"role": role,
		"host_signals": signals,
		"family_totals_us": payload.get("family_totals_us"),
		"categories": cats,
		"device_totals": {role: payload["device_totals"]},
		"activity_histogram_top": hist[:15],
		"note": "dlpti heavy parse; dual merge fills InfiniLM/vLLM ratios",
	}
	(out_dir / "compare.json").write_text(json.dumps(compare, indent=2) + "\n", encoding="utf-8")
	(out_dir / "activity_histogram.json").write_text(
		json.dumps({"activities": hist}, indent=2) + "\n", encoding="utf-8"
	)
	return payload


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--out-dir", type=Path, default=None)
	ap.add_argument("--model", default=os.environ.get("MODEL", "Qwen3-8B"))
	ap.add_argument("--role", default=os.environ.get("ROLE", "candidate"))
	args = ap.parse_args()
	out_dir = (args.out_dir or Path(os.environ.get("OUT_DIR", "."))).expanduser().resolve()
	payload = write_summary(out_dir, model=args.model, role=args.role)
	print(
		f"[dlpti-heavy] wrote {out_dir}/host_signals.json "
		f"categories={len(payload.get('categories') or [])} "
		f"acts={payload.get('capture_provenance', {}).get('activity_count')}"
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
