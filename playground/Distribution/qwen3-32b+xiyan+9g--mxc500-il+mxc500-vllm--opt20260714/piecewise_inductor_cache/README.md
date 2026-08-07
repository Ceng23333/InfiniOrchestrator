# Offline piecewise inductor AOT cache (Qwen)

AOT products under this directory are **gitignored** (seed locally / offline pack). Only `README.md` (+ `.gitignore`) are tracked.

Mounted **read-write** at `/workspace/piecewise_inductor_cache` for the Qwen worker so
`python -m infinilm.server.entry --phase all` can cold-compile missing packages on first boot.
Warm restarts skip compile when every planned `segment.pt2` already exists.

Expected layout (model hash dir + shared inductor trees):

```
piecewise_inductor_cache/
  Qwen3-32B_<hash>/
    tp4/rank{0..3}/pre_attn_B{8192}/
    inductor_shared/
```

Populate from the HPCC37 worktree (example), or let cold kickoff compile:

```bash
SRC=../../../../bench_results/hpcc_migration_20260703_161241/worktree-hpcc37/bench_results/piecewise_inductor_cache
rsync -a --delete "${SRC}/Qwen3-32B_"* ./
```

Qwen TOML: `entry --phase all`, `SEGMENT=1`, `COMPILE_ON_MISS=0` (deprecated/ignored),
`CACHE=/workspace/piecewise_inductor_cache`, `NATIVE_CG_CAPTURE_BUCKETS=8192`.
