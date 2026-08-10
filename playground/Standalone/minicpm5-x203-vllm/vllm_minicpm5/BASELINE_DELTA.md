# BASELINE_DELTA — Native MiniCPM5MoE (HPCC37 / GPU2)

**Model:** `/models/minicpm5.16a3.v0314` · bf16 · TP=1 · FLASH_ATTN · FusedMoE X203 tune · ByteLevel tokenizer sidecar  
**Bench:** `vllm bench serve --backend openai-chat`, OUT=128, N=20 timed (+1 warmup)

## 1. Transformers vs native (eager)

Both runs used `--enforce-eager` and `--max-model-len 8192`.

| Cell | Metric | Transformers | Native tuned | Δ (native/tf) |
|------|--------|-------------:|-------------:|--------------:|
| MC=1 IN=512 | ttft_p50_ms | 241.85 | 128.57 | **0.53×** |
| MC=1 IN=512 | itl_p50_ms | 212.51 | 106.80 | **0.50×** |
| MC=1 IN=512 | out_tok/s | 4.44 | 8.70 | **1.96×** |
| MC=1 IN=2048 | ttft_p50_ms | 249.80 | 135.97 | **0.54×** |
| MC=1 IN=2048 | itl_p50_ms | 213.61 | 107.42 | **0.50×** |
| MC=1 IN=2048 | out_tok/s | 4.48 | 8.97 | **2.00×** |
| MC=4 IN=512 | ttft_p50_ms | 463.78 | 231.55 | **0.50×** |
| MC=4 IN=512 | itl_p50_ms | 223.89 | 111.54 | **0.50×** |
| MC=4 IN=512 | out_tok/s | 16.85 | 33.95 | **2.02×** |
| MC=4 IN=2048 | ttft_p50_ms | 479.52 | 261.78 | **0.55×** |
| MC=4 IN=2048 | itl_p50_ms | 224.12 | 115.82 | **0.52×** |
| MC=4 IN=2048 | out_tok/s | 16.79 | 33.09 | **1.97×** |

- Native arch: `MiniCPM5MoEForCausalLM` (~2× decode / throughput vs TransformersMoE)
- Transformers CG blocked by HF LongRoPE capture error on HPCC 3.7

## 2. Native eager vs CUDA graph (`FULL_AND_PIECEWISE`)

Same grid as §1; CG serve **without** `--enforce-eager` (`max_model_len=8192`). Capture: PIECEWISE=51 + FULL=35 in ~63 s (0.15 GiB).

| Cell | Metric | Eager | CG | CG/Eager |
|------|--------|------:|---:|---------:|
| MC=1 IN=512 | ttft_p50_ms | 128.57 | 254.28 | **1.98×** |
| MC=1 IN=512 | itl_p50_ms | 106.80 | 14.48 | **0.14×** |
| MC=1 IN=512 | out_tok/s | 8.70 | 58.94 | **6.77×** |
| MC=1 IN=2048 | ttft_p50_ms | 135.97 | 272.22 | **2.00×** |
| MC=1 IN=2048 | itl_p50_ms | 107.42 | 14.59 | **0.14×** |
| MC=1 IN=2048 | out_tok/s | 8.97 | 58.48 | **6.52×** |
| MC=4 IN=512 | ttft_p50_ms | 231.55 | 505.07 | **2.18×** |
| MC=4 IN=512 | itl_p50_ms | 111.54 | 20.55 | **0.18×** |
| MC=4 IN=512 | out_tok/s | 33.95 | 162.54 | **4.79×** |
| MC=4 IN=2048 | ttft_p50_ms | 261.78 | 526.63 | **2.01×** |
| MC=4 IN=2048 | itl_p50_ms | 115.82 | 20.95 | **0.18×** |
| MC=4 IN=2048 | out_tok/s | 33.09 | 156.69 | **4.74×** |

