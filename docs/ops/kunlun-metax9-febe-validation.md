# Kunlun Frontend + metax-9 Workers Validation

This runbook reproduces the FE/BE-disaggregated validation where the
Frontend, etcd, panel, Grafana, and warehouse reader run on `kunlun`, while
InfiniLM workers run on `metax-9`.

Use the direct LAN path when it works. Use the PC-anchored SSH tunnel only when
`metax-9` workers cannot reach `kunlun` directly.

## Target Topology

| Role | Host | Address / Port |
|------|------|----------------|
| Frontend + panel | `kunlun` | `http://172.22.163.183:18880/panel` |
| etcd discovery | `kunlun` | `http://127.0.0.1:2379` on FE host |
| Prometheus | `kunlun` | private Docker network, `9090` |
| Grafana | `kunlun` | `http://172.22.163.183:3000` |
| 9g worker | `metax-9` | `http://172.31.1.9:8100` |
| Qwen worker | `metax-9` | `http://172.31.1.9:8200` |
| Embedding worker | `metax-9` | `http://172.31.1.9:20002` |

## Direct Path Preflight

From `metax-9`, check whether `kunlun` ports are reachable:

```bash
timeout 5 bash -lc '</dev/tcp/172.22.163.183/18880' && echo frontend-ok || echo frontend-blocked
timeout 5 bash -lc '</dev/tcp/172.22.163.183/2379' && echo etcd-ok || echo etcd-blocked
```

If both succeed, use direct worker env:

```bash
ETCD_ENDPOINTS=http://172.22.163.183:2379
ROUTER_URL=http://172.22.163.183:18880
REGISTRY_URL=http://172.22.163.183:18880
ADVERTISE_HOST=172.31.1.9
```

If either is blocked, use the SSH tunnel fallback below.

## PC-Anchored SSH Tunnel Fallback

This is a rendezvous bridge when the PC can reach both hosts but `metax-9`
cannot reach `kunlun` directly. Keep both SSH sessions alive; if the PC sleeps
or either SSH process exits, worker leases in FE-side etcd will expire.

On the PC, open channel 1 to `kunlun`:

```powershell
ssh -F none -N `
  -L 127.0.0.1:12379:127.0.0.1:2379 `
  -L 127.0.0.1:12880:127.0.0.1:18880 `
  -p 14735 -i C:\Users\QY\.ssh\id_ed25519_cursor `
  zenghua@172.22.163.183
```

On the PC, open channel 2 to `metax-9`:

```powershell
ssh -F none -N `
  -R 127.0.0.1:12379:127.0.0.1:12379 `
  -R 127.0.0.1:12880:127.0.0.1:12880 `
  -i C:\Users\QY\.ssh\id_ed25519_cursor `
  root@172.31.1.9
```

`sshd` commonly binds remote forwards to loopback only. Expose them on the
`metax-9` host for Docker containers with relays:

```bash
nohup ncat -lk 0.0.0.0 22379 --sh-exec 'ncat 127.0.0.1 12379' >/tmp/kunlun-etcd-relay.log 2>&1 &
nohup ncat -lk 0.0.0.0 22880 --sh-exec 'ncat 127.0.0.1 12880' >/tmp/kunlun-fe-relay.log 2>&1 &
```

Then use worker env:

```bash
ETCD_ENDPOINTS=http://172.31.1.9:22379
ROUTER_URL=http://172.31.1.9:22880
REGISTRY_URL=http://172.31.1.9:22880
ADVERTISE_HOST=172.31.1.9
```

Use `ssh -F none` for these channels so host aliases do not add unrelated
`RemoteForward` entries such as `57890`.

## Host-Native Frontend

The host-native FE should run with an explicit warehouse path and public
Grafana URL:

```bash
cd /home/zenghua/workspace/InfiniOrchestrator-panel/InfiniOrchestrator
IO_ROOT=$PWD \
BENCH_WAREHOUSE_REPO=/home/zenghua/workspace/InfiniOrchestrator-panel/bench-warehouse \
GRAFANA_URL=http://172.22.163.183:3000 \
  rust/target/release/infini-loadbalancer \
  --load-balancer-port 18880 \
  --etcd-endpoints http://127.0.0.1:2379 \
  --discovery-prefix /infini/orchestrator
```

For host-native warehouse refresh, use:

```bash
cd /home/zenghua/workspace/InfiniOrchestrator-panel/InfiniOrchestrator
BENCH_WAREHOUSE_SYNC_INTERVAL_SEC=300 \
  nohup frontend/warehouse-sync-host.sh > ../warehouse-sync-host.log 2>&1 &
```

The script sparse-checks out `raw/` from `bench-warehouse`, updates the sibling
`bench-warehouse` symlink after a successful sync, and writes
`.warehouse-sync-status`.

## Validation

```bash
curl -fsS http://172.22.163.183:18880/health
curl -fsS http://172.22.163.183:18880/panel/api/snapshot
curl -fsS http://172.22.163.183:18880/panel/api/harness/longbench_v2
curl -fsS http://172.22.163.183:3000/api/health
```

Expected panel state:

- `source_status.visualization` points at `GET /panel/api/harness/longbench_v2`
- `grafana_url` resolves to `http://172.22.163.183:3000`
- LongBench source status is `ok`
- LongBench `source.sync.status` is `ok` after warehouse sync

## What Belongs In Git

Commit runbooks, scripts, env templates, and validation commands. Do not commit
host-specific live artifacts such as PIDs, logs, generated `.env` files with
tokens, private SSH keys, or benchmark raw rows unless the bench-warehouse
ingest workflow produced and validated those rows.
