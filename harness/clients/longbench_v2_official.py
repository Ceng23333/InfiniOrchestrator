#!/usr/bin/env python3
"""LongBench-v2 client that references official THUDM/LongBench (not a vendored fork).

Imports extract_answer from $LONGBENCH_OFFICIAL_ROOT/pred.py and reads prompts from
that checkout. Adds warehouse glue: length/difficulty/limit filters, concurrency,
latency metrics, and longbench_summary.json for bench-warehouse staging.
"""
from __future__ import annotations

import argparse
import asyncio
import importlib.util
import json
import os
import statistics
import sys
import time
from pathlib import Path
from typing import Any

import aiohttp


def _load_official(root: Path):
    pred_path = root / "pred.py"
    if not pred_path.is_file():
        raise FileNotFoundError(f"official pred.py missing: {pred_path}")
    zero_shot = root / "prompts" / "0shot.txt"
    if not zero_shot.is_file():
        raise FileNotFoundError(f"official prompt missing: {zero_shot}")
    spec = importlib.util.spec_from_file_location("longbench_official_pred", pred_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {pred_path}")
    mod = importlib.util.module_from_spec(spec)
    # pred.py eagerly loads config/model maps + openai at import; stub minimal attrs
    # by reading only extract_answer via exec of the function body is fragile.
    # Instead: exec file with a patched open for config loads, then take extract_answer.
    # Safer: compile and extract function source — simplest path used below.
    src = pred_path.read_text(encoding="utf-8")
    # Isolate extract_answer without running module-level network/config loads.
    ns: dict[str, Any] = {"re": __import__("re")}
    # Pull extract_answer function text
    start = src.find("def extract_answer")
    if start < 0:
        raise RuntimeError("extract_answer not found in official pred.py")
    end = src.find("\ndef ", start + 1)
    if end < 0:
        end = len(src)
    exec(compile(src[start:end], str(pred_path), "exec"), ns)
    extract_answer = ns["extract_answer"]
    prompts = {
        "0shot": (root / "prompts" / "0shot.txt").read_text(encoding="utf-8"),
        "0shot_cot": (root / "prompts" / "0shot_cot.txt").read_text(encoding="utf-8")
        if (root / "prompts" / "0shot_cot.txt").is_file()
        else "",
        "0shot_cot_ans": (root / "prompts" / "0shot_cot_ans.txt").read_text(encoding="utf-8")
        if (root / "prompts" / "0shot_cot_ans.txt").is_file()
        else "",
    }
    return extract_answer, prompts


def _load_dataset(data_json: str | None) -> list[dict[str, Any]]:
    if data_json:
        path = Path(data_json)
        raw = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(raw, dict) and "data" in raw:
            raw = raw["data"]
        return list(raw)
    from datasets import load_dataset

    ds = load_dataset("THUDM/LongBench-v2", split="train")
    return [
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
        for item in ds
    ]


def _filter_items(
    items: list[dict[str, Any]], length: str, difficulty: str, limit: int
) -> tuple[list[dict[str, Any]], int]:
    lengths = {x.strip() for x in length.split(",") if x.strip()} if length != "all" else None
    diffs = (
        {x.strip() for x in difficulty.split(",") if x.strip()}
        if difficulty and difficulty != "all"
        else None
    )
    pool = []
    for it in items:
        if lengths and it.get("length") not in lengths:
            continue
        if diffs and it.get("difficulty") not in diffs:
            continue
        pool.append(it)
    pool_n = len(pool)
    if limit and limit > 0:
        pool = pool[:limit]
    return pool, pool_n


def _middle_truncate(tokenizer, prompt: str, max_input_tokens: int) -> tuple[str, bool]:
    ids = tokenizer.encode(prompt, add_special_tokens=False)
    if len(ids) <= max_input_tokens:
        return prompt, False
    half = max_input_tokens // 2
    truncated = ids[:half] + ids[-half:]
    return tokenizer.decode(truncated, skip_special_tokens=True), True


def _percentile(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    if len(s) == 1:
        return float(s[0])
    k = (len(s) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return float(s[f])
    return float(s[f] + (s[c] - s[f]) * (k - f))


async def _chat_completion(
    session: aiohttp.ClientSession,
    base_url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    timeout_sec: float,
    extra_body: dict[str, Any] | None = None,
) -> tuple[str, dict[str, float]]:
    """Stream chat completion; return text + latency metrics (ms)."""
    url = base_url.rstrip("/") + "/v1/chat/completions"
    payload: dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.1,
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if extra_body:
        # Shallow-merge nested dicts (e.g. chat_template_kwargs) so callers can override keys.
        for key, value in extra_body.items():
            if isinstance(value, dict) and isinstance(payload.get(key), dict):
                merged = dict(payload[key])
                merged.update(value)
                payload[key] = merged
            else:
                payload[key] = value
    t0 = time.perf_counter()
    ttft_ms = None
    itls: list[float] = []
    last_tok_t = None
    chunks: list[str] = []
    completion_tokens = 0

    timeout = aiohttp.ClientTimeout(total=timeout_sec)
    async with session.post(url, json=payload, timeout=timeout) as resp:
        resp.raise_for_status()
        async for raw in resp.content:
            line = raw.decode("utf-8", errors="ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except json.JSONDecodeError:
                continue
            now = time.perf_counter()
            if ttft_ms is None:
                ttft_ms = (now - t0) * 1000.0
            choice0 = (obj.get("choices") or [{}])[0]
            delta = choice0.get("delta") or {}
            piece = delta.get("content") or ""
            if piece:
                if last_tok_t is not None:
                    itls.append((now - last_tok_t) * 1000.0)
                last_tok_t = now
                chunks.append(piece)
            usage = obj.get("usage") or {}
            if usage.get("completion_tokens"):
                completion_tokens = int(usage["completion_tokens"])

    text = "".join(chunks)
    e2e_ms = (time.perf_counter() - t0) * 1000.0
    if completion_tokens <= 0:
        completion_tokens = max(len(chunks), 1)
    tpot_ms = (e2e_ms - (ttft_ms or 0.0)) / max(completion_tokens, 1)
    metrics = {
        "ttft_ms": float(ttft_ms or e2e_ms),
        "e2e_ms": float(e2e_ms),
        "tpot_ms": float(tpot_ms),
        "itl_ms": float(statistics.mean(itls)) if itls else float(tpot_ms),
        "completion_tokens": float(completion_tokens),
    }
    return text, metrics


def _request_extra_body(args: argparse.Namespace) -> dict[str, Any]:
    """Build OpenAI-compatible extra fields for chat/completions.

    MiniCPM5 / Qwen-style chat templates open a free-form <think> block unless
    enable_thinking=false is passed via chat_template_kwargs. With max_tokens=128
    that burns the whole budget and extract_answer returns None (lb_em ~0).
    """
    extra: dict[str, Any] = {}
    if args.extra_body_json:
        parsed = json.loads(args.extra_body_json)
        if not isinstance(parsed, dict):
            raise ValueError("--extra-body-json must be a JSON object")
        extra.update(parsed)
    # Default: disable native thinking for official 0-shot; keep CoT path enabled.
    ct_kwargs = dict(extra.get("chat_template_kwargs") or {})
    if "enable_thinking" not in ct_kwargs:
        ct_kwargs["enable_thinking"] = bool(args.enable_thinking)
    extra["chat_template_kwargs"] = ct_kwargs
    return extra


async def _run_one(
    sem: asyncio.Semaphore,
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    item: dict[str, Any],
    tokenizer,
    extract_answer,
    prompts: dict[str, str],
    extra_body: dict[str, Any],
) -> dict[str, Any]:
    async with sem:
        truncated = False
        if args.enable_thinking:
            template = prompts["0shot_cot"]
            prompt = (
                template.replace("$DOC$", item["context"].strip())
                .replace("$Q$", item["question"].strip())
                .replace("$C_A$", item["choice_A"].strip())
                .replace("$C_B$", item["choice_B"].strip())
                .replace("$C_C$", item["choice_C"].strip())
                .replace("$C_D$", item["choice_D"].strip())
            )
            prompt, truncated = _middle_truncate(tokenizer, prompt, args.max_input_tokens)
            cot_text, m1 = await _chat_completion(
                session,
                args.base_url,
                args.model,
                prompt,
                1024,
                args.timeout_sec,
                extra_body,
            )
            ans_tmpl = prompts["0shot_cot_ans"]
            prompt2 = (
                ans_tmpl.replace("$DOC$", item["context"].strip())
                .replace("$Q$", item["question"].strip())
                .replace("$C_A$", item["choice_A"].strip())
                .replace("$C_B$", item["choice_B"].strip())
                .replace("$C_C$", item["choice_C"].strip())
                .replace("$C_D$", item["choice_D"].strip())
                .replace("$COT$", cot_text.strip())
            )
            prompt2, trunc2 = _middle_truncate(tokenizer, prompt2, args.max_input_tokens)
            truncated = truncated or trunc2
            response, m2 = await _chat_completion(
                session,
                args.base_url,
                args.model,
                prompt2,
                128,
                args.timeout_sec,
                extra_body,
            )
            metrics = {
                "ttft_ms": m1["ttft_ms"],
                "e2e_ms": m1["e2e_ms"] + m2["e2e_ms"],
                "tpot_ms": m2["tpot_ms"],
                "itl_ms": m2["itl_ms"],
                "completion_tokens": m1["completion_tokens"] + m2["completion_tokens"],
            }
        else:
            template = prompts["0shot"]
            prompt = (
                template.replace("$DOC$", item["context"].strip())
                .replace("$Q$", item["question"].strip())
                .replace("$C_A$", item["choice_A"].strip())
                .replace("$C_B$", item["choice_B"].strip())
                .replace("$C_C$", item["choice_C"].strip())
                .replace("$C_D$", item["choice_D"].strip())
            )
            prompt, truncated = _middle_truncate(tokenizer, prompt, args.max_input_tokens)
            response, metrics = await _chat_completion(
                session,
                args.base_url,
                args.model,
                prompt,
                args.max_gen_toks,
                args.timeout_sec,
                extra_body,
            )
        pred = extract_answer(response.strip() if response else "")
        return {
            "_id": item.get("_id"),
            "answer": item.get("answer"),
            "pred": pred,
            "judge": pred == item.get("answer"),
            "truncated": truncated,
            "response": response,
            **metrics,
        }


async def _amain(args: argparse.Namespace) -> int:
    official_root = Path(
        args.official_root
        or os.environ.get("LONGBENCH_OFFICIAL_ROOT")
        or ""
    )
    if not official_root.is_dir():
        print(
            "Error: LONGBENCH_OFFICIAL_ROOT / --official-root must point at THUDM/LongBench checkout",
            file=sys.stderr,
        )
        return 2
    extract_answer, prompts = _load_official(official_root)

    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(args.tokenizer_dir, trust_remote_code=True)

    items = _load_dataset(args.data_json or os.environ.get("LONGBENCH_DATA_JSON"))
    length_n = sum(
        1
        for it in items
        if args.length == "all"
        or it.get("length") in {x.strip() for x in args.length.split(",") if x.strip()}
    )
    pool, pool_n = _filter_items(items, args.length, args.difficulty, args.limit)
    extra_body = _request_extra_body(args)
    print(
        f"[longbench_v2_official] pool={pool_n} selected={len(pool)} "
        f"length={args.length} difficulty={args.difficulty} limit={args.limit} "
        f"chat_template_kwargs={extra_body.get('chat_template_kwargs')}"
    )

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    sem = asyncio.Semaphore(max(1, args.max_concurrency))
    connector = aiohttp.TCPConnector(limit=max(4, args.max_concurrency * 2))
    t_wall0 = time.perf_counter()
    results: list[dict[str, Any]] = []
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [
            _run_one(
                sem, session, args, it, tokenizer, extract_answer, prompts, extra_body
            )
            for it in pool
        ]
        for fut in asyncio.as_completed(tasks):
            try:
                results.append(await fut)
            except Exception as exc:  # noqa: BLE001
                print(f"[longbench_v2_official] request failed: {exc}", file=sys.stderr)
                results.append(
                    {
                        "judge": False,
                        "pred": None,
                        "truncated": False,
                        "ttft_ms": 0.0,
                        "e2e_ms": 0.0,
                        "tpot_ms": 0.0,
                        "itl_ms": 0.0,
                        "completion_tokens": 0.0,
                        "error": str(exc),
                    }
                )

    wall_s = max(time.perf_counter() - t_wall0, 1e-6)
    n = len(results)
    correct = sum(1 for r in results if r.get("judge"))
    truncated_n = sum(1 for r in results if r.get("truncated"))
    ttfts = [float(r["ttft_ms"]) for r in results if r.get("ttft_ms")]
    tpots = [float(r["tpot_ms"]) for r in results if r.get("tpot_ms")]
    itls = [float(r["itl_ms"]) for r in results if r.get("itl_ms")]
    e2es = [float(r["e2e_ms"]) for r in results if r.get("e2e_ms")]
    out_toks = sum(float(r.get("completion_tokens") or 0) for r in results)

    cot_tag = "cot" if args.enable_thinking else "no_cot"
    limit_tag = "all" if not args.limit else str(args.limit)
    workload_scale = (
        f"length={args.length};difficulty={args.difficulty};length_n={length_n};"
        f"pool={pool_n};truncated_n={truncated_n};limit={limit_tag};n={n};"
        f"mc={args.max_concurrency};max_gen={args.max_gen_toks};"
        f"max_input={args.max_input_tokens};{cot_tag};official_0shot"
    )

    summary = {
        "lb_em": (correct / n) if n else 0.0,
        "lb_n": n,
        "lb_limit": n if not args.limit else min(args.limit, pool_n),
        "lb_pool_n": pool_n,
        "lb_truncated_n": truncated_n,
        "lb_length": args.length,
        "lb_difficulty": args.difficulty,
        "workload_scale": workload_scale,
        "ttft_p50_ms": _percentile(ttfts, 50),
        "ttft_p99_ms": _percentile(ttfts, 99),
        "ttft_mean_ms": statistics.mean(ttfts) if ttfts else 0.0,
        "tpot_p50_ms": _percentile(tpots, 50),
        "tpot_mean_ms": statistics.mean(tpots) if tpots else 0.0,
        "itl_p50_ms": _percentile(itls, 50),
        "itl_p99_ms": _percentile(itls, 99),
        "itl_mean_ms": statistics.mean(itls) if itls else 0.0,
        "req_per_s": n / wall_s,
        "output_tok_per_s": out_toks / wall_s,
        "total_tok_per_s": out_toks / wall_s,
        "status": "PASS" if n else "FAIL",
        "e2e_mean_ms": statistics.mean(e2es) if e2es else 0.0,
    }

    (out_dir / "longbench_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    (out_dir / "longbench_preds.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in results) + ("\n" if results else ""),
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2))
    print(f"[longbench_v2_official] wrote {out_dir / 'longbench_summary.json'}")
    return 0 if n else 1


def main() -> int:
    p = argparse.ArgumentParser(description="LongBench-v2 via official THUDM/LongBench")
    p.add_argument("--base-url", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--length", default=os.environ.get("LONGBENCH_LENGTH", "short,medium"))
    p.add_argument("--difficulty", default=os.environ.get("LONGBENCH_DIFFICULTY", "all"))
    p.add_argument("--limit", type=int, default=int(os.environ.get("LIMIT", "0")))
    p.add_argument("--max-concurrency", type=int, default=int(os.environ.get("MAX_CONCURRENCY", "4")))
    p.add_argument("--max-gen-toks", type=int, default=int(os.environ.get("MAX_GEN_TOKS", "128")))
    p.add_argument(
        "--max-input-tokens", type=int, default=int(os.environ.get("MAX_INPUT_TOKENS", "28672"))
    )
    p.add_argument("--tokenizer-dir", required=True)
    p.add_argument("--timeout-sec", type=float, default=float(os.environ.get("TIMEOUT", "600")))
    p.add_argument("--data-json", default=None)
    p.add_argument("--official-root", default=None)
    p.add_argument("--enable-thinking", action="store_true")
    p.add_argument("--extra-body-json", default=None)
    args = p.parse_args()
    if os.environ.get("ENABLE_THINKING") in ("1", "true") and not args.enable_thinking:
        args.enable_thinking = True
    return asyncio.run(_amain(args))


if __name__ == "__main__":
    raise SystemExit(main())
