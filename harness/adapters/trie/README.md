# Applied Compute trie adapter

This run-only adapter executes the pinned Applied Compute `trie` CLI against an
already-running OpenAI-compatible endpoint. It writes the same staging shape
used by the existing benchmark emitter: `summary.json`, `metadata.json`, raw
CLI output, and the deterministic workload.

The default workload contains repeated multi-turn agent traces. It is intended
for M6 comparisons such as round-robin versus cache-aware routing; the router
and server must expose cached prompt-token usage for cache-hit fields to be
populated.
