# Case: infinilm-metax-deployment-opt-20260611

Current InfiniOrchestrator deployment case for offline Metax hosts. Builds from sibling worktree `InfiniCore/` + `InfiniLM/` on `prefill_profile`, with Phase 3 production flags baked into paged inference workers.

Historical reference: [`infinilm-metax-deployment-opt-20260325`](../infinilm-metax-deployment-opt-20260325/).

## Source revisions (at image build time)

| Repo | Branch | Commit |
|------|--------|--------|
| InfiniCore | `prefill_profile` | `8c901136` |
| InfiniLM | `prefill_profile` | `ece9948` (`gc.collect()` + Qwen2 `PiecewiseTextCausalLM` for XiYanSQL) |

Phase 3 validation: [`bench_results/validate_phase3_gates_20260611_161905/validation_summary.md`](../../../../bench_results/validate_phase3_gates_20260611_161905/validation_summary.md)

## Versioned `IMAGE_TAG`

Do **not** use bare `:local`. Tag format:

```
infini-orchestrator-metax:<IL_SHA>-<IC_SHA>-<BUILD_TS>
```

Example: `infini-orchestrator-metax:8e8b492-8c901136-20260611` (`BUILD_TS` = UTC `YYYYMMDD`)

After `build-image.sh`, copy the tag into `.env` from `.image_tag` (written at build time) or from the build command output.

## Quick start

Build and validate in a **fresh `WORKSPACE`** (rsync codebase only from dev worktree — no prebuilt image or `.image_tag`; see [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](OFFLINE_DEPLOY_GUIDE_ZH_CN.md)):

Build the runtime image once:

```bash
cd ../../container/metax
IL_SHA="$(git -C ../../../InfiniLM rev-parse --short HEAD)"
IC_SHA="$(git -C ../../../InfiniCore rev-parse --short HEAD)"
BUILD_TS="$(date -u +%Y%m%d)"
IMAGE_TAG="infini-orchestrator-metax:${IL_SHA}-${IC_SHA}-${BUILD_TS}"
IMAGE_TAG="${IMAGE_TAG}" \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
INFINI_RUNTIME_CONTAINER=__base__ \
DOCKER_BUILD_NO_CACHE=1 \
./build-image.sh
echo "${IMAGE_TAG}" > ../../deploy/cases/infinilm-metax-deployment-opt-20260611/.image_tag
```

Run the case:

```bash
cd deploy/cases/infinilm-metax-deployment-opt-20260611
cp .env.example .env
# edit MODEL1_DIR, QWEN3_32B_DIR, XIYAN_QWENCODER_DIR, EMBEDDING_MODEL_DIR, IMAGE_TAG
docker-compose up -d master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

Slave (XiYanSQL):

```bash
docker-compose up -d worker-slave-xiyan-qwencoder-8200
./validate.sh <master_ip> <slave_ip>
```

Endpoints:

- Router: `http://localhost:${ROUTER_PORT:-8000}`
- Registry: `http://localhost:${REGISTRY_PORT:-18000}`
- Embeddings: `http://localhost:${EMBEDDING_PORT:-20002}`

## Services in this compose

**Master stack:**

- `master`: registry + router (`LAUNCH_COMPONENTS=registry,router`)
- `worker-master-9g-8100`: 9g_8b_thinking @ 8100 (paged + flash-attn + graph)
- `worker-master-qwen-paged-8200`: Qwen3-32B paged @ 8200 (Phase 3 env, `--num-blocks 1024`)
- `worker-master-embeddings-20002`: embedding/rerank @ 20002 (requires `EMBEDDING_MODEL_DIR`)

**Slave (primary):**

- `worker-slave-xiyan-qwencoder-8200`: XiYanSQL-QwenCoder-32B-2504 @ TP=4, port 8200

**Optional bisect slaves (legacy FLA presets):**

- `worker-slave-fla-9g-8100`, `worker-slave-fla-qwen-8200`

## XiYanSQL note

XiYanSQL loads 14 × ~4.8 GB safetensors shards. The image must include `gc.collect()` call sites in `/workspace/InfiniLM/python/infinilm/modeling_utils.py` (landed in InfiniLM `8e8b492`). This ships via `build-image.sh` rsync — not a runtime env var or pip package.
