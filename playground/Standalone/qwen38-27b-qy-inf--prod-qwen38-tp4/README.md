# Playground: Qwen3.8-27B + InfiniLM (Standalone, MetaX QY TP4)

**Candidate** backend for the AIPerf mooncake_trace dual-run harness (always measured **after** the vLLM baseline).

Case id: `qwen38-27b-qy-inf--prod-qwen38-tp4` (`case.toml`).

## Production pin

| Item | Value |
|------|-------|
| Tag | `v2026.10.29-infinilm-prod-qwen38-tp4` |
| ITW release | https://github.com/Ceng23333/InfiniTensorWorktree/releases/tag/v2026.10.29-infinilm-prod-qwen38-tp4 |
| InfiniLM release | https://github.com/Ceng23333/InfiniLM/releases/tag/v2026.10.29-infinilm-prod-qwen38-tp4 |

Serving profile (from ITW `deployment/infinilm-prod`): Qwen3.8-27B BF16, MetaX TP4, batch limit 1, paged KV 512×256, 2048-token chunked prefill, max output 4096.

This case documents bring-up only. The InfiniOrchestrator harness is **client-only** and never starts or stops InfiniLM.

## Bring-up (outside harness)

1. Check out the production tag (recursive submodules) into a sibling `InfiniTensorWorktree` (or use the published `InfiniTensorWorktree-prod` tree).
2. Use the pinned runtime image / `deployment/infinilm-prod/start.sh` pattern when available, or an equivalent OpenAI-compatible InfiniLM serve on TP4 with served name `Qwen3.8-27B`.
3. Mount weights read-only (site-specific), e.g. `/home/metax/Downloads/Qwen3.8-27B`.

Example container start (from the prod deployment helper):

```bash
# From InfiniTensorWorktree deployment/infinilm-prod (tag checkout)
./start.sh
# waits on :8000 by default — use a distinct host port if vLLM already owns 8000
```

Preflight:

```bash
curl -sf http://127.0.0.1:8001/v1/models | head   # example if remapped
export CASE_PATH=$PWD/case.toml
```

## Dual-run (vLLM baseline URL first)

```bash
cd InfiniOrchestrator
export BASE_URL_VLLM=http://127.0.0.1:8000
export BASE_URL_INFINILM=http://127.0.0.1:8001   # this case
harness/bin/run-aiperf-dual \
  --base-url-vllm "$BASE_URL_VLLM" \
  --base-url-infinilm "$BASE_URL_INFINILM" \
  --profile harness/adapters/aiperf/profiles/ci_mooncake_replay.yaml \
  --case-path-vllm "$PWD/playground/Standalone/qwen38-27b-qy-vllm--prod-qwen38-tp4/case.toml" \
  --case-path-infinilm "$PWD/playground/Standalone/qwen38-27b-qy-inf--prod-qwen38-tp4/case.toml" \
  --model Qwen3.8-27B
```

Gates (defaults): InfiniLM / vLLM throughput ≥ 0.50; InfiniLM TTFT p95 ≤ 1.25× vLLM; both success_rate ≥ 0.99. Details in `harness/adapters/aiperf/README.md`.
