# jg_rag Router Benchmark Metrics (2026-03-31)

Router: `http://192.168.163.151:8000`  
Dataset (160p): `bench/jg_rag_benchmark.jsonl`  
Dataset (320p): `bench/jg_rag_benchmark_320.jsonl`  
Backend: `openai-chat` (`/v1/chat/completions`)

## 160 prompts (default inputs)

### Model: `9g_8b_thinking` (label: `jg_rag-router-9g-20260331-default`)

Source JSON: `jg_rag-router-9g-20260331-default-1.0qps-concurrency4-9g_8b_thinking-20260331-102142.json`

| Metric | Value |
| --- | --- |
| **Completed** | 159 |
| **Failed** | 1 |
| **Success Rate** | 99.38% |
| **Duration (s)** | 1717.35 |
| **Request rate (req/s)** | 1.0 |
| **Max concurrency** | 4 |
| **Mean TTFT (ms)** | 1158.66 |
| **Median TTFT (ms)** | 860.721 |
| **P99 TTFT (ms)** | 3547.86 |
| **Mean TPOT (ms)** | 38.9193 |
| **Median TPOT (ms)** | 29.2254 |
| **P99 TPOT (ms)** | 126.418 |
| **Output throughput (tok/s)** | 98.9537 |
| **Total token throughput (tok/s)** | 941.086 |

### Model: `Qwen3-32B` (label: `jg_rag-router-qwen3-20260331-default`)

Source JSON: `jg_rag-router-qwen3-20260331-default-1.0qps-concurrency4-Qwen3-32B-20260331-104246.json`

| Metric | Value |
| --- | --- |
| **Completed** | 158 |
| **Failed** | 2 |
| **Success Rate** | 98.75% |
| **Duration (s)** | 1237.78 |
| **Request rate (req/s)** | 1.0 |
| **Max concurrency** | 4 |
| **Mean TTFT (ms)** | 1668.91 |
| **Median TTFT (ms)** | 1302.44 |
| **P99 TTFT (ms)** | 5317.22 |
| **Mean TPOT (ms)** | 61.6213 |
| **Median TPOT (ms)** | 49.5646 |
| **P99 TPOT (ms)** | 121.557 |
| **Output throughput (tok/s)** | 59.9041 |
| **Total token throughput (tok/s)** | 1214.02 |

## 320 prompts (rerun plan)

Dataset: `bench/jg_rag_benchmark_320.jsonl` (320 prompts)  
Request rate: 1.0 req/s

### Model: `9g_8b_thinking` (concurrency 16)

Label: `jg_rag-router-9g-20260331-320p-c16`  
Source JSON: `jg_rag-router-9g-20260331-320p-c16-1.0qps-concurrency16-9g_8b_thinking-20260331-113112.json`

| Metric | Value |
| --- | --- |
| **Completed** | 317 |
| **Failed** | 3 |
| **Success Rate** | 99.06% |
| **Duration (s)** | 2625.30 |
| **Max concurrency** | 16 |
| **Mean TTFT (ms)** | 1672.73 |
| **Median TTFT (ms)** | 1041.83 |
| **P99 TTFT (ms)** | 5362.72 |
| **Mean TPOT (ms)** | 117.601 |
| **Median TPOT (ms)** | 109.379 |
| **P99 TPOT (ms)** | 294.802 |
| **Output throughput (tok/s)** | 134.322 |
| **Total token throughput (tok/s)** | 1243.97 |

### Model: `9g_8b_thinking` (concurrency 32)

Label: `jg_rag-router-9g-20260331-320p-c32`  
Source JSON: `jg_rag-router-9g-20260331-320p-c32-1.0qps-concurrency32-9g_8b_thinking-20260331-121301.json`

| Metric | Value |
| --- | --- |
| **Completed** | 317 |
| **Failed** | 3 |
| **Success Rate** | 99.06% |
| **Duration (s)** | 2100.67 |
| **Max concurrency** | 32 |
| **Mean TTFT (ms)** | 1716.91 |
| **Median TTFT (ms)** | 1259.31 |
| **P99 TTFT (ms)** | 6887.21 |
| **Mean TPOT (ms)** | 188.773 |
| **Median TPOT (ms)** | 170.846 |
| **P99 TPOT (ms)** | 346.222 |
| **Output throughput (tok/s)** | 167.520 |
| **Total token throughput (tok/s)** | 1551.89 |

