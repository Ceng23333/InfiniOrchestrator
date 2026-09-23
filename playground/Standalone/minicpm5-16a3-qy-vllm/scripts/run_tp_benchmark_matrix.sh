#!/usr/bin/env bash
# Restart minicpm5.16a3 vLLM at TP=1,2,4 and collect a latency/throughput matrix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BENCH_PY="${BENCH_PY:-/home/qinyiqun/workspace/minicpm5-2b-support/benchmark_2b.py}"
TOK="${TOK:-${CASE_DIR}/../minicpm5-x203-vllm/vllm_minicpm5/tokenizer_bytelevel}"
MODEL="${MODEL:-minicpm5.16a3.v0314}"
API_PORT="${API_PORT:-18181}"
URL="http://127.0.0.1:${API_PORT}"
RESULTS_ROOT="${RESULTS_ROOT:-${CASE_DIR}/benchmark-results/tp-matrix-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${RESULTS_ROOT}"

INPUT_LENS="${INPUT_LENS:-512 2048}"
OUTPUT_LEN="${OUTPUT_LEN:-128}"
WARMUP="${WARMUP:-2}"
RUNS="${RUNS:-5}"

if [[ ! -f "${BENCH_PY}" ]]; then
  echo "error: missing ${BENCH_PY}" >&2
  exit 1
fi
if [[ ! -f "${TOK}/tokenizer_config.json" ]]; then
  echo "error: missing tokenizer at ${TOK}" >&2
  exit 1
fi

matrix_json="${RESULTS_ROOT}/tp_performance_matrix.json"
echo "[]" > "${matrix_json}"

for TP in 1 2 4; do
  echo "=========================================="
  echo "TP=${TP} — restart server"
  echo "=========================================="
  export TENSOR_PARALLEL_SIZE="${TP}"
  unset DENGLIN_DEVICES
  "${CASE_DIR}/run-wrap.sh" | tee "${RESULTS_ROOT}/run-wrap-tp${TP}.log"

  out="${RESULTS_ROOT}/bench_tp${TP}.json"
  log="${RESULTS_ROOT}/bench_tp${TP}.log"
  echo "TP=${TP} — benchmark → ${out}"
  python3 "${BENCH_PY}" \
    --url "${URL}" \
    --model "${MODEL}" \
    --tokenizer "${TOK}" \
    --backend "vllm-tp${TP}" \
    --output "${out}" \
    --input-lens ${INPUT_LENS} \
    --output-len "${OUTPUT_LEN}" \
    --warmup "${WARMUP}" \
    --runs "${RUNS}" \
    2>&1 | tee "${log}"

  python3 - <<PY
import json
from pathlib import Path
bench = json.loads(Path("${out}").read_text())
summary = bench.get("summary", {})
rows = []
for inp, stats in summary.items():
    rows.append({
        "tp": ${TP},
        "input_tokens": int(inp),
        "ttft_sec_median": stats["ttft_sec"]["median"],
        "decode_toks_per_sec_median": stats["decode_toks_per_sec"]["median"],
        "prefill_toks_per_sec_median": stats["prefill_toks_per_sec"]["median"],
        "total_latency_sec_median": stats["total_latency_sec"]["median"],
    })
matrix = json.loads(Path("${matrix_json}").read_text())
matrix.extend(rows)
Path("${matrix_json}").write_text(json.dumps(matrix, indent=2), encoding="utf-8")
print(json.dumps(rows, indent=2))
PY
done

echo ""
echo "Wrote matrix: ${matrix_json}"
python3 - <<'PY'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
rows = json.loads(p.read_text())
if not rows:
    sys.exit(0)
print("\n| TP | input | TTFT (s) | decode tok/s | prefill tok/s |")
print("|----|-------|----------|--------------|---------------|")
for r in sorted(rows, key=lambda x: (x["tp"], x["input_tokens"])):
    print(
        f"| {r['tp']} | {r['input_tokens']} | "
        f"{r['ttft_sec_median']:.3f} | {r['decode_toks_per_sec_median']:.1f} | "
        f"{r['prefill_toks_per_sec_median']:.0f} |"
    )
PY "${matrix_json}"
