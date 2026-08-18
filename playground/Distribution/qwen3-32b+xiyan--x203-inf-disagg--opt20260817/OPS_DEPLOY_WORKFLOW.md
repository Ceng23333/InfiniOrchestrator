# Ops Deployment Workflow: qwen3-32b+xiyan target split

This runbook reproduces the forked case:

```text
qwen3-32b+xiyan--x203-inf-disagg--opt20260817
```

Target layout:

| Host | IP | Role | Services |
|------|----|------|----------|
| metax-8 | 172.31.1.8 | External FE + embedding | etcd, frontend, worker-embeddings-20002 |
| metax-9 | 172.31.1.9 | LLM workers + harness | worker-xiyan-qwencoder-8300, worker-qwen-paged-8200 |

All external health checks, smokes, and LongBench traffic must go through the metax-8 frontend:

```bash
curl http://172.31.1.8:8800/health
curl http://172.31.1.8:18800/services
```

## Latest status

As of `2026-08-18T14:06:17+08:00`, the target split is deployed and healthy:

- metax-8 FE/embedding remains the external endpoint and was not restarted to free GPU.
- metax-9 runs Qwen on `8200/8201` and XiYan on `8300/8301`.
- `http://172.31.1.8:8800/health` reports `healthy_services=3/3`.
- `validate.sh` passed with `Passed: 13`, `Failed: 0` against `172.31.1.8:18800` and `172.31.1.8:8800`.
- Smoke artifact: `/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/regression/target_split_smoke_20260818T044201Z`.
- LongBench artifact root: `/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/regression/split_metax8_fe_20260818T044725Z`.

LongBench latest finding:

- `short_medium` was started through the metax-8 FE but stopped before completion after no `longbench_summary.json` or `longbench_preds.jsonl` appeared and the log showed `TransferEncodingError` plus repeated `503 Service Unavailable`.
- `all` and `all_cot` are skipped for this validation cycle by operator decision.
- The runner now executes only `short_medium` by default. Full `all` and `all_cot` require explicit env toggles.

## Safety rules

- Do not kill existing metax-8 processes to free GPU. Only start or stop the target compose services you own.
- metax-9 target worker containers may be removed/recreated when switching layouts.
- Use named services in `compose.sh up`; do not run the full `workers` profile without service names, because that can start preserved optional services such as 9g or embeddings on the wrong host.
- XiYan and 9g both want low-numbered GPUs by default. In this target layout, start XiYan and Qwen, not 9g.

## Case paths

Primary authoring/harness copy on metax-9:

```bash
/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817
```

Frontend mirror on metax-8:

```bash
/root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817
```

## Prerequisites

On both hosts:

```bash
docker image inspect infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813
```

On metax-8:

```bash
docker image inspect quay.io/coreos/etcd:v3.7.0
test -x /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/rust/target/release/infini-loadbalancer
test -d /root/zenghua/models/bge-m3
test -d /root/zenghua/models/bce-reranker-base_v1
```

Required images:

```text
infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813
quay.io/coreos/etcd:v3.7.0
```

Optional observability images, only needed if starting Prometheus/Grafana:

```text
prom/prometheus:v2.54.1
grafana/grafana:11.2.0
```

On metax-9:

```bash
test -d /root/zenghua/models/Qwen3-32B
test -d /nfs/models/XiYanSQL-QwenCoder-32B-2504
```

The XiYan model is staged on metax-9 under `/nfs/models` because `/root` has limited spare space. If the model is still in the `.partial` directory, the copy has not completed yet.

## Sync the fork to metax-8

If the metax-8 mirror is missing or stale, sync from metax-9:

```bash
# metax-8 receiver
mkdir -p /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution
ncat -l 24083 | tar -C /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution -xf -
```

```bash
# metax-9 sender
tar -C /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution \
  -cf - qwen3-32b+xiyan--x203-inf-disagg--opt20260817 | ncat 172.31.1.8 24083
```

Confirm:

```bash
test -f /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/case.toml
```

## Configure metax-8 frontend and embedding

```bash
cd /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/docker-compose
cp -n .env.split-fe.example .env.split-fe
```

