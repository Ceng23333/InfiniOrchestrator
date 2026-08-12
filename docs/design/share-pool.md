# InfiniSharePool (placeholder)

Cross-node shared resource manager for InfiniOrchestrator clusters (KV cache coordination, signal dispatch).

**Status:** placeholder binary `infini-sharepool` exposes `/health` only. Not launched by playground cases yet.

## Intended role

- Manage shared resources across nodes (e.g. KV cache pools)
- Signal / event dispatch between InfiniEntrypoint instances
- Optional coordination with Entrypoint `/metadata` probes where needed

Wire later to InfiniEntrypoint and Distribution cases.
