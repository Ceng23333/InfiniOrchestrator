# InfiniOrchestrator

Deployment-focused repo for InfiniLM / vLLM / SGLang stacks with **InfiniEntrypoint** (pid=1), **InfiniLoadBalancer**, etcd discovery, playground cases, and harness.

Frozen InfiniCore / InfiniLM / InfiniMetadata pins live in the sibling **[InfiniTensorWorktree](https://github.com/Ceng23333/InfiniTensorWorktree)** repo (release tags `vYYYY.MM.DD`).

## Layout

```text
workspace/
  InfiniOrchestrator/
    rust/                   # infini-entrypoint, infini-loadbalancer, infini-sharepool
    harness/                # bench runners + emit/compact/query
    playground/
      Standalone/           # n=1 cases: {model}-{hw_abbr}-{be_abbr}
      Distribution/         # n>=2 / deploy recipes
    deploy/                 # packaging overlay (not a second case tree)
  InfiniTensorWorktree/     # sibling: InfiniCore, InfiniLM, InfiniMetadata + MANIFEST
```

External private catalogs (env):

| Env | Role |
|-----|------|
| `INFINI_TENSOR_WORKTREE` | Pin umbrella (default `../InfiniTensorWorktree`) |
| `BENCH_WAREHOUSE_REPO` | Data-only metrics: `raw/<date>/`, `compact/<model_id>/` |
| `HARDWARE_PROFILE_REPO` | GPU-primary HW catalog (`abbr`, profiles) |

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
require_worktree_repos InfiniCore InfiniLM InfiniMetadata
```

Release pin (in InfiniTensorWorktree):

```bash
TAG=vYYYY.MM.DD ./scripts/release.sh --from-current
```

Manifest: `InfiniTensorWorktree/MANIFEST` (`ITW_SHA`, `IC_SHA`, `IL_SHA`, `IM_SHA`).

## Control plane

| Binary | Role |
|--------|------|
| `infini-entrypoint` | pid=1 process manager; registers to etcd |
| `infini-loadbalancer` | OpenAI gateway; watches etcd |
| `infini-sharepool` | Placeholder `/health` |
| `infini-registry` | Removed (exits with deprecation) |

```bash
ETCD_ENDPOINTS=http://127.0.0.1:2379 DISCOVERY_PREFIX=/infini/orchestrator/case \
  infini-entrypoint --config-file master.toml
```

## Playground naming

- **Simple:** `{model_id}-{hw_abbr}-{be_abbr}` (e.g. `minicpm5-mxc500-vllm`)
- **Complex:** `{model_expr}--{band}[+{band}...][--{qualifier}]`
- Service count via `Standalone` / `Distribution` + `case.toml` `n` (no `n{N}` prefix, no soft scope)

## Harness + warehouse

Harness lives in this repo. Warehouse is data-only:

```bash
export BENCH_WAREHOUSE_REPO=../bench-warehouse
export HARDWARE_PROFILE_REPO=../hardware-profile
export CASE_ID=minicpm5-mxc500-vllm
"${IO_ROOT}/harness/run_bench_client.sh" longbench
# compact:
python -m bench_harness.compact --repo-root "$BENCH_WAREHOUSE_REPO"
```

## Design docs

- [`docs/design/discovery-etcd.md`](docs/design/discovery-etcd.md)
- [`docs/design/share-pool.md`](docs/design/share-pool.md)
- [`docs/design/operations-panel.md`](docs/design/operations-panel.md) (deferred panel refactor)
