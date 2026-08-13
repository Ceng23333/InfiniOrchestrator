# Case: qwen3-32b+9g--x203-inf--opt20260811

Master-only **InfiniLM** Distribution case (`be_abbr = inf`). Stack: master + 9g + Qwen-paged + embeddings. **No XiYan / slave. No vLLM babysitter TOMLs or validate presets.**

Forked from [`qwen3-32b+xiyan+9g--x203-il+x203-vllm--opt20260714`](../qwen3-32b+xiyan+9g--x203-il+x203-vllm--opt20260714/). `DEPLOYMENT_CASE=infinilm-metax-deployment-opt-20260811`.

## Layout

| Dir | Role |
|-----|------|
| [`image/`](image/) | Phase 1/2 build scripts, entrypoint, `.image_tag` / `.runtime_base_tag` / `.worktree_tag`, `MANIFEST` |
| [`docker-compose/`](docker-compose/) | Compose stack, env templates, babysitter `config/`, `validate.sh` |
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

The tag name contains `vllm-mars` (HPCC base). That is **not** a case runtime backend — LLM serving is InfiniLM via the SVC entrypoint. Embeddings may use a separate MiniCPM/`embeddings_server.py` image (`EMBEDDING_IMAGE_TAG`), which is also not a vLLM LLM worker.

Tag prefixes: `infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-<YYYYMMDD>` (Phase 1), `infini-orchestrator-metax:<IL>-<IC>-<YYYYMMDD>` (Phase 2).

```bash
SOURCE_ROOT=/path/to/InfiniTensorWorktree \
SVC_ROOT=/path/to/InfiniOrchestrator \
  ./image/build-image-phase1.sh
```

## Pipeline

```bash
source scripts/worktree_env.sh
cd playground/Distribution/qwen3-32b+9g--x203-inf--opt20260811

# 1. Image
./image/build-image-phase1.sh
./image/phase1-smoke.sh
./image/build-image-phase2.sh

# 2. Compose (shared Frontend fragments + case workers)
cd docker-compose
cp -n .env.master.example .env   # or keep existing .env
# IMAGE_TAG=$(cat ../image/.image_tag)
./compose.sh --profile frontend --profile workers up -d
# Optional: ./compose.sh --profile observability up -d
# Optional hot warehouse pull (needs BENCH_WAREHOUSE_GITHUB_TOKEN for private HTTPS):
# ./compose.sh --profile frontend --profile warehouse-sync up -d
# Canonical full stack:
# ./compose.sh --profile frontend --profile workers --profile observability --profile warehouse-sync up -d

# 3. Smoke
./validate.sh localhost

# 4. LongBench regression (official 0-shot)
cd ..
./regression/run_longbench.sh
# LIMIT=8 ./regression/run_longbench.sh   # quick gate

# Optional offline transfer
./export-bundle.sh
```

`compose.sh` merges [`frontend/docker-compose/`](../../../../frontend/docker-compose/) `etcd` + `frontend` (+ optional `observability` / `warehouse-sync`) with this case’s workers. Service name **`frontend`** is the Dynamo Frontend (formerly `master`); workers use `ROUTER_URL=http://frontend:${ROUTER_PORT}`.

**Bench warehouse:** owned by Frontend fragments (`BENCH_WAREHOUSE_REPO=/warehouse` + named volume `bench_warehouse`). Enable `--profile warehouse-sync` to pull the private repo on an interval (set `BENCH_WAREHOUSE_GITHUB_TOKEN`; see fragment README). Without sync the volume may be empty — LongBench viz needs sync+token, or host-native panel via [`frontend/run-host-panel.sh`](../../../../frontend/run-host-panel.sh). Panel LongBench `source.sync` reflects `/warehouse/.warehouse-sync-status` when present.

Default `COMPOSE_PROJECT_NAME` is **`docker-compose`** (matches the historical project on this host). Override only when intentionally creating a parallel project — and then use a non-overlapping compose subnet.
GPU map: 9g `0`, Qwen `4,5,6,7`, embeddings on free GPU / remap. Network subnet `172.28.0.0/16`. MetaX device blocks unchanged.

Babysitter TOMLs (InfiniLM only):

- `docker-compose/config/master-9g_8b_thinking.toml`
- `docker-compose/config/master-qwen3-32b-paged.toml`
- `docker-compose/config/master-embeddings.toml`

## Qwen cold-start inductor + CG

[`docker-compose/config/master-qwen3-32b-paged.toml`](docker-compose/config/master-qwen3-32b-paged.toml) launches `python -m infinilm.server.entry --phase all`. Compose mounts [`cache/piecewise_inductor/`](cache/piecewise_inductor/) **rw** → `/workspace/piecewise_inductor_cache`. Prefer seeding under that host path.

## Offline validation

```bash
cd docker-compose
ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh localhost
# Expect: master-9g_8b_thinking + master-qwen3-32b-paged + master-embeddings
```

## Services

- `master`: registry + router
- `worker-master-9g-8100`: 9g_8b_thinking (InfiniLM)
- `worker-master-qwen-paged-8200`: Qwen3-32B paged (InfiniLM)
- `worker-master-embeddings-20002`: MiniCPM embeddings/rerank

See [`COLD_START_GUIDE.md`](COLD_START_GUIDE.md) (fresh ITW) and [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](OFFLINE_DEPLOY_GUIDE_ZH_CN.md) (ZH redeploy / offline).

Workspace-level InfiniLM vs stock vLLM diverge A/B (separate from compose): [`scripts/run_longbench_v2_ab_qwen3_32b.sh`](../../../../scripts/run_longbench_v2_ab_qwen3_32b.sh).
