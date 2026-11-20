#!/usr/bin/env python3
"""Merge baseline+candidate light profiler outs → Qwen3-8B dual summary for continuous merge.

Writes:
  <suite_host>/qwen3_8b_profile_summary.json
  <suite_host>/profile_dual_host_signals.json  (alias payload)
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Optional


HOST_VENDOR = {
	"c610": "dlpti",
	"metax-showroom": "mctracer",
	"metax-9": "hctracer",
}
HOST_TRACK = {
	"c610": "qy",
	"metax-showroom": "metax",
	"metax-9": "mars",
}


def _load(path: Path) -> Optional[Dict[str, Any]]:
	if not path.is_file():
		return None
	try:
		doc = json.loads(path.read_text(encoding="utf-8"))
	except (OSError, json.JSONDecodeError):
		return None
	return doc if isinstance(doc, dict) else None


def _find_role_summary(role_dir: Path) -> Optional[Dict[str, Any]]:
	if not role_dir.is_dir():
		return None
	# Prefer newest profiler outs under profile/ (ignore wall compare at role root).
	cands: List[Path] = []
	cands += list(role_dir.glob("profile/*/host_signals.json"))
	cands += list(role_dir.glob("profile/*/compare.json"))
	# Newest mtime first; prefer attach_serve when present.
	def _rank(p: Path) -> tuple:
		doc = _load(p) or {}
		attach = 1 if (
			str(doc.get("profiler_mode") or "") == "attach_serve"
			or "matched_attach" in str(doc.get("source") or "")
		) else 0
		try:
			mtime = p.stat().st_mtime
		except OSError:
			mtime = 0.0
		return (attach, mtime)

	cands = sorted(set(cands), key=_rank, reverse=True)
	for p in cands:
		doc = _load(p)
		if not doc:
			continue
		# Skip wall-only stubs
		if doc.get("source") in ("evalscope", "evalscope_dual") and not doc.get("family_totals_us"):
			continue
		doc["_summary_path"] = str(p)
		return doc
	return None


def _totals(doc: Dict[str, Any]) -> Dict[str, float]:
	raw = doc.get("family_totals_us") or {}
	out: Dict[str, float] = {}
	if isinstance(raw, dict):
		for k, v in raw.items():
			try:
				out[str(k)] = float(v)
			except (TypeError, ValueError):
				continue
	if out:
		return out
	# Derive from host_signals absolute placeholders
	for sig in doc.get("host_signals") or []:
		if not isinstance(sig, dict):
			continue
		fam = sig.get("family")
		val = sig.get("candidate")
		if fam is None or val is None:
			continue
		try:
			out[str(fam)] = float(val)
		except (TypeError, ValueError):
			continue
	return out


def _detect_source(base: Optional[Dict[str, Any]], cand: Optional[Dict[str, Any]]) -> str:
	modes = {
		str((base or {}).get("profiler_mode") or ""),
		str((cand or {}).get("profiler_mode") or ""),
	}
	srcs = {
		str((base or {}).get("source") or ""),
		str((cand or {}).get("source") or ""),
	}
	if "attach_serve" in modes or any("matched_attach" in s for s in srcs):
		return "matched_attach_serve"
	if any("smoke" in s for s in srcs) or "smoke" in modes:
		return "synthesize_qwen3_8b_dual_profile_summary"
	return "synthesize_qwen3_8b_dual_profile_summary"


def merge_host_signals(
	base: Optional[Dict[str, Any]],
	cand: Optional[Dict[str, Any]],
	*,
	vendor: str,
	source: str,
) -> List[Dict[str, Any]]:
	bt = _totals(base or {})
	ct = _totals(cand or {})
	families = sorted(set(bt) | set(ct) | {"api", "gap", "command"})
	signals: List[Dict[str, Any]] = []
	note = (
		"matched attach_serve InfiniLM/vLLM family totals"
		if source == "matched_attach_serve"
		else "dual light smoke InfiniLM/vLLM family totals"
	)
	for fam in families:
		b = float(bt.get(fam) or 0.0)
		c = float(ct.get(fam) or 0.0)
		if b <= 0 and c <= 0:
			continue
		if b <= 0:
			# Keep absolute candidate-only row for Grafana abs panels (ratio null).
			signals.append(
				{
					"family": fam,
					"baseline": None,
					"candidate": c,
					"ratio": None,
					"mapped_from": vendor,
					"note": f"{note}; baseline missing",
				}
			)
			continue
		signals.append(
			{
				"family": fam,
				"baseline": b,
				"candidate": c,
				"ratio": c / b,
				"mapped_from": vendor,
				"note": note,
			}
		)
	return signals


def absolute_family_rows(
	base: Optional[Dict[str, Any]],
	cand: Optional[Dict[str, Any]],
	*,
	vendor: str,
) -> List[Dict[str, Any]]:
	"""Per-engine absolute family totals for Grafana cross-device vLLM baselines."""
	rows: List[Dict[str, Any]] = []
	for doc, engine, role in (
		(base, "vllm", "baseline"),
		(cand, "infinilm", "candidate"),
	):
		totals = _totals(doc or {})
		for fam, us in sorted(totals.items()):
			if float(us or 0.0) <= 0:
				continue
			rows.append(
				{
					"family": fam,
					"total_us": float(us),
					"engine": engine,
					"role": role,
					"mapped_from": vendor,
				}
			)
	return rows


def merge_dlpti(
	base: Optional[Dict[str, Any]],
	cand: Optional[Dict[str, Any]],
	*,
	source: str,
) -> Dict[str, Any]:
	"""Build DLPTI-shaped compare with infinilm_over_vllm ratios."""
	b = base or {}
	c = cand or {}
	b_dt = (b.get("device_totals") or {}).get("vllm") or (b.get("device_totals") or {}).get("infinilm") or {}
	c_dt = (c.get("device_totals") or {}).get("infinilm") or {}
	ratio: Dict[str, float] = {}
	for kind in ("cu_ms", "tu_ms", "memcpy_ms", "command_ms"):
		bv = float(b_dt.get(kind) or 0.0)
		cv = float(c_dt.get(kind) or 0.0)
		if bv > 0:
			# Chart expects infinilm_over_vllm kind names like cu_per_flash
			key = kind.replace("_ms", "_per_flash") if kind.endswith("_ms") else kind
			ratio[key] = cv / bv
	# categories: join by bucket
	b_cats = {
		str(x.get("bucket")): x
		for x in (b.get("categories") or [])
		if isinstance(x, dict) and x.get("bucket") is not None
	}
	c_cats = {
		str(x.get("bucket")): x
		for x in (c.get("categories") or [])
		if isinstance(x, dict) and x.get("bucket") is not None
	}
	categories = []
	for bucket in sorted(set(b_cats) | set(c_cats)):
		bc = b_cats.get(bucket) or {}
		cc = c_cats.get(bucket) or {}
		vllm_us = bc.get("vllm_us_per_flash")
		if vllm_us is None:
			vllm_us = bc.get("infinilm_us_per_flash")
		inf_us = cc.get("infinilm_us_per_flash")
		over = None
		try:
			if vllm_us is not None and float(vllm_us) > 0 and inf_us is not None:
				over = float(inf_us) / float(vllm_us)
		except (TypeError, ValueError):
			over = None
		categories.append(
			{
				"bucket": bucket,
				"infinilm_us_per_flash": inf_us,
				"vllm_us_per_flash": vllm_us,
				"infinilm_over_vllm": over,
			}
		)
	host = {
		"infinilm": ((c.get("host") or {}).get("infinilm") or {}),
		"vllm": ((b.get("host") or {}).get("vllm") or (b.get("host") or {}).get("infinilm") or {}),
	}
	return {
		"labels": {"a": "infinilm", "b": "vllm"},
		"device_totals": {
			"infinilm": c_dt,
			"vllm": b_dt,
			"infinilm_over_vllm": ratio,
		},
		"categories": categories,
		"host": host,
		"vendor_profiler": "dlpti",
		"parser": "dlpti_light_dual",
		"model": "Qwen3-8B",
		"dlpti_source": (
			"qwen3_8b dual matched_attach_serve DLPTI merge"
			if source == "matched_attach_serve"
			else "qwen3_8b dual in-container DLPTI light merge"
		),
	}


def synthesize_host(suite_host: Path, host: str) -> Dict[str, Any]:
	vendor = HOST_VENDOR.get(host, "none")
	track = HOST_TRACK.get(host, "other")
	base = _find_role_summary(suite_host / "profile_baseline")
	cand = _find_role_summary(suite_host / "profile_candidate")
	source = _detect_source(base, cand)
	signals = merge_host_signals(base, cand, vendor=vendor, source=source)
	abs_rows = absolute_family_rows(base, cand, vendor=vendor)
	payload: Dict[str, Any] = {
		"source": source,
		"model": "Qwen3-8B",
		"host": host,
		"device_track": track,
		"vendor_profiler": vendor,
		"host_signals": signals,
		"family_totals_abs": abs_rows,
		"baseline_family_totals_us": _totals(base or {}),
		"candidate_family_totals_us": _totals(cand or {}),
		"baseline_summary": (base or {}).get("_summary_path"),
		"candidate_summary": (cand or {}).get("_summary_path"),
		"baseline_engine": (base or {}).get("engine") or "vllm",
		"candidate_engine": (cand or {}).get("engine") or "infinilm",
	}
	if vendor == "dlpti":
		dlpti = merge_dlpti(base, cand, source=source)
		for k, v in dlpti.items():
			if k == "host":
				# Keep payload["host"] as hostname string; stash DLPTI sides here.
				payload["profile_host"] = v
			elif k == "dlpti_source":
				payload["dlpti_source"] = v
			else:
				payload[k] = v
		if not payload.get("host_signals"):
			payload["host_signals"] = signals
	return payload


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--suite-root", type=Path, required=True)
	ap.add_argument("--host", action="append", default=None)
	args = ap.parse_args()
	suite = args.suite_root.resolve()
	hosts = args.host or list(HOST_TRACK)
	for host in hosts:
		host_dir = suite / host
		if not host_dir.is_dir():
			print(f"[synth] skip missing {host_dir}", flush=True)
			continue
		payload = synthesize_host(host_dir, host)
		out = host_dir / "qwen3_8b_profile_summary.json"
		out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
		(host_dir / "profile_dual_host_signals.json").write_text(
			json.dumps(
				{
					"source": payload["source"],
					"vendor_profiler": payload["vendor_profiler"],
					"parser": f"{payload['vendor_profiler']}_host_signals",
					"model": "Qwen3-8B",
					"host_signals": payload.get("host_signals") or [],
					"family_totals_abs": payload.get("family_totals_abs") or [],
				},
				indent=2,
			)
			+ "\n",
			encoding="utf-8",
		)
		n = len(payload.get("host_signals") or [])
		n_cat = len(payload.get("categories") or [])
		n_abs = len(payload.get("family_totals_abs") or [])
		print(
			f"[synth] {host}: source={payload['source']} host_signals={n} "
			f"abs_family={n_abs} categories={n_cat} → {out}",
			flush=True,
		)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
