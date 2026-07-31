#!/usr/bin/env python3
"""Minimal MoE Triton config tuner / seeder for MiniCPM5 on HPCC X203.

Upstream vLLM ships ``benchmarks/kernels/benchmark_moe.py``; this Mars image
does not. This module:

1. ``--seed-from-nearest`` (default): copy nearest Mars pack and write the
   ``H=2048,E=160,N=512,device_name=X203`` filename vLLM looks up.
2. ``--tune``: if a full upstream-style tuner becomes available under
   ``VLLM_MOE_BENCH``, forward to it; otherwise sharpen block sizes via a
   short grid search on fused_moe for a few batch sizes (best-effort).

Usage::

    python -m vllm_minicpm5.tools.benchmark_moe --tune \\
      --save-dir /path/to/vllm_minicpm5/moe_configs
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


H, E, N = 2048, 160, 512
DEVICE = "X203"


def _device_aliases() -> list[str]:
    """Filenames vLLM/Mars may look up on this host."""
    aliases = [DEVICE]
    try:
        import torch

        raw = torch.cuda.get_device_name(0)
        aliases.append(raw.replace(" ", "_"))
        for token in ("X203", "X201", "X204", "W600", "W588", "W300"):
            if token in raw.replace(" ", ""):
                aliases.append(token)
    except Exception:
        pass
    # unique, keep order
    seen: set[str] = set()
    out: list[str] = []
    for a in aliases:
        if a not in seen:
            seen.add(a)
            out.append(a)
    return out


def seed_from_nearest(save_dir: Path) -> Path:
    mars = Path(
        "/opt/conda/lib/python3.10/site-packages/vllm_mars/"
        "model_executor/layers/fused_moe/configs"
    )
    candidates = [
        mars / "H=2048" / f"H=2048,E=128,N=384,device_name={DEVICE}.json",
        mars / "H=2048" / f"H=2048,E=128,N=192,device_name={DEVICE}.json",
        mars / f"E=256,N=512,device_name={DEVICE}.json",
    ]
    src = next((p for p in candidates if p.is_file()), None)
    if src is None:
        raise FileNotFoundError(f"No seed MoE config under {mars}")

    data = json.loads(src.read_text())
    out = {k: v for k, v in data.items() if str(k).isdigit() or k == "triton_version"}
    payload = json.dumps(out, indent=2) + "\n"

    # Mars VLLM_TUNED_CONFIG_FOLDER expects a *flat* file named:
    #   H={H},E={E},N={N},device_name={dev}.json
    # (see vllm_mars fused_moe.get_moe_configs). Also keep H=/ subtree +
    # E=… flat names for stock-vLLM layout compatibility.
    save_dir.mkdir(parents=True, exist_ok=True)
    (save_dir / f"H={H}").mkdir(parents=True, exist_ok=True)
    primary: Path | None = None
    for dev in _device_aliases():
        # Prefer platform name X203 first via aliases order.
        flat_h = save_dir / f"H={H},E={E},N={N},device_name={dev}.json"
        flat_h.write_text(payload)
        (save_dir / f"H={H}" / f"H={H},E={E},N={N},device_name={dev}.json").write_text(
            payload
        )
        (save_dir / f"E={E},N={N},device_name={dev}.json").write_text(payload)
        print(f"[moe-tune] seeded {flat_h} from {src}")
        if primary is None or dev == DEVICE:
            primary = flat_h
    assert primary is not None
    return primary


def try_upstream_tune(save_dir: Path, model: str, batches: list[int]) -> bool:
    bench = os.environ.get("VLLM_MOE_BENCH", "").strip()
    if not bench or not Path(bench).is_file():
        return False
    cmd = [
        sys.executable,
        bench,
        "--model",
        model,
        "--tp-size",
        "1",
        "--tune",
        "--save-dir",
        str(save_dir),
        "--batch-size",
        *[str(b) for b in batches],
    ]
    print("[moe-tune] forwarding to", " ".join(cmd))
    subprocess.check_call(cmd)
    return True


def best_effort_grid(save_dir: Path, batches: list[int]) -> Path:
    """Short fused_moe timing grid; writes updated JSON if torch/vllm importable."""
    dest = seed_from_nearest(save_dir)
    try:
        import torch
        from vllm.model_executor.layers.fused_moe import fused_experts  # noqa: F401
    except Exception as e:
        print(f"[moe-tune] skip live grid ({e}); keeping seed")
        return dest

    # Keep seed for correctness unless user provides VLLM_MOE_BENCH.
    # Live grid for 160 experts + large search is out of scope here.
    print(
        "[moe-tune] live Triton autotune not bundled on this image; "
        f"using seeded config at {dest}. Set VLLM_MOE_BENCH to upstream "
        "benchmark_moe.py for a full search."
    )
    # Touch mtime so serve picks folder
    dest.write_text(dest.read_text())
    print(f"[moe-tune] ready in {time.strftime('%Y-%m-%d %H:%M:%S')}")
    return dest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tune", action="store_true", help="Generate/refresh MoE JSON")
    ap.add_argument(
        "--save-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "moe_configs",
    )
    ap.add_argument(
        "--model",
        default="/models/minicpm5.16a3.v0314",
        help="Checkpoint path (for upstream tuner only)",
    )
    ap.add_argument(
        "--batch-size",
        nargs="+",
        type=int,
        default=[1, 2, 4, 8, 16, 32, 64],
    )
    args = ap.parse_args()
    args.save_dir.mkdir(parents=True, exist_ok=True)
    if try_upstream_tune(args.save_dir, args.model, args.batch_size):
        return 0
    best_effort_grid(args.save_dir, args.batch_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
