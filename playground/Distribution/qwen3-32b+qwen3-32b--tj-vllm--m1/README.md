# TJ M1 baseline: two Qwen3-32B vLLM workers

Case ID: `qwen3-32b+qwen3-32b--tj-vllm--m1`

This is the M1 TJ baseline: etcd and `infini-loadbalancer` run on
`tj-container`; two identical InfiniEntrypoint-wrapped vLLM workers run on
`tj-io-node0` and `tj-io-node1`. Both workers register `Qwen3-32B` under the
same etcd discovery prefix.

This case is daemon-native. Do not use Docker Compose or Kubernetes as the
process supervisor. The supplied scripts use `nohup`, PID files, explicit
logs, and a case run directory under `/private/zenghua`.

Deployment scripts are grouped by process supervisor:

- `scripts/daemon/`: supported M1 `nohup` daemon lifecycle.
- `scripts/docker-compose/`: reserved for a Docker Compose deployment.
- `scripts/k8s/`: reserved for a Kubernetes deployment.

The Docker Compose and Kubernetes directories are placeholders only; they do
not change the M1 daemon-native launch contract.

## Topology

| Role | Host | Address | Ports |
|---|---|---|---|
| etcd + load balancer | tj-container | 177.177.61.18 | 2379, 8800 |
| worker-a | tj-io-node0 | 177.177.171.193 | 18180, 18181 |
| worker-b | tj-io-node1 | 177.177.38.20 | 18180, 18181 |

The normal data path is `tj-container -> tj-io-node{0,1}`. PC-relayed backend
traffic is diagnostic-only and is not an M1 baseline measurement.

## Prerequisites

- Model path: `/private/zenghua/models/Qwen3-32B` on both worker nodes.
- `infini-loadbalancer` and `infini-entrypoint` built for the TJ runtime and
  exposed through `LB_BIN` and `ENTRYPOINT_BIN`.
- `ETCD_BIN` points to etcd 3.7.x, or the etcd start script is adapted to the
  approved etcd container runtime.
- vLLM and the accelerator runtime are available through `VLLM_PYTHON` and
  the worker environment.

Defaults:

```text
LB_BIN=/private/zenghua/staging/InfiniOrchestrator/bin/infini-loadbalancer
ENTRYPOINT_BIN=/private/zenghua/staging/InfiniOrchestrator/bin/infini-entrypoint
ETCD_BIN=/usr/local/bin/etcd
RUN_ROOT=/private/zenghua/runs/qwen3-32b+qwen3-32b--tj-vllm--m1
```

The Rust toolchain is a build prerequisite only. Use the node-local copy from
the TJ toolchain manifest; keep Cargo registries and `target/` directories
node-local.

## Daemon lifecycle

Run from a new SSH session on the relevant host:

```bash
# tj-container
bash scripts/daemon/daemon-start-etcd.sh
bash scripts/daemon/daemon-start-lb.sh

# tj-io-node0
bash scripts/daemon/daemon-start-worker.sh worker-a

# tj-io-node1
bash scripts/daemon/daemon-start-worker.sh worker-b
```

Inspect and stop with `scripts/daemon/daemon-status.sh` and
`scripts/daemon/daemon-stop.sh`. Each process
has a PID file and log under the case run directory. Reconnect after launch
and verify the PIDs remain alive before validation.

## Validation order

1. Worker `/health` on both entrypoints.
2. Load balancer `/health`.
3. Load balancer `/v1/models`.
4. Non-streaming request.
5. Streaming request and client cancellation.
6. Stop one worker daemon, verify service state and routing behavior, restart
   it, and verify recovery.

This case does not claim `M1_READY` until those checks and daemon evidence are
complete.
