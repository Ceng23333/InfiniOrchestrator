#!/usr/bin/env bash
# Prefetch LongBench-v2 dataset into this case's cache/data.json.
#
# Usage:
#   ./scripts/prefetch.sh
#   FORCE=1 ./scripts/prefetch.sh          # refresh even if cache/data.json exists
#   LONGBENCH_DATA_SEED=/path/to/data.json ./scripts/prefetch.sh
#
# Resolution order when cache is missing:
#   1. LONGBENCH_DATA_SEED
#   2. ${BENCH_WAREHOUSE_REPO}/third_party/LongBench-data/data.json
#   3. HuggingFace datasets download (THUDM/LongBench-v2) → write cache/data.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARNESS_ROOT="$(cd "${CASE_ROOT}/../../../.." && pwd)"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/lib/paths.sh"

CACHE_DIR="${CASE_ROOT}/cache"
DEST="${CACHE_DIR}/data.json"
FORCE="${FORCE:-0}"

mkdir -p "${CACHE_DIR}"

if [[ -f "${DEST}" && "${FORCE}" != "1" ]]; then
  echo "[longbench_v2 prefetch] already present: ${DEST}"
  ls -lh "${DEST}"
  exit 0
fi

seed="${LONGBENCH_DATA_SEED:-}"
if [[ -z "${seed}" && -n "${BENCH_WAREHOUSE_REPO:-}" ]]; then
  _wh="${BENCH_WAREHOUSE_REPO}/third_party/LongBench-data/data.json"
  if [[ -f "${_wh}" ]]; then
    seed="${_wh}"
  fi
fi

if [[ -n "${seed}" && -f "${seed}" ]]; then
  echo "[longbench_v2 prefetch] seeding from ${seed}"
  if [[ "${FORCE}" == "1" && -e "${DEST}" ]]; then
    rm -f "${DEST}"
  fi
  # Prefer hardlink (same FS); fall back to copy.
  if ! ln "${seed}" "${DEST}" 2>/dev/null; then
    cp -f "${seed}" "${DEST}"
  fi
  ls -lh "${DEST}"
  echo "[longbench_v2 prefetch] OK → ${DEST}"
  exit 0
fi

echo "[longbench_v2 prefetch] downloading THUDM/LongBench-v2 → ${DEST}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-0}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-0}"
export HF_DATASETS_OFFLINE="${HF_DATASETS_OFFLINE:-0}"
python3 - <<PY
import json
from pathlib import Path

dest = Path("${DEST}")
from datasets import load_dataset

ds = load_dataset("THUDM/LongBench-v2", split="train")
rows = []
for item in ds:
    rows.append(
        {
            "_id": item["_id"],
            "domain": item["domain"],
            "sub_domain": item["sub_domain"],
            "difficulty": item["difficulty"],
            "length": item["length"],
            "question": item["question"],
            "choice_A": item["choice_A"],
            "choice_B": item["choice_B"],
            "choice_C": item["choice_C"],
            "choice_D": item["choice_D"],
            "answer": item["answer"],
            "context": item["context"],
        }
    )
dest.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
print(f"[longbench_v2 prefetch] wrote {len(rows)} rows → {dest}")
PY

ls -lh "${DEST}"
echo "[longbench_v2 prefetch] OK → ${DEST}"
