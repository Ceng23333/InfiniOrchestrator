# Playground: Qwen3-32B + InfiniLM (Standalone Hygon / tj-io-node00)

Daemon-only InfiniLM arm on host-native x86_64 HPCC/Mars (no Docker on tj).

| Pin | Value |
|-----|--------|
| `case_id` | `qwen3-32b-tj-inf--hygon` |
| Host | `tj-io-node00` (Hygon, `x86_64`) |
| Worktree | `v2026.08.12` |
| GPUs | `0,1,2,3` (TP=4) |
| Ports | API `8200` / babysitter `8201` |
| Weights | `/private/zenghua/Qwen3-32B` |
| `ENTRYPOINT_BIN` | `/private/zenghua/staging/InfiniOrchestrator/phase2-m1/bin/infini-entrypoint` |
| `INFINILM_ROOT` | `/private/zenghua/staging/InfiniLM` → ITW `…/InfiniTensorWorktree-v2026.08.12/InfiniLM` |
| `INFINICORE` | `/private/zenghua/staging/InfiniCore` → same ITW pin |
| `INFINI_ROOT` | `/private/zenghua/.infini` |
| `RUN_ROOT` | `/private/zenghua/runs/qwen3-32b-tj-inf--hygon` |

## Host status (2026-09-21)

- Model + InfiniEntrypoint + HPCC 3.5.3.20 + conda Mars torch 2.8 present
- Native rebuild completed: `_infinicore` / `_infinilm` are `cpython-312-x86_64-linux-gnu`
- No Docker on node (product image path not used)

## Launch

```bash
# from this case dir (or set CASE_DIR)
bash scripts/daemon/daemon-start-worker.sh
bash scripts/daemon/daemon-status.sh
curl -s http://127.0.0.1:8200/v1/models
```

Stop: `bash scripts/daemon/daemon-stop.sh`

## LongBench

```bash
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```
