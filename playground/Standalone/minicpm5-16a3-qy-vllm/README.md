# Playground: MiniCPM5.16a3 MoE + vLLM 0.21 (Denglin QY)

Serve `minicpm5.16a3.v0314` via stock Denglin `dl-vllm` 0.21 with the out-of-tree
`vllm_minicpm5` plugin (native `MiniCPM5MoEForCausalLM`).

Case id: `minicpm5-16a3-qy-vllm` (`case.toml`).

This is **not** the dense MiniCPM5-2B case. The 2B unify image deliberately omits
the MoE plugin; this wrap installs it on a derived 0.21 image.

## Prerequisites

```bash
# Extract once (uncompressed tar, ~28G weights)
tar -xf ~/models/minicpm5.16a3.v0314.tar -C ~/models
test -f ~/models/minicpm5.16a3.v0314/config.json
```

Base image must exist:

`dl-vllm-v0.21.0-docker-image:MR-4.2.1-202606231124-ubuntu22.04-x86_64-20260701`

## Quickstart

```bash
cd InfiniOrchestrator/playground/Standalone/minicpm5-16a3-qy-vllm
./build-wrap-image.sh
./run-wrap.sh

curl -s http://127.0.0.1:18181/v1/models
```

Stop: `./stop-wrap.sh`

## Notes

- Always pass `--tokenizer /opt/vllm_minicpm5/tokenizer_bytelevel` (checkpoint
  `LlamaTokenizerFast` rewrites ByteLevel → Metaspace and drops Chinese).
- Default `--max-model-len 8192` and `--gpu-memory-utilization 0.95` (weights alone
  are ~28 GiB on KS38; 0.85 leaves negative KV headroom after CUDA-graph profiling).
  Set `ENFORCE_EAGER=1` if KV is still tight.
- Denglin `dl_fused_moe` reads MoE JSON from
  `.../dl_platform_plugin/ops/configs/E=160,N=512,device_name=KS38_QUAD-3.json`
  (build script installs aliases there).
- Port `18181` avoids the 2B server on `18000`.
