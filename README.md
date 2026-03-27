# InfiniOrchestrator

InfiniOrchestrator is a deployment-focused repo for running InfiniLM-SVC style stacks (Metax base image, babysitter, router, discovery) with a layout inspired by [Dynamo](../dynamo): `deploy/`, `container/`, `docs/`, vendored `rust/`, plus optional `examples/` and `tests/`.

It is separate from [InfiniLM-SVC](../InfiniLM-SVC); this tree vendors the Rust workspace from there for orchestration binaries and future changes.

## Relationship to Dynamo

Dynamo is referenced for **structure and long-term discovery design** (for example [`dynamo/docs/design-docs/discovery-plane.md`](../dynamo/docs/design-docs/discovery-plane.md)), not as a runtime dependency in the first deployment skeleton.

## Build the Metax orchestrator runtime image

The runtime image starts from `infinilm-svc:metax-hpcc-1004_218-202602281209` and bakes in **InfiniCore** and **InfiniLM** from the sibling directories under the same workspace root as this repo (for example `/home/zenghua/workspace/infinilm-svc-refactor`).

From this repository root:

```bash
./container/metax/build-image.sh
```

Override the tag or base image if needed:

```bash
IMAGE_TAG=infini-orchestrator-metax:dev \
BASE_IMAGE=infinilm-svc:metax-hpcc-1004_218-202602281209 \
./container/metax/build-image.sh
```

The script stages only `InfiniCore/` and `InfiniLM/` into a temporary build context so `docker build` does not upload the whole monorepo (useful on older Docker without `--ignorefile`).

If you prefer to build manually, use a context directory that contains `Dockerfile.orchestrator-runtime` renamed to `Dockerfile`, plus `InfiniCore/` and `InfiniLM/` at the context root, matching the `COPY` instructions in that file.

## Deploy layout

- `deploy/docker-compose/` — shared fragments (networks, common options) as they are added.
- `deploy/cases/infinilm-metax-deployment-opt-20260325/` — first case: Compose, env templates, per-worker TOML under `config/` (filled in as the case is finalized).

## Future: etcd-backed discovery (proposal)

Today’s first case targets the **existing HTTP registry** on the master (`REGISTRY_URL`, same protocol as `InfiniLM-SVC` babysitter code). A later phase can align with Dynamo-style discovery using **etcd** (lease-backed keys, `ETCD_ENDPOINTS`, key hierarchy similar to Dynamo’s discovery plane). See [`docs/design/discovery-etcd.md`](docs/design/discovery-etcd.md) for the proposed contract; implementation is **not** part of the initial skeleton.
