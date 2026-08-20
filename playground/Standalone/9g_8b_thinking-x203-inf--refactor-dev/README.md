# Playground: 9g_8b_thinking + InfiniLM (Standalone `--refactor-dev`)

Mars-device Standalone wrap for the `v2026.08.19-refactor-dev` pin. Adapted from `--refactor` (scripts/config/image layout). Product `--refactor` stays the blocked MetaX-xmake pin (`v2026.08.18-refactor`); do not reuse its IMAGE_TAG / runtime-base.

| Pin | Value |
|-----|--------|
| `case_id` | `9g_8b_thinking-x203-inf--refactor-dev` |
| Worktree | `v2026.08.19-refactor-dev` |
| `SOURCE_ROOT` | `InfiniTensorWorktree-refactor-dev` |
| Device | `--device mars` (eager step-1; no flash/graph) |
| Toolkit | `HPCC_PATH=/opt/hpcc` (do **not** alias `MACA_*`) |
| Container | `9g-inf-refactor-dev` |
| Image | `infini-orchestrator-metax:9g-refactor-dev-YYYYMMDD` |

GPU1 `infinilm-dev-refactor-dev` (`:8230`) is Mars rebuild/package only — not the LongBench target.

## Image

```bash
cd InfiniOrchestrator/playground/Standalone/9g_8b_thinking-x203-inf--refactor-dev
./image/build-image.sh
```

Does **not** overwrite `--deploy` `runtime-base-20260813` or `--main` `runtime-base-main-20260819`.

## Launch

```bash
ln -sfn 9g_8b_thinking_llama /root/zenghua/models/9g_8b_thinking
./run-wrap.sh
```

Default config: `config/ablation/master-step1.toml` (Mars eager; no paged/flash/graph — paged SIGBUS 135 on first chat). Stop: `./stop-wrap.sh`

## LongBench

```bash
LIMIT=1 LONGBENCH_LENGTH=short ./regression/run_longbench.sh
```
