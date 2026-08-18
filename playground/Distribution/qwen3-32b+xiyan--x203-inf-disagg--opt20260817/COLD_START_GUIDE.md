# Cold start — same-arch host (empty → identical InfiniTensorWorktree)

Case: `qwen3-32b+9g--x203-inf--opt20260811` (`be_abbr=inf`).

This guide brings up **vendor BASE_IMAGE + InfiniTensorWorktree + InfiniOrchestrator** on a host whose CPU arch matches the vendor image (`aarch64` / arm64). It starts from an **empty directory** that becomes **identical** to InfiniTensorWorktree at the case pin — not from a dirty sibling checkout.

Redeploy / offline transfer after images already exist: see [`OFFLINE_DEPLOY_GUIDE_ZH_CN.md`](OFFLINE_DEPLOY_GUIDE_ZH_CN.md).

```text
EmptyDir → Identical ITW at PIN → worktree_env + SOURCE_ROOT
  → Phase1 runtime-base → phase1-smoke → Phase2 product
  → compose up → validate.sh
```

Phase 1/2 scripts **never clone** ITW. They only stream `SOURCE_ROOT` (`InfiniCore/` + `InfiniLM/`) into the build container. You must materialize an identical ITW tree first.

## Pin

| Source | Value |
|--------|--------|
| `case.toml` / `image/.worktree_tag` | `v2026.08.12` |
| Expected ITW `MANIFEST` | `ITW_SHA=90000cb639f11feec3e15a06d7b8e3855bf1662f`, `IC_SHA=6ad5e1c9…`, `IL_SHA=4e0fdd7e…` |
| BASE_IMAGE Docker ID | `1a3cbde5ff2a` |

```
mx-devops-acr-cn-shanghai.cr.volces.com/pub-registry1/ai-release/hpcc/vllm-mars:0.20.0-hpcc.ai3.7.0.102-torch2.8-py310-kylin2309a-arm64
```

Tag name contains `vllm-mars` (HPCC OS/stack). That is **not** the LLM runtime; serving is InfiniLM via InfiniEntrypoint.

## Prerequisites

- Host arch **aarch64** (same as BASE_IMAGE)
- Docker; MetaX devices (`/dev/dri`, `/dev/htcd`) for smoke + compose
- Host **cargo** (release build of InfiniOrchestrator `rust/` bins: entrypoint, loadbalancer)
- InfiniOrchestrator checkout with `rust/` — control plane is **`SVC_ROOT=${IO_ROOT}`**, not InfiniLM-SVC
- BASE_IMAGE present locally (`docker image inspect 1a3cbde5ff2a`) or pullable
- Model dirs (see `docker-compose/.env.frontend.example`): `MODEL1_DIR`, `QWEN3_32B_DIR`, `EMBEDDING_MODEL_DIR`
- Optional: seed `cache/piecewise_inductor/` for Qwen AOT (separate from ITW identity; `export-bundle.sh` omits it)

## Phase 0 — empty → identical InfiniTensorWorktree

```bash
PIN=v2026.08.12   # from case.toml / image/.worktree_tag
ITW_URL=https://github.com/Ceng23333/InfiniTensorWorktree.git
EMPTY=/path/to/empty-itw   # must not exist, or be an empty directory

git clone --recurse-submodules "${ITW_URL}" "${EMPTY}"
cd "${EMPTY}"
git checkout "${PIN}"
git submodule update --init --recursive

# Identity checks
test "$(git describe --tags --exact-match HEAD)" = "${PIN}"
# Compare EMPTY/MANIFEST to case image/MANIFEST (IC_SHA / IL_SHA; ITW_SHA freeze field)
# and submodule HEADs:
git -C InfiniCore rev-parse HEAD   # == MANIFEST IC_SHA
git -C InfiniLM rev-parse HEAD     # == MANIFEST IL_SHA
```

Do **not** use a dirty workspace sibling as `SOURCE_ROOT` for cold-start proof without first asserting the pin SHAs above.

If GitHub is unreachable (nested `third_party` submodules), materialize an **identical** tree from a pin-verified local mirror instead of `git clone` from the network:

```bash
# EMPTY must not exist yet
cp -a /path/to/pin-verified-InfiniTensorWorktree "${EMPTY}"
cd "${EMPTY}"
# re-run the identity checks above
```