### Model: `9g_8b_thinking` (concurrency 48)

Label: `jg_rag-router-9g-20260331-320p-c48`  
Source JSON: `jg_rag-router-9g-20260331-320p-c48-1.0qps-concurrency48-9g_8b_thinking-20260331-125947.json`

| Metric | Value |
| --- | --- |
| **Completed** | 318 |
| **Failed** | 2 |
| **Success Rate** | 99.38% |
| **Duration (s)** | 1587.39 |
| **Max concurrency** | 48 |
| **Mean TTFT (ms)** | 4928 |
| **Median TTFT (ms)** | 1470.42 |
| **P99 TTFT (ms)** | 68763.67 |
| **Mean TPOT (ms)** | 221.91 |
| **Median TPOT (ms)** | 218.33 |
| **P99 TPOT (ms)** | 367.08 |
| **Output throughput (tok/s)** | 221.33 |
| **Total token throughput (tok/s)** | 2053.46 |

### Model: `Qwen3-32B` (concurrency 16)

Label: `jg_rag-router-qwen3-20260401-320p-c16-rerun-clean`  
Source JSON: `jg_rag-router-qwen3-20260401-320p-c16-rerun-clean-1.0qps-concurrency16-Qwen3-32B-20260401-111419.json`  

Supersedes the 2026-03-31 c16 JSON (`...153714.json`), whose mean / P99 TTFT were consistent with **misrouting to a dead slave** while the router still listed `slave-fla-qwen-paged-server`.

| Metric | Value |
| --- | --- |
| **Completed** | 320 |
| **Failed** | 0 |
| **Success Rate** | 100.00% |
| **Duration (s)** | 3013.71 |
| **Max concurrency** | 16 |
| **Mean TTFT (ms)** | 2508.09 |
| **Median TTFT (ms)** | 1948.09 |
| **P99 TTFT (ms)** | 10380.42 |
| **Mean TPOT (ms)** | 310.61 |
| **Median TPOT (ms)** | 325.40 |
| **P99 TPOT (ms)** | 393.29 |
| **Output throughput (tok/s)** | 50.45 |
| **Total token throughput (tok/s)** | 998.81 |

### Model: `Qwen3-32B` (concurrency 32)

Label: `jg_rag-router-qwen3-20260401-320p-c32-rerun`  
Source JSON: `jg_rag-router-qwen3-20260401-320p-c32-rerun-1.0qps-concurrency32-Qwen3-32B-20260401-101911.json`  
(Registry clean; single Qwen3 backend — 320/320 completed.)

| Metric | Value |
| --- | --- |
| **Completed** | 320 |
| **Failed** | 0 |
| **Success Rate** | 100.00% |
| **Duration (s)** | 2158.00 |
| **Max concurrency** | 32 |
| **Mean TTFT (ms)** | 4252.88 |
| **Median TTFT (ms)** | 2459.91 |
| **P99 TTFT (ms)** | 40124.57 |
| **Mean TPOT (ms)** | 443.26 |
| **Median TPOT (ms)** | 482.39 |
| **P99 TPOT (ms)** | 565.78 |
| **Output throughput (tok/s)** | 70.22 |
| **Total token throughput (tok/s)** | 1394.64 |

### Model: `Qwen3-32B` (concurrency 48)

Label: `jg_rag-router-qwen3-20260401-320p-c48-rerun`  
Source JSON: `jg_rag-router-qwen3-20260401-320p-c48-rerun-1.0qps-concurrency48-Qwen3-32B-20260401-114812.json`  
(320/320 completed; P99 TTFT tail is high under c48 — see JSON for raw stats.)

