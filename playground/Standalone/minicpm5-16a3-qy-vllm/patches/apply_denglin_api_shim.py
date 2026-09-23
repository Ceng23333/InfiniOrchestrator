#!/usr/bin/env python3
"""Rewrite /opt/vllm_minicpm5/vllm_minicpm5/model.py for Denglin vLLM 0.21 API drift.

Idempotent. Safe to re-run. Leaves architecture unchanged; only softens imports
and filters kwargs that may be missing between vllm-mars 0.20 and dl-vllm 0.21.
"""
from __future__ import annotations

from pathlib import Path

PATH = Path("/opt/vllm_minicpm5/vllm_minicpm5/model.py")
MARKER = "DENGLIN_VLLM021_API_SHIM"


def main() -> None:
    text = PATH.read_text()
    if MARKER in text:
        print(f"already patched: {PATH}")
        return

    old_imports = '''from vllm.model_executor.layers.fused_moe import (
    FusedMoE,
    fused_moe_make_expert_params_mapping,
)
from vllm.model_executor.layers.fused_moe.router.gate_linear import GateLinear'''

    new_imports = f'''# {MARKER}
import inspect

from vllm.model_executor.layers.fused_moe import FusedMoE

try:
    from vllm.model_executor.layers.fused_moe import (
        fused_moe_make_expert_params_mapping,
    )
except ImportError:  # pragma: no cover - older / vendor layouts
    try:
        from vllm.model_executor.layers.fused_moe.layer import (
            fused_moe_make_expert_params_mapping,
        )
    except ImportError:
        from vllm.model_executor.models.utils import (  # type: ignore
            fused_moe_make_expert_params_mapping,
        )

try:
    from vllm.model_executor.layers.fused_moe.router.gate_linear import GateLinear
except ImportError:  # pragma: no cover
    try:
        from vllm.model_executor.layers.fused_moe.gate_linear import GateLinear
    except ImportError:
        from vllm.model_executor.layers.linear import ReplicatedLinear as _GateBase

        class GateLinear(_GateBase):  # type: ignore[no-redef]
            """Minimal GateLinear stand-in when vendor package lacks router.gate_linear."""

            def __init__(self, input_size: int, output_size: int, prefix: str = "") -> None:
                super().__init__(
                    input_size,
                    output_size,
                    bias=False,
                    params_dtype=None,
                    quant_config=None,
                    prefix=prefix,
                )
                self.e_score_correction_bias = None

            def set_out_dtype(self, dtype):  # noqa: ANN001
                self._out_dtype = dtype'''

    if old_imports not in text:
        raise SystemExit("expected FusedMoE/GateLinear import block not found; aborting")
    text = text.replace(old_imports, new_imports, 1)

    helper = '''
def _call_with_supported_kwargs(fn, *args, **kwargs):
    """Call fn, dropping kwargs not accepted by its signature (API drift)."""
    try:
        sig = inspect.signature(fn)
    except (TypeError, ValueError):
        return fn(*args, **kwargs)
    params = sig.parameters
    if any(p.kind == inspect.Parameter.VAR_KEYWORD for p in params.values()):
        return fn(*args, **kwargs)
    filtered = {k: v for k, v in kwargs.items() if k in params}
    dropped = sorted(set(kwargs) - set(filtered))
    if dropped:
        logger.warning(
            "Dropping unsupported kwargs for %s: %s",
            getattr(fn, "__qualname__", str(fn)),
            dropped,
        )
    return fn(*args, **filtered)


def _get_rope_compat(head_dim, max_position, rope_parameters):
    """Prefer rope_parameters= (newer); fall back to rope_scaling= (older)."""
    kwargs = {"max_position": max_position, "rope_parameters": rope_parameters}
    try:
        return _call_with_supported_kwargs(get_rope, head_dim, **kwargs)
    except TypeError:
        kwargs = {"max_position": max_position, "rope_scaling": rope_parameters}
        return _call_with_supported_kwargs(get_rope, head_dim, **kwargs)
'''

    anchor = "logger = init_logger(__name__)\n"
    if anchor not in text:
        raise SystemExit("logger anchor not found")
    text = text.replace(anchor, anchor + helper, 1)

    # Soften FusedMoE construction.
    text = text.replace(
        "        self.experts = FusedMoE(\n",
        "        self.experts = _call_with_supported_kwargs(\n            FusedMoE,\n",
        1,
    )

    # Soften get_rope construction.
    old_rope = """        self.rotary_emb = get_rope(
            self.head_dim,
            max_position=max_position_embeddings,
            rope_parameters=rope_parameters,
        )"""
    new_rope = """        self.rotary_emb = _get_rope_compat(
            self.head_dim,
            max_position_embeddings,
            rope_parameters,
        )"""
    if old_rope not in text:
        raise SystemExit("get_rope call site not found")
    text = text.replace(old_rope, new_rope, 1)

    PATH.write_text(text)
    print(f"patched: {PATH}")


if __name__ == "__main__":
    main()
