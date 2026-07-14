# Case: infinilm-metax-deployment-opt-20260714

HPCC **3.7.0.38** / torch **2.8** deployment case (forked from [`…-opt-20260611`](../infinilm-metax-deployment-opt-20260611/)). Master + 9g + Qwen-paged + embeddings + optional XiYan slave.

**Image pipeline:** Phase 1 → 1.5 → 2 (`docker run` + `docker commit`). Design doc: [`docs/IMAGE_BUILD_PHASES.md`](../../../../docs/IMAGE_BUILD_PHASES.md).

| Phase | Script | Status |
|-------|--------|--------|
| 1 runtime-base | [`build-image-phase1.sh`](build-image-phase1.sh) | **Execute** → `.runtime_base_tag` |
| 1.5 offline deps | [`build-image-phase1_5.sh`](build-image-phase1_5.sh) | Scaffold |
| 2 product | [`build-image-phase2.sh`](build-image-phase2.sh) | Scaffold → `.image_tag` for compose |

Do **not** use bind-mounted `infinilm-dev-hpcc37` as compose `IMAGE_TAG`.

## BASE_IMAGE (HPCC 3.7)

```
mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64
```

Tag prefixes: `infinilm-svc:metax-hpcc-ai370-runtime-base-<YYYYMMDD>` (Phase 1), `…-runtime-base-deps-…` (1.5), `…-<IL>-<IC>-<YYYYMMDD>` (Phase 2).

Optional Phase 1 / Phase 2 seed: [`worktree-hpcc37`](../../../../bench_results/hpcc_migration_20260703_161241/worktree-hpcc37).

## Quick start — Phase 1

```bash
cd InfiniOrchestrator/deploy/cases/infinilm-metax-deployment-opt-20260714
./build-image-phase1.sh
# writes .runtime_base_tag + MANIFEST

./phase1-smoke.sh    # GPU imports + HPCC Version + infini-* binaries; no external pulls
./export-bundle.sh   # optional offline transfer of runtime-base
```

Recorded after Phase 1: `.runtime_base_tag`, `MANIFEST` (`BASE_DIGEST`, `CEVAL_CACHE_LAYOUT`, `INDUCTOR_CACHE`).

Phase 1.5 / 2 (prepared, not required for this iteration):

```bash
RUNTIME_BASE_TAG=$(cat .runtime_base_tag) OFFLINE_DEPS_ROOT=$PWD/offline-deps ./build-image-phase1_5.sh
FROM_TAG=$(cat .runtime_base_tag) SOURCE_ROOT=/path/to/worktree ./build-image-phase2.sh
# then: cp .env.master.example .env; set IMAGE_TAG from .image_tag; docker-compose up …
```

## Compose / env

```bash
cp .env.master.example .env   # or .env.example for single-host
# After Phase 2: IMAGE_TAG from .image_tag
docker-compose up -d master worker-master-9g-8100 worker-master-qwen-paged-8200 worker-master-embeddings-20002
```

GPU map (unchanged vs prod): 9g `0`, Qwen `4,5,6,7`, embeddings on free GPU / remap. Network subnet `172.28.0.0/16`. Dual-host slave: `cp .env.slave.example .env` and `sed` `<MASTER_IP>` / `<SLAVE_IP>`.

## Qwen cold-start inductor + CG

[`config/master-qwen3-32b-paged.toml`](config/master-qwen3-32b-paged.toml): Phase-3 native CG (`INFINI_PREFILL_NATIVE_CG`, buckets `4096,2048,1024,512`, chunk `4096`, decode CG TP) plus:

| Key | Value |
|-----|-------|
| `INFINI_PIECEWISE_INDUCTOR_SEGMENT` | `1` |
| `INFINI_PIECEWISE_LAYER_AGNOSTIC` | `1` |
| `INFINI_PIECEWISE_INDUCTOR_COMPILE_ON_MISS` | `0` (seeded AOT; miss≠compile) |
| `INFINI_PIECEWISE_INDUCTOR_CACHE` | `/workspace/piecewise_inductor_cache` |
| `INFINI_REQUEST_TIMEOUT_S` | `7200` |

Seed AOT under [`piecewise_inductor_cache/`](piecewise_inductor_cache/) (compose mount; see README there). Do **not** use `COMPILE_ON_MISS=1` on a loaded TP4 32B — empty-cache compile OOMs on 64 GiB.

## Offline validation

Smoke (`validate.sh`) talks **only** to local compose endpoints — no HuggingFace / PyPI / registry pulls:

```bash
ROUTER_PORT=8800 EMBEDDING_PORT=20003 ./validate.sh localhost
# PASS: registry/router health, models, short chat, embeddings HTTP 200
```

Pack must include `validate.sh`, compose, TOMLs, and bench helpers it needs (see [`bench/pack-offline-worktree.sh`](bench/pack-offline-worktree.sh)).

### Pre-cached CEval

Layout: [`bench/ceval_cache/`](bench/ceval_cache/). On a networked host, download CEval + lm-eval assets into that tree, then pin:

```bash
export CEVAL_CACHE_ROOT="$PWD/bench/ceval_cache"
export HF_HOME="${CEVAL_CACHE_ROOT}/hf"
export HF_DATASETS_CACHE="${CEVAL_CACHE_ROOT}/hf/datasets"
export LM_EVAL="${CEVAL_CACHE_ROOT}/lm_eval"
export CEVAL_REPO="${CEVAL_CACHE_ROOT}/repo"
CEVAL_FULL=1 CEVAL_ENABLE_THINKING=0 ROUTER_URL=http://localhost:8800 MODELS=Qwen3-32B \
  ./bench/run_deploy_ceval.sh
# Gate: em > 0.7, no network
```

`MANIFEST` records `CEVAL_CACHE_LAYOUT=bench/ceval_cache` and `INDUCTOR_CACHE=/workspace/piecewise_inductor_cache`.

## Services

- `master`: registry + router
- `worker-master-9g-8100`: 9g_8b_thinking
- `worker-master-qwen-paged-8200`: Qwen3-32B paged + inductor cold-start
- `worker-master-embeddings-20002`: embeddings/rerank
- `worker-slave-xiyan-qwencoder-8200`: XiYanSQL @ TP=4 (optional)

Historical: [`…-20260611`](../infinilm-metax-deployment-opt-20260611/), [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](OFFLINE_DEPLOY_GUIDE_ZH_CN.md) (adapt paths to `20260714` / Phase scripts).
