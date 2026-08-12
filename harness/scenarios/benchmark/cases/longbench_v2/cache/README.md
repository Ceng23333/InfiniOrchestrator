# LongBench-v2 case cache (gitignored except this README + .gitignore).

## data.json

Put the LongBench-v2 dataset JSON here as `cache/data.json`.

Harness defaults `LONGBENCH_DATA_JSON` to this path when the file exists
(`config/default.env`). Override with env if needed.

Prefetch (preferred):

```bash
./scripts/prefetch.sh
# FORCE=1 ./scripts/prefetch.sh   # refresh
```

Resolution order when missing: `LONGBENCH_DATA_SEED` →
`bench-warehouse/third_party/LongBench-data/data.json` → HuggingFace download.

Official THUDM/LongBench checkout (pred.py / prompts) stays at
`bench-warehouse/third_party/LongBench` via `LONGBENCH_OFFICIAL_ROOT`.
