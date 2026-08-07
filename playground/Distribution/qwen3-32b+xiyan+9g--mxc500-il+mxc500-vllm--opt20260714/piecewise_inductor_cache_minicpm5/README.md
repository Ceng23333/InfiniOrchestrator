# Offline MiniCPM5 MoE FusedMoE AOT + Triton cubin bundle (M5)

AOT products and Triton cubins under this directory are **gitignored** (seed
locally / offline pack). Only `README.md` (+ `.gitignore`) are tracked.

See [`docs/M5_moe_fused_artifact_design.md`](../../../../../../docs/M5_moe_fused_artifact_design.md).

Expected layout:

```
piecewise_inductor_cache_minicpm5/
  <model_hash>/
    tp1/rank0/moe_B{16,32,...,4096}/segment.pt2
    inductor_shared/
    moe_configs/          # INFINI_MOE_CONFIGS
    moe_triton_cache/     # INFINI_MOE_TRITON_CACHE / TRITON_CACHE_DIR
    moe_manifest.json
```

Populate:

```bash
./scripts/rebuild_minicpm5_moe_artifacts.sh
```

Serve env (vLLM-free):

```bash
export INFINI_PIECEWISE_INDUCTOR_CACHE=.../piecewise_inductor_cache_minicpm5
export INFINI_PIECEWISE_INDUCTOR_COMPILE_ON_MISS=0
export INFINI_MOE_CONFIGS=$INFINI_PIECEWISE_INDUCTOR_CACHE/<hash>/moe_configs
export INFINI_MOE_TRITON_CACHE=$INFINI_PIECEWISE_INDUCTOR_CACHE/<hash>/moe_triton_cache
export TRITON_CACHE_DIR=$INFINI_MOE_TRITON_CACHE
```
