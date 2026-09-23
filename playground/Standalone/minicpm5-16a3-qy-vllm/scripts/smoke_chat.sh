#!/usr/bin/env bash
# Smoke: /v1/models + one short Chinese chat completion.
set -euo pipefail

API_PORT="${API_PORT:-18181}"
URL="${BENCH_TARGET_URL:-http://127.0.0.1:${API_PORT}}"
MODEL="${MODEL:-minicpm5.16a3.v0314}"

echo "== GET ${URL}/v1/models =="
curl -sf --noproxy "*" "${URL}/v1/models" | head -c 2000
echo ""

echo "== Chinese chat completion =="
curl -sf --noproxy "*" "${URL}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$(cat <<EOF
{
  "model": "${MODEL}",
  "messages": [{"role": "user", "content": "用一句话介绍你自己。"}],
  "max_tokens": 64,
  "temperature": 0.0
}
EOF
)" | tee /tmp/minicpm5-16a3-smoke.json
echo ""

python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path("/tmp/minicpm5-16a3-smoke.json").read_text())
content = data["choices"][0]["message"]["content"]
print("content=", repr(content))
if not content or not content.strip():
    raise SystemExit("empty completion — ByteLevel tokenizer likely broken")
# crude Chinese presence check
if not any("\u4e00" <= ch <= "\u9fff" for ch in content):
    print("warning: no CJK chars in completion; check tokenizer")
else:
    print("smoke ok: got CJK output")
PY