Nested submodule fetch failures leave empty `InfiniCore/` / broken `.git` gitfile links — Phase 1 will stream incomplete trees. Prefer a full `cp -a` of a known-good pin checkout on the same host.

## Phase 1 → smoke → Phase 2

```bash
CASE="/path/to/InfiniOrchestrator/playground/Distribution/qwen3-32b+9g--x203-inf--opt20260811"
IO_ROOT="/path/to/InfiniOrchestrator"

export SOURCE_ROOT=/path/to/empty-itw
export INFINI_TENSOR_WORKTREE="${SOURCE_ROOT}"
# Optional explicit control plane (default in Phase scripts is IO_ROOT):
# export SVC_ROOT="${IO_ROOT}"

source "${IO_ROOT}/scripts/worktree_env.sh"
require_worktree_repos InfiniCore InfiniLM

cd "${CASE}"
./image/build-image-phase1.sh    # asserts BASE_IMAGE_ID=1a3cbde5ff2a; writes .runtime_base_tag, .worktree_tag, MANIFEST
./image/phase1-smoke.sh          # GPU import + entrypoint bins
./image/build-image-phase2.sh    # writes .image_tag
```

After Phase 1/2, `image/.worktree_tag` should read `v2026.08.12` and `image/MANIFEST` should record `SOURCE_ROOT` as your empty→identical tree.

## Compose + validate

```bash
cd "${CASE}/docker-compose"
cp -n .env.frontend.example .env
# Set IMAGE_TAG=$(cat ../image/.image_tag) in .env; confirm model paths
./compose.sh --profile frontend --profile workers up -d

ROUTER_PORT=8800 EMBEDDING_PORT=20002 ./validate.sh localhost
# Expect registry: master-9g_8b_thinking-server, master-qwen3-32b-paged-server, master-embeddings-server
```

Optional quick regression (not required for cold-start gate):

```bash
cd "${CASE}"
LIMIT=8 ./regression/run_longbench.sh
```

## Failure notes

| Symptom | Likely cause |
|---------|----------------|
| `BASE_IMAGE_ID` check fails | Wrong/missing vendor image; need ID `1a3cbde5ff2a` (or `SKIP_BASE_IMAGE_ID_CHECK=1` only if intentional) |
| `expected ${SOURCE_ROOT}/InfiniCore` | Phase 0 incomplete; `SOURCE_ROOT` not set to the identical ITW tree |
| `git describe` not exact tag | Checked out commit is not the annotated pin; re-checkout `${PIN}` |
| Missing `.so` / xmake errors in Phase 1 | No prebuilt natives and in-container build failed; check proxy / `DEV_CONTAINER` overlay |
| `SVC_ROOT` / InfiniLM-SVC errors | Stale env: this case uses InfiniOrchestrator `rust/` as control plane (`SVC_ROOT=${IO_ROOT}`) |
| Compose workers unhealthy | Model path wrong, GPU map conflict, or inductor cold path without seed (slow first Qwen start) |
| Validate missing service names | Stack not ready; wait and re-run `validate.sh` |

## Verified

| Field | Value |
|-------|--------|
| Date | 2026-08-13 |
| Host arch | aarch64 |
| PIN | `v2026.08.12` |
| `SOURCE_ROOT` | `/tmp/cold-start-itw-verify-20260813` (empty → identical ITW via `cp -a` of pin-verified mirror; GitHub submodule clone timed out) |
| Identity | `ITW_SHA=90000cb…`, `IC_SHA=6ad5e1c9…`, `IL_SHA=4e0fdd7e…` |
| BASE_IMAGE ID | `1a3cbde5ff2a` |
| Phase 1 | `infini-orchestrator-metax:metax-hpcc-ai370-runtime-base-20260813` + `phase1-smoke.sh` **SMOKE_PASS** |
| Phase 2 | `infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813` |
| Compose | frontend + workers on product `IMAGE_TAG` above |
| `validate.sh` | **Passed: 13 / Failed: 0** (chat 9g + Qwen OK; `master-embeddings-server` in `/services`; `/v1/models` + `/v1/embeddings` OK on product `IMAGE_TAG`) |


Logs: `/tmp/cold-start-phase1.log`, `/tmp/cold-start-phase1-smoke.log`, `/tmp/cold-start-phase2.log`, `/tmp/cold-start-validate.log`.