- **Decode wins:** MC=1 ITL ~14.5 ms (~7× vs eager); out tok/s ~59 (~6.5–6.8×)
- **TTFT regresses ~2×:** FULL graphs help decode; prefill uses PIECEWISE / fixed shapes (non-adaptive FA + padding). Known vLLM pattern.
- Native Phi3 RoPE path captures cleanly (Transformers HF LongRoPE does not)
- **Remeasured 2026-07-21** (GPU3, same `FULL_AND_PIECEWISE`): MC=1 IN=512 `median_itl_ms`=**14.31** (−0.17 vs 14.48); G7-matched OUT=16 ITL=**16.02**; MoE microbench `vllm_m1` notracer **0.996** ms/iter. Artifacts: [`profiling/hctracer_fusedmoe/20260721_vllm_cg_remeasure/`](../profiling/hctracer_fusedmoe/20260721_vllm_cg_remeasure/OPT_NOTES.md)

## 3. Long prompt + chunked prefill (`max_model_len=131072`)

`config.max_position_embeddings=131072`. Chunked prefill on (`max_num_batched_tokens=2048`). Same grid under **eager** and **CG**.

| Cell | ~chunks | Metric | Eager | CG | CG/Eager |
|------|--------:|--------|------:|---:|---------:|
| MC=1 IN=4096 | 2 | ttft_p50_ms | 231.6 | 750.5 | **3.24×** |
| MC=1 IN=4096 | 2 | itl_p50_ms | 107.69 | 14.64 | **0.14×** |
| MC=1 IN=4096 | 2 | out_tok/s | 8.75 | 47.51 | **5.43×** |
| MC=1 IN=8192 | 4 | ttft_p50_ms | 236.4 | 762.7 | **3.23×** |
| MC=1 IN=8192 | 4 | itl_p50_ms | 108.17 | 14.79 | **0.14×** |
| MC=1 IN=8192 | 4 | out_tok/s | 8.77 | 47.40 | **5.41×** |
| MC=1 IN=16384 | 8 | ttft_p50_ms | 245.3 | 1244.0 | **5.07×** |
| MC=1 IN=16384 | 8 | itl_p50_ms | 107.84 | 15.05 | **0.14×** |
| MC=1 IN=16384 | 8 | out_tok/s | 8.68 | 40.10 | **4.62×** |
| MC=4 IN=4096 | 2 | ttft_p50_ms | 262.1 | 469.8 | **1.79×** |
| MC=4 IN=4096 | 2 | itl_p50_ms | 109.07 | 20.36 | **0.19×** |
| MC=4 IN=4096 | 2 | out_tok/s | 34.74 | 164.14 | **4.72×** |
| MC=4 IN=8192 | 4 | ttft_p50_ms | 381.1 | 534.7 | **1.40×** |
| MC=4 IN=8192 | 4 | itl_p50_ms | 110.97 | 20.84 | **0.19×** |
| MC=4 IN=8192 | 4 | out_tok/s | 33.96 | 158.86 | **4.68×** |
| MC=4 IN=16384 | 8 | ttft_p50_ms | 450.1 | 596.9 | **1.33×** |
| MC=4 IN=16384 | 8 | itl_p50_ms | 113.03 | 21.51 | **0.19×** |
| MC=4 IN=16384 | 8 | out_tok/s | 32.95 | 150.17 | **4.56×** |

- **Eager TTFT stays flat with length** (~232–245 ms MC=1 across 4k→16k) — adaptive prefill / fewer CG pad+launch taxes
- **CG TTFT much worse and grows with chunks** (751→1244 ms MC=1); MC=4 gap narrows (~1.3–1.8×) as concurrency hides some prefill cost
- **Decode still ~7× faster with CG** (ITL ~15 ms vs ~108 ms); long-gen throughput favors CG despite TTFT

## Artifacts

| Stack | Path |
|-------|------|
| Transformers eager | `bench_results/minicpm5_hpcc37_20260714_144754/phase1_vllm/` |
| Native eager (512/2k) | `bench_results/minicpm5_hpcc37_20260714_165410/phase1_vllm_tuned/` |
| Native CG (512/2k) | `bench_results/minicpm5_hpcc37_20260714_165410/phase1_vllm_cg/` |
| Native CG long / 131k | `bench_results/minicpm5_hpcc37_20260714_165410/phase1_vllm_cg_long/` |
| Native eager long / 131k | `bench_results/minicpm5_hpcc37_20260714_165410/phase1_vllm_eager_long/` |
