# Case: infinilm-metax-deployment-opt-20260611

Current InfiniOrchestrator deployment case for offline Metax hosts. Builds from sibling worktree `InfiniCore/` + `InfiniLM/` on `prefill_profile`, with Phase 3 production flags baked into paged inference workers.

Historical reference: [`infinilm-metax-deployment-opt-20260325`](../infinilm-metax-deployment-opt-20260325/).

## Source revisions (at image build time)

| Repo | Branch | Commit |
|------|--------|--------|
| InfiniCore | `prefill_profile` | `b81c5860` |
| InfiniLM | `prefill_profile` | `8fa8b74` (RC-7A: decode CG, request timeout, prefix cache ON) |

Phase 3 validation: [`bench_results/validate_phase3_gates_20260611_161905/validation_summary.md`](../../../../bench_results/validate_phase3_gates_20260611_161905/validation_summary.md)

## Versioned `IMAGE_TAG`

Do **not** use bare `:local`. Tag format:

```
infini-orchestrator-metax:<IL_SHA>-<IC_SHA>-<BUILD_TS>
```

Example: `infini-orchestrator-metax:8e8b492-8c901136-20260611` (`BUILD_TS` = UTC `YYYYMMDD`)

After `build-image.sh`, copy the tag into `.env` from `.image_tag` (written at build time) or from the build command output.

## Quick start

Build and validate in a **fresh `WORKSPACE`** (Path A: [`bench/pack-offline-worktree.sh`](bench/pack-offline-worktree.sh) → transfer tar → [`bench/unpack-offline-worktree.sh`](bench/unpack-offline-worktree.sh); or Path B rsync from dev worktree — no prebuilt image or `.image_tag`; see [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](OFFLINE_DEPLOY_GUIDE_ZH_CN.md) §路径 A):

Build the runtime image once:

```bash
cd ../../container/metax
IL_SHA="$(git -C ../../../InfiniLM rev-parse --short HEAD)"
IC_SHA="$(git -C ../../../InfiniCore rev-parse --short HEAD)"
BUILD_TS="$(date -u +%Y%m%d)"
IMAGE_TAG="infini-orchestrator-metax:${IL_SHA}-${IC_SHA}-${BUILD_TS}"
IMAGE_TAG="${IMAGE_TAG}" \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
INFINI_RUNTIME_CONTAINER=infinilm-dev-20260622 \
DOCKER_BUILD_NO_CACHE=1 \
./build-image.sh
echo "${IMAGE_TAG}" > ../../deploy/cases/infinilm-metax-deployment-opt-20260611/.image_tag
```

Run the case (master host):

```bash
cd deploy/cases/infinilm-metax-deployment-opt-20260611
cp .env.master.example .env
# set IMAGE_TAG from .image_tag after build
docker-compose up -d master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

Slave host (XiYanSQL, two-machine):

```bash
cp .env.slave.example .env
# sed replaces <MASTER_IP> / <SLAVE_IP> — see OFFLINE_DEPLOY_GUIDE_ZH_CN.md
docker-compose up -d worker-slave-xiyan-qwencoder-8200
```

See [OFFLINE_DEPLOY_GUIDE_ZH_CN.md §双机部署](OFFLINE_DEPLOY_GUIDE_ZH_CN.md#第二阶段双机部署master--slave推荐) for full copy-paste blocks.

Single-host slave simulation (no second machine — LAN IP registration path):

```bash
./bench/simulate_slave_localhost.sh
./bench/validate_slave_localhost.sh
# restore: docker-compose stop worker-slave-xiyan-qwencoder-8200 && docker-compose up -d worker-master-9g-8100 worker-master-qwen-paged-8200
```

See [OFFLINE_DEPLOY_GUIDE_ZH_CN.md §单机 Slave 模拟](OFFLINE_DEPLOY_GUIDE_ZH_CN.md#单机-slave-模拟无分机) and [`.env.slave-sim.example`](.env.slave-sim.example).

Endpoints:

- Router: `http://localhost:${ROUTER_PORT:-8000}`
- Registry: `http://localhost:${REGISTRY_PORT:-18000}`
- Embeddings: `http://localhost:${EMBEDDING_PORT:-20002}`

## Production flags (RC-7, per-model TOML)

CG graphs are captured **once at worker startup** (`LLMEngine` init → `C++ capture complete`). Request path replays captured graphs only — no cold capture on first HTTP request.

