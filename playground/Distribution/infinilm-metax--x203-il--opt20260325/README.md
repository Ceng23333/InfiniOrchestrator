# Case: infinilm-metax-deployment-opt-20260325

First InfiniOrchestrator deployment case, modeled on `InfiniLM-SVC/deployment/cases/infinilm-metax-deployment-opt`.

## Mapping from legacy scripts

| Legacy (InfiniLM-SVC) | Target (this case) |
|-----------------------|--------------------|
| `start-master.sh` (registry + router + multiple babysitters) | `docker compose up`: master service with `LAUNCH_COMPONENTS=registry,router` only; one Compose service per model/embeddings role with `LAUNCH_COMPONENTS=babysitter` and a single TOML in `BABYSITTER_CONFIGS`. |
| Slave start scripts with multiple babysitter configs | One container per babysitter config; `config/*.toml` one file per worker. |

## Quick start

Build the runtime image once:

```bash
cd ../../..
./container/metax/build-image.sh
```

Run the case:

```bash
cd deploy/cases/infinilm-metax-deployment-opt-20260325
cp .env.example .env
# edit MODEL1_DIR and QWEN3_32B_DIR in .env
# optional: set EMBEDDING_MODEL_DIR to enable embedding worker
docker compose up -d
```

Endpoints:

- Router: `http://localhost:${ROUTER_PORT:-8000}`
- Registry: `http://localhost:${REGISTRY_PORT:-18000}`
- Embeddings (optional): `http://localhost:${EMBEDDING_PORT:-20002}`

## Services in this compose

- `master`: runs **registry + router** only (`LAUNCH_COMPONENTS=registry,router`).
- `worker-master-9g-8100`: one babysitter (9g_8b_thinking @ 8100).
- `worker-master-qwen-paged-8200`: one babysitter (Qwen3-32B paged @ 8200).
- `worker-master-embeddings-20002`: one babysitter (embedding/rerank @ 20002, requires `EMBEDDING_MODEL_DIR`).

Optional profiles (disabled by default):

- mixed slave pair: 9g @ 8100 + Qwen paged @ 8200 (both flash-attn + graph) (`worker-slave-fla-9g-8100`, `worker-slave-fla-qwen-8200`).
- two vLLM Qwen services @ 8200/8300 (`worker-slave-3vllm-vllm-1`, `worker-slave-3vllm-vllm-2`).

All worker services point discovery to the master via:

- `REGISTRY_URL=http://master:18000`
- `ROUTER_URL=http://master:8000`
