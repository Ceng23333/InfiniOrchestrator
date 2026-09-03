# Remaining M2 work completed

Case: `m2-9g-9g--x203-inf--rr-20260902`

The new T3 case is live on metax-9 with two `9g_8b_thinking` replicas. The contract suite completed for the active `round_robin` policy:

- diagnostic validator: PASS
- same-model discovery: 2 healthy services
- non-streaming requests: PASS
- SSE framing: PASS (`data:` chunks and `[DONE]`)
- invalid model error: PASS (JSON HTTP 503)
- replica counters: both increased during successive requests
- host tool: `ht-smi`; selected GPUs 2 and 3

No weighted, pinned, affinity, prefix-cache, or KV-aware policy was exercised.
