# Playground: MiniCPM5 MoE + vLLM (Standalone)

Serve `minicpm5` via stock MetaX HPCC vLLM with in-tree `vllm_minicpm5/`, wrapped by **InfiniEntrypoint**.

Case id: `minicpm5-mxc500-vllm` (`case.toml`).

## Quickstart

```bash
cd InfiniOrchestrator/playground/Standalone/minicpm5-mxc500-vllm

ln -sfn minicpm5.16a3.v0314 /root/zenghua/models/minicpm5
./build-wrap-image.sh
./run-wrap.sh

curl -s "http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minicpm5-mxc500-vllm):18180/v1/models"
```

Stop: `./stop-wrap.sh`

## LongBench v2 short+easy+cot

```bash
source InfiniOrchestrator/scripts/worktree_env.sh
export HARDWARE_PROFILE_REPO="${HARDWARE_PROFILE_REPO}"
export BENCH_WAREHOUSE_REPO="${BENCH_WAREHOUSE_REPO}"
export CASE_ID=minicpm5-mxc500-vllm
export CASE_PATH="${IO_ROOT}/playground/Standalone/minicpm5-mxc500-vllm/case.toml"
export BENCH_BACKEND=vllm
export DEV_CONTAINER_NAME=minicpm5-mxc500-vllm
export DEV_PORT=18180
export BENCH_TARGET_URL=http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minicpm5-mxc500-vllm):18180
export MODEL=minicpm5
export TOKENIZER_DIR=/opt/vllm_minicpm5/tokenizer_bytelevel
export LONGBENCH_LENGTH=short LONGBENCH_DIFFICULTY=easy ENABLE_THINKING=1
export HOST_ID=metax-152 PLATFORM=hpcc ARCH=aarch64 GPU_MODEL=metax-c500

"${IO_ROOT}/harness/run_bench_client.sh" longbench
```
