# Discovery: etcd contract (M1 alpha)

M1 freezes the currently implemented etcd contract for diagnosable TJ
deployment. This is an alpha contract, not the versioned M3 discovery
promotion. HTTP `infini-registry` is deprecated; discovery uses the etcd v3
HTTP API client in Rust.

## Environment

| Variable | Role |
|----------|------|
| `ETCD_ENDPOINTS` | Comma-separated etcd URLs, for example `http://177.177.61.18:2379` |
| `DISCOVERY_PREFIX` | Case namespace, for example `/infini/orchestrator/qwen3-32b-tj-vllm-m1` |

Both `infini-entrypoint` and `infini-loadbalancer` must use the same values.
The prefix is trimmed of trailing slashes when constructing keys.

## Key layout

Each registration is stored at:

```text
{DISCOVERY_PREFIX}/instances/{instance_id}
```

The value is JSON with this as-implemented shape:

```json
{
  "instance_id": "tj-worker-a-server",
  "name": "tj-worker-a-server",
  "host": "177.177.171.193",
  "port": 18180,
  "hostname": "177.177.171.193",
  "url": "http://177.177.171.193:18180",
  "status": "running",
  "weight": 1,
  "metadata": {
    "type": "openai-api",
    "parent_service": "tj-worker-a",
    "entrypoint": "enhanced",
    "server_id": "opaque-entrypoint-uuid",
    "models": ["Qwen3-32B"],
    "models_list": [{"id": "Qwen3-32B"}]
  }
}
```

`hostname` is accepted for compatibility and is not used as the routing
address when `host` and `url` are present. `status = "running"` is the
registration-health value consumed by the current load balancer; the load
balancer exposes its own derived lifecycle state (`startup`, `ready`,
`unhealthy`, `draining`, or `removed`) through `/services`.

## Lease and watch behavior

- InfiniEntrypoint registers the entrypoint and managed OpenAI API service.
- Registrations use an etcd lease with heartbeat renewal.
- InfiniLoadBalancer performs an initial list, a polling watch/diff, and
  periodic refresh.
- Missing registrations are removed after the configured grace period.
- A registration is admitted to routing only when its metadata `type` is
  `openai-api` and its current health is ready.

## M1 limitations

This alpha contract intentionally has no schema version, generation fencing,
model/accelerator/role capability schema, stale-generation rejection, or
discovery revision in diagnostics. Those are M3 concerns. The TJ baseline
uses one case-specific prefix so its registrations cannot collide with other
deployments.

## Components

1. **InfiniEntrypoint** — register and heartbeat through etcd.
2. **InfiniLoadBalancer** — list/watch registrations and proxy HTTP traffic.
3. **infini-registry** — deprecated and not part of the M1 TJ launch.
