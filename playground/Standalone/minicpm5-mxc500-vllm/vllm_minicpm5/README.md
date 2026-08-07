# vllm_minicpm5

Out-of-tree vLLM plugin registering native `MiniCPM5MoEForCausalLM` (FusedMoE + gated GQA + LongRoPE). Does **not** patch `vllm_mars`.

## Install (hpcc37)

```bash
pip install -e /opt/offline/infinilm-metax-20260622/vllm_minicpm5
```

## Tune MoE Triton config (X203)

```bash
HPCC_VISIBLE_DEVICES=2 python -m vllm_minicpm5.tools.benchmark_moe \
  --tune --save-dir /opt/offline/infinilm-metax-20260622/vllm_minicpm5/moe_configs
```

## Serve

**Tokenizer:** the checkpoint’s `LlamaTokenizerFast` rewrites the ByteLevel pre-tokenizer to Metaspace, so **Chinese (and other non-Latin) text is dropped**. Always pass the package sidecar:

```bash
export VLLM_TUNED_CONFIG_FOLDER=/opt/offline/infinilm-metax-20260622/vllm_minicpm5/moe_configs
export HPCC_VISIBLE_DEVICES=2
TOK=/opt/offline/infinilm-metax-20260622/vllm_minicpm5/tokenizer_bytelevel
vllm serve /models/minicpm5.16a3.v0314 --tokenizer "$TOK" \
  --host 0.0.0.0 --port 18180 \
  --dtype bfloat16 --trust-remote-code \
  --max-model-len 131072 --gpu-memory-utilization 0.85
```

Expect serve log: resolved arch `MiniCPM5MoEForCausalLM` and MoE config `H=2048,E=160,N=512,device_name=X203`.

## Smoke

```bash
TOKENIZER_PATH=/opt/offline/infinilm-metax-20260622/vllm_minicpm5/tokenizer_bytelevel \
  python /opt/offline/infinilm-metax-20260622/vllm_minicpm5/scripts/smoke_chat.py
```
