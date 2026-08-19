# Playground: 9g_8b_thinking + InfiniLM (Standalone `--deploy`)

Serve `9g_8b_thinking_llama` via InfiniLM wrapped by **InfiniEntrypoint**.

| Pin | Value |
|-----|--------|
| `case_id` | `9g_8b_thinking-x203-inf--deploy` |
| Worktree | `v2026.08.12` |
| InfiniCore | `6ad5e1c9` |
| InfiniLM | `4e0fdd7e` |
| `BASE_IMAGE_ID` | `1a3cbde5ff2a` |
| `IMAGE_TAG` | `infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813` (copied, not rebuilt) |
| Container | `9g-inf-deploy` |

Product image is the existing Distribution pin from `qwen3-32b+9g--x203-inf--opt20260811`. Do **not** run Phase 1/2 for this qualifier.

## Launch

```bash
cd InfiniOrchestrator/playground/Standalone/9g_8b_thinking-x203-inf--deploy
ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking
./run-wrap.sh
```

Stop: `./stop-wrap.sh`

## LongBench

```bash
LIMIT=8 ./regression/run_longbench.sh
./regression/run_longbench.sh
```
