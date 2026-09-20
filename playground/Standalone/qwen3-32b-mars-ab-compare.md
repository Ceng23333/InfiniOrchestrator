# Qwen3-32B Mars A/B — `short_easy_cot` (n=59)

Four-arm comparison: Phytium (metax-9) vs Hygon (tj-io-node00) × vLLM vs InfiniLM.  
Preset: `LONGBENCH_PRESET=short_easy_cot` · TP=4 · GPUs 0–3 · MAX_INPUT=7800 · CoT on.

## Full-pool summary

| Arm | Host / CPU | Backend | EM | TTFT p50 | Out tok/s | E2E mean | Status | Notes |
|-----|------------|---------|----|----------|-----------|----------|--------|-------|
| Phytium vLLM | metax-9 / Phytium | vLLM | 0.475 | 983 ms | 135.8 | 21.0 s | PASS | wrap image `vllm-mars-entrypoint:0.20.0-…9g` |
| Phytium InfiniLM | metax-9 / Phytium | InfiniLM | 0.492 | 1602 ms | 32.9 | 82.3 s | PASS | product image; **AOT cache seeded** (piecewise) |
| Hygon vLLM | tj-io-node00 / Hygon | vLLM | 0.525 | 979 ms | 147.0 | 19.5 s | PASS | daemon, port 18180 |
| Hygon InfiniLM | tj-io-node00 / Hygon | InfiniLM | 0.508 | 1530 ms | 55.2 | 51.0 s | PASS | native ITW **v0812**; **SEGMENT=0** (AOT blocked) |

Rounded from summary JSON (`lb_em`, `ttft_p50_ms`, `output_tok_per_s`, `e2e_mean_ms`).

## Takeaways

- **Accuracy:** all four arms land ~0.47–0.53 EM on the same 59-sample pool; Hygon vLLM highest (0.525), Phytium vLLM lowest (0.475).
- **Latency / throughput:** vLLM dominates both platforms (~136–147 tok/s, ~1 s TTFT p50). InfiniLM is 2.5–4× slower on decode; Hygon InfiniLM (SEGMENT=0) still beats Phytium InfiniLM on out tok/s (55 vs 33) and e2e (51 s vs 82 s).
- **InfiniLM AOT:** Phytium ran with seeded piecewise inductor cache. Hygon was previously **blocked** on piecewise AOT (`std::experimental`); unblocked by rebuilding ITW v2026.08.12 natively and serving with `INFINI_PIECEWISE_INDUCTOR_SEGMENT=0`. Re-enable `SEGMENT=1` only after x86_64 AOT fix/cache.

## Artifact paths

### Phytium (metax-9)

| Arm | Summary / OUT |
|-----|----------------|
| Combined | `/root/zenghua/runs/qwen3-32b-mars-ab/phytium-summary.json` |
| vLLM full | `/root/zenghua/workspace/profiling_20260731/bench-warehouse/bench_results/longbench_v2_Qwen3-32B_20260920_233946` |
| InfiniLM full | `/root/zenghua/workspace/profiling_20260731/bench-warehouse/bench_results/longbench_v2_Qwen3-32B_20260921_011151` |

### Hygon (tj-io-node00)

| Arm | Summary / OUT |
|-----|----------------|
| vLLM full | `/private/zenghua/staging/bench-warehouse/bench_results/longbench_v2_Qwen3-32B_20260920_233331` |
| InfiniLM LIMIT=8 | `/private/zenghua/staging/bench-warehouse/bench_results/longbench_v2_Qwen3-32B_20260921_015938` |
| InfiniLM full | `/private/zenghua/staging/bench-warehouse/bench_results/longbench_v2_Qwen3-32B_20260921_020648` |
| InfiniLM case / ITW | `/private/zenghua/runs/qwen3-32b-tj-inf--hygon/case` · `/private/zenghua/staging/InfiniTensorWorktree-v2026.08.12` |

### Laptop (this repo)

- This file + `qwen3-32b-mars-ab-compare.json`
- Per-arm copies under `playground/Standalone/*/results/`

## Reproduction steps

Shared for all arms: TP=4, GPUs `0–3`, `LONGBENCH_PRESET=short_easy_cot`, `MODEL=Qwen3-32B`, MAX_INPUT≈7800 + CoT. **OK to kill** holders of devices 0–3 before each arm. Run **one backend at a time** on a host (vLLM and InfiniLM share the same GPUs).

