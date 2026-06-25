#!/usr/bin/env bash
# Two sequential chat requests with a shared >=512-token prefix; assert 2nd TTFT is faster.
#
# Uses streaming to measure time-to-first-token (prefill-dominated), which is the
# right signal for prefix-cache hits on thinking models (decode varies).
#
# Usage:
#   ./bench/test_prefix_cache.sh [ROUTER_URL] [MODEL]
#   ./bench/test_prefix_cache.sh http://localhost:8800 Qwen3-32B

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${CASE_DIR}/.env" ]]; then
  # shellcheck source=/dev/null
  set -a && source "${CASE_DIR}/.env" && set +a
fi

ROUTER_URL="${1:-${ROUTER_URL:-http://localhost:${ROUTER_PORT:-8800}}}"
MODEL="${2:-${MODEL:-Qwen3-32B}}"
CHAT_URL="${ROUTER_URL%/}/v1/chat/completions"
MIN_PREFIX_TOKENS="${MIN_PREFIX_TOKENS:-2048}"
SPEEDUP_MIN="${SPEEDUP_MIN:-1.05}"

echo "=========================================="
echo "Prefix cache smoke"
echo "=========================================="
echo "Router:  ${ROUTER_URL}"
echo "Model:   ${MODEL}"
echo "Min prefix tokens: ${MIN_PREFIX_TOKENS}"
echo ""

python3 - <<'PY' "${CHAT_URL}" "${MODEL}" "${MIN_PREFIX_TOKENS}" "${SPEEDUP_MIN}"
import json
import secrets
import sys
import time
import urllib.request

chat_url, model, min_prefix_s, speedup_min_s = sys.argv[1:5]
min_prefix = int(min_prefix_s)
speedup_min = float(speedup_min_s)
nonce = secrets.token_hex(4)

unit = (
    "The quick brown fox jumps over the lazy dog. "
    "Prefix caching reuses KV blocks for shared prompt segments. "
)
prefix = f"[nonce={nonce}] "
while len(prefix) // 4 < min_prefix:
    prefix += unit

suffix_a = "\n\nQuestion A: What is 2+2? Answer with one number only."
suffix_b = "\n\nQuestion B: What is 3+3? Answer with one number only."

def chat_ttft(user_content: str) -> tuple[float, str]:
    body = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": user_content}],
            "max_tokens": 32,
            "stream": True,
            "temperature": 0.0,
        }
    ).encode()
    req = urllib.request.Request(
        chat_url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.perf_counter()
    ttft = None
    chunks = []
    with urllib.request.urlopen(req, timeout=600) as resp:
        for raw_line in resp:
            line = raw_line.decode(errors="replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            if ttft is None:
                ttft = time.perf_counter() - t0
            try:
                obj = json.loads(payload)
                delta = obj.get("choices", [{}])[0].get("delta", {})
                if "content" in delta and delta["content"]:
                    chunks.append(delta["content"])
            except json.JSONDecodeError:
                pass
    if ttft is None:
        raise SystemExit("FAIL: no streamed tokens received")
    return ttft, "".join(chunks)

print(f"[prefix-cache] prefix_chars={len(prefix)} (~{len(prefix)//4} tokens est.)")
t1, ans1 = chat_ttft(prefix + suffix_a)
print(f"[prefix-cache] request 1 TTFT: {t1:.3f}s answer={ans1[:80]!r}")
t2, ans2 = chat_ttft(prefix + suffix_b)
print(f"[prefix-cache] request 2 TTFT: {t2:.3f}s answer={ans2[:80]!r}")

if not ans1.strip() or not ans2.strip():
    raise SystemExit("FAIL: empty completion")
if t2 >= t1 / speedup_min:
    raise SystemExit(
        f"FAIL: 2nd TTFT not faster (t1={t1:.3f}s t2={t2:.3f}s need t2 < t1/{speedup_min})"
    )
print(f"PASS prefix_cache ttft1={t1:.3f}s ttft2={t2:.3f}s speedup={t1/t2:.2f}x")
PY
