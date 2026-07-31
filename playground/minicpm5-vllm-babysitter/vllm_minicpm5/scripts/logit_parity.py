#!/usr/bin/env python3
"""Compare next-token logits: HF vs native vLLM MiniCPM5."""
from __future__ import annotations

import os
import sys

import torch
import torch.nn.functional as F
from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer
from transformers.modeling_rope_utils import ROPE_INIT_FUNCTIONS


def fix_rope(model, cfg) -> None:
    rope = model.model.rotary_emb
    inv, scal = ROPE_INIT_FUNCTIONS["longrope"](cfg, device=torch.device("cpu"))
    rope.register_buffer("inv_freq", inv, persistent=False)
    rope.original_inv_freq = inv.clone()
    rope.attention_scaling = scal


def main() -> int:
    path = "/models/minicpm5.16a3.v0314"
    device = torch.device("cuda:0")
    tok = AutoTokenizer.from_pretrained(path, trust_remote_code=True)
    cfg = AutoConfig.from_pretrained(path, trust_remote_code=True)
    prompt = tok.apply_chat_template(
        [{"role": "user", "content": "Hello"}],
        tokenize=False,
        add_generation_prompt=True,
    )
    # Match HF generate path (includes bos via tokenizer)
    enc = tok(prompt, return_tensors="pt")
    input_ids = enc["input_ids"].to(device)
    print("IDS", input_ids.tolist(), flush=True)

    print("HF forward...", flush=True)
    hf = AutoModelForCausalLM.from_pretrained(
        path, trust_remote_code=True, dtype=torch.bfloat16
    )
    fix_rope(hf, cfg)
    hf = hf.to(device).eval()
    with torch.no_grad():
        out = hf(input_ids=input_ids)
        hf_logits = out.logits[0, -1].float()
    print(
        "HF top5",
        torch.topk(hf_logits, 5).indices.tolist(),
        torch.topk(hf_logits, 5).values.tolist(),
        flush=True,
    )
    del hf
    torch.cuda.empty_cache()

    print("vLLM forward...", flush=True)
    os.environ["VLLM_ALLOW_INSECURE_SERIALIZATION"] = "1"
    from vllm import LLM
    from vllm.plugins import load_general_plugins

    load_general_plugins()
    llm = LLM(
        model=path,
        trust_remote_code=True,
        dtype="bfloat16",
        max_model_len=1024,
        enforce_eager=True,
        gpu_memory_utilization=0.7,
    )

    # Use prompt logprobs / prompt only
    from vllm import SamplingParams

    sp = SamplingParams(temperature=0, max_tokens=1, prompt_logprobs=1)
    # Use raw prompt ids to match HF
    outs = llm.generate(
        [{"prompt_token_ids": input_ids[0].tolist()}], sp, use_tqdm=False
    )
    print("vLLM next", outs[0].outputs[0].token_ids, repr(outs[0].outputs[0].text))

    # Try to pull last-token logits via collective rpc if possible
    def grab(worker):
        # Not easy to get logits; return True
        return True

    try:
        llm.collective_rpc(grab)
    except Exception as e:
        print("rpc", e)

    # Compare via tokenizer decode of top tokens only
    print("HF decode top", [tok.decode([i]) for i in torch.topk(hf_logits, 5).indices])
    return 0


if __name__ == "__main__":
    sys.exit(main())
