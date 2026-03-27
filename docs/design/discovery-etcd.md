# Discovery: proposed etcd contract (later phase)

This document records a **proposal** for replacing or complementing the HTTP infini-registry with **etcd**, aligned with ideas in Dynamo’s discovery plane (`dynamo/docs/design-docs/discovery-plane.md`). **The first InfiniOrchestrator deployment case does not run etcd or etcd clients.**

## Goals

- Babysitters register endpoints and metadata with **lease-backed keys** so stale entries expire when a process dies.
- The router (or an intermediate component) **watches or lists** keys under a shared prefix to route traffic and honor cache-type / model routing similar to today’s registry responses.

## Environment (sketch)

| Variable | Role |
|----------|------|
| `ETCD_ENDPOINTS` | Comma-separated etcd client URLs (for example `http://etcd:2379`). |
| `DISCOVERY_PREFIX` | Key prefix for this cluster or case (for example `/infini/orchestrator/<case-id>/`). |

Workers would stop using `REGISTRY_URL=http://<master>:18000` once etcd registration is implemented; until then, keep the HTTP registry.

## Key layout (sketch)

Exact paths should be finalized when implementing Phase B/C in the main proposal; a plausible hierarchy:

- `{prefix}/instances/{instance_id}` — JSON or protobuf payload with listen address, model id, cache mode, health, etc.
- Optional index keys for fast lookup by model or role.

Leases should match babysitter heartbeat intervals so failed nodes disappear from discovery without manual cleanup.

## Phasing

1. **Phase A** — Docker Compose with HTTP registry on master (current InfiniLM-SVC behavior).
2. **Phase B** — Babysitter registers via etcd + leases.
3. **Phase C** — Router consumes etcd instead of HTTP registry polling.
4. **Phase D** — Remove the registry binary from the master image when unused.