Canonical case checkouts used in the A/B:

| Host | Case root |
|------|-----------|
| `metax-9` | `/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Standalone/<case_id>` |
| `tj-io-node00` | `/private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/<case_id>` |

---

### 0. Free GPUs 0–3 (before each arm)

**Phytium (`metax-9`):**

```bash
ssh metax-9
# stop prior A/B wraps if present
docker rm -f qwen-vllm-phytium qwen-inf-phytium 2>/dev/null || true
# optional: stop other known GPU holders, then confirm
mx-smi   # or nvidia-smi-equivalent on Mars; devices 0-3 should be free
```

**Hygon (`tj-io-node00`):**

```bash
ssh tj-io-node00
bash /private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/qwen3-32b-tj-vllm--hygon/scripts/daemon/daemon-stop.sh || true
bash /private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/qwen3-32b-tj-inf--hygon/scripts/daemon/daemon-stop.sh || true
# kill any remaining holders of HPCC devices 0-3 if needed, then confirm free
```

---

### 1. Phytium vLLM — `qwen3-32b-x203-vllm--phytium`

**Prerequisites**

| Item | Value |
|------|--------|
| SSH | `metax-9` |
| Weights | `/root/zenghua/models/Qwen3-32B` |
| Wrap image | `vllm-mars-entrypoint:0.20.0-hpcc.ai3.7.0.102-9g` |
| GPUs / port | `0–3` / API `18180` |
| Container | `qwen-vllm-phytium` |

**Start / stop**

```bash
ssh metax-9
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-vllm--phytium
# rebuild wrap image only if missing:
# ./build-wrap-image.sh
./run-wrap.sh
# stop: ./stop-wrap.sh
```

**Ready check**

```bash
curl -s http://127.0.0.1:18180/v1/models
```

**LongBench**

```bash
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-vllm--phytium
# optional smoke:
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
# full n=59:
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```

**Gotchas**

- Stock wrap image must already exist (or `./build-wrap-image.sh` first).
- Do not leave InfiniLM wrap (`qwen-inf-phytium`) running on the same GPUs.
- Harness may need Docker-bridge `BENCH_CTN_URL=http://172.17.0.1:18180` when the bench client runs in a container (script auto-derives from localhost).

---

### 2. Phytium InfiniLM — `qwen3-32b-x203-inf--phytium`

**Prerequisites**

| Item | Value |
|------|--------|
| SSH | `metax-9` |
| Weights | `/root/zenghua/models/Qwen3-32B` |
| Product image | `infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813` (pin in `image/.image_tag`) |
| GPUs / ports | `0–3` / API `8200`, babysitter `8201` |
| AOT | Piecewise inductor cache under `cache/piecewise_inductor/` (seeded; `SEGMENT=1`, compile-on-miss **off**) |
| Container | `qwen-inf-phytium` |

**Start / stop**

```bash
ssh metax-9
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-inf--phytium
# ensure pin exists:
echo 'infini-orchestrator-metax:4e0fdd7e-6ad5e1c9-20260813' > image/.image_tag
# confirm AOT seed present (expect non-empty cache dir, e.g. Qwen3-32B_*):
ls cache/piecewise_inductor/
./run-wrap.sh
# stop: ./stop-wrap.sh
```

**Ready check**

```bash
curl -s http://127.0.0.1:8200/v1/models
# cold CG / first ready can take 30+ min if cache is empty
```

**LongBench**

```bash
cd /root/zenghua/workspace/profiling_20260731/InfiniOrchestrator/playground/Standalone/qwen3-32b-x203-inf--phytium
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```

**Gotchas**

- Do **not** rebuild Phase 1/2 for this case — use the Distribution product image pin.
- TOML sets `INFINI_PIECEWISE_INDUCTOR_SEGMENT=1` and `INFINI_PIECEWISE_INDUCTOR_COMPILE_ON_MISS=0`; without a seeded cache, serve will miss AOT and fail/hang.
- `run-wrap.sh` waits up to ~60 min for `/v1/models`.

---

### 3. Hygon vLLM — `qwen3-32b-tj-vllm--hygon`

**Prerequisites**

| Item | Value |
|------|--------|
| SSH | `tj-io-node00` |
| Weights | `/private/zenghua/Qwen3-32B` |
| Entrypoint | `/private/zenghua/staging/InfiniOrchestrator/phase2-m1/bin/infini-entrypoint` |
| Runtime | host `/opt/conda` + HPCC `/opt/hpcc` (**no Docker**) |
| GPUs / port | `0–3` / API `18180` |
| `RUN_ROOT` | `/private/zenghua/runs/qwen3-32b-tj-vllm--hygon` |
| `--max-model-len` | `16384` |

