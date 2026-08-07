#!/usr/bin/env python3
"""Native MiniCPM5 chat smoke (EN + ZH)."""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from vllm import LLM, SamplingParams
from vllm.plugins import load_general_plugins


def main() -> int:
    load_general_plugins()
    path = os.environ.get("MODEL_PATH", "/models/minicpm5.16a3.v0314")
    # LlamaTokenizerFast.from_pretrained rewrites ByteLevel → Metaspace and
    # drops non-Latin text; use the package ByteLevel tokenizer sidecar.
    tok_path = os.environ.get(
        "TOKENIZER_PATH",
        str(
            Path(__file__).resolve().parents[1] / "tokenizer_bytelevel"
        ),
    )
    out_path = Path(
        os.environ.get(
            "SMOKE_OUT",
            "/opt/offline/infinilm-metax-20260622/bench_results/"
            "minicpm5_hpcc37_20260714_165410/phase1_vllm_tuned/smoke_chat_fixed.json",
        )
    )
    llm = LLM(
        model=path,
        tokenizer=tok_path,
        trust_remote_code=True,
        dtype="bfloat16",
        max_model_len=1024,
        enforce_eager=True,
        gpu_memory_utilization=float(os.environ.get("GPU_MEM_UTIL", "0.7")),
    )
    sp = SamplingParams(temperature=0.0, max_tokens=64)
    o1 = llm.chat([{"role": "user", "content": "Hello"}], sp, use_tqdm=False)
    o2 = llm.chat(
        [{"role": "user", "content": "你好，请用一句话介绍你自己。"}],
        sp,
        use_tqdm=False,
    )
    payload = {
        "hello": {
            "text": o1[0].outputs[0].text,
            "token_ids": list(o1[0].outputs[0].token_ids),
        },
        "zh": {
            "text": o2[0].outputs[0].text,
            "token_ids": list(o2[0].outputs[0].token_ids),
        },
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2))
    print("HELLO:", o1[0].outputs[0].text[:240])
    print("ZH:", o2[0].outputs[0].text[:240])
    print("wrote", out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
