# Mooncake traces for the AIPerf adapter

## Files

| File | Role |
|------|------|
| `ci_mooncake_short.jsonl` | Default dual-run / regression profile (~60 requests) |
| `ci_mooncake_smoke.jsonl` | Tiny dry-run / adapter self-check (~10 requests) |

Format: Mooncake JSONL (`timestamp` ms, `input_length`, `output_length`) as consumed by AIPerf `--custom-dataset-type mooncake_trace --fixed-schedule`.

Checked-in CI traces omit `hash_ids` so AIPerf prompt synthesis does not require a consistent `--isl-block-size` block map (hash reuse across different trailing block sizes fails configure).

## Provenance

Shape and field set follow the Mooncake FAST25 arxiv trace:

https://raw.githubusercontent.com/kvcache-ai/Mooncake/refs/heads/main/FAST25-release/arxiv-trace/mooncake_trace.jsonl

Checked-in files are **capped** for Qwen3.8-27B TP4 host runs:

- `input_length` ≤ 2048
- `output_length` ≤ 256 (prod max output is 4096; CI keeps OSL short)
- synthetic 50 ms timestamp spacing when source rows share `timestamp: 0`

They are **not** a full FAST25 dump.

## Regenerate / enlarge

```bash
curl -sL \
  https://raw.githubusercontent.com/kvcache-ai/Mooncake/refs/heads/main/FAST25-release/arxiv-trace/mooncake_trace.jsonl \
  | head -n 200 \
  | python3 -c '
import json,sys
rows=[]
for i,line in enumerate(sys.stdin):
    r=json.loads(line)
    r["input_length"]=min(int(r.get("input_length",0)), 2048)
    r["output_length"]=min(max(int(r.get("output_length",1)),1), 256)
    if isinstance(r.get("hash_ids"), list):
        n=max(1,(r["input_length"]+511)//512)
        r["hash_ids"]=r["hash_ids"][:n]
    rows.append(r)
if rows and all(int(r.get("timestamp",0))==0 for r in rows):
    for i,r in enumerate(rows):
        r["timestamp"]=i*50
for r in rows:
    print(json.dumps(r, separators=(",", ":")))
' > ci_mooncake_short.jsonl
```

Use a longer head (or the full remote file) only for overnight capacity studies; keep CI subsets small.