**Start / stop**

```bash
ssh tj-io-node00
CASE=/private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/qwen3-32b-tj-vllm--hygon
cd "$CASE"
bash scripts/daemon/daemon-start-worker.sh
bash scripts/daemon/daemon-status.sh
# stop: bash scripts/daemon/daemon-stop.sh
```

**Ready check**

```bash
curl -s http://127.0.0.1:18180/v1/models
```

**LongBench**

```bash
cd /private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/qwen3-32b-tj-vllm--hygon
# ensure PATH can find staging curl / env helpers if used in your shell:
#   export PATH=/private/zenghua/staging/bin:/opt/conda/bin:$PATH
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```

**Gotchas**

- `ENTRYPOINT_BIN` is under `phase2-m1/bin`, not `staging/InfiniOrchestrator/bin`.
- Case-local `runtime-overlay/` is prepended to `PYTHONPATH` by the start script.
- Stop InfiniLM daemon first if it still owns GPUs 0–3 / port 8200.

---

### 4. Hygon InfiniLM — `qwen3-32b-tj-inf--hygon`

**Prerequisites**

| Item | Value |
|------|--------|
| SSH | `tj-io-node00` |
| Weights | `/private/zenghua/Qwen3-32B` |
| Entrypoint | `/private/zenghua/staging/InfiniOrchestrator/phase2-m1/bin/infini-entrypoint` |
| ITW | `/private/zenghua/staging/InfiniTensorWorktree-v2026.08.12` (native **x86_64** rebuild) |
| InfiniLM / InfiniCore | `/private/zenghua/staging/InfiniLM` → ITW InfiniLM; `/private/zenghua/staging/InfiniCore` → same pin |
| GPUs / ports | `0–3` / API `8200`, babysitter `8201` |
| Segment | **`INFINI_PIECEWISE_INDUCTOR_SEGMENT=0`** (piecewise AOT blocked on this host) |
| `RUN_ROOT` | `/private/zenghua/runs/qwen3-32b-tj-inf--hygon` |

**Start / stop**

```bash
ssh tj-io-node00
# confirm native ITW pin + staging links
readlink -f /private/zenghua/staging/InfiniLM
# expect: .../InfiniTensorWorktree-v2026.08.12/InfiniLM
CASE=/private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/qwen3-32b-tj-inf--hygon
cd "$CASE"
bash scripts/daemon/daemon-start-worker.sh
bash scripts/daemon/daemon-status.sh
# stop: bash scripts/daemon/daemon-stop.sh
```

**Ready check**

```bash
curl -s http://127.0.0.1:8200/v1/models
```

**LongBench**

```bash
cd /private/zenghua/staging/InfiniOrchestrator-run/playground/Standalone/qwen3-32b-tj-inf--hygon
LIMIT=8 LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
LONGBENCH_PRESET=short_easy_cot ./regression/run_longbench.sh
```

**Gotchas**

- Must use **host-native** ITW **v2026.08.12** (`_infinicore` / `_infinilm` = `cpython-312-x86_64-linux-gnu`). Phytium aarch64 wheels will not load.
- Config hard-codes `INFINI_PIECEWISE_INDUCTOR_SEGMENT=0` + `INFINI_AOT_CHECK_SKIP=1`. Re-enable `SEGMENT=1` only after an x86_64 piecewise AOT fix/cache.
- Earlier runs with mismatched / empty InfiniLM libs or SEGMENT=1 failed on `std::experimental`; if serve dies, check `RUN_ROOT/logs/worker.log`.
- No Docker on this node — product-image path is not used.

---

### Quick port / backend map

| Arm | Host | Backend | Port | Start |
|-----|------|---------|------|-------|
| Phytium vLLM | metax-9 | Docker wrap | 18180 | `./run-wrap.sh` |
| Phytium InfiniLM | metax-9 | Docker wrap | 8200 | `./run-wrap.sh` |
| Hygon vLLM | tj-io-node00 | Daemon | 18180 | `scripts/daemon/daemon-start-worker.sh` |
| Hygon InfiniLM | tj-io-node00 | Daemon | 8200 | `scripts/daemon/daemon-start-worker.sh` |
