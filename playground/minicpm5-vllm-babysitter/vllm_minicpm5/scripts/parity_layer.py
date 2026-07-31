#!/usr/bin/env python3
"""Numerical parity: HF MiniCPM5 gated attn / MoE vs vllm_minicpm5 modules."""
from __future__ import annotations

import os
import sys

import torch
import torch.nn.functional as F
from transformers import AutoConfig, AutoModelForCausalLM


def main() -> int:
    model_path = os.environ.get("MODEL_PATH", "/models/minicpm5.16a3.v0314")
    device = torch.device("cuda:0" if torch.cuda.is_available() else "cpu")
    dtype = torch.bfloat16

    cfg = AutoConfig.from_pretrained(model_path, trust_remote_code=True)
    print("Loading HF model (may take a bit)...", flush=True)
    hf = AutoModelForCausalLM.from_pretrained(
        model_path, trust_remote_code=True, torch_dtype=dtype
    ).to(device)
    hf.eval()

    torch.manual_seed(0)
    B, S = 1, 8
    hidden = torch.randn(B, S, cfg.hidden_size, device=device, dtype=dtype)
    position_ids = torch.arange(S, device=device).unsqueeze(0)

    # --- HF layer0 attention ---
    layer0 = hf.model.layers[0]
    with torch.no_grad():
        # match HF decoder: norm then attn
        h_norm = layer0.input_layernorm(hidden)
        pos_emb = hf.model.rotary_emb(h_norm, position_ids)
        attn_out_hf, _ = layer0.self_attn(
            hidden_states=h_norm,
            position_embeddings=pos_emb,
            attention_mask=None,
            past_key_values=None,
            cache_position=torch.arange(S, device=device),
        )
        print("HF attn0 out", float(attn_out_hf.float().norm()), attn_out_hf.shape)

    # --- Manual gated path matching our packing vs HF packing ---
    attn = layer0.self_attn
    with torch.no_grad():
        x = h_norm
        input_shape = x.shape[:-1]
        q_full = attn.q_proj(x)
        q_hf, gate_hf = torch.chunk(
            q_full.view(*input_shape, -1, attn.head_dim * 2), 2, dim=-1
        )
        # our style reshape
        q_gate = q_full.view(*input_shape, attn.num_attention_heads, 2 * attn.head_dim)
        q_us, gate_us = q_gate.split([attn.head_dim, attn.head_dim], dim=-1)
        print(
            "q pack maxabs diff",
            float((q_hf - q_us).abs().max()),
            "gate",
            float((gate_hf - gate_us).abs().max()),
        )

        # Flat half packing (wrong) for contrast
        q_flat, gate_flat = q_full.chunk(2, dim=-1)
        print(
            "flat-vs-hf q maxabs",
            float((q_hf.reshape(*input_shape, -1) - q_flat).abs().max()),
        )

    # --- Init vLLM modules ---
    os.environ.setdefault("RANK", "0")
    os.environ.setdefault("LOCAL_RANK", "0")
    os.environ.setdefault("WORLD_SIZE", "1")
    os.environ.setdefault("MASTER_ADDR", "127.0.0.1")
    os.environ.setdefault("MASTER_PORT", "29555")

    from vllm.config import (
        CacheConfig,
        DeviceConfig,
        ModelConfig,
        ParallelConfig,
        SchedulerConfig,
        VllmConfig,
        set_current_vllm_config,
    )
    from vllm.distributed.parallel_state import (
        init_distributed_environment,
        initialize_model_parallel,
    )
    from vllm.plugins import load_general_plugins

    load_general_plugins()
    if not torch.distributed.is_initialized():
        init_distributed_environment(
            world_size=1, rank=0, distributed_init_method="env://", local_rank=0, backend="gloo"
        )
        initialize_model_parallel(tensor_model_parallel_size=1)

    model_config = ModelConfig(
        model=model_path,
        tokenizer=model_path,
        trust_remote_code=True,
        dtype="bfloat16",
        max_model_len=1024,
        seed=0,
    )
    vllm_config = VllmConfig(
        model_config=model_config,
        cache_config=CacheConfig(block_size=16),
        parallel_config=ParallelConfig(),
        scheduler_config=SchedulerConfig(max_model_len=1024),
        device_config=DeviceConfig(device="cuda"),
    )

    from vllm_minicpm5.model import MiniCPM5MoEAttention, _rope_params

    with set_current_vllm_config(vllm_config):
        our_attn = MiniCPM5MoEAttention(
            hidden_size=cfg.hidden_size,
            num_heads=cfg.num_attention_heads,
            num_kv_heads=cfg.num_key_value_heads,
            rope_parameters=_rope_params(cfg),
            max_position_embeddings=cfg.max_position_embeddings,
            head_dim=cfg.head_dim,
            qkv_bias=bool(cfg.attention_bias),
            use_gated_attention=True,
            cache_config=vllm_config.cache_config,
            quant_config=None,
            prefix="model.layers.0.self_attn",
        ).to(device=device, dtype=dtype)

        # copy weights from HF
        with torch.no_grad():
            our_attn.q_proj.weight.copy_(attn.q_proj.weight)
            our_attn.k_proj.weight.copy_(attn.k_proj.weight)
            our_attn.v_proj.weight.copy_(attn.v_proj.weight)
            our_attn.o_proj.weight.copy_(attn.o_proj.weight)

        # vLLM attention needs forward context; skip full attn module —
        # instead compare QKV+RoPE pre-attn only via hooks
        x2 = h_norm.view(S, cfg.hidden_size)  # native vllm 2d tokens
        positions = torch.arange(S, device=device)
        q_gate, _ = our_attn.q_proj(x2)
        q_gate_v = q_gate.view(S, our_attn.num_heads, 2 * our_attn.head_dim)
        q_o, gate_o = q_gate_v.split([our_attn.head_dim, our_attn.head_dim], dim=-1)
        q_o = q_o.reshape(S, our_attn.q_size)
        gate_o = gate_o.reshape(S, our_attn.q_size)
        k_o, _ = our_attn.k_proj(x2)
        v_o, _ = our_attn.v_proj(x2)

        # HF q flattened after chunk
        q_hf_flat = q_hf.reshape(S, -1)
        print("q our-vs-hf", float((q_o - q_hf_flat).abs().max()))
        print("gate our-vs-hf", float((gate_o - gate_hf.reshape(S, -1)).abs().max()))
        print("k our-vs-hf", float((k_o - attn.k_proj(x2)).abs().max()))
        print("v our-vs-hf", float((v_o - attn.v_proj(x2)).abs().max()))

        q_rope, k_rope = our_attn.rotary_emb(positions, q_o, k_o)
        # HF rope on [B,H,S,D]
        cos, sin = pos_emb
        q_hf_bhsd = q_hf.transpose(1, 2)  # already heads-first from HF path before rope?
        # Recompute HF pre-rope query/key in HF layout
        q_states = q_hf.transpose(1, 2)  # [B, H, S, D]
        k_states = attn.k_proj(x).view(B, S, -1, attn.head_dim).transpose(1, 2)
        from transformers.models.llama.modeling_llama import apply_rotary_pos_emb as _arp

        # Use the one from modeling file
        sys.path.insert(0, model_path)
        import modeling_minicpm as mm

        q_hf_r, k_hf_r = mm.apply_rotary_pos_emb(q_states, k_states, cos, sin)
        # reshape our rope to compare: our q_rope is [S, H*D]
        q_ours_r = q_rope.view(S, cfg.num_attention_heads, cfg.head_dim).permute(1, 0, 2)
        # HF [B,H,S,D] -> [H,S,D]
        q_hf_r2 = q_hf_r[0]
        print(
            "rope q maxabs",
            float((q_ours_r.float() - q_hf_r2.float()).abs().max()),
            "norm our",
            float(q_ours_r.float().norm()),
            "norm hf",
            float(q_hf_r2.float().norm()),
        )
        k_ours_r = k_rope.view(S, cfg.num_key_value_heads, cfg.head_dim).permute(1, 0, 2)
        k_hf_r2 = k_hf_r[0]
        print(
            "rope k maxabs",
            float((k_ours_r.float() - k_hf_r2.float()).abs().max()),
        )

    # --- MoE block layer1: HF vs FusedMoE ---
    from vllm_minicpm5.model import MiniCPM5MoESparseMoeBlock

    layer1 = hf.model.layers[1]
    with torch.no_grad():
        x_moe = torch.randn(S, cfg.hidden_size, device=device, dtype=dtype)
        hf_moe = layer1.mlp(x_moe.unsqueeze(0)).view(S, -1)
        print("HF moe norm", float(hf_moe.float().norm()))

    with set_current_vllm_config(vllm_config):
        our_moe = MiniCPM5MoESparseMoeBlock(
            vllm_config=vllm_config, prefix="model.layers.1.mlp"
        ).to(device=device, dtype=dtype)
        # load from HF state
        sd = layer1.mlp.state_dict()
        # map into fused
        with torch.no_grad():
            our_moe.gate.weight.copy_(sd["gate.weight"])
            our_moe.gate.e_score_correction_bias.copy_(sd["gate.e_score_correction_bias"])
            # shared
            our_moe.shared_experts.gate_up_proj.weight.copy_(
                torch.cat(
                    [sd["shared_experts.gate_proj.weight"], sd["shared_experts.up_proj.weight"]],
                    dim=0,
                )
            )
            our_moe.shared_experts.down_proj.weight.copy_(sd["shared_experts.down_proj.weight"])
            # experts w13 / w2
            w1 = torch.stack(
                [sd[f"experts.{i}.gate_proj.weight"] for i in range(cfg.n_routed_experts)]
            )
            w3 = torch.stack(
                [sd[f"experts.{i}.up_proj.weight"] for i in range(cfg.n_routed_experts)]
            )
            w2 = torch.stack(
                [sd[f"experts.{i}.down_proj.weight"] for i in range(cfg.n_routed_experts)]
            )
            our_moe.experts.w13_weight.copy_(torch.cat([w1, w3], dim=1))
            our_moe.experts.w2_weight.copy_(w2)

        our_out = our_moe(x_moe)
        print("OUR moe norm", float(our_out.float().norm()))
        print("moe maxabs", float((our_out.float() - hf_moe.float()).abs().max()))
        print("moe meanabs", float((our_out.float() - hf_moe.float()).abs().mean()))
        cos = F.cosine_similarity(our_out.float().flatten(), hf_moe.float().flatten(), dim=0)
        print("moe cosine", float(cos))

    return 0


if __name__ == "__main__":
    sys.exit(main())
