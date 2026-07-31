#!/usr/bin/env python3
"""Load native MiniCPM5, smoke decode, audit key weights vs checkpoint."""
from __future__ import annotations

import os
import sys

import torch
from vllm import LLM, SamplingParams
from vllm.plugins import load_general_plugins


def main() -> int:
    load_general_plugins()
    model_path = os.environ.get("MODEL_PATH", "/models/minicpm5.16a3.v0314")
    tok_path = os.environ.get(
        "TOKENIZER_PATH",
        "/opt/offline/infinilm-metax-20260622/vllm_minicpm5/tokenizer_bytelevel",
    )
    llm = LLM(
        model=model_path,
        tokenizer=tok_path,
        trust_remote_code=True,
        dtype="bfloat16",
        max_model_len=1024,
        enforce_eager=True,
        gpu_memory_utilization=float(os.environ.get("GPU_MEM_UTIL", "0.75")),
    )

    sp = SamplingParams(temperature=0.0, max_tokens=32)
    outs = llm.chat([{"role": "user", "content": "Hello"}], sp, use_tqdm=False)
    text = outs[0].outputs[0].text
    tids = outs[0].outputs[0].token_ids
    print("OUT:", repr(text))
    print("TOKEN_IDS:", list(tids)[:40])

    def _audit(worker_or_self):
        # v1 worker object
        runner = getattr(worker_or_self, "model_runner", None)
        if runner is None and hasattr(worker_or_self, "worker"):
            runner = worker_or_self.worker.model_runner
        model = runner.model
        bias = model.model.layers[1].mlp.gate.e_score_correction_bias
        print(
            "LIVE_BIAS",
            float(bias.float().mean()),
            float(bias.float().std()),
            float(bias.float().sum()),
        )
        w13 = model.model.layers[1].mlp.experts.w13_weight
        print("LIVE_W13", tuple(w13.shape), float(w13.float().norm()))
        q = model.model.layers[0].self_attn.q_proj.weight
        print("LIVE_Q", tuple(q.shape), float(q.float().norm()))
        return True

    try:
        llm.collective_rpc(_audit)
    except Exception as e:
        print("AUDIT_RPC_FAIL", type(e).__name__, e)
        try:
            eng = llm.llm_engine
            eng.engine_core.collective_rpc(_audit)
        except Exception as e2:
            print("AUDIT_RPC_FAIL2", type(e2).__name__, e2)

    ckpt = torch.load(
        f"{model_path}/pytorch_model.bin", map_location="cpu", weights_only=True
    )
    b = ckpt["model.layers.1.mlp.gate.e_score_correction_bias"]
    print("CKPT_BIAS", float(b.float().mean()), float(b.float().std()), float(b.float().sum()))
    q = ckpt["model.layers.0.self_attn.q_proj.weight"]
    print("CKPT_Q", tuple(q.shape), float(q.float().norm()))
    # one expert gate+up stack norm proxy
    g0 = ckpt["model.layers.1.mlp.experts.0.gate_proj.weight"]
    u0 = ckpt["model.layers.1.mlp.experts.0.up_proj.weight"]
    print("CKPT_E0_GATE", float(g0.float().norm()), "UP", float(u0.float().norm()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
