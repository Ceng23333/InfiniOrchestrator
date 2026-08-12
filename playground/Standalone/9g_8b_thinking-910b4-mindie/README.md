# Playground: 9g_8b_thinking + MindIE (Standalone)

Serve `9g_8b_thinking` through the official Ascend MindIE 2.3 image wrapped by
**InfiniEntrypoint**.

Case id: `9g_8b_thinking-910b4-mindie` (`case.toml`).

## Quickstart

```bash
cd /home/zenghua/workspace/profiling_20260812_ascend/InfiniOrchestrator/playground/Standalone/9g_8b_thinking-910b4-mindie
./build-wrap-image.sh
WAIT_READY=1 ./run-wrap.sh
```

Stop:

```bash
./stop-wrap.sh
```

## Benchmark environment

```bash
export CASE_ID=9g_8b_thinking-910b4-mindie
export CASE_PATH=/home/zenghua/workspace/profiling_20260812_ascend/InfiniOrchestrator/playground/Standalone/9g_8b_thinking-910b4-mindie/case.toml
export BENCH_BACKEND=oai
export BENCH_TARGET_URL=http://192.168.162.27:1135
export MODEL=9g_8b_thinking
export TOKENIZER_DIR=/data-aisoft/zenghua/models/9g_8b_thinking_llama
export HOST_ID=ascend PLATFORM=ascend ARCH=aarch64 GPU_MODEL=ascend-910B4
export HW_PROFILE_ID=ascend-910b4-ascend HW_ABBR=910B4
```

Runtime note: the case is pinned to host Ascend NPUs 2/3 via ASCEND_RT_VISIBLE_DEVICES; MindIE uses relative device ids 0/1 so it can coexist with the earlier standalone benchmark server on host NPUs 0/1.

Runtime note: MindIE run-daemon preserves ASCEND_RT_VISIBLE_DEVICES supplied by InfiniEntrypoint; npuDeviceIds remain relative [[0,1]].
