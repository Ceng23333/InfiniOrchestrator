#!/usr/bin/env bash
# Sweep TENSOR_PARALLEL_SIZE=1,2,4 and run a fixed OpenAI microbench grid.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_WRAP="${CASE_DIR}/run-wrap.sh"
STOP_WRAP="${CASE_DIR}/stop-wrap.sh"
BENCH_PY="${SCRIPT_DIR}/bench_tp_matrix.py"

API_PORT="${API_PORT:-18181}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.95}"
# Raise above 1 so MC=4 cells are meaningful across TP.
MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
TPS="${TPS:-1 2 4}"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_ROOT="${OUT_ROOT:-${CASE_DIR}/logs/tp_matrix_${TS}}"
mkdir -p "${OUT_ROOT}"

echo "OUT_ROOT=${OUT_ROOT}"
echo "TPS=${TPS} MAX_NUM_SEQS=${MAX_NUM_SEQS} MAX_MODEL_LEN=${MAX_MODEL_LEN}"

for tp in ${TPS}; do
  echo "=========================================="
  echo "TP=${tp} bring-up $(date -Is)"
  echo "=========================================="
  "${STOP_WRAP}" || true
  TENSOR_PARALLEL_SIZE="${tp}" \
    MAX_MODEL_LEN="${MAX_MODEL_LEN}" \
    GPU_MEM_UTIL="${GPU_MEM_UTIL}" \
    MAX_NUM_SEQS="${MAX_NUM_SEQS}" \
    API_PORT="${API_PORT}" \
    "${RUN_WRAP}" | tee "${OUT_ROOT}/bringup_tp${tp}.log"

  # Confirm ready
  curl -sf --max-time 10 "http://127.0.0.1:${API_PORT}/v1/models" >/dev/null

  echo "=== bench TP=${tp} $(date -Is) ==="
  python3 "${BENCH_PY}" \
    --base-url "http://127.0.0.1:${API_PORT}" \
    --model minicpm5.16a3.v0314 \
    --tp "${tp}" \
    --max-num-seqs "${MAX_NUM_SEQS}" \
    --max-model-len "${MAX_MODEL_LEN}" \
    --input-lens 512 2048 \
    --mc 1 4 \
    --output-len 128 \
    --n 10 \
    --warmup 1 \
    --out-json "${OUT_ROOT}/tp${tp}.json" \
    2>&1 | tee "${OUT_ROOT}/bench_tp${tp}.log"
done

# Merge summary
python3 - <<PY
import json
from pathlib import Path
root = Path("${OUT_ROOT}")
rows = []
for tp in [int(x) for x in "${TPS}".split()]:
    p = root / f"tp{tp}.json"
    if not p.is_file():
        continue
    data = json.loads(p.read_text())
    for c in data["cells"]:
        rows.append({
            "tp": tp,
            "mc": c["concurrency"],
            "input_len": c["input_len"],
            "output_len": c["output_len"],
            "ttft_p50_ms": c["ttft_p50_ms"],
            "itl_p50_ms": c["itl_p50_ms"],
            "out_tok_s_total": c["out_tok_s_total"],
            "wall_s": c["wall_s"],
        })
summary = {"max_num_seqs": int("${MAX_NUM_SEQS}"), "max_model_len": int("${MAX_MODEL_LEN}"), "rows": rows}
(root / "matrix_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
print("WROTE", root / "matrix_summary.json")
PY

echo "DONE OUT_ROOT=${OUT_ROOT}"
