#!/usr/bin/env python3
"""Shared chrome-trace light parse for mcTracer / hcTracer smoke captures.

Produces absolute family totals + host_signals stub (ratios filled later by dual merge
when both baseline and candidate captures exist). Never invents InfiniLM↔vLLM wall ratios.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def _find_tracer_outs(raw_dir: Path) -> List[Path]:
	if not raw_dir.is_dir():
		return []
	hits = sorted(raw_dir.rglob("tracer_out*.json"))
	hits += [p for p in sorted(raw_dir.rglob("*.json")) if p not in hits]
	return [p for p in hits if p.is_file()]


def load_chrome_trace(path: Path) -> Tuple[Dict[str, Any], Optional[str]]:
	"""Load a chrome-trace JSON, repairing truncated hcTracer/mcTracer dumps.

	Large attach stops (SIGKILL after soft Ctrl+T) often leave the file without a
	closing `]}`. Recover all complete events up to the last `}`.
	"""
	text = path.read_text(encoding="utf-8", errors="replace")
	try:
		doc = json.loads(text)
		if isinstance(doc, dict):
			return doc, None
		raise json.JSONDecodeError("root not object", text, 0)
	except json.JSONDecodeError as exc:
		err = str(exc)
	# Truncated dumps usually end mid-object; close after the last complete `}`.
	# Cap attempts — each loads a multi-hundred-MB string.
	i = text.rfind("}")
	attempts = 0
	while i > 0 and attempts < 8:
		prefix = text[: i + 1].rstrip().rstrip(",")
		for suffix in ("\n]}\n", "]}\n"):
			try:
				doc = json.loads(prefix + suffix)
			except json.JSONDecodeError:
				continue
			if isinstance(doc, dict) and isinstance(doc.get("traceEvents"), list):
				return doc, f"repaired_truncated:{err}"
		i = text.rfind("}", 0, i)
		attempts += 1
	raise json.JSONDecodeError(f"unrecoverable chrome trace ({err})", text, 0)


def _sum_dur_us(events: List[Dict[str, Any]], pred) -> float:
	total = 0.0
	for e in events:
		if not isinstance(e, dict):
			continue
		if "dur" not in e:
			continue
		if not pred(e):
			continue
		try:
			total += float(e["dur"])
		except (TypeError, ValueError):
			continue
	return total


def _name(e: Dict[str, Any]) -> str:
	return str(e.get("name") or "")


def extract_family_totals(doc: Dict[str, Any]) -> Dict[str, float]:
	"""Map chrome-trace events → absolute family totals (µs)."""
	events = [e for e in (doc.get("traceEvents") or []) if isinstance(e, dict)]
	api_re = re.compile(r"^(hc|mc|cuda|cu)[A-Z]")
	memcpy_re = re.compile(r"memcpy|Memcpy|HTOD|DTOH", re.I)
	kernel_re = re.compile(r"vectorAdd|LaunchKernel|kernel", re.I)

	api_us = _sum_dur_us(
		events,
		lambda e: api_re.search(_name(e)) is not None and e.get("cat") in (None, "", "cpu"),
	)
	# Fallback: any host-side X event with null cat
	if api_us <= 0:
		api_us = _sum_dur_us(
			events,
			lambda e: e.get("ph") == "X" and e.get("cat") in (None, "") and "Launch" not in _name(e),
		)
	command_us = _sum_dur_us(
		events,
		lambda e: _name(e) in ("Launch", "hcLaunchKernel", "mcLaunchKernel", "cudaLaunchKernel")
		or e.get("cat") == "Launch",
	)
	kernel_us = _sum_dur_us(
		events,
		lambda e: (e.get("cat") not in (None, "", "Launch", "__metadata"))
		and kernel_re.search(_name(e)) is not None,
	)
	memcpy_us = _sum_dur_us(events, lambda e: memcpy_re.search(_name(e)) is not None)
	# Gap proxy: API span vs kernel+memcpy busy (non-negative).
	busy = kernel_us + memcpy_us
	gap_us = max(0.0, api_us + command_us - busy) if (api_us + command_us) > 0 else 0.0
	driver_us = _sum_dur_us(
		events,
		lambda e: _name(e).startswith(("hc", "mc", "cu")) and "Launch" not in _name(e),
	)
	runtime_us = api_us
	graph_us = _sum_dur_us(events, lambda e: "graph" in _name(e).lower() or "Graph" in _name(e))

	return {
		"api": api_us,
		"command": command_us,
		"kernel": kernel_us,
		"memcpy": memcpy_us,
		"gap": gap_us,
		"driver": driver_us,
		"runtime": runtime_us,
		"graph": graph_us,
	}


def totals_to_signals(
	totals: Dict[str, float],
	*,
	vendor: str,
	baseline_totals: Optional[Dict[str, float]] = None,
) -> List[Dict[str, Any]]:
	signals: List[Dict[str, Any]] = []
	for fam in ("api", "gap", "command", "driver", "runtime", "graph"):
		cand = float(totals.get(fam) or 0.0)
		if cand <= 0 and not (baseline_totals and float(baseline_totals.get(fam) or 0.0) > 0):
			continue
		base = float((baseline_totals or {}).get(fam) or 0.0) if baseline_totals else None
		if base is not None and base > 0:
			ratio = cand / base
		elif baseline_totals is None:
			# Single-role smoke: emit absolute as ratio=1.0 placeholder with note.
			ratio = 1.0
			base = cand
		else:
			continue
		signals.append(
			{
				"family": fam,
				"baseline": base,
				"candidate": cand if baseline_totals is not None else cand,
				"ratio": float(ratio),
				"mapped_from": vendor,
				"note": None
				if baseline_totals is not None
				else "single-role absolute totals; dual merge fills InfiniLM/vLLM ratio",
			}
		)
	return signals


def parse_outs(
	raw_dir: Path,
	*,
	vendor: str,
) -> Tuple[List[Dict[str, Any]], Dict[str, float], List[Dict[str, Any]]]:
	outs = _find_tracer_outs(raw_dir)
	totals: Dict[str, float] = {}
	provenance: List[Dict[str, Any]] = []
	for p in outs:
		stat = p.stat()
		provenance.append({"path": str(p), "bytes": stat.st_size})
		try:
			doc, repair_note = load_chrome_trace(p)
		except (OSError, json.JSONDecodeError, MemoryError) as exc:
			provenance[-1]["error"] = str(exc)
			continue
		if repair_note:
			provenance[-1]["repair"] = repair_note
		if not isinstance(doc, dict):
			continue
		part = extract_family_totals(doc)
		for k, v in part.items():
			totals[k] = float(totals.get(k) or 0.0) + float(v)
	signals = totals_to_signals(totals, vendor=vendor)
	return signals, totals, provenance


def write_summary(
	out_dir: Path,
	*,
	vendor: str,
	model: str = "Qwen3-8B",
	role: str = "candidate",
) -> Dict[str, Any]:
	raw_dir = out_dir / "raw"
	signals, totals, provenance = parse_outs(raw_dir, vendor=vendor)
	payload = {
		"source": f"{vendor} chrome_trace_light smoke (no invented wall ratios)",
		"vendor_profiler": vendor,
		"parser": f"{vendor}_host_signals",
		"model": model,
		"role": role,
		"host_signals": signals,
		"family_totals_us": totals,
		"capture_provenance": {
			"raw_dir": str(raw_dir),
			"tracer_outs": provenance,
		},
	}
	(out_dir / "host_signals.json").write_text(
		json.dumps(payload, indent=2) + "\n", encoding="utf-8"
	)
	compare = {
		"ok": True,
		"status": "SMOKE",
		"vendor_profiler": vendor,
		"model": model,
		"role": role,
		"host_signals": signals,
		"family_totals_us": totals,
		"note": f"{vendor} smoke compare stub; dual merge may overwrite ratios",
	}
	(out_dir / "compare.json").write_text(json.dumps(compare, indent=2) + "\n", encoding="utf-8")
	return payload


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--out-dir", type=Path, default=None)
	ap.add_argument("--vendor", default=os.environ.get("VENDOR_PROFILER", "mctracer"))
	ap.add_argument("--model", default=os.environ.get("MODEL", "Qwen3-8B"))
	ap.add_argument("--role", default=os.environ.get("ROLE", "candidate"))
	args = ap.parse_args()
	out_dir = (args.out_dir or Path(os.environ.get("OUT_DIR", "."))).expanduser().resolve()
	payload = write_summary(out_dir, vendor=args.vendor, model=args.model, role=args.role)
	print(
		f"[chrome-trace-light] wrote {out_dir}/host_signals.json "
		f"n_signals={len(payload.get('host_signals') or [])} "
		f"totals={payload.get('family_totals_us')}"
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
