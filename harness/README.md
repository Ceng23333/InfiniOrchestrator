# InfiniOrchestrator harness

Bench **runners** only: scenarios, shell libs, and HTTP scrape (`server_client.py`).

The data plane lives in the sibling **`bench-warehouse`** repo as package **`bench_warehouse`** (`warehouse-emit`, `warehouse-compact`, `warehouse-query`, `warehouse-validate-e2e`).

## Setup

```bash
export BENCH_WAREHOUSE_REPO=../../bench-warehouse   # or absolute path
export HARDWARE_PROFILE_REPO=../../hardware-profile
# lib/paths.sh also sets HARNESS_ROOT, IO_ROOT, PYTHONPATH

pip install -e "${BENCH_WAREHOUSE_REPO}"
# optional path install of this tree (server_client + dep on bench-warehouse):
pip install -e .
```

Emit from a scenario step:

```bash
bash lib/emit_bench.sh "${BENCH_ID}" "${SUMMARY_DIR}" "${started}" "${finished}"
# → python -m bench_warehouse.emit …
```

Scrape / preflight:

```bash
python -m server_client …   # module at harness/server_client.py
```
