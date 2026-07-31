#!/usr/bin/env python3
"""Compare HF MiniCPM5 MoE block vs vllm_minicpm5 FusedMoE block."""
from __future__ import annotations

import os
import sys

import torch
import torch.nn.functional as F
from transformers import AutoConfig, AutoModelForCausalLM


def main() -> int:
    model_path = os.environ.get("MODEL_PATH", "/models/minicpm5.16a3.v0314")
    device = torch.device("cuda:0")
    dtype = torch.bfloat16
    cfg = AutoConfig.from_pretrained(model_path, trust_remote_code=True)
    print("Loading HF...", flush=True)
    hf = AutoModelForCausalLM.from_pretrained(
        model_path, trust_remote_code=True, dtype=dtype
    ).to(device)
    hf.eval()

    # Fix rotary meta buffer if needed
    if hasattr(hf.model, "rotary_emb"):
        re = hf.model.rotary_emb
        if getattr(re, "inv_freq", None) is not None and re.inv_freq.is_meta:
            print("WARN rotary inv_freq is meta; skipping attn path", flush=True)

    os.environ.setdefault("RANK", "0")
    os.environ.setdefault("LOCAL_RANK", "0")
    os.environ.setdefault("WORLD_SIZE", "1")
    os.environ.setdefault("MASTER_ADDR", "127.0.0.1")
    os.environ.setdefault("MASTER_PORT", "29557")

    from vllm.config import ModelConfig, VllmConfig, set_current_vllm_config
    from vllm.distributed.parallel_state import (
        init_distributed_environment,
        initialize_model_parallel,
    )
    from vllm.plugins import load_general_plugins
    from vllm_minicpm5.model import MiniCPM5MoESparseMoeBlock

    load_general_plugins()
    model_config = ModelConfig(
        model=model_path,
        tokenizer=model_path,
        trust_remote_code=True,
        dtype="bfloat16",
        max_model_len=1024,
        seed=0,
    )
    vllm_config = VllmConfig(model_config=model_config)
    # initialize_model_parallel() requires current VllmConfig
    from contextlib import ExitStack

    stack = ExitStack()
    stack.enter_context(set_current_vllm_config(vllm_config))
    if not torch.distributed.is_initialized():
        init_distributed_environment(
            world_size=1,
            rank=0,
            distributed_init_method="env://",
            local_rank=0,
            backend="gloo",
        )
        initialize_model_parallel(tensor_model_parallel_size=1)

    layer1 = hf.model.layers[1]
    S = 16
    torch.manual_seed(0)
    x = torch.randn(S, cfg.hidden_size, device=device, dtype=dtype)
    with torch.no_grad():
        hf_out = layer1.mlp(x.unsqueeze(0)).view(S, -1)
    print("HF moe", float(hf_out.float().norm()), flush=True)

    with set_current_vllm_config(vllm_config):
        our = MiniCPM5MoESparseMoeBlock(
            vllm_config=vllm_config, prefix="model.layers.1.mlp"
        ).to(device=device, dtype=dtype)
        sd = layer1.mlp.state_dict()
        with torch.no_grad():
            our.gate.weight.copy_(sd["gate.weight"])
            our.gate.e_score_correction_bias.copy_(
                sd["gate.e_score_correction_bias"].float()
            )
            our.shared_experts.gate_up_proj.weight.copy_(
                torch.cat(
                    [
                        sd["shared_experts.gate_proj.weight"],
                        sd["shared_experts.up_proj.weight"],
                    ],
                    dim=0,
                )
            )
            our.shared_experts.down_proj.weight.copy_(
                sd["shared_experts.down_proj.weight"]
            )
            w1 = torch.stack(
                [
                    sd[f"experts.{i}.gate_proj.weight"]
                    for i in range(cfg.n_routed_experts)
                ]
            )
            w3 = torch.stack(
                [
                    sd[f"experts.{i}.up_proj.weight"]
                    for i in range(cfg.n_routed_experts)
                ]
            )
            w2 = torch.stack(
                [
                    sd[f"experts.{i}.down_proj.weight"]
                    for i in range(cfg.n_routed_experts)
                ]
            )
            our.experts.w13_weight.copy_(torch.cat([w1, w3], dim=1))
            our.experts.w2_weight.copy_(w2)

        from vllm.forward_context import set_forward_context

        with torch.no_grad(), set_forward_context(None, vllm_config, num_tokens=S):
            our_out = our(x)
        print("OUR moe", float(our_out.float().norm()), flush=True)
        diff = (our_out.float() - hf_out.float()).abs()
        print("maxabs", float(diff.max()), "meanabs", float(diff.mean()), flush=True)
        print(
            "cosine",
            float(
                F.cosine_similarity(
                    our_out.float().flatten(), hf_out.float().flatten(), dim=0
                )
            ),
            flush=True,
        )

        # Router-only: topk ids
        logits, _ = our.gate(x.float() if False else x)
        # force float32 like HF
        logits_f = F.linear(x.float(), our.gate.weight.float())
        scores = logits_f.sigmoid()
        bias = our.gate.e_score_correction_bias.float()
        choice = scores + bias
        hf_ids = []
        # use HF gate
        from importlib.machinery import SourceFileLoader

        # just call HF gate
        ids_hf, w_hf = layer1.mlp.gate(x.float())
        print("HF topk ids[0]", ids_hf[0].tolist()[:8], flush=True)
        # grouped topk from vllm
        from vllm.model_executor.layers.fused_moe.router.grouped_topk_router import (
            grouped_topk,
        )

        w_v, ids_v = grouped_topk(
            x,
            logits_f,
            topk=cfg.num_experts_per_tok,
            renormalize=True,
            num_expert_group=cfg.n_group,
            topk_group=cfg.topk_group,
            scoring_func="sigmoid",
            routed_scaling_factor=cfg.routed_scaling_factor,
            e_score_correction_bias=bias,
        )
        print("VL topk ids[0]", ids_v[0].tolist()[:8], flush=True)
        print(
            "ids match",
            bool(torch.equal(torch.sort(ids_hf[0])[0].cpu(), torch.sort(ids_v[0].long())[0].cpu())),
            flush=True,
        )
        print(
            "weights maxabs",
            float((w_hf[0].float() - w_v[0].float()).abs().max()),
            flush=True,
        )

    # Packing quick check on q
    attn = hf.model.layers[0].self_attn
    xh = torch.randn(1, 4, cfg.hidden_size, device=device, dtype=dtype)
    with torch.no_grad():
        qf = attn.q_proj(xh)
        q_hf, g_hf = torch.chunk(
            qf.view(1, 4, -1, attn.head_dim * 2), 2, dim=-1
        )
        qg = qf.view(1, 4, attn.num_attention_heads, 2 * attn.head_dim)
        q_us, g_us = qg.split([attn.head_dim, attn.head_dim], dim=-1)
        print("q pack diff", float((q_hf - q_us).abs().max()), flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
