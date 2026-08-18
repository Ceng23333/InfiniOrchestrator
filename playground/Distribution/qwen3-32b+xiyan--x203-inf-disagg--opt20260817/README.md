# Case: qwen3-32b+xiyan--x203-inf-disagg--opt20260817

Dynamo-style **InfiniLM** Distribution case (`be_abbr = inf`) for the target disaggregated layout: **Frontend** (etcd + `infini-loadbalancer`) and **embeddings** on `metax-8`; **XiYanSQL-QwenCoder-32B-2504** and **Qwen3-32B paged** on `metax-9`.

Forked from [`qwen3-32b+9g--x203-inf--opt20260811`](../qwen3-32b+9g--x203-inf--opt20260811/) and restores the XiYan worker config from [`qwen3-32b+xiyan+9g--x203-il+x203-vllm--opt20260714`](../qwen3-32b+xiyan+9g--x203-il+x203-vllm--opt20260714/). `DEPLOYMENT_CASE=infinilm-metax-disagg-opt-20260817`.

## Target split layout

| Host | Role | Services |
|------|------|----------|
| `metax-8` / `172.31.1.8` | External frontend + embedding | `etcd`, `frontend`, `worker-embeddings-20002` |
| `metax-9` / `172.31.1.9` | LLM workers + harness | `worker-xiyan-qwencoder-8300`, `worker-qwen-paged-8200` |

All external health checks, smokes, and LongBench traffic should target the metax-8 Frontend:

```bash
curl http://172.31.1.8:8800/health
curl http://172.31.1.8:18800/services
```

XiYan is a separate TP=4 worker, not the 9g worker. In this target layout XiYan uses devices `0,1,2,3` and Qwen uses devices `4,5,6,7`; do not start `worker-9g-8100` at the same time unless its GPU map is remapped.

The split env templates are:

- `docker-compose/.env.split-fe.example` for `metax-8`
- `docker-compose/.env.split-workers.example` for `metax-9`

Bring up the target layout manually:

```bash
# metax-8
cd /root/zenghua/workspace/profiling_20260817_split_fe/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/docker-compose
cp -n .env.split-fe.example .env.split-fe
COMPOSE_PROJECT_NAME=io-feembed COMPOSE_ENV_FILE=.env.split-fe ./compose.sh --profile frontend up -d etcd frontend
COMPOSE_PROJECT_NAME=io-feembed COMPOSE_ENV_FILE=.env.split-fe ./compose.sh --profile workers up -d worker-embeddings-20002

# metax-9
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817/docker-compose
cp -n .env.split-workers.example .env.split-workers
COMPOSE_PROJECT_NAME=io-workers COMPOSE_ENV_FILE=.env.split-workers ./compose.sh --profile workers up -d worker-xiyan-qwencoder-8300 worker-qwen-paged-8200
```

## Layout

| Dir | Role |
|-----|------|
| [`image/`](image/) | Phase 1/2 build scripts, entrypoint, `.image_tag` / `.runtime_base_tag` / `.worktree_tag`, `MANIFEST` |
| [`docker-compose/`](docker-compose/) | Compose stack, env templates, babysitter `config/`, `validate.sh`, multinode sim |
| [`cache/piecewise_inductor/`](cache/piecewise_inductor/) | Host AOT seed (mounted rw at `/workspace/piecewise_inductor_cache`) |
| [`regression/`](regression/) | Post-deploy LongBench-v2 gate |
| [`k8s/`](k8s/) | Placeholder for future manifests |

**Image pipeline:** Phase 1 (runtime-base) → Phase 2 product `IMAGE_TAG` (`docker run` + `docker commit`). Design: [`docs/IMAGE_BUILD_PHASES.md`](../../../../docs/IMAGE_BUILD_PHASES.md).

| Phase | Script | Status |
|-------|--------|--------|
| 1 runtime-base | [`image/build-image-phase1.sh`](image/build-image-phase1.sh) | **Execute** → `image/.runtime_base_tag` + `image/MANIFEST` |
| 2 product | [`image/build-image-phase2.sh`](image/build-image-phase2.sh) | **Execute** → `image/.image_tag` for compose |

