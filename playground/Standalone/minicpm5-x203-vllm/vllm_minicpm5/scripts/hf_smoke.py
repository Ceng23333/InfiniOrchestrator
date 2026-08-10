#!/usr/bin/env python3
"""HuggingFace MiniCPM5 smoke for compare with native vLLM."""
from __future__ import annotations

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer


def main() -> None:
    path = "/models/minicpm5.16a3.v0314"
    tok = AutoTokenizer.from_pretrained(path, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        path, trust_remote_code=True, dtype=torch.bfloat16
    ).cuda().eval()
    msgs = [{"role": "user", "content": "Hello"}]
    prompt = tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
    print("PROMPT", repr(prompt), flush=True)
    inputs = tok(prompt, return_tensors="pt")
    inputs = {k: v.cuda() for k, v in inputs.items()}
    print("INPUT_IDS", inputs["input_ids"].tolist(), flush=True)
    with torch.no_grad():
        out = model.generate(
            **inputs,
            max_new_tokens=32,
            do_sample=False,
        )
    new = out[0, inputs.input_ids.shape[1] :]
    print("NEW_IDS", new.tolist())
    print("TEXT", repr(tok.decode(new, skip_special_tokens=False)))


if __name__ == "__main__":
    main()
