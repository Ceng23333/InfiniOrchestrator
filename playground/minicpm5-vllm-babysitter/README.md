# Playground: stock vLLM + vllm_minicpm5 plugin (MiniCPM5 MoE)

Serve `minicpm5` via stock MetaX HPCC vLLM with the in-tree
[`vllm_minicpm5/`](./vllm_minicpm5) plugin (baked to `/opt/vllm_minicpm5` in the
wrap image), wrapped by `infini-babysitter`.

A compatibility symlink remains at `/root/zenghua/vllm_minicpm5` → this tree.

## Quickstart

```bash
cd InfiniOrchestrator/playground/minicpm5-vllm-babysitter

ln -sfn minicpm5.16a3.v0314 /root/zenghua/models/minicpm5
./build-wrap-image.sh
./run-wrap.sh

curl -s "http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minicpm5-vllm-babysitter):18180/v1/models"
```

Stop: `./stop-wrap.sh`

## LongBench short+easy

```bash
export BENCH_WAREHOUSE_REPO=/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/worktree/bench-warehouse
export LONGBENCH_OFFICIAL_ROOT="${BENCH_WAREHOUSE_REPO}/third_party/LongBench"
export LONGBENCH_DATA_JSON="${BENCH_WAREHOUSE_REPO}/third_party/LongBench-data/data.json"
export BENCH_BACKEND=vllm
export DEV_CONTAINER_NAME=minicpm5-vllm-babysitter
export DEV_PORT=18180
export BENCH_TARGET_URL=http://$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' minicpm5-vllm-babysitter):18180
export MODEL=minicpm5
export TOKENIZER_DIR=/opt/vllm_minicpm5/tokenizer_bytelevel
export LONGBENCH_LENGTH=short LONGBENCH_DIFFICULTY=easy LIMIT=0 ENABLE_THINKING=0
export HOST_ID=metax-152 PLATFORM=hpcc ARCH=aarch64 GPU_MODEL=metax-c500

"${BENCH_WAREHOUSE_REPO}/harness/run_bench_client.sh" longbench
```
