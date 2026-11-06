# minicpm5-2b-qy-inf-perf

InfiniOrchestrator Standalone case for the **llm_performace_benchmark** complete matrix
(MiniCPM5-2B × InfiniLM) on Denglin QY.

| Field | Value |
|-------|-------|
| case_id | `minicpm5-2b-qy-inf-perf` |
| backend | InfiniLM (`be_abbr=inf`) |
| worktree | `v2026.11.06-qy-full-pd` |
| harness container | `minicpm5-2b-inf-perf-harness` |
| Layer A | TP1/2/4 × prompts 512/2048/8192, o=1024, graph-on |
| Layer B | longbench-task on `short_easy_cot` (59), TP1/2/4 |

## Run

```bash
# Full campaign (Layer A then Layer B)
bash scripts/run_complete.sh

# Or layers separately
bash scripts/run_layer_a.sh
bash scripts/run_layer_b.sh

# Resume after TP1 already done
SKIP_TP1=1 bash scripts/run_layer_a.sh
```

Results land in `llm_performace_benchmark/result/`. Campaign findings:
`llm_performace_benchmark/result/*/FINDINGS_v20261103_complete_matrix.md`.

Stop leftover containers: `bash stop.sh`.
