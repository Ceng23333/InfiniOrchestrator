# Playground: 9g_8b_thinking + vLLM (Standalone)

Serve `9g_8b_thinking` via stock MetaX HPCC vLLM wrapped by **InfiniEntrypoint**.

Case id: `9g_8b_thinking-mxc500-vllm` (`case.toml`).

## Quickstart

```bash
cd InfiniOrchestrator/playground/Standalone/9g_8b_thinking-mxc500-vllm

ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking
./build-wrap-image.sh
./run-wrap.sh

curl -s "http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 9g-vllm-mxc500):18180/v1/models"
```

Stop: `./stop-wrap.sh`

## LongBench

```bash
source InfiniOrchestrator/scripts/worktree_env.sh
export CASE_ID=9g_8b_thinking-mxc500-vllm
export CASE_PATH="${IO_ROOT}/playground/Standalone/9g_8b_thinking-mxc500-vllm/case.toml"
export BENCH_BACKEND=vllm
export BENCH_TARGET_URL=http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 9g-vllm-mxc500):18180
export MODEL=9g_8b_thinking
export TOKENIZER_DIR=/models/9g_8b_thinking
export LONGBENCH_LENGTH=short LONGBENCH_DIFFICULTY=easy ENABLE_THINKING=0
export HOST_ID=metax-152 PLATFORM=hpcc ARCH=aarch64 GPU_MODEL=metax-c500

"${IO_ROOT}/harness/run_bench_client.sh" longbench
```