InfiniTensorWorktree pin: `image/.worktree_tag` (e.g. `v2026.08.12`) + `ITW_TAG` / `ITW_SHA` in `image/MANIFEST`.

**Cold start (same-arch, empty → identical ITW):** [`COLD_START_GUIDE.md`](COLD_START_GUIDE.md) — Phase 0 clone at pin, then Phase 1 → smoke → Phase 2 → compose → `validate.sh`.

## BASE_IMAGE (vendor HPCC OS/stack only)

Pinned Docker ID **`1a3cbde5ff2a`**:

```
mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64
```

The tag name contains `vllm-mars` (HPCC base). That is **not** a case runtime backend — LLM serving is InfiniLM via the SVC entrypoint. Embeddings run as the Flask sidecar `embeddings_server.py` on the **same product `IMAGE_TAG`** (TF5). MiniCPM is attempted with a TF5 `is_torch_fx_available` shim + numeric smoke; on NaN/import failure the server falls back to **bge-m3** (+ BCE rerank). Optional `EMBEDDING_IMAGE_TAG` is emergency rollback only. InfiniLM has no native embeddings HTTP API yet — not folded into InfiniLM here.

Tag prefixes: `infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-<YYYYMMDD>` (Phase 1), `infini-orchestrator-metax:<IL>-<IC>-<YYYYMMDD>` (Phase 2).

```bash
SOURCE_ROOT=/path/to/InfiniTensorWorktree \
SVC_ROOT=/path/to/InfiniOrchestrator \
  ./image/build-image-phase1.sh
```

## Pipeline

```bash
source scripts/worktree_env.sh
cd playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817

# 1. Image
./image/build-image-phase1.sh
./image/phase1-smoke.sh
./image/build-image-phase2.sh

# 2. Compose (shared Frontend fragments + case workers)
cd docker-compose
cp -n .env.frontend.example .env   # or keep existing .env
# IMAGE_TAG=$(cat ../image/.image_tag)
./compose.sh --profile frontend --profile workers up -d
# Optional: ./compose.sh --profile observability up -d
# Optional hot warehouse pull (needs BENCH_WAREHOUSE_GITHUB_TOKEN for private HTTPS):
# ./compose.sh --profile frontend --profile warehouse-sync up -d
# Canonical full stack:
# ./compose.sh --profile frontend --profile workers --profile observability --profile warehouse-sync up -d

# 3. Smoke
./validate.sh localhost

# 3b. Embeddings quality A/B (optional; not part of validate.sh)
# Live bge-m3 self-gate + ranking agreement vs ephemeral TF4 MiniCPM
# (infini-orchestrator-metax:local). Model swap ⇒ compare preference order, not vector equality.
./regression_embeddings_vs_baseline.sh

# 4. LongBench regression (official 0-shot, length=all)
#    MAX_INPUT_TOKENS defaults to serve compile caps (Qwen 40832 / 9g 65408),
#    not official ~120k. Official code: harness/.../longbench_v2/third_party/LongBench
cd ..
./regression/run_longbench.sh
# LIMIT=8 ./regression/run_longbench.sh   # quick gate

# Optional offline transfer
./export-bundle.sh
```

`compose.sh` merges [`frontend/docker-compose/`](../../../../frontend/docker-compose/) `etcd` + `frontend` (+ optional `observability` / `warehouse-sync`) with this case’s workers. Service name **`frontend`** is the Dynamo Frontend; same-host workers default to `ROUTER_URL=http://frontend:${ROUTER_PORT}` and `ADVERTISE_HOST=<compose_service_name>`.

**Multi-host / fake multi-node:** see [`.env.workers.example`](docker-compose/.env.workers.example) and [`simulate_multinode_localhost.sh`](docker-compose/simulate_multinode_localhost.sh). Workers override `ROUTER_URL` / `REGISTRY_URL` / `ETCD_ENDPOINTS` / `ADVERTISE_HOST` to LAN IPs (never `127.0.0.1` from inside containers). If workers cannot reach the Frontend host directly, use the PC-anchored tunnel runbook: [`docs/ops/kunlun-metax9-febe-validation.md`](../../../../docs/ops/kunlun-metax9-febe-validation.md).

