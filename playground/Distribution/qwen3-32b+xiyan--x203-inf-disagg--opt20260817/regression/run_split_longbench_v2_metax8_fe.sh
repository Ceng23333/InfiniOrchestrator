#!/usr/bin/env bash
set -euo pipefail

IO_ROOT=/root/zenghua/workspace/profiling_20260731/InfiniOrchestrator
CASE_DIR="${IO_ROOT}/playground/Distribution/qwen3-32b+xiyan--x203-inf-disagg--opt20260817"
RUN_ID="split_metax8_fe_$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ROOT="${CASE_DIR}/regression/${RUN_ID}"
mkdir -p "${RUN_ROOT}"

export BENCH_TARGET_URL=http://172.31.1.8:8800
export ROUTER_URL="${BENCH_TARGET_URL}"
export BENCH_CTN_URL="${BENCH_TARGET_URL}"
export BENCH_METRICS_URL="${BENCH_TARGET_URL}"
export INFERENCE_SERVER_BASE_URL="${BENCH_TARGET_URL}"
export INFERENCE_METADATA_URL=http://localhost:8201
export MODEL=Qwen3-32B
export BENCH_BACKEND=infinilm
export TOKENIZER_DIR=/root/zenghua/models/Qwen3-32B
export LONGBENCH_DATA_JSON="${IO_ROOT}/harness/scenarios/benchmark/cases/longbench_v2/cache/data.json"
export LONGBENCH_OFFICIAL_ROOT="${IO_ROOT}/harness/scenarios/benchmark/cases/longbench_v2/third_party/LongBench"
export DEV_CONTAINER_NAME=infinilm-dev-hpcc37
export MAX_CONCURRENCY="${MAX_CONCURRENCY:-4}"
export MAX_GEN_TOKS="${MAX_GEN_TOKS:-128}"
export TIMEOUT="${TIMEOUT:-7200}"
export LIMIT="${LIMIT:-0}"
export HOST_ID=metax-9
export PLATFORM=hpcc
export BENCH_INGEST_LABEL=metax-9
export CASE_ID=qwen3-32b+xiyan--x203-inf-disagg--opt20260817
export CASE_PATH="${CASE_DIR}/case.toml"

sanity() {
  local out_dir="$1"
  python3 - "$out_dir" <<'PY'
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
summary_path = out / "longbench_summary.json"
pred_path = out / "longbench_preds.jsonl"
print(f"OUT_DIR={out}")
if summary_path.exists():
    summary = json.loads(summary_path.read_text())
    keys = ["status", "lb_em", "lb_score", "lb_accuracy", "lb_limit", "lb_length", "lb_difficulty", "lb_truncated"]
    for key in keys:
        if key in summary:
            print(f"{key}={summary[key]}")
else:
    print("missing longbench_summary.json")

n = none = errors = empty = 0
if pred_path.exists():
    for line in pred_path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        n += 1
        try:
            row = json.loads(line)
        except Exception:
            errors += 1
            continue
        pred = row.get("pred")
        if pred is None:
            none += 1
        elif isinstance(pred, str) and not pred.strip():
            empty += 1
        if row.get("error") or row.get("request_error"):
            errors += 1
    print(f"pred_rows={n}")
    print(f"pred_none={none}")
    print(f"pred_empty={empty}")
    print(f"request_errors={errors}")
else:
    print("missing longbench_preds.jsonl")
PY
}

run_stage() {
  local name="$1"
  local length="$2"
  local thinking="$3"
  export LONGBENCH_LENGTH="$length"
  export LONGBENCH_DIFFICULTY=all
  export ENABLE_THINKING="$thinking"
  export OUT_DIR="${RUN_ROOT}/${name}"
  mkdir -p "${OUT_DIR}"

  {
    echo "===== ${name} start $(date -Is) ====="
    echo "BENCH_TARGET_URL=${BENCH_TARGET_URL}"
    echo "LONGBENCH_LENGTH=${LONGBENCH_LENGTH}"
    echo "ENABLE_THINKING=${ENABLE_THINKING}"
    "${CASE_DIR}/regression/run_longbench.sh"
    echo "===== ${name} sanity $(date -Is) ====="
    sanity "${OUT_DIR}"
    echo "===== ${name} done $(date -Is) ====="
  } 2>&1 | tee "${RUN_ROOT}/${name}.log"
}

echo "${RUN_ROOT}" | tee "${CASE_DIR}/regression/latest_split_metax8_fe_run.txt"
run_stage short_medium short,medium 0
run_stage all all 0
run_stage all_cot all 1

echo "all stages complete $(date -Is)" | tee -a "${RUN_ROOT}/DONE"
