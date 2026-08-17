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

## Official LongBench code (pred.py / prompts)

Checkout lives in this case as a git submodule:

`harness/scenarios/benchmark/cases/longbench_v2/third_party/LongBench`
(THUDM/LongBench, branch `main`). Default `LONGBENCH_OFFICIAL_ROOT` → that path.

Dataset (`LongBench-data`) remains under bench-warehouse; only the code submodule
moved into InfiniOrchestrator.
