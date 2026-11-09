# minicpm5-16a3-qy-inf-perf

InfiniOrchestrator Standalone case for the **llm_performace_benchmark** complete matrix
(MiniCPM5.16a3 × InfiniLM) on Denglin QY.

| Field | Value |
|-------|-------|
| case_id | `minicpm5-16a3-qy-inf-perf` |
| backend | InfiniLM (`be_abbr=inf`) |
| worktree | `v2026.11.09-qy-moe-bf16-warpnk` |
| harness container | `minicpm5-16a3-inf-perf-harness` |
| Layer A | TP1/2 × prompts 512/2048, o=1024 (p4096 skipped: QY RoPE) |
| Layer B | longbench-task on `short_easy_cot` (59), TP1/2 |

## Run

```bash
bash scripts/run_complete.sh
# or
bash scripts/run_layer_a.sh
bash scripts/run_layer_b.sh
```

Results: `llm_performace_benchmark/result/`. Stop: `bash stop.sh`.
