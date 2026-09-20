# Playground: Qwen3-32B + vLLM (Standalone phytium / metax-9)

Serve `Qwen3-32B` via stock MetaX HPCC vLLM wrapped by **InfiniEntrypoint**.

| Pin | Value |
|-----|--------|
| `case_id` | `qwen3-32b-x203-vllm--phytium` |
| Host | `metax-9` (Phytium) |
| GPUs | `0,1,2,3` (TP=4) |
| Port | `18180` |
| Weights | `/root/zenghua/models/Qwen3-32B` |
| Wrap image | `vllm-mars-entrypoint:0.20.0-hpcc.ai3.7.0.102-9g` |
| Container | `qwen-vllm-phytium` |

## Quickstart

```bash
cd InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-vllm--phytium
# rebuild wrap image only if missing on metax-9
./build-wrap-image.sh   # optional
./run-wrap.sh
```

Stop: `./stop-wrap.sh`

## LongBench

```bash
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```
