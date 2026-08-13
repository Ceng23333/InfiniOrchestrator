# InfiniOrchestrator

Deployment-focused repo for InfiniLM / vLLM / SGLang stacks with **InfiniEntrypoint** (pid=1), **InfiniLoadBalancer**, etcd discovery, playground cases, and harness.

Frozen InfiniCore / InfiniLM pins live in the sibling **[InfiniTensorWorktree](https://github.com/Ceng23333/InfiniTensorWorktree)** repo (release tags `vYYYY.MM.DD`).

## Layout

```text
workspace/
  InfiniOrchestrator/
    rust/                   # infini-entrypoint, infini-loadbalancer, infini-sharepool
    harness/                # bench runners + emit/compact/query
    playground/             # case scheme → emit (see playground/README.md)
      case.schema.toml      # case.toml field contract
      Standalone/           # n=1 cases: {model}-{hw_abbr}-{be_abbr}
      Distribution/         # n>=2 / deploy recipes
    frontend/               # packaging overlay (Frontend stack compose fragments; not a second case tree)
  InfiniTensorWorktree/     # sibling: InfiniCore, InfiniLM + MANIFEST
```

External private catalogs (env):

| Env | Role |
|-----|------|
| `INFINI_TENSOR_WORKTREE` | Pin umbrella (default `../InfiniTensorWorktree`) |
| `BENCH_WAREHOUSE_REPO` | Data-only metrics: `raw/<date>/`, `compact/<model_id>/` |
| `HARDWARE_PROFILE_REPO` | GPU band files (`profiles/{vendor}-{gpu.model}.yaml`) + hosts list (ip-primary) |

```bash
source scripts/worktree_env.sh
# exports IO_ROOT, INFINI_TENSOR_WORKTREE, HARNESS_ROOT,
# BENCH_WAREHOUSE_REPO, HARDWARE_PROFILE_REPO, SVC_ROOT
```

## InfiniTensorWorktree

```bash
# Sibling of InfiniOrchestrator:
git clone --recurse-submodules https://github.com/Ceng23333/InfiniTensorWorktree.git
cd InfiniTensorWorktree
git checkout vYYYY.MM.DD && git submodule update --init --recursive
```

From InfiniOrchestrator:

```bash
source scripts/worktree_env.sh
require_worktree_repos InfiniCore InfiniLM
```

Release pin (in InfiniTensorWorktree):

```bash
TAG=vYYYY.MM.DD ./scripts/release.sh --from-current
```

Manifest: `InfiniTensorWorktree/MANIFEST` (`ITW_SHA`, `IC_SHA`, `IL_SHA`).

## Control plane

| Binary | Role |
|--------|------|
| `infini-entrypoint` | pid=1 process manager; `GET /metadata`; registers to etcd |
| `infini-loadbalancer` | OpenAI gateway; `GET /metrics`; watches etcd |
| `infini-sharepool` | Placeholder `/health` |
| `infini-registry` | Removed (exits with deprecation) |

```bash
ETCD_ENDPOINTS=http://127.0.0.1:2379 DISCOVERY_PREFIX=/infini/orchestrator/case \
  infini-entrypoint --config-file master.toml
```

Warehouse identity scrapes Entrypoint (`INFERENCE_METADATA_URL`, default inference port+1). Gateway `srv_*` scrapes LoadBalancer (`BENCH_METRICS_URL` / `ROUTER_URL`). See [`docs/design/deprecate-infinimetadata.md`](docs/design/deprecate-infinimetadata.md).

## Playground naming

Canonical definition: [`playground/README.md`](playground/README.md) + [`playground/case.schema.toml`](playground/case.schema.toml).

- **Simple:** `{model_id}-{hw_abbr}-{be_abbr}` (e.g. `minicpm5-mxc500-vllm`)
- **Complex:** `{model_expr}--{band}[+{band}...][--{qualifier}]`
- Service count via `Standalone` / `Distribution` + `case.toml` `n` (no `n{N}` prefix, no soft scope)
- Emit reads `CASE_PATH` → `case.toml` into warehouse `CASE_META_COLUMNS`

## Harness + warehouse

- **`harness/`** — runners (`scenarios/`, `lib/*.sh`, `server_client.py` scrape).
- **`../bench-warehouse`** — data repo + Python package `bench_warehouse` (`warehouse-emit` / `warehouse-compact` / …).

```bash
export BENCH_WAREHOUSE_REPO=../bench-warehouse
export HARDWARE_PROFILE_REPO=../hardware-profile
pip install -e "$BENCH_WAREHOUSE_REPO"
# optional: pip install -e harness   # installs server_client + path-dep on bench-warehouse
export CASE_ID=minicpm5-mxc500-vllm
"${IO_ROOT}/harness/run_bench_client.sh" longbench
python -m bench_warehouse.compact --repo-root "$BENCH_WAREHOUSE_REPO"
```

## Design docs

- [`docs/design/discovery-etcd.md`](docs/design/discovery-etcd.md)
- [`docs/design/share-pool.md`](docs/design/share-pool.md)
- [`docs/design/deprecate-infinimetadata.md`](docs/design/deprecate-infinimetadata.md)
- [`docs/design/operations-panel.md`](docs/design/operations-panel.md) (deferred panel refactor)
