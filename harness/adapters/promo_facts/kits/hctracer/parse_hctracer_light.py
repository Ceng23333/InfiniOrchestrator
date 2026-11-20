#!/usr/bin/env python3
"""Lightweight hcTracer smoke parse → promo host_signals.json (no fake wall ratios)."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

# Prefer sibling shared chrome-trace parser when available.
_PARENT = Path(__file__).resolve().parents[1]
if str(_PARENT) not in sys.path:
	sys.path.insert(0, str(_PARENT))
try:
	from chrome_trace_light import write_summary  # type: ignore
except Exception:  # noqa: BLE001
	write_summary = None  # type: ignore


def main() -> int:
	ap = argparse.ArgumentParser(description="Parse hcTracer smoke output lightly")
	ap.add_argument("--out-dir", type=Path, default=None)
	args = ap.parse_args()
	out_dir = (args.out_dir or Path(os.environ.get("OUT_DIR", "."))).expanduser().resolve()
	model = os.environ.get("MODEL", "Qwen3-8B")
	role = os.environ.get("ROLE", "candidate")
	if write_summary is not None:
		payload = write_summary(out_dir, vendor="hctracer", model=model, role=role)
		print(
			f"[hctracer-light] wrote {out_dir}/host_signals.json "
			f"n_signals={len(payload.get('host_signals') or [])}"
		)
		return 0

	# Minimal fallback if shared module missing.
	raw_dir = out_dir / "raw"
	payload = {
		"source": "hctracer smoke parse_hctracer_light fallback",
		"vendor_profiler": "hctracer",
		"parser": "hctracer_host_signals",
		"model": model,
		"host_signals": [],
		"capture_provenance": {"raw_dir": str(raw_dir)},
	}
	(out_dir / "host_signals.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
	(out_dir / "compare.json").write_text(
		json.dumps(
			{
				"ok": True,
				"status": "SMOKE",
				"vendor_profiler": "hctracer",
				"host_signals": [],
			},
			indent=2,
		)
		+ "\n",
		encoding="utf-8",
	)
	print(f"[hctracer-light] wrote {out_dir}/host_signals.json n_signals=0 (fallback)")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