**Bench warehouse:** owned by Frontend fragments (`BENCH_WAREHOUSE_REPO=/warehouse` + named volume `bench_warehouse`). Enable `--profile warehouse-sync` to pull the private repo on an interval (set `BENCH_WAREHOUSE_GITHUB_TOKEN`; see fragment README). Without sync the volume may be empty — LongBench viz needs sync+token, or host-native panel via [`frontend/run-host-panel.sh`](../../../../frontend/run-host-panel.sh) plus [`frontend/warehouse-sync-host.sh`](../../../../frontend/warehouse-sync-host.sh). Panel LongBench `source.sync` reflects `InfiniOrchestrator/.warehouse-sync-status` (host-native) or `/warehouse/.warehouse-sync-status` (compose) when present.

Default `COMPOSE_PROJECT_NAME` is **`docker-compose`** (matches the historical project on this host). Override for parallel projects (e.g. `io-frontend` / `io-workers` multinode sim) — use a non-overlapping compose subnet when both share one host.
GPU map: 9g `0`, Qwen `4,5,6,7`, embeddings on free GPU / remap. Network subnet `172.28.0.0/16`. MetaX device blocks unchanged.

Babysitter TOMLs (InfiniLM only):

- `docker-compose/config/9g_8b_thinking.toml`
- `docker-compose/config/qwen3-32b-paged.toml`
- `docker-compose/config/embeddings.toml`

## Qwen cold-start inductor + CG

[`docker-compose/config/qwen3-32b-paged.toml`](docker-compose/config/qwen3-32b-paged.toml) launches `python -m infinilm.server.entry --phase all`. Compose mounts [`cache/piecewise_inductor/`](cache/piecewise_inductor/) **rw** → `/workspace/piecewise_inductor_cache`. Prefer seeding under that host path.

## Offline validation

```bash
cd docker-compose
ROUTER_PORT=8800 EMBEDDING_PORT=20002 ./validate.sh localhost
# Expect openai-api registry names: master-9g_8b_thinking-server + master-qwen3-32b-paged-server + master-embeddings-server
# (compose services remain worker-*)

# Fake multi-node on one host (LAN IP path):
./simulate_multinode_localhost.sh
./validate_multinode_localhost.sh
```

### Embeddings smoke vs quality A/B

`validate.sh` only checks that the embeddings API responds (fast smoke). Product path on TF5 is **bge-m3** (MiniCPM skipped after NaN smoke); old TF4 image `infini-orchestrator-metax:local` served **MiniCPM**. Vectors will not match across that model swap.

For ranking / preference regression (candidate self-consistency + pairwise agreement vs ephemeral MiniCPM baseline on GPU 2, default port `21002`):

```bash
cd docker-compose
./validate.sh localhost
./regression_embeddings_vs_baseline.sh
# Artifacts: ../results/embeddings-regression-<ts>/{baseline.json,candidate.json,report.json}
# Pass: bge-m3 gate OK and pairwise agreement ≥ AGREE_THRESHOLD (default 0.75)
```

## Services

- `frontend`: Dynamo Frontend (`infini-loadbalancer` + panel)
- `etcd`: discovery plane
- `worker-xiyan-qwencoder-8300`: XiYanSQL-QwenCoder-32B-2504 (InfiniLM)
- `worker-qwen-paged-8200`: Qwen3-32B paged (InfiniLM)
- `worker-embeddings-20002`: Flask embeddings/rerank on `IMAGE_TAG` (bge-m3; MiniCPM optional)
- `worker-9g-8100`: optional preserved 9g_8b_thinking service; not part of the target XiYan+Qwen split unless remapped

See [`COLD_START_GUIDE.md`](COLD_START_GUIDE.md) (fresh ITW) and [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](OFFLINE_DEPLOY_GUIDE_ZH_CN.md) (ZH redeploy / offline).

Workspace-level InfiniLM vs stock vLLM diverge A/B (separate from compose): [`scripts/run_longbench_v2_ab_qwen3_32b.sh`](../../../../scripts/run_longbench_v2_ab_qwen3_32b.sh).
