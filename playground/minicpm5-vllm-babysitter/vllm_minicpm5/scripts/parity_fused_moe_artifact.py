#!/usr/bin/env python3
"""G2: pinned launcher parity vs vLLM fused_experts + moe_sum (recompile container).

Pass criteria (M5): bf16 max abs diff < 1e-2 for M in {1,16,512,4096};
``moe_sum`` matches vLLM ``_custom_ops`` when available.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Repo roots for imports when not installed.
_ROOT = Path(__file__).resolve().parents[2]
for p in (
    _ROOT / "InfiniLM" / "python",
    _ROOT / "InfiniCore" / "python",
    _ROOT / "vllm_minicpm5",
):
    s = str(p)
    if s not in sys.path:
        sys.path.insert(0, s)


def _write_gate(status: str, details: dict, error: str | None = None) -> Path:
    from infinilm.tools.gate_common import write_gate_result

    return write_gate_result("G2", status=status, details=details, error=error)


def main() -> int:
    Ms = [int(x) for x in os.environ.get("PARITY_MS", "1,16,512,4096").split(",") if x]
    H, E, N, TOP_K = 2048, 160, 512, 16
    details: dict = {"Ms": Ms, "threshold": 1e-2}
    # Warmup/parity may JIT and import vLLM.
    os.environ["INFINI_MOE_ALLOW_JIT"] = "1"
    if not os.environ.get("INFINI_MOE_CONFIGS"):
        print("FATAL: set INFINI_MOE_CONFIGS", file=sys.stderr)
        _write_gate("FAIL", details, "INFINI_MOE_CONFIGS unset")
        return 2
    if not (
        os.environ.get("INFINI_MOE_TRITON_CACHE") or os.environ.get("TRITON_CACHE_DIR")
    ):
        print("FATAL: set INFINI_MOE_TRITON_CACHE", file=sys.stderr)
        _write_gate("FAIL", details, "INFINI_MOE_TRITON_CACHE unset")
        return 2

    try:
        import torch
        from infinilm.kernels.fused_moe_runtime import fused_moe_routed, moe_sum

        if not torch.cuda.is_available():
            raise RuntimeError("G2 requires CUDA")

        device = torch.device("cuda", 0)
        dtype = torch.bfloat16
        torch.manual_seed(0)

        # moe_sum parity (torch + optional vLLM)
        cache3 = torch.randn(16, TOP_K, H, device=device, dtype=dtype)
        ours_sum = moe_sum(cache3)
        torch_sum = cache3.float().sum(dim=1).to(dtype)
        sum_vs_torch = (ours_sum.float() - torch_sum.float()).abs().max().item()
        details["moe_sum_vs_torch"] = sum_vs_torch
        if sum_vs_torch >= 1e-2:
            raise RuntimeError(f"moe_sum vs torch fail max_abs={sum_vs_torch}")

        try:
            from vllm import _custom_ops as vllm_ops

            vllm_out = torch.empty(16, H, device=device, dtype=dtype)
            vllm_ops.moe_sum(cache3, vllm_out)
            sum_vs_vllm = (ours_sum.float() - vllm_out.float()).abs().max().item()
            details["moe_sum_vs_vllm"] = sum_vs_vllm
            if sum_vs_vllm >= 1e-2:
                raise RuntimeError(f"moe_sum vs vLLM fail max_abs={sum_vs_vllm}")
        except ImportError as exc:
            details["moe_sum_vs_vllm"] = f"skipped: {exc}"

        try:
            from vllm.model_executor.layers.fused_moe import fused_experts
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(
                f"G2 requires vLLM fused_experts in recompile container: {exc}"
            ) from exc

        per_m: dict = {}
        # Scale like Xavier/real MoE init — unscaled randn yields O(1e6) activations
        # where bf16 absolute error is meaningless vs the 1e-2 gate threshold.
        scale = float(H) ** -0.5
        for M in Ms:
            torch.manual_seed(M)
            x = (torch.randn(M, H, device=device, dtype=dtype) * scale)
            topk_ids = torch.randint(0, E, (M, TOP_K), device=device, dtype=torch.int32)
            topk_w = torch.softmax(
                torch.randn(M, TOP_K, device=device, dtype=torch.float32), dim=-1
            ).to(dtype)
            w_gate_up = (
                torch.randn(E, 2 * N, H, device=device, dtype=dtype) * scale
            ).contiguous()
            w_down = (
                torch.randn(E, H, N, device=device, dtype=dtype) * scale
            ).contiguous()
            with torch.no_grad():
                out = fused_moe_routed(x, topk_w, topk_ids, w_gate_up, w_down)
                ref = fused_experts(
                    x, w_gate_up, w_down, topk_w, topk_ids, inplace=False
                )
            diff = (out.float() - ref.float()).abs().max().item()
            per_m[str(M)] = diff
            print(f"[G2] M={M} max_abs={diff:.6g}", flush=True)
            if diff >= 1e-2:
                raise RuntimeError(f"parity fail M={M} max_abs={diff} (>=1e-2)")

        details["max_abs_per_M"] = per_m
        details["weight_scale"] = scale
        path = _write_gate("PASS", details)
        print(f"[G2] PASS → {path}")
        return 0
    except Exception as exc:  # noqa: BLE001
        path = _write_gate("FAIL", details, str(exc))
        print(f"[G2] FAIL → {path}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
