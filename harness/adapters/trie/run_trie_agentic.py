#!/usr/bin/env python3
"""Run Applied Compute trie and emit a warehouse-compatible staging summary."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--trie-root", type=Path, required=True)
    p.add_argument("--endpoint", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--tokenizer-model", required=True)
    p.add_argument("--output-dir", type=Path, required=True)
    p.add_argument("--concurrency", type=int, default=2)
    p.add_argument("--duration", type=int, default=30)
    p.add_argument("--num-gpus", type=int, default=2)
    p.add_argument("--trace-count", type=int, default=8)
    return p


def write_workload(path: Path, count: int) -> None:
    trace = {
        "num_turns": 2,
        "input_prompt_length": 256,
        "assistant_response_length": [32, 32],
        "tool_call_output_length": [256, 256],
        "tool_call_latency": [0.0, 0.0],
        "final_assistant_response_length": 64,
    }
    path.write_text("".join(json.dumps(trace) + "\n" for _ in range(count)), encoding="utf-8")


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    offset = (len(values) - 1) * p / 100
    lower, upper = int(offset), min(int(offset) + 1, len(values) - 1)
    return values[lower] + (values[upper] - values[lower]) * (offset - lower)


def main() -> int:
    args = build_parser().parse_args()
    if args.concurrency < 1 or args.trace_count < 1 or args.duration < 1:
        raise SystemExit("concurrency, trace-count, and duration must be positive")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    workload = args.output_dir / "agentic_workload.jsonl"
    write_workload(workload, args.trace_count)
    sys.path.insert(0, str(args.trie_root / "src"))
    from trie import Client

    command = {
        "endpoint": f"{args.endpoint.rstrip('/')}/v1",
        "model": args.model,
        "tokenizer_model": args.tokenizer_model,
        "concurrency": args.concurrency,
        "duration": args.duration,
        "stream": True,
        "num_gpus": args.num_gpus,
    }
    started = time.time()
    client = Client(
        endpoint=command["endpoint"],
        model=args.model,
        tokenizer_model=args.tokenizer_model,
        timeout=max(args.duration + 120, 180),
    )
    result = client.sync_run(
        str(workload),
        concurrency=args.concurrency,
        duration=args.duration,
        num_gpus=args.num_gpus,
        stream=True,
    )
    finished = time.time()
    (args.output_dir / "trie.stdout.log").write_text("programmatic Client run\n", encoding="utf-8")
    (args.output_dir / "trie.stderr.log").write_text("", encoding="utf-8")
    (args.output_dir / "trie_command.json").write_text(
        json.dumps({"command": command, "run_only": True}, indent=2) + "\n", encoding="utf-8"
    )
    completed = result.completed_requests
    failed = result.failed_requests
    total = completed + failed
    server_prompt = sum(item.prompt_tokens for item in result.server_metrics)
    server_cached = sum(item.cached_tokens for item in result.server_metrics)
    steady = result.steady_state_rates()
    summary = {
        "adapter": "applied_compute_trie",
        "adapter_mode": "run_only",
        "status": "PASS" if completed > 0 and failed == 0 else "FAIL",
        "requests_total": total,
        "requests_ok": completed or 0,
        "requests_error": failed or 0,
        "success_rate": (completed / total) if total else 0.0,
        "error_rate": (failed / total) if total else 1.0,
        "wall_time_s": result.wall_time or (finished - started),
        "concurrency": args.concurrency,
        "trace_count": args.trace_count,
        "duration_s": args.duration,
        "endpoint": args.endpoint,
        "model": args.model,
        "cache_hit_rate": (server_cached / server_prompt) if server_prompt else None,
        "eligible_cache_hit_rate": (
            sum(item.cached_tokens for item in result.server_metrics)
            / sum(item.eligible_prompt_tokens for item in result.server_metrics)
            if sum(item.eligible_prompt_tokens for item in result.server_metrics) else None
        ),
        "ttft_p50_ms": percentile([x * 1000 for x in result.ttfts], 50),
        "ttfat_p50_ms": percentile([x * 1000 for x in result.ttfats], 50),
        "decode_tpot_p50_ms": percentile(
            [1000 / x for x in result.tps_values if x > 0], 50
        ),
        "cached_prompt_tok_s": steady.cached_tok_s,
        "uncached_prompt_tok_s": steady.new_prompt_tok_s,
        "completion_tok_s": steady.completion_tok_s,
        "endpoint_distribution": {"router": completed},
        "latency_p50_ms": percentile([x * 1000 for x in result.latencies], 50),
        "latency_p95_ms": percentile([x * 1000 for x in result.latencies], 95),
    }
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0 if completed > 0 and failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
