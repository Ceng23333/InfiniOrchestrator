# InfiniOrchestrator

InfiniOrchestrator is a deployment-focused repo for running InfiniLM-SVC style stacks (Metax base image, babysitter, router, discovery) with a layout inspired by [Dynamo](../dynamo): `deploy/`, `container/`, `docs/`, vendored `rust/`, plus optional `examples/` and `tests/`.

It is separate from [InfiniLM-SVC](../InfiniLM-SVC); this tree vendors the Rust workspace from there for orchestration binaries and future changes.

## Worktree (frozen dependencies)

InfiniCore, InfiniLM, InfiniMetadata, and bench-warehouse live under **`worktree/`** as git submodules. An InfiniOrchestrator **release tag** freezes their commits via gitlinks.

```text
InfiniOrchestrator/
  worktree/
    InfiniCore/         # submodule → Ceng23333/InfiniCore (branch hint: prefill_profile)
    InfiniLM/           # submodule → Ceng23333/InfiniLM (branch hint: prefill_profile_dev2)
    InfiniMetadata/     # submodule → InfiniTensor/InfiniMetadata
    bench-warehouse/    # submodule → InfiniTensor/bench-warehouse
  scripts/
    worktree_env.sh     # IO_ROOT / WORKTREE_ROOT / SVC_ROOT helpers
    pin_worktree.sh     # checkout SHAs + stage gitlinks + WORKTREE_MANIFEST
    release.sh          # pin + commit + annotated tag
```

**Hard cutover:** build/pack scripts resolve sources only from `worktree/` (no sibling-dir fallback). `InfiniLM-SVC` stays outside this freeze set; Phase-1 uses `SVC_ROOT` (default `../InfiniLM-SVC`).

### Clone

```bash
git clone --recurse-submodules https://github.com/Ceng23333/InfiniOrchestrator.git
cd InfiniOrchestrator
# or after a plain clone:
git submodule update --init --recursive

source scripts/worktree_env.sh
# prints/exports IO_ROOT, WORKTREE_ROOT, BENCH_WAREHOUSE_REPO, SVC_ROOT
```

Checkout a release:

```bash
git checkout vYYYY.MM.DD
git submodule update --init --recursive
```

### Publish a release (freeze worktree)

```bash
# Pin current submodule HEADs (or set IC_SHA IL_SHA IM_SHA BW_SHA):
TAG=v2026.07.31 ./scripts/release.sh --from-current

# Review, then push:
git push origin HEAD --tags
```

`WORKTREE_MANIFEST` records `IO/IC/IL/IM/BW` SHAs and remote URLs.

### Host / workspace scripts

Outside this repo (e.g. offline HPCC `scripts/`), point at the worktree:

```bash
export WORKTREE_ROOT=/path/to/InfiniOrchestrator/worktree
export BENCH_WAREHOUSE_REPO=$WORKTREE_ROOT/bench-warehouse
export PYTHONPATH=$WORKTREE_ROOT/InfiniLM/python:$WORKTREE_ROOT/InfiniCore/python${PYTHONPATH:+:$PYTHONPATH}
```

## Relationship to Dynamo

Dynamo is referenced for **structure and long-term discovery design** (for example [`dynamo/docs/design-docs/discovery-plane.md`](../dynamo/docs/design-docs/discovery-plane.md)), not as a runtime dependency in the first deployment skeleton.

## Build the Metax orchestrator runtime image

The runtime image starts from `infinilm-svc:metax-hpcc-1004_218-202602281209` and bakes in **InfiniCore** and **InfiniLM** from `worktree/`.

From this repository root (submodules initialized):

```bash
source scripts/worktree_env.sh
./container/metax/build-image.sh
```

Override the tag or base image if needed:

```bash
IMAGE_TAG=infini-orchestrator-metax:dev \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
./container/metax/build-image.sh
```

The script stages only `worktree/InfiniCore/` and `worktree/InfiniLM/` into a temporary build context so `docker build` does not upload the whole monorepo (useful on older Docker without `--ignorefile`).

If you prefer to build manually, use a context directory that contains `Dockerfile.orchestrator-runtime` renamed to `Dockerfile`, plus `InfiniCore/` and `InfiniLM/` at the context root, matching the `COPY` instructions in that file.

## Deploy layout

- `deploy/docker-compose/` — shared fragments (networks, common options) as they are added.
- `deploy/cases/infinilm-metax-deployment-opt-20260714/` — current case: Phase 1 → 1.5 → 2 image pipeline + offline pack.
- `deploy/cases/infinilm-metax-deployment-opt-20260611/` — historical reference case.
- `deploy/cases/infinilm-metax-deployment-opt-20260325/` — historical reference case (unchanged).

## Design docs

- [`docs/design/discovery-etcd.md`](docs/design/discovery-etcd.md) — proposed etcd discovery contract (later phase).
- [`docs/design/operations-panel.md`](docs/design/operations-panel.md) — operations panel entity model (Cluster / Host / Router / Server / Bench / BenchResult) and Benchmark / Playground / Dashboard module IA.

## Future: etcd-backed discovery (proposal)

Today’s first case targets the **existing HTTP registry** on the master (`REGISTRY_URL`, same protocol as `InfiniLM-SVC` babysitter code). A later phase can align with Dynamo-style discovery using **etcd** (lease-backed keys, `ETCD_ENDPOINTS`, key hierarchy similar to Dynamo’s discovery plane). See [`docs/design/discovery-etcd.md`](docs/design/discovery-etcd.md) for the proposed contract; implementation is **not** part of the initial skeleton.
