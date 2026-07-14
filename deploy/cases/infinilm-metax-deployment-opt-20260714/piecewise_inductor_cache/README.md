# Offline piecewise inductor AOT seed (Qwen)

AOT products under this directory are **gitignored** (seed locally / offline pack). Only `README.md` (+ `.gitignore`) are tracked.

Mounted read-only at `/workspace/piecewise_inductor_cache` for the Qwen worker.

Expected layout (model hash dir + shared inductor trees):

```
piecewise_inductor_cache/
  Qwen3-32B_<hash>/
    tp4/rank{0..3}/pre_attn_B{4,512,1024,2048,4096}/
    inductor_shared/
```

Populate from the HPCC37 worktree (example):

```bash
SRC=../../../../bench_results/hpcc_migration_20260703_161241/worktree-hpcc37/bench_results/piecewise_inductor_cache
rsync -a --delete "${SRC}/Qwen3-32B_"* ./
```

Qwen TOML: `SEGMENT=1`, `COMPILE_ON_MISS=0`, `CACHE=/workspace/piecewise_inductor_cache`.
