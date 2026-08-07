# Discovery: etcd contract (implemented)

HTTP `infini-registry` is removed. Discovery uses **etcd** (HTTP v3 API client in Rust).

## Environment

| Variable | Role |
|----------|------|
| `ETCD_ENDPOINTS` | Comma-separated etcd URLs (e.g. `http://etcd:2379`) |
| `DISCOVERY_PREFIX` | Key prefix (e.g. `/infini/orchestrator/<case-id>/`) |

## Key layout

- `{prefix}/instances/{instance_id}` — JSON payload: listen address, model id, cache mode, health URL, role

Leases: InfiniEntrypoint registers and renews; InfiniLoadBalancer lists/watches.

## Components

1. **InfiniEntrypoint** — register + heartbeat via discovery client
2. **InfiniLoadBalancer** — consume instance list from etcd
3. **infini-registry** — deprecated stub (exits nonzero)

Standalone playground cases may omit etcd and expose the backend directly.
