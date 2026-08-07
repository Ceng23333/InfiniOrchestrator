"""Parse harness staging directories into flat metric dicts."""

from __future__ import annotations

import csv
import json
import re
from pathlib import Path
from typing import Any

_EM_RE = re.compile(r"exact_match[=,\s]+([\d.]+)")
_LIMIT_RE = re.compile(r"limit[=:\s]+(\d+)")
_MIN_LATENCY_MS = 0.001


def _str_val(v: Any) -> str:
    if v is None or v == "":
        return ""
    return str(v)


def sanitize_latency_ms(val: Any) -> str:
    """Return latency string in ms, or empty if invalid/non-positive."""
    if val is None or val == "":
        return ""
    try:
        num = float(val)
    except (TypeError, ValueError):
        return ""
    if num <= _MIN_LATENCY_MS:
        return ""
    return str(num)


def _resolve_tpot_p50(raw_tpot: Any, raw_itl: Any) -> str:
    tpot = sanitize_latency_ms(raw_tpot)
    if tpot:
        return tpot
    return sanitize_latency_ms(raw_itl)


def _resolve_tpot_mean(raw_tpot: Any, raw_itl: Any) -> str:
    tpot = sanitize_latency_ms(raw_tpot)
    if tpot:
        return tpot
    return sanitize_latency_ms(raw_itl)


def _throughput_metrics_from_row(row: dict[str, Any]) -> dict[str, str]:
    median_ttft = row.get("median_ttft_ms")
    mean_ttft = row.get("mean_ttft_ms")
    median_itl = row.get("median_itl_ms")
    mean_itl = row.get("mean_itl_ms")
    median_tpot = row.get("median_tpot_ms")
    mean_tpot = row.get("mean_tpot_ms")
    return {
        "ttft_p50_ms": sanitize_latency_ms(median_ttft or mean_ttft),
        "ttft_p99_ms": sanitize_latency_ms(
            row.get("p99_ttft_ms") or row.get("p99.0_ttft_ms")
        ),
        "ttft_mean_ms": sanitize_latency_ms(mean_ttft),
        "tpot_p50_ms": _resolve_tpot_p50(median_tpot or mean_tpot, median_itl or mean_itl),
        "tpot_mean_ms": _resolve_tpot_mean(mean_tpot, mean_itl),
        "itl_p50_ms": sanitize_latency_ms(median_itl or mean_itl),
        "itl_p99_ms": sanitize_latency_ms(
            row.get("p99_itl_ms") or row.get("p99.0_itl_ms")
        ),
        "itl_mean_ms": sanitize_latency_ms(mean_itl),
        "req_per_s": _str_val(row.get("request_throughput")),
        "output_tok_per_s": _str_val(row.get("output_throughput")),
        "total_tok_per_s": _str_val(row.get("total_token_throughput")),
    }


def find_throughput_csv(staging_dir: Path) -> Path | None:
    matches = sorted(staging_dir.glob("*throughput.csv"))
    if matches:
        return matches[-1]
    for sub in staging_dir.iterdir():
        if sub.is_dir():
            nested = sorted(sub.glob("*throughput.csv"))
            if nested:
                return nested[-1]
    return None


def parse_throughput_csv(path: Path) -> dict[str, str]:
    """Parse vllm_harness_sweep throughput CSV (last data row)."""
    if not path.is_file():
        return {}
    with path.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        rows = list(reader)
    if not rows:
        return {}
    row = rows[-1]
    return _throughput_metrics_from_row(row)


def parse_throughput_staging(staging_dir: Path) -> dict[str, str]:
    csv_path = find_throughput_csv(staging_dir)
    if csv_path is None:
        return {}
    metrics = parse_throughput_csv(csv_path)
    if metrics.get("req_per_s") or metrics.get("ttft_p50_ms"):
        metrics["status"] = "PASS"
    return metrics


