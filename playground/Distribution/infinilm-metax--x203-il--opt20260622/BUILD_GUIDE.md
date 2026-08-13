# Build Guide — infinilm-metax-deployment-opt-20260622

Commit-based image build on HPCC ai3.1.0.7 / torch2.6.

## Prerequisites

- Docker with access to `cr.metax-tech.com/public-ai-release-wb/hpcc/vllm:hpcc.ai3.1.0.7-torch2.6-py310-kylin2309a-arm64`
- Monorepo worktree with siblings: `InfiniCore/`, `InfiniLM/`, `InfiniLM-SVC/`, `InfiniOrchestrator/`
- ~80 GB free disk for image layers + build artifacts
- Network for first-time base pull and Rust/cargo deps (if not cached in base)

## Build steps

```bash
CASE=/opt/offline/infinilm-metax-20260622/InfiniOrchestrator/playground/Distribution/infinilm-metax--x203-il--opt20260622
cd "${CASE}"

# Verify source SHAs
git -C ../../../InfiniCore rev-parse --short HEAD
git -C ../../../InfiniLM rev-parse --short HEAD

# Build deliverable image (Dockerfile → container setup → docker commit)
./build-image.sh
# Writes .image_tag and MANIFEST

# Optional: GPU smoke inside committed image
IMAGE_TAG="$(cat .image_tag)"
docker run --rm --privileged --ipc=host --network=host \
  --device /dev/dri --device /dev/htcd \
  --entrypoint /bin/bash "${IMAGE_TAG}" -lc '
  source /app/env-set.sh
  python /workspace/InfiniLM/examples/jiuge.py --device metax --model /models/Qwen3-32B \
    --tp 4 --max-new-tokens 64 --attn flash-attn --enable-graph --enable-paged-attn \
    --prompt "hello"
'

# Export offline bundle
./export-bundle.sh
```

## What build-image.sh does

1. `docker build` thin scaffold (`Dockerfile` + `env-set.sh`)
2. `docker create` + `docker cp` InfiniLM-SVC, InfiniCore, InfiniLM
3. `docker exec setup-in-container.sh` — install Rust binaries, xmake InfiniCore/InfiniLM
4. `docker commit` → `infinilm-svc:metax-hpcc-ai3107-<IL>-<IC>-<DATE>`

## Offline codebase update

When InfiniCore/InfiniLM change but the base image stays the same:

```bash
./update-codebase.sh \
  --source-image "$(cat .image_tag)" \
  --infinicore-src /path/to/InfiniCore \
  --infinilm-src /path/to/InfiniLM
```

## torch2.6 / flash-attn notes

- `env-set.sh` auto-detects `FLASH_ATTN_2_CUDA_SO` under `/opt/conda/lib/python3.10/site-packages/`
- If jiuge smoke fails with flash-attn errors, verify the `.so` exists in the base image and matches torch 2.6 ABI
- InfiniCore xmake uses `--flash-attn=.` and `--graph=y` for PRD-03 native piecewise CG

## Network / proxy (port 57890)

Build scripts use [`proxy-env.sh`](proxy-env.sh). Proxy is applied **only when**:

1. Direct GitHub is unreachable, **and**
2. `http://127.0.0.1:57890` is listening (build containers use `--network host`)

Force proxy: `USE_PROXY=1 ./build-image.sh`

If xmake cannot download packages (GitHub timeout), prebuilt `_infinicore` / `_infinilm` `.so` files in the source tree are staged automatically. Ensure worktree includes compiled artifacts under `InfiniCore/python/infinicore/lib/` and `InfiniLM/python/infinilm/lib/`, or overlay `/root/.infini` from dev container `infinilm-dev-20260622`.

Force full xmake rebuild (when network available): `FORCE_XMAKE_BUILD=true ./build-image.sh`

## Troubleshooting build failures

- **Container kept on failure:** `docker exec -it infinilm-build-ai3107-* bash`
- **hcComplex.h missing:** ensure `env-set.sh` HPCC include paths are sourced before xmake
- **install.sh Rust errors:** check network/proxy for `cargo fetch`; re-run inside container manually
