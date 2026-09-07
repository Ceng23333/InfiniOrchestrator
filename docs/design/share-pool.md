# InfiniSharePool

Cross-node shared resource manager for InfiniOrchestrator clusters (KV cache coordination, signal dispatch).

**Status:** Pre-M6 Day-0 process-local KV event sink. It accepts normalized
llm-d-style events over HTTP and exposes inspection APIs. The load balancer
does not consume overlap results for routing yet.

## Day-0 API

- `GET /health`: service status, `index_entries`, and maximum observed generation.
- `POST /v1/kv_events`: ingest `{ "events": [...] }` with `BlockStored`,
  `BlockRemoved`, or `AllBlocksCleared` events.
- `GET /v1/kv_index`: return per-worker block counts and index summary.
- `POST /v1/kv_overlap`: accept `model_id`, `page_size`, and ordered
  `block_keys`; return each worker's longest consecutive prefix.

The in-memory key is `(model_id, page_size, block_key)` and owners are fenced
by `(worker_id, generation)`. Clear events remove all prior entries for that
worker; older-generation events are ignored. `SHAREPOOL_MAX_BLOCKS` bounds the
naive index (default `100000`).

The router owns block-key derivation. In the current native-Rust integration it
loads the model's `tokenizer.json`, applies the model chat template, chunks
token IDs by `KV_PAGE_SIZE`, and hashes each page. The hash version and exact
backend-compatible block hashing must be conformance-tested before production
throughput claims; sharepool itself remains tokenizer-agnostic.

## Intended role

- Manage shared resources across nodes (e.g. KV cache pools)
- Signal / event dispatch between InfiniEntrypoint instances
- Optional coordination with Entrypoint `/metadata` probes where needed

Wire later to InfiniEntrypoint and Distribution cases.
