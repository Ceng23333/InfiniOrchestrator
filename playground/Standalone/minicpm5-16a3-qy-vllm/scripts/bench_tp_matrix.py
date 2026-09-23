#!/usr/bin/env python3
"""OpenAI-chat microbench for MiniCPM5.16a3 TP matrix (host-side client)."""
from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import time
from typing import Any

import aiohttp


def _percentile(xs: list[float], p: float) -> float:
    if not xs:
        return float("nan")
    ys = sorted(xs)
    if len(ys) == 1:
        return ys[0]
    k = (len(ys) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(ys) - 1)
    if f == c:
        return ys[f]
    return ys[f] + (ys[c] - ys[f]) * (k - f)


async def _one(
    session: aiohttp.ClientSession,
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    timeout: float,
) -> dict[str, float]:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    t0 = time.perf_counter()
    ttft = None
    itls: list[float] = []
    last = None
    chunks = 0
    completion_tokens = 0
    prompt_tokens = 0
    async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
        resp.raise_for_status()
        async for raw in resp.content:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            obj = json.loads(data)
            now = time.perf_counter()
            usage = obj.get("usage") or {}
            if usage.get("completion_tokens"):
                completion_tokens = int(usage["completion_tokens"])
            if usage.get("prompt_tokens"):
                prompt_tokens = int(usage["prompt_tokens"])
            choice = (obj.get("choices") or [{}])[0]
            delta = (choice.get("delta") or {}).get("content") or ""
            if not delta:
                continue
            chunks += 1
            if ttft is None:
                ttft = (now - t0) * 1000.0
            elif last is not None:
                itls.append((now - last) * 1000.0)
            last = now
    e2e = (time.perf_counter() - t0) * 1000.0
    if completion_tokens <= 0:
        completion_tokens = max(chunks, 1)
    return {
        "ttft_ms": float(ttft if ttft is not None else e2e),
        "e2e_ms": float(e2e),
        "itl_p50_ms": float(statistics.median(itls)) if itls else float("nan"),
        "completion_tokens": float(completion_tokens),
        "prompt_tokens": float(prompt_tokens),
        "out_tok_s": float(completion_tokens) / (e2e / 1000.0) if e2e > 0 else 0.0,
    }


async def _run_cell(
    base_url: str,
    model: str,
    input_len: int,
    output_len: int,
    concurrency: int,
    n: int,
    warmup: int,
    timeout: float,
) -> dict[str, Any]:
    # Approximate token length with repeated ASCII word (tokenizer-independent for load).
    # ~1 token/word for English pieces.
    word = "hello "
    prompt = (word * max(input_len, 1))[: max(input_len * 6, 8)]
    url = base_url.rstrip("/") + "/v1/chat/completions"
    sem = asyncio.Semaphore(concurrency)
    results: list[dict[str, float]] = []

    async with aiohttp.ClientSession() as session:
        async def guarded(i: int, keep: bool) -> None:
            async with sem:
                m = await _one(session, url, model, prompt, output_len, timeout)
                if keep:
                    results.append(m)

        # warmup
        await asyncio.gather(*[guarded(i, False) for i in range(warmup)])
        t_wall0 = time.perf_counter()
        await asyncio.gather(*[guarded(i, True) for i in range(n)])
        wall_s = time.perf_counter() - t_wall0

    ttfts = [r["ttft_ms"] for r in results]
    itls = [r["itl_p50_ms"] for r in results if r["itl_p50_ms"] == r["itl_p50_ms"]]
    out_toks = sum(r["completion_tokens"] for r in results)
    return {
        "input_len": input_len,
        "output_len": output_len,
        "concurrency": concurrency,
        "n": n,
        "warmup": warmup,
        "wall_s": wall_s,
        "ttft_p50_ms": _percentile(ttfts, 50),
        "ttft_p90_ms": _percentile(ttfts, 90),
        "itl_p50_ms": _percentile(itls, 50) if itls else float("nan"),
        "out_tok_s_total": out_toks / wall_s if wall_s > 0 else 0.0,
        "out_tok_s_per_req_p50": _percentile([r["out_tok_s"] for r in results], 50),
        "prompt_tokens_mean": statistics.mean([r["prompt_tokens"] for r in results])
        if results
        else 0.0,
        "completion_tokens_mean": statistics.mean([r["completion_tokens"] for r in results])
        if results
        else 0.0,
    }


async def main_async(args: argparse.Namespace) -> None:
    cells = []
    for mc in args.mc:
        for inn in args.input_lens:
            print(
                f"[bench] TP={args.tp} MC={mc} IN≈{inn} OUT={args.output_len} N={args.n}",
                flush=True,
            )
            cell = await _run_cell(
                args.base_url,
                args.model,
                inn,
                args.output_len,
                mc,
                args.n,
                args.warmup,
                args.timeout,
            )
            cell["tp"] = args.tp
            cells.append(cell)
            print(json.dumps(cell, indent=2), flush=True)
    out = {
        "tp": args.tp,
        "base_url": args.base_url,
        "model": args.model,
        "max_num_seqs": args.max_num_seqs,
        "max_model_len": args.max_model_len,
        "cells": cells,
    }
    args.out_json.write_text(json.dumps(out, indent=2) + "\n")
    print(f"[bench] wrote {args.out_json}", flush=True)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--base-url", default="http://127.0.0.1:18181")
    p.add_argument("--model", default="minicpm5.16a3.v0314")
    p.add_argument("--tp", type=int, required=True)
    p.add_argument("--max-num-seqs", type=int, default=4)
    p.add_argument("--max-model-len", type=int, default=8192)
    p.add_argument("--input-lens", type=int, nargs="+", default=[512, 2048])
    p.add_argument("--mc", type=int, nargs="+", default=[1, 4])
    p.add_argument("--output-len", type=int, default=128)
    p.add_argument("--n", type=int, default=10)
    p.add_argument("--warmup", type=int, default=1)
    p.add_argument("--timeout", type=float, default=600.0)
    p.add_argument("--out-json", type=str, required=True)
    args = p.parse_args()
    from pathlib import Path

    args.out_json = Path(args.out_json)
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
