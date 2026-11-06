# minicpm5-16a3-qy-vllm-perf

InfiniOrchestrator Standalone case for the **llm_performace_benchmark** complete matrix
(MiniCPM5.16a3 × vLLM) on Denglin QY.

| Field | Value |
|-------|-------|
| case_id | `minicpm5-16a3-qy-vllm-perf` |
| backend | vLLM |
| worktree | `v2026.09.21-qy-minicpm5-16a3` |
| harness container | `minicpm5-16a3-perf-harness` |
| Layer A | **reused** `result/20261102_123008_9e595f73` (no TP4) |
| Layer B | longbench-task TP1/2 (fresh) |

```bash
bash scripts/run_complete.sh
bash scripts/run_layer_b.sh
bash stop.sh
```
