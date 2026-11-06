"""Gate InfiniLM (candidate) against a frozen vLLM (baseline) AIPerf summary."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


DEFAULT_TOK_S_FLOOR = 0.50
DEFAULT_TTFT_P95_MAX_RATIO = 1.25
DEFAULT_SUCCESS_RATE_MIN = 0.99


def _metric(summary: Dict[str, Any], *keys: str) -> Optional[float]:
    for key in keys:
        if key in summary and summary[key] is not None:
            try:
                return float(summary[key])
            except (TypeError, ValueError):
                continue
        metrics = summary.get("metrics")
        if isinstance(metrics, dict) and key in metrics and metrics[key] is not None:
            try:
                return float(metrics[key])
            except (TypeError, ValueError):
                continue
    return None


def compare_summaries(
    baseline: Dict[str, Any],
    candidate: Dict[str, Any],
    *,
    tok_s_floor: float = DEFAULT_TOK_S_FLOOR,
    ttft_p95_max_ratio: float = DEFAULT_TTFT_P95_MAX_RATIO,
    success_rate_min: float = DEFAULT_SUCCESS_RATE_MIN,
) -> Dict[str, Any]:
    """Return compare.json payload. ok=true when gates pass."""
    reasons: List[str] = []

    base_ok = _metric(baseline, "success_rate")
    cand_ok = _metric(candidate, "success_rate")
    if base_ok is None:
        reasons.append("baseline missing success_rate")
    elif base_ok < success_rate_min:
        reasons.append(
            f"baseline success_rate {base_ok:.4f} < min {success_rate_min:.4f}"
        )
    if cand_ok is None:
        reasons.append("candidate missing success_rate")
    elif cand_ok < success_rate_min:
        reasons.append(
            f"candidate success_rate {cand_ok:.4f} < min {success_rate_min:.4f}"
        )

    base_tok = _metric(
        baseline,
        "output_token_throughput_per_sec",
        "tok_s",
        "output_tok_s",
        "request_throughput",
    )
    cand_tok = _metric(
        candidate,
        "output_token_throughput_per_sec",
        "tok_s",
        "output_tok_s",
        "request_throughput",
    )
    tok_ratio: Optional[float] = None
    if base_tok is None or cand_tok is None:
        reasons.append("missing throughput metric on baseline and/or candidate")
    elif base_tok <= 0:
        reasons.append(f"baseline throughput non-positive: {base_tok}")
    else:
        tok_ratio = float(cand_tok) / float(base_tok)
        if tok_ratio < tok_s_floor:
            reasons.append(
                f"PROFILE_REGRESS tok_s ratio {tok_ratio:.3f} < floor {tok_s_floor:.3f} "
                f"(infinilm={cand_tok:.3f} vllm={base_tok:.3f})"
            )

    base_ttft = _metric(baseline, "ttft_p95_ms", "time_to_first_token_p95_ms")
    cand_ttft = _metric(candidate, "ttft_p95_ms", "time_to_first_token_p95_ms")
    ttft_ratio: Optional[float] = None
    if base_ttft is None or cand_ttft is None:
        reasons.append("missing ttft_p95_ms on baseline and/or candidate")
    elif base_ttft <= 0:
        reasons.append(f"baseline ttft_p95_ms non-positive: {base_ttft}")
    else:
        ttft_ratio = float(cand_ttft) / float(base_ttft)
        if ttft_ratio > ttft_p95_max_ratio:
            reasons.append(
                f"PROFILE_REGRESS ttft_p95 ratio {ttft_ratio:.3f} > max "
                f"{ttft_p95_max_ratio:.3f} (infinilm={cand_ttft:.3f}ms vllm={base_ttft:.3f}ms)"
            )

    ok = len(reasons) == 0
    return {
        "ok": ok,
        "status": "PASS" if ok else "PROFILE_REGRESS",
        "baseline_backend": "vllm",
        "candidate_backend": "infinilm",
        "tok_s_floor": tok_s_floor,
        "ttft_p95_max_ratio": ttft_p95_max_ratio,
        "success_rate_min": success_rate_min,
        "tok_s_ratio": tok_ratio,
        "ttft_p95_ratio": ttft_ratio,
        "baseline": {
            "success_rate": base_ok,
            "tok_s": base_tok,
            "ttft_p95_ms": base_ttft,
        },
        "candidate": {
            "success_rate": cand_ok,
            "tok_s": cand_tok,
            "ttft_p95_ms": cand_ttft,
        },
        "reasons": reasons,
    }


def _load(path: Path) -> Dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"summary must be a JSON object: {path}")
    return data


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compare InfiniLM AIPerf summary against frozen vLLM baseline"
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        required=True,
        help="baseline/vllm/summary.json (vLLM)",
    )
    parser.add_argument(
        "--candidate",
        type=Path,
        required=True,
        help="candidate/infinilm/summary.json (InfiniLM)",
    )
    parser.add_argument("-o", "--output", type=Path, help="Write compare.json")
    parser.add_argument("--tok-s-floor", type=float, default=DEFAULT_TOK_S_FLOOR)
    parser.add_argument(
        "--ttft-p95-max-ratio", type=float, default=DEFAULT_TTFT_P95_MAX_RATIO
    )
    parser.add_argument(
        "--success-rate-min", type=float, default=DEFAULT_SUCCESS_RATE_MIN
    )
    args = parser.parse_args(argv)

    result = compare_summaries(
        _load(args.baseline.resolve()),
        _load(args.candidate.resolve()),
        tok_s_floor=args.tok_s_floor,
        ttft_p95_max_ratio=args.ttft_p95_max_ratio,
        success_rate_min=args.success_rate_min,
    )
    payload = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    sys.stdout.write(payload)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
