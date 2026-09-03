# M2 remaining work plan

Case: `m2-9g-9g--x203-inf--rr-20260902`

Current evidence covers the two-replica `round_robin` path on metax-9:

- diagnostic validator: PASS
- same-model discovery: 2 healthy services
- non-streaming requests: PASS
- SSE framing: PASS
- invalid-model JSON error: PASS
- replica counters increased during successive requests
- GPU tool: `ht-smi`

The following policies are deprecated and are not M2 gates: weighted,
model-pinned, and session/prompt-affinity routing.

## Execution order

1. **Freeze the supported case matrix.** Add and validate direct-backend,
   single-backend-behind-LB, and two-backend-behind-LB cases. Keep the current
   two-replica round-robin case as the multi-backend reference and add explicit
   model matching only where the case exposes multiple models.
2. **Add shared HTTP conformance probes.** Cover status/JSON errors, SSE
   framing, token usage, cancellation, deadlines, and model selection in
   `harness/case_diagnostic`; run the same probe set against every matrix case.
3. **Exercise pressure and retry behavior.** Add bounded tests for admission
   limits, per-backend concurrency, queue accounting, and retry behavior. A
   retry test must prove that an in-generation request is never duplicated.
4. **Capture golden diagnostics and thresholds.** Store `/services`, `/models`,
   `/stats`, and `/metrics` snapshots and define success-rate, TTFT, ITL,
   throughput, and routing-overhead thresholds.
5. **Expand benchmark integration.** Extend the M1 `llm-d-benchmark` adapter
   to collect the full metrics profile and compare it with native diagnostic
   results. Keep benchmark clients run-only; case lifecycle remains owned by
   the playground case.

## Exit gate

All three supported case shapes pass the shared diagnostic/conformance suite;
round-robin and explicit model matching have reproducible tests; pressure,
queue, retry, and deadline behavior meet thresholds; and no retry duplicates
an in-generation request.
