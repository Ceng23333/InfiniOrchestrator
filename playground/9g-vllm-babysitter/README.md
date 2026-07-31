# Playground: stock vLLM wrapped by InfiniOrchestrator babysitter (9g)

Serve `9g_8b_thinking` via stock MetaX HPCC vLLM inside a wrap image that only
adds `infini-babysitter` (no InfiniLM / InfiniCore bake).

## Quickstart

```bash
cd InfiniOrchestrator/playground/9g-vllm-babysitter

# 1) Ensure host weights symlink (served-model-name = path basename)
ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking

# 2) Build wrap image (stock vllm-mars + infini-babysitter)
./build-wrap-image.sh

# 3) Run babysitter → vLLM on :18180
./run-wrap.sh

# 4) Health
curl -s "http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 9g-vllm-babysitter):18180/v1/models"
```

Stop:

```bash
./stop-wrap.sh
```

## Image / ports

| Item | Default |
|------|---------|
| `BASE_IMAGE` | `.../vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64` |
| `IMAGE_TAG` | `vllm-mars-babysitter:0.20.0-hpcc.ai3.7.0.102-9g` |
| `CONTAINER_NAME` | `9g-vllm-babysitter` |
| Serve port | `18180` |
| Config | [`config/master-9g_8b_thinking-vllm.toml`](config/master-9g_8b_thinking-vllm.toml) |

## LongBench (bench-warehouse)

```bash
export BENCH_WAREHOUSE_REPO=/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/worktree/bench-warehouse
export LONGBENCH_OFFICIAL_ROOT="${BENCH_WAREHOUSE_REPO}/third_party/LongBench"
export BENCH_BACKEND=vllm
export DEV_CONTAINER_NAME=9g-vllm-babysitter
export DEV_PORT=18180
export BENCH_TARGET_URL=http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 9g-vllm-babysitter):18180
export MODEL=9g_8b_thinking
export TOKENIZER_DIR=/models/9g_8b_thinking
export LONGBENCH_LENGTH=short LONGBENCH_DIFFICULTY=easy LIMIT=0 ENABLE_THINKING=0
export HOST_ID=metax-152 PLATFORM=hpcc ARCH=aarch64 GPU_MODEL=metax-c500

"${BENCH_WAREHOUSE_REPO}/harness/run_bench_client.sh" longbench
```
