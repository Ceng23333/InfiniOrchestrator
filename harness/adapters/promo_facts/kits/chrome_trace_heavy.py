#!/usr/bin/env python3
"""Heavy chrome-trace parse for mcTracer / hcTracer kept raw.

Unlike chrome_trace_light (vectorAdd|kernel regex), this histograms real
kernel/event names and emits CU categories for dual rank.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Reuse light family totals when available.
try:
	from chrome_trace_light import (  # type: ignore
		_find_tracer_outs,
		extract_family_totals,
		load_chrome_trace,
		totals_to_signals,
	)
except ImportError:  # pragma: no cover
	from adapters.promo_facts.kits.chrome_trace_light import (  # type: ignore
		_find_tracer_outs,
		extract_family_totals,
		load_chrome_trace,
		totals_to_signals,
	)

SKIP_CATS = {None, "", "Launch", "__metadata", "cpu"}
API_RE = re.compile(r"^(hc|mc|cuda|cu)[A-Z]")
MEMCPY_RE = re.compile(r"memcpy|Memcpy|HTOD|DTOH|copy", re.I)


def _bucket_for(name: str) -> str:
	n = name.lower()
	if MEMCPY_RE.search(n):
		return "memcpy"
	if any(x in n for x in ("flash", "attn", "attention", "softmax", "sdpa")):
		return "attention"
	if any(x in n for x in ("gemm", "gemv", "matmul", "cublas", "blas", "sgemm", "hgemm", "bgemm")):
		return "gemm"
	if any(x in n for x in ("allreduce", "all_reduce", "nccl", "rccl", "mccl", "comm")):
		return "allreduce"
	if any(x in n for x in ("rope", "rotary")):
		return "rope"
	if any(x in n for x in ("rmsnorm", "layernorm", "norm")):
		return "residual_add_rmsnorm"
	if any(x in n for x in ("moe", "expert")):
		return "moe_fused"
	if "graph" in n:
		return "graph"
	if any(x in n for x in ("kv", "cache", "reshape", "transpose")):
		return "kv_cache_reshape"
	return "other"


def _is_device_kernel(e: Dict[str, Any]) -> bool:
	name = str(e.get("name") or "")
	cat = e.get("cat")
	if e.get("ph") not in ("X", "C", None) and e.get("ph") not in ("X",):
		# Prefer complete events with duration.
		pass
	if "dur" not in e:
		return False
	if cat in SKIP_CATS and API_RE.search(name):
		return False
	if name in ("Launch", "hcLaunchKernel", "mcLaunchKernel", "cudaLaunchKernel"):
		return False
	if cat in SKIP_CATS and not name:
		return False
	# Device kernels typically have a non-empty cat or look like kernel symbols.
	if cat not in SKIP_CATS:
		return True
	if MEMCPY_RE.search(name):
		return True
	# Demangled / mangled kernel-like names
	if "::" in name or name.startswith("_Z") or "kernel" in name.lower():
		return True
	return False


def histogram_kernels(docs: List[Dict[str, Any]], top_n: int = 40) -> List[Dict[str, Any]]:
	by_name: Dict[str, float] = defaultdict(float)
	by_count: Dict[str, int] = defaultdict(int)
	for doc in docs:
		for e in doc.get("traceEvents") or []:
			if not isinstance(e, dict) or not _is_device_kernel(e):
				continue
			name = str(e.get("name") or "unknown")
			try:
				dur = float(e["dur"])
			except (TypeError, ValueError, KeyError):
				continue
			by_name[name] += dur
			by_count[name] += 1
	ranked = sorted(by_name.items(), key=lambda kv: kv[1], reverse=True)
	out: List[Dict[str, Any]] = []
	for name, us in ranked[:top_n]:
		out.append(
			{
				"name": name,
				"total_us": us,
				"count": by_count[name],
				"bucket": _bucket_for(name),
			}
		)
	return out


def categories_from_hist(hist: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
	by_bucket: Dict[str, float] = defaultdict(float)
	for row in hist:
		by_bucket[str(row["bucket"])] += float(row["total_us"])
	total = sum(by_bucket.values()) or 1.0
	cats: List[Dict[str, Any]] = []
	for bucket, us in sorted(by_bucket.items(), key=lambda kv: kv[1], reverse=True):
		share = us / total
		cats.append(
			{
				"bucket": bucket,
				"path_id": bucket,
				"total_us": us,
				"share": share,
				# Single-role placeholder; dual merge fills InfiniLM/vLLM ratio.
				"ratio": 1.0,
				"material": share >= 0.05 and bucket not in ("other", "memcpy"),
			}
		)
	return cats


def parse_heavy(raw_dir: Path, *, vendor: str) -> Dict[str, Any]:
	outs = _find_tracer_outs(raw_dir)
	docs: List[Dict[str, Any]] = []
	provenance: List[Dict[str, Any]] = []
	totals: Dict[str, float] = {}
	for p in outs:
		stat = p.stat()
		provenance.append({"path": str(p), "bytes": stat.st_size})
		try:
			# Large traces may be truncated mid-flush after attach stop.
			doc, repair_note = load_chrome_trace(p)
		except (OSError, json.JSONDecodeError, MemoryError) as exc:
			provenance[-1]["error"] = str(exc)
			continue
		if repair_note:
			provenance[-1]["repair"] = repair_note
		if not isinstance(doc, dict):
			continue
		docs.append(doc)
		part = extract_family_totals(doc)
		for k, v in part.items():
			totals[k] = float(totals.get(k) or 0.0) + float(v)
	hist = histogram_kernels(docs)
	cats = categories_from_hist(hist)
	device_total_us = sum(float(c["total_us"]) for c in cats)
	signals = totals_to_signals(totals, vendor=vendor)
	return {
		"source": f"{vendor} chrome_trace_heavy",
		"vendor_profiler": vendor,
		"parser": f"{vendor}_heavy",
		"host_signals": signals,
		"family_totals_us": totals,
		"categories": cats,
		"device_totals": {"self_us": device_total_us},
		"kernel_histogram": hist,
		"capture_provenance": {"raw_dir": str(raw_dir), "tracer_outs": provenance},
	}


def write_summary(
	out_dir: Path,
	*,
	vendor: str,
	model: str = "Qwen3-8B",
	role: str = "candidate",
) -> Dict[str, Any]:
	raw_dir = out_dir / "raw"
	payload = parse_heavy(raw_dir, vendor=vendor)
	payload["model"] = model
	payload["role"] = role
	(out_dir / "host_signals.json").write_text(
		json.dumps(payload, indent=2) + "\n", encoding="utf-8"
	)
	compare = {
		"ok": True,
		"status": "HEAVY",
		"vendor_profiler": vendor,
		"parser": payload["parser"],
		"model": model,
		"role": role,
		"host_signals": payload["host_signals"],
		"family_totals_us": payload["family_totals_us"],
		"categories": payload["categories"],
		"device_totals": {role: payload["device_totals"]},
		"kernel_histogram_top": payload["kernel_histogram"][:15],
		"note": f"{vendor} heavy parse; dual merge fills InfiniLM/vLLM ratios",
	}
	(out_dir / "compare.json").write_text(json.dumps(compare, indent=2) + "\n", encoding="utf-8")
	(out_dir / "kernel_histogram.json").write_text(
		json.dumps({"kernels": payload["kernel_histogram"]}, indent=2) + "\n",
		encoding="utf-8",
	)
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
	n_cat = len(payload.get("categories") or [])
	n_hist = len(payload.get("kernel_histogram") or [])
	print(
		f"[chrome-trace-heavy] wrote {out_dir}/host_signals.json "
		f"categories={n_cat} hist={n_hist} totals={payload.get('family_totals_us')}"
	)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