Important values in `.env.split-fe`:

```bash
ROUTER_PORT=8800
REGISTRY_PORT=18800
EMBEDDING_PORT=21002
EMBEDDING_BABYSITTER_PORT=21003
COMPOSE_SUBNET=172.29.0.0/16
```

Confirm embeddings stay off protected GPUs:

```bash
grep -E 'HPCC_VISIBLE_DEVICES|CUDA_VISIBLE_DEVICES' config/embeddings.toml
```

Expected:

```text
HPCC_VISIBLE_DEVICES = "2"
CUDA_VISIBLE_DEVICES = "2"
```

Start only FE-side services:

```bash
COMPOSE_PROJECT_NAME=io-feembed COMPOSE_ENV_FILE=.env.split-fe ./compose.sh --profile frontend up -d etcd frontend
COMPOSE_PROJECT_NAME=io-feembed COMPOSE_ENV_FILE=.env.split-fe ./compose.sh --profile workers up -d worker-embeddings-20002
```

If a healthy `io-feembed` frontend is already running on metax-8, you may reuse it. Do not remove metax-8 containers just to free GPU.

## Configure metax-9 workers

```bash
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/docker-compose
cp -n .env.split-workers.example .env.split-workers
```

Important values in `.env.split-workers`:

```bash
ROUTER_URL=http://172.31.1.8:8800
REGISTRY_URL=http://172.31.1.8:18800
ETCD_ENDPOINTS=http://172.31.1.8:2379
ADVERTISE_HOST=172.31.1.9
WORKER_XIYAN_API_PORT=8300
WORKER_XIYAN_BABYSITTER_PORT=8301
WORKER_QWEN_API_PORT=8200
WORKER_QWEN_BABYSITTER_PORT=8201
XIYAN_QWENCODER_DIR=/nfs/models/XiYanSQL-QwenCoder-32B-2504
QWEN3_32B_DIR=/root/zenghua/models/Qwen3-32B
COMPOSE_SUBNET=172.30.0.0/16
```

Validate compose without starting:

```bash
COMPOSE_PROJECT_NAME=io-workers COMPOSE_ENV_FILE=.env.split-workers ./compose.sh --profile workers config >/tmp/qwen3-xiyan-compose-config.out
grep -A40 'worker-xiyan-qwencoder-8300:' /tmp/qwen3-xiyan-compose-config.out
```

When switching from the old Qwen+9g layout, remove only metax-9 worker containers:

```bash
docker rm -f \
  infiniorch-worker-xiyan-qwencoder-8300-20260817 \
  infiniorch-worker-qwen-paged-8200-20260811 \
  infiniorch-worker-9g-8100-20260811
```

If legacy all-in-one split-test containers are still running on metax-9, remove those metax-9 containers too so operators cannot accidentally hit a local FE and so embedding does not occupy low-numbered GPUs:

```bash
docker rm -f \
  infiniorch-worker-embeddings-20002-20260811 \
  infiniorch-frontend-opt-20260811 \
  infiniorch-etcd-opt-20260811
```

Do not remove or restart the metax-8 FE/embedding containers as part of this switch.

Validated XiYan startup tuning for this model on GPUs 0-3:

```text
--max-batch-size 2
--num-blocks 256
INFINI_NATIVE_CG_CAPTURE_BUCKETS=2048
INFINI_MAX_NUM_BATCHED_TOKENS=2048
```

The larger initial XiYan setting, batch 4 with 512 blocks, hit `hcMalloc` during cache reset/compile and did not register.

Start target workers:

```bash
COMPOSE_PROJECT_NAME=io-workers COMPOSE_ENV_FILE=.env.split-workers ./compose.sh --profile workers up -d \
  worker-xiyan-qwencoder-8300 \
  worker-qwen-paged-8200
```

## External validation

Poll only metax-8 FE from outside:

```bash
curl -s http://172.31.1.8:8800/health
curl -s http://172.31.1.8:18800/services
```

Expected `/health`:

```text
status=healthy
healthy_services=3/3
```

Expected registry services:

```text
master-embeddings-server          host=worker-embeddings-20002
master-qwen3-32b-paged-server     host=172.31.1.9
master-xiyan-qwencoder-32b-server host=172.31.1.9
```

Run the split-aware validator from metax-9:

```bash
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/docker-compose
REGISTRY_PORT=18800 ROUTER_PORT=8800 EMBEDDING_PORT=21002 WORKER_HOST=172.31.1.9 ./validate.sh 172.31.1.8
```

## Smoke requests

Qwen smoke through FE:

```bash
curl -s http://172.31.1.8:8800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen3-32B","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":8,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}'
```

XiYan smoke through FE:

```bash
curl -s http://172.31.1.8:8800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"XiYanSQL-QwenCoder-32B-2504","messages":[{"role":"user","content":"Write a SQL query that selects 1."}],"max_tokens":64,"temperature":0}'
```

Embedding smoke through FE:

```bash
curl -s http://172.31.1.8:8800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"bge-m3","input":"hello"}'
```

## LongBench v2

LongBench v2 targets Qwen3-32B through the metax-8 FE. It does not validate XiYan quality; use XiYan-specific SQL/RAG workloads separately if needed.

Run the default short/medium-only gate from metax-9:

```bash
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/regression
nohup ./run_split_longbench_v2_metax8_fe.sh > split_metax8_fe_nohup.log 2>&1 &
echo $! > split_metax8_fe.pid
```

Stages:

```text
short_medium: always runs; short,medium, thinking off
all:          skipped unless RUN_LONGBENCH_ALL=1
all_cot:      skipped unless RUN_LONGBENCH_ALL_COT=1
```

To explicitly request the skipped full stages later:

```bash
RUN_LONGBENCH_ALL=1 RUN_LONGBENCH_ALL_COT=1 ./run_split_longbench_v2_metax8_fe.sh
```

Artifacts:

```bash
cat latest_split_metax8_fe_run.txt
find "$(cat latest_split_metax8_fe_run.txt)" -maxdepth 3 -type f
```

Each completed stage should contain:

```text
longbench_summary.json
longbench_preds.jsonl
metadata.json
bench_console.log
server/metrics_*.json
```

Sanity gates:

- `longbench_summary.json` has `status: PASS`.
- Prediction rows match selected examples.
- No all-empty, all-null, or error-dominated predictions.
- For Qwen official 0-shot stages, `chat_template_kwargs.enable_thinking=false`.

## Troubleshooting

XiYan model missing:

```bash
test -d /nfs/models/XiYanSQL-QwenCoder-32B-2504
```

If missing, stage the model or update `XIYAN_QWENCODER_DIR` before starting the worker.

Service not registered:

```bash
curl -s http://172.31.1.8:18800/services
docker logs --tail 200 infiniorch-worker-xiyan-qwencoder-8300-20260817
docker logs --tail 200 infiniorch-worker-qwen-paged-8200-20260811
```

Wrong health target:

```text
Do not poll metax-9 for external FE health. The external contract is metax-8:8800 and metax-8:18800.
```

Port conflict on metax-9:

```bash
ss -ltnp | grep -E ':8200|:8201|:8300|:8301'
```

LongBench transfer errors:

```text
TransferEncodingError or request cancellation in all/all_cot means the benchmark stage is not clean, even if the deployment remains healthy. Inspect logs and rerun the affected stage after fixing worker stability.
```

For the `20260818T044725Z` run, the same rule applied to `short_medium`: it produced transfer errors and `503 Service Unavailable`, then was stopped before `all` and `all_cot`.

## Rollback

On metax-9, remove target workers:

```bash
docker rm -f \
  infiniorch-worker-xiyan-qwencoder-8300-20260817 \
  infiniorch-worker-qwen-paged-8200-20260811
```

On metax-8, keep the FE stack running unless the operator explicitly wants the split FE torn down. If tearing down only this target stack, use the named project and services from the case directory:

```bash
cd /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/docker-compose
COMPOSE_PROJECT_NAME=io-feembed COMPOSE_ENV_FILE=.env.split-fe ./compose.sh stop worker-embeddings-20002 frontend etcd
```
