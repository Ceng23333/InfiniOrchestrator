# Launch evidence

- Target: metax-9 (`172.31.1.9`), architecture `aarch64`, matching tj-node architecture.
- GPU tool: `/usr/bin/ht-smi` on metax-9. `mx-smi` is reserved for metax-49 (`node2`).
- Selected GPUs: 2 and 3. Existing workloads on GPUs 0, 1, and 4-7 were not killed.
- Image: `infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813`.
- Compose project: `m2-rr-20260902`.
- Containers: `m2-9g-9g-worker-a-20260902`, `m2-9g-9g-worker-b-20260902`, `m2-rr-20260902_frontend_1`, `m2-rr-20260902_etcd_1`.
- Host ports: frontend `28800`, registry `21800`; worker A `28102/28103`; worker B `28112/28113`.
- Worker A: `HPCC_VISIBLE_DEVICES=2`, server ID `b5259cd9-9df1-4186-933d-f47b677a924e`.
- Worker B: `HPCC_VISIBLE_DEVICES=3`, server ID `172a5a9d-0c7e-400e-a688-423804ab05bd`.
- Registry: two healthy `9g_8b_thinking` services.
- Validator: PASS; latest manifest `/root/zenghua/workspace/profiling_20260731/bench-warehouse/bench_results/diagnostics/m2-9g-9g--x203-inf--rr-20260902_20260902T060445Z/diagnostic-manifest.json`.
- Round-robin smoke: four additional successful requests returned completion IDs; both replica service counters increased.
- SSE: valid `data:` completion chunk followed by `data: [DONE]`.
- Error contract: unknown model returned JSON `{"error":"No healthy services available for model 'missing-model'"}` with HTTP 503.
- Final service state: both same-model replicas healthy; router health HTTP 200.

## Routing scope

Only `round_robin` is active for this case. Weighted, pinned, affinity, prefix-cache, and KV-aware policies are out of scope.