def parse_throughput_json(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return _throughput_metrics_from_row(
        {
            "median_ttft_ms": data.get("ttft_p50_ms", data.get("median_ttft_ms")),
            "mean_ttft_ms": data.get("ttft_mean_ms", data.get("mean_ttft_ms")),
            "p99_ttft_ms": data.get("ttft_p99_ms", data.get("p99_ttft_ms")),
            "median_tpot_ms": data.get("tpot_p50_ms", data.get("median_tpot_ms")),
            "mean_tpot_ms": data.get("tpot_mean_ms", data.get("mean_tpot_ms")),
            "median_itl_ms": data.get("itl_p50_ms", data.get("median_itl_ms")),
            "mean_itl_ms": data.get("itl_mean_ms", data.get("mean_itl_ms")),
            "p99_itl_ms": data.get("itl_p99_ms", data.get("p99_itl_ms")),
            "request_throughput": data.get("request_throughput", data.get("req_per_s")),
            "output_throughput": data.get("output_tok_per_s", data.get("output_throughput", data.get("tok_per_s"))),
            "total_token_throughput": data.get("total_tok_per_s", data.get("total_token_throughput")),
        }
    )


def _extract_em_from_text(text: str) -> tuple[str, str]:
    em_match = _EM_RE.search(text)
    limit_match = _LIMIT_RE.search(text)
    em = em_match.group(1) if em_match else ""
    limit = limit_match.group(1) if limit_match else "1"
    return em, limit


def parse_ceval_log(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    em, limit = _extract_em_from_text(path.read_text(encoding="utf-8"))
    return {"ceval_em": em, "ceval_limit": limit}


def _ceval_from_json(staging_dir: Path) -> dict[str, str]:
    root = staging_dir / "lm_eval_results"
    if not root.is_dir():
        return {}
    files = sorted(root.rglob("results_*.json"))
    if not files:
        return {}
    data = json.loads(files[-1].read_text(encoding="utf-8"))
    em = None
    for k, v in data.get("results", {}).items():
        if "ceval" in k and isinstance(v, dict):
            for sk, sv in v.items():
                if "exact_match" in sk:
                    em = sv
                    break
    if em is None:
        return {}
    return {"ceval_em": _str_val(em), "ceval_limit": "1"}


def parse_ceval_staging(staging_dir: Path) -> dict[str, str]:
    for name in ("progress.txt", "ceval.log"):
        p = staging_dir / name
        if p.is_file():
            em, limit = _extract_em_from_text(p.read_text(encoding="utf-8"))
            if em:
                return {"ceval_em": em, "ceval_limit": limit, "status": "PASS"}
    for log in sorted(staging_dir.glob("*.log")):
        metrics = parse_ceval_log(log)
        if metrics.get("ceval_em"):
            metrics["status"] = "PASS"
            return metrics
    metrics = _ceval_from_json(staging_dir)
    if metrics.get("ceval_em"):
        metrics["status"] = "PASS"
    return metrics


def parse_longbench_staging(staging_dir: Path) -> dict[str, str]:
    """Parse LongBench-v2 dual-metric summary into warehouse columns."""
    path = staging_dir / "longbench_summary.json"
    if not path.is_file():
        # Fallback: throughput CSV only (no EM).
        metrics = parse_throughput_staging(staging_dir)
        return metrics
    data = json.loads(path.read_text(encoding="utf-8"))
    out: dict[str, str] = {
        "lb_em": _str_val(data.get("lb_em")),
        "lb_n": _str_val(data.get("lb_n")),
        "lb_limit": _str_val(data.get("lb_limit")),
        "lb_pool_n": _str_val(data.get("lb_pool_n")),
        "lb_truncated_n": _str_val(data.get("lb_truncated_n")),
        "lb_length": _str_val(data.get("lb_length")),
        "lb_difficulty": _str_val(data.get("lb_difficulty")),
        "workload_scale": _str_val(data.get("workload_scale")),
        "ttft_p50_ms": sanitize_latency_ms(data.get("ttft_p50_ms")),
        "ttft_p99_ms": sanitize_latency_ms(data.get("ttft_p99_ms")),
        "ttft_mean_ms": sanitize_latency_ms(data.get("ttft_mean_ms")),
        "tpot_p50_ms": sanitize_latency_ms(data.get("tpot_p50_ms")),
        "tpot_mean_ms": sanitize_latency_ms(data.get("tpot_mean_ms")),
        "itl_p50_ms": sanitize_latency_ms(data.get("itl_p50_ms")),
        "itl_p99_ms": sanitize_latency_ms(data.get("itl_p99_ms")),
        "itl_mean_ms": sanitize_latency_ms(data.get("itl_mean_ms")),
        "req_per_s": _str_val(data.get("req_per_s")),
        "output_tok_per_s": _str_val(data.get("output_tok_per_s")),
        "total_tok_per_s": _str_val(data.get("total_tok_per_s")),
    }
    status = data.get("status")
    if status:
        out["status"] = str(status)
    elif out.get("lb_em") or out.get("req_per_s"):
        out["status"] = "PASS"
    return {k: v for k, v in out.items() if v != ""}
