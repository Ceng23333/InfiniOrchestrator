# Pre-M6 Day-0 vLLM round-robin baseline

This case is the load-only control arm for Pre-M6: two static `9g_8b_thinking`
vLLM backends behind the naive MapState round-robin router on `29920`, with the
process-local `infini-sharepool` KV event sink on `29820`.

The router does not query KV overlap for placement in Day-0. The trie run records `N`
and `throughput_rr` as the denominator for the later KV-aware comparison;
Day-0 does not claim `M6_READY` or the linear throughput target.

## Post-Day-0 KV-aware experiment

Set `KV_AWARE_ROUTING=1`, `SHAREPOOL_URL`, and `ROUTER_TOKENIZER_PATH` on the
router. The router loads `tokenizer.json`, renders the model chat template,
and derives token-ID pages using `KV_PAGE_SIZE` (default `16`). It queries
sharepool overlap and selects the highest-scoring healthy same-model backend;
absent/failed/zero overlap falls back to the existing RR path. Responses
identify the decision with `x-route-decision: kv_aware` or `selected`.