| Setting | 9g (`master-9g_8b_thinking.toml`) | Qwen3-32B (`master-qwen3-32b-paged.toml`) | XiYan slave |
|---------|-----------------------------------|-------------------------------------------|-------------|
| `INFINI_DECODE_CG_TP` | `"1"` | `"1"` | `"1"` |
| `INFINI_COMPILE_MAX_SEQ` | `"65536"` | `"40960"` | `"32768"` |
| `INFINI_REQUEST_TIMEOUT_S` | `"600"` | `"600"` | `"600"` |
| `INFINI_PREFILL_DISABLE_PREFIX_CACHE` | omit (prefix cache ON) | omit | omit |

**Keep absent:** `INFINI_PREFILL_COMPILE`, `INFINI_PREFILL_SHARE_WEIGHTS`, `INFINI_PREFILL_CUDAGRAPH`, `INFINI_PREFILL_DISABLE_PREFIX_CACHE`.

Startup log gates: 9g `max_seq=65536`; Qwen `max_seq=40960` + `paged decode CG: capturing under TP`.

## Post-deploy validation ladder

After `docker-compose up` and startup CG capture completes:

```bash
cd deploy/cases/infinilm-metax-deployment-opt-20260611

# Full ladder (smoke + prefix cache + throughput + C-Eval)
./bench/run_deploy_validation.sh

# Or step-by-step:
ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh localhost
./bench/test_prefix_cache.sh http://localhost:8800 Qwen3-32B
MODEL=9g_8b_thinking ./bench/run_deploy_throughput.sh
MODEL=Qwen3-32B ./bench/run_deploy_throughput.sh
ROUTER_URL=http://localhost:8800 MODELS=9g_8b_thinking ./bench/run_deploy_ceval.sh
ROUTER_URL=http://localhost:8800 MODELS=Qwen3-32B MAX_GEN_TOKS=1024 ./bench/run_deploy_ceval.sh
```

Results land under `bench_results/deploy_*_<timestamp>/`.

## Services in this compose

**Master stack:**

- `master`: registry + router (`LAUNCH_COMPONENTS=registry,router`)
- `worker-master-9g-8100`: 9g_8b_thinking @ 8100 (paged + flash-attn + graph)
- `worker-master-qwen-paged-8200`: Qwen3-32B paged @ 8200 (Phase 3 env, `--num-blocks 512` — halves KV pool vs 1024; ~8 GiB headroom per TP rank on 64 GiB cards)
- `worker-master-embeddings-20002`: embedding/rerank @ 20002 (requires `EMBEDDING_MODEL_DIR`)

**Slave (primary):**

- `worker-slave-xiyan-qwencoder-8200`: XiYanSQL-QwenCoder-32B-2504 @ TP=4, port 8200

**Optional bisect slaves (legacy FLA presets):**

- `worker-slave-fla-9g-8100`, `worker-slave-fla-qwen-8200`

## XiYanSQL note

XiYanSQL loads 14 × ~4.8 GB safetensors shards. The image must include `gc.collect()` call sites in `/workspace/InfiniLM/python/infinilm/modeling_utils.py` (landed in InfiniLM `8e8b492`). This ships via `build-image.sh` staging — not a runtime env var or pip package.

E2E doc validation (2026-06-25): see [`bench_results/offline_doc_validate_20260625_202455/summary.md`](../../../../bench_results/offline_doc_validate_20260625_202455/summary.md) and [`bench/wait_worker_capture.sh`](bench/wait_worker_capture.sh).

## Unexpected-behavior bench (cancel / disconnect)

Fault-injection regression for client cancel, TCP disconnect, and short-timeout probes — run from the **monorepo root** (full dev/HPC worktree; not included in offline src tar):

```bash
./scripts/run_unexpected_behavior_bench.sh
SCENARIOS=cancel_mid_decode ./scripts/repro_cancel_token_mismatch.sh
./scripts/run_unexpected_behavior_bench.sh --via-router
```

See [`scripts/unexpected_behavior/README.md`](../../../../scripts/unexpected_behavior/README.md) and [OFFLINE_DEPLOY_GUIDE_ZH_CN.md §M) cancel/disconnect](OFFLINE_DEPLOY_GUIDE_ZH_CN.md#m-canceldisconnect-后-sampled-token-count-mismatchworker-退出).
