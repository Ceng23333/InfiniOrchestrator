# minicpm5-2b-qy-vllm-perf

InfiniOrchestrator Standalone case for the **llm_performace_benchmark** complete matrix
(MiniCPM5-2B × vLLM) on Denglin QY.

| Field | Value |
|-------|-------|
| case_id | `minicpm5-2b-qy-vllm-perf` |
| backend | vLLM |
| worktree | `v2026.09.15-qy-minicpm5` (image pin) |
| harness container | `minicpm5-2b-perf-harness` |
| Layer A | **reused** `result/20261102_105946_87156c97` |
| Layer B | longbench-task TP1/2/4 (fresh) |

```bash
bash scripts/run_complete.sh   # verify Layer A baseline + run Layer B
bash scripts/run_layer_b.sh
bash stop.sh
```
