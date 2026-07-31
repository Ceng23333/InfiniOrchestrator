"""Out-of-tree MiniCPM5 MoE plugin for vLLM (vllm.general_plugins)."""

from __future__ import annotations


def register() -> None:
    from vllm import ModelRegistry

    ModelRegistry.register_model(
        "MiniCPM5MoEForCausalLM",
        "vllm_minicpm5.model:MiniCPM5MoEForCausalLM",
    )


__all__ = ["register"]
