# Playground: Qwen3-32B + vLLM (Standalone Hygon / tj-io-node00)

Daemon-only single worker (no etcd / load balancer). Slimmed from
`qwen3-32b+qwen3-32b--tj-vllm--m1`.

| Pin | Value |
|-----|--------|
| `case_id` | `qwen3-32b-tj-vllm--hygon` |
| Host | `tj-io-node00` (Hygon) |
| GPUs | `0,1,2,3` (TP=4) |
| Port | `18180` |
| Weights | `/private/zenghua/Qwen3-32B` |
| `ENTRYPOINT_BIN` | `/private/zenghua/staging/InfiniOrchestrator/phase2-m1/bin/infini-entrypoint` |
| `RUN_ROOT` | `/private/zenghua/runs/qwen3-32b-tj-vllm--hygon` |
| `--max-model-len` | `16384` (LongBench short + CoT headroom) |

Discovered on host (2026-09-20): InfiniEntrypoint lives under `phase2-m1/bin`
(not `staging/InfiniOrchestrator/bin`). vLLM is installed in `/opt/conda`
(Python 3.12); HPCC runtime is `/opt/hpcc` (3.5.3). No Docker on this node.

## Launch

On `tj-io-node00`, from a checkout of this case (or sync the case dir to the node):

```bash
bash scripts/daemon/daemon-start-worker.sh
bash scripts/daemon/daemon-status.sh
curl -s http://127.0.0.1:18180/v1/models
```

Stop: `bash scripts/daemon/daemon-stop.sh`

## LongBench

```bash
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```
