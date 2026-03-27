# Offline-Friendly Deployment Guide (Metax)

This guide deploys `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325` in **3 phases**:

1. Build the deploy/runtime image from **local** `InfiniCore/InfiniLM` sources (no external pulls).
2. Launch `master` + model workers with `docker-compose` using the case `.env`.
3. Validate registry/router health + model aggregation + chat completion via the router.

## Goal

Deploy `InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325` using:

- Local InfiniCore + InfiniLM code as build context
- The already-present base image `infinilm-svc:metax-hpcc-1004_218-202602281209` on the host
- No external/internet pulls during build/run (only local Docker layers + local model mounts)

## Pre-checks (no edits yet)

- Confirm the deploy case’s `.env` has correct model host paths:
  - `MODEL1_DIR=/path/on/host/9g_8b_thinking_llama`
  - `QWEN3_32B_DIR=/path/on/host/Qwen3-32B`
- Confirm the base image exists locally (to avoid a pull):
  - `infinilm-svc:metax-hpcc-1004_218-202602281209`

### Offline-friendly prerequisites (recommended)

- Confirm you have `docker-compose` **v1.x** available (this repo’s compose file is tuned for v1.x compatibility).
- Do not edit model paths unless the host directories already exist and contain:
  - `9g_8b_thinking_llama/...`
  - `Qwen3-32B/config.json` and weight shards
- Confirm your local host can resolve the validation target IP you will pass to `validate.sh`:
  - in this guide we use: `192.168.162.18`

## Phase 1: Build the deploy image (from local code)

Run from `InfiniOrchestrator/container/metax`:

```bash
cd "/home/zenghua/workspace/infinilm-svc-refactor/InfiniOrchestrator/container/metax" && \
IMAGE_TAG=infini-orchestrator-metax:local \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
INFINI_RUNTIME_CONTAINER=__base__ \
DOCKER_BUILD_NO_CACHE=1 \
./build-image.sh
```

Notes:

- `INFINI_RUNTIME_CONTAINER=__base__` makes the build stage runtime libs from the *local* base image, not from `dev2`.

## Phase 2: Launch docker-compose (no profiles)

Run from the case directory:

```bash
cd "/home/zenghua/workspace/infinilm-svc-refactor/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325" && \
docker-compose up -d --force-recreate \
  master worker-master-9g-8100 worker-master-qwen-paged-8200
```

Notes:

- Ensure the case `.env` points to your real host model directories.
- Avoid overwriting `.env` with `.env.example`.

## Phase 3: Validate accessibility (registry/router + model routing)

Run:

```bash
cd "/home/zenghua/workspace/infinilm-svc-refactor/InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260325" && \
./validate.sh 192.168.162.18
```

Fast smoke endpoints (optional, but useful):

```bash
curl -s --max-time 5 http://192.168.162.18:8000/health && echo
curl -s --max-time 5 http://192.168.162.18:8000/v1/models
```

## Expected outcome

When successful, `validate.sh` should pass:

- Registry `/health` is OK
- Router `/health` is OK
- Model aggregation discovers:
  - `9g_8b_thinking`
  - `Qwen3-32B`
- `/v1/chat/completions` works for both models

In a successful run, `./validate.sh 192.168.162.18` exits with code `0` and chat completion tests succeed for both `9g_8b_thinking` and `Qwen3-32B`.

## Troubleshooting

### A) `No healthy services available for model 'Qwen3-32B'`

Symptom:

- Router returns “no healthy services” for Qwen.

Likely causes:

- The Qwen babysitter process crashed (common when `--enable-graph` is enabled under some conditions).
- Worker is still loading weights (early requests can fail).

What to do:

1. Check router model list:
   - `curl -s --max-time 5 http://<ip>:8000/v1/models`
2. Check registry health:
   - `curl -s --max-time 5 http://<ip>:18000/services`
3. Tail Qwen worker babysitter logs:
   - `docker exec infiniorch-worker-master-qwen-paged-8200-*/bash -lc 'f=$(ls -t /app/logs/babysitter_master-qwen3-32b-paged_*.log | head -n1); tail -n 200 "$f"'`

Fix ideas (based on observed behavior in this workspace):

- If you recently enabled `--enable-graph`, try disabling it (flash-attn-only / no-graph baseline).
- Recreate the Qwen worker after changes:
  - `docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### B) Router `/v1/models` is empty or missing one model

Symptom:

- `/v1/models` shows only `9g_8b_thinking` or nothing.

Likely causes:

- Wrong host model paths in `.env` (e.g., mounts point to `/path/to/...`).
- Qwen `config.json` missing under the mounted host directory.

What to do:

1. Verify `.env` paths:
   - `MODEL1_DIR=...`
   - `QWEN3_32B_DIR=...`
2. Confirm host file existence:
   - host: `.../Qwen3-32B/config.json`
3. Recreate workers:
   - `docker-compose up -d --force-recreate worker-master-qwen-paged-8200`

### C) Worker restart loops / service exits with code 134

Symptom:

- Qwen babysitter keeps restarting and router returns 503.

Likely causes:

- Unstable runtime mode (in this workspace, graph-enabled runs have shown `hcErrorIllegalAddress` / `infinicclAllReduce` followed by process exit).

What to do:

- Use “flash-attn-only / no-graph” baseline for benchmarking:
  - remove `--enable-graph` from:
    - `config/master-qwen3-32b-paged.toml`
    - `config/master-9g_8b_thinking.toml`
- Recreate:
  - `docker-compose up -d --force-recreate master worker-master-9g-8100 worker-master-qwen-paged-8200`

### D) Compose command fails / unsupported compose options

Symptom:

- Messages like “unsupported config option” or version/profile incompatibilities.

Fix:

- Use `docker-compose` (legacy binary) not `docker compose` in this environment.
- Ensure the compose file version is the one tuned for v1.x compatibility (already set in this case).

### E) Build pulls images / requires network

Symptom:

- `docker build` attempts to download layers.

Fix:

- Ensure the base image tag exists locally:
  - `infinilm-svc:metax-hpcc-1004_218-202602281209`
- If not present, pre-load it on the host machine or temporarily allow network access.