| Metric | Value |
| --- | --- |
| **Completed** | 320 |
| **Failed** | 0 |
| **Success Rate** | 100.00% |
| **Duration (s)** | 1991.56 |
| **Max concurrency** | 48 |
| **Mean TTFT (ms)** | 6589.59 |
| **Median TTFT (ms)** | 3163.02 |
| **P99 TTFT (ms)** | 82087.35 |
| **Mean TPOT (ms)** | 610.65 |
| **Median TPOT (ms)** | 666.12 |
| **P99 TPOT (ms)** | 754.29 |
| **Output throughput (tok/s)** | 75.80 |
| **Total token throughput (tok/s)** | 1510.90 |

## Qwen3-32B — two backends (master + slave)

Router load-balanced across **two** registered `openai-api` workers (slave restarted; 2026-04-01). Dataset and rate same as above (`320` prompts, `1.0` req/s).

### Concurrency 48 (2 workers)

Label: `jg_rag-router-qwen3-20260401-320p-c48-2workers`  
Source JSON: `jg_rag-router-qwen3-20260401-320p-c48-2workers-1.0qps-concurrency48-Qwen3-32B-20260401-125913.json`

| Metric | Value |
| --- | --- |
| **Completed** | 320 |
| **Failed** | 0 |
| **Success Rate** | 100.00% |
| **Duration (s)** | 1223.60 |
| **Max concurrency** | 48 |
| **Mean TTFT (ms)** | 5355.57 |
| **Median TTFT (ms)** | 2239.42 |
| **P99 TTFT (ms)** | 50880.04 |
| **Mean TPOT (ms)** | 366.49 |
| **Median TPOT (ms)** | 382.71 |
| **P99 TPOT (ms)** | 518.54 |
| **Output throughput (tok/s)** | 123.90 |
| **Total token throughput (tok/s)** | 2459.71 |

### Concurrency 32 (2 workers)

Label: `jg_rag-router-qwen3-20260401-320p-c32-2workers`  
Source JSON: `jg_rag-router-qwen3-20260401-320p-c32-2workers-1.0qps-concurrency32-Qwen3-32B-20260401-132024.json`  
(One client request failed; check bench log for error.)

| Metric | Value |
| --- | --- |
| **Completed** | 319 |
| **Failed** | 1 |
| **Success Rate** | 99.69% |
| **Duration (s)** | 1248.24 |
| **Max concurrency** | 32 |
| **Mean TTFT (ms)** | 2273.59 |
| **Median TTFT (ms)** | 1828.82 |
| **P99 TTFT (ms)** | 7665.38 |
| **Mean TPOT (ms)** | 250.51 |
| **Median TPOT (ms)** | 204.39 |
| **P99 TPOT (ms)** | 515.05 |
| **Output throughput (tok/s)** | 121.29 |
| **Total token throughput (tok/s)** | 2403.04 |

### Concurrency 16 (2 workers)

Label: `jg_rag-router-qwen3-20260401-320p-c16-2workers`  
Source JSON: `jg_rag-router-qwen3-20260401-320p-c16-2workers-1.0qps-concurrency16-Qwen3-32B-20260401-134923.json`

| Metric | Value |
| --- | --- |
| **Completed** | 320 |
| **Failed** | 0 |
| **Success Rate** | 100.00% |
| **Duration (s)** | 1714.74 |
| **Max concurrency** | 16 |
| **Mean TTFT (ms)** | 1843.23 |
| **Median TTFT (ms)** | 1348.86 |
| **P99 TTFT (ms)** | 5642.43 |
| **Mean TPOT (ms)** | 173.94 |
| **Median TPOT (ms)** | 88.01 |
| **P99 TPOT (ms)** | 378.66 |
| **Output throughput (tok/s)** | 87.91 |
| **Total token throughput (tok/s)** | 1754.69 |

---

**Sweep status (320p, 1.0 req/s):**

| Model | c16 | c32 | c48 |
| --- | --- | --- | --- |
| `9g_8b_thinking` | done | done | done |
| `Qwen3-32B` (1 worker) | done (2026-04-01 clean c16) | done (2026-04-01) | done (2026-04-01) |
| `Qwen3-32B` (2 workers) | done | done (1 fail) | done |

