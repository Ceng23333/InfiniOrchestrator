# Playground: 9g_8b_thinking + InfiniLM (Standalone `--main`)

Serve `9g_8b_thinking_llama` via InfiniLM wrapped by **InfiniEntrypoint**.

| Pin | Value |
|-----|--------|
| `case_id` | `9g_8b_thinking-x203-inf--main` |
| Worktree | `v2026.08.19-main-ic1510` |
| InfiniCore | InfiniTensor `main` `b2938e7d` (PR #1510 MetaX `select_last_token_hidden`) |
| InfiniLM | InfiniTensor `main` `62ef33d6` |
| `BASE_IMAGE_ID` | `1a3cbde5ff2a` |
| Container | `9g-inf-main` |
| Image | `infini-orchestrator-metax:9g-main-20260819` |

Upstream remotes: `https://github.com/InfiniTensor/InfiniCore.git` and `https://github.com/InfiniTensor/InfiniLM.git`.

InfiniCore pin `b2938e7d` is InfiniTensor PR #1510 (MetaX `select_last_token_hidden`). The pin snapshot also keeps the local HPCC 3.7 Mars flash-attn trailing-`bool` overlay (same as `v2026.08.18-main`) so `--flash-attn=.` links against the pip wheel.

## Image

```bash
cd InfiniOrchestrator/playground/Standalone/9g_8b_thinking-x203-inf--main
FORCE_XMAKE_BUILD=true ./image/build-image.sh   # Phase 1 runtime-base-main-20260819 + Phase 2 9g-main-YYYYMMDD
```

Does **not** overwrite `--deploy` `runtime-base-20260813`.

## Launch

Furthest green infer is **ablation step-1** (eager paged). Product `config/master-9g_8b_thinking.toml` still has step-3 flags (flash+graph) pending the ladder.

```bash
ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking
CONFIG_IN_CONTAINER=/config/ablation/master-step1.toml ./run-wrap.sh
curl -sf http://127.0.0.1:8100/v1/models
```

Stop: `./stop-wrap.sh`

## LongBench

```bash
LIMIT=8 ./regression/run_longbench.sh   # quick gate
./regression/run_longbench.sh
```
