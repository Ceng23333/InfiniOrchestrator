# Playground: Qwen3.8-27B + vLLM (Standalone, MetaX QY TP4)

**Baseline** backend for the AIPerf mooncake_trace dual-run harness.

Case id: `qwen38-27b-qy-vllm--prod-qwen38-tp4` (`case.toml`).

Production pin (shared with InfiniLM candidate): `v2026.10.29-infinilm-prod-qwen38-tp4`.

This case documents bring-up only. The InfiniOrchestrator harness is **client-only** and never starts or stops vLLM.

## Serving defaults

| Setting | Value |
|---------|-------|
| Model | `Qwen3.8-27B` (served name) |
| Weights | site path, e.g. `/home/metax/Downloads/Qwen3.8-27B` |
| TP | 4 |
| dtype | bfloat16 |
| OpenAI base URL | `http://<host>:8000` (override via `BASE_URL_VLLM`) |

Aligned with PilotDeck `scripts/infinilm_vllm_entrypoint.sh` (TP=4, `--served-model-name Qwen3.8-27B`).

## Bring-up (outside harness)

Example (host Python / container entrypoint):

```bash
export MODEL=/home/metax/Downloads/Qwen3.8-27B
export TP=4 PORT=8000
python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --served-model-name Qwen3.8-27B \
  --tensor-parallel-size "$TP" \
  --dtype bfloat16 \
  --host 0.0.0.0 \
  --port "$PORT" \
  --trust-remote-code
```

Preflight:

```bash
curl -sf http://127.0.0.1:8000/v1/models | head
export CASE_PATH=$PWD/case.toml
# optional: InfiniOrchestrator/harness/bin/validate-case --host 127.0.0.1
```

## Dual-run (vLLM first, then InfiniLM)

```bash
cd InfiniOrchestrator
export BASE_URL_VLLM=http://127.0.0.1:8000          # this case
export BASE_URL_INFINILM=http://127.0.0.1:8001       # sibling InfiniLM case
harness/bin/run-aiperf-dual \
  --base-url-vllm "$BASE_URL_VLLM" \
  --base-url-infinilm "$BASE_URL_INFINILM" \
  --profile harness/adapters/aiperf/profiles/ci_mooncake_replay.yaml \
  --case-path-vllm "$PWD/playground/Standalone/qwen38-27b-qy-vllm--prod-qwen38-tp4/case.toml" \
  --case-path-infinilm "$PWD/playground/Standalone/qwen38-27b-qy-inf--prod-qwen38-tp4/case.toml" \
  --model Qwen3.8-27B
```

See `harness/adapters/aiperf/README.md` for gates and artifact layout (`baseline/vllm/` then `candidate/infinilm/`).
