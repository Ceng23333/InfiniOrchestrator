"""vLLM baseline then InfiniLM candidate dual-run recipe (local harness)."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional

from .compare import compare_summaries
from .profile import load_profile
from .runner import run_aiperf


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run AIPerf mooncake_trace against vLLM first (baseline), then InfiniLM "
            "(candidate), and gate candidate vs frozen baseline"
        )
    )
    parser.add_argument("--base-url-vllm", required=True)
    parser.add_argument("--base-url-infinilm", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument(
        "--case-path-vllm",
        default="",
        help="CASE_PATH / case.toml for the vLLM playground case",
    )
    parser.add_argument(
        "--case-path-infinilm",
        default="",
        help="CASE_PATH / case.toml for the InfiniLM playground case",
    )
    parser.add_argument("--suite-dir", default="")
    parser.add_argument("--model", default=os.environ.get("MODEL", "Qwen3.8-27B"))
    parser.add_argument("--aiperf-bin", default=os.environ.get("AIPERF_BIN", ""))
    parser.add_argument("--tok-s-floor", type=float, default=0.50)
    parser.add_argument("--ttft-p95-max-ratio", type=float, default=1.25)
    parser.add_argument("--success-rate-min", type=float, default=0.99)
    args = parser.parse_args(argv)

    profile = load_profile(Path(args.profile))
    model = args.model or profile.model
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    suite_dir = Path(
        args.suite_dir
        or os.environ.get(
            "SUITE_DIR",
            f"bench_results/aiperf_dual_{model}_{ts}",
        )
    ).resolve()
    baseline_dir = suite_dir / "baseline" / "vllm"
    candidate_dir = suite_dir / "candidate" / "infinilm"
    suite_dir.mkdir(parents=True, exist_ok=True)

    case_vllm = args.case_path_vllm or os.environ.get("CASE_PATH_VLLM", "vllm")
    case_il = args.case_path_infinilm or os.environ.get(
        "CASE_PATH_INFINILM", "infinilm"
    )

    print(f"[aiperf-dual] suite_dir={suite_dir}", file=sys.stderr)
    print("[aiperf-dual] step 1/3: vLLM baseline", file=sys.stderr)
    try:
        baseline_raw = run_aiperf(
            profile,
            base_url=args.base_url_vllm,
            model=model,
            output_dir=baseline_dir,
            role="baseline",
            aiperf_bin=args.aiperf_bin or None,
        )
    except Exception as exc:  # noqa: BLE001 - surface operator errors cleanly
        print(f"[aiperf-dual] baseline failed: {exc}", file=sys.stderr)
        return 2

    baseline_summary = json.loads(
        (baseline_dir / "summary.json").read_text(encoding="utf-8")
    )
    if float(baseline_summary.get("success_rate") or 0) < args.success_rate_min:
        print(
            "[aiperf-dual] abort: vLLM baseline success_rate below threshold; "
            "not starting InfiniLM",
            file=sys.stderr,
        )
        return 2
    if baseline_raw.get("status") != "pass":
        print(
            "[aiperf-dual] abort: vLLM baseline status!=pass; not starting InfiniLM",
            file=sys.stderr,
        )
        return 2

    # Stash case identity for operators / future warehouse emit.
    (baseline_dir / "case_path.txt").write_text(case_vllm + "\n", encoding="utf-8")

    print("[aiperf-dual] step 2/3: InfiniLM candidate", file=sys.stderr)
    try:
        run_aiperf(
            profile,
            base_url=args.base_url_infinilm,
            model=model,
            output_dir=candidate_dir,
            role="candidate",
            aiperf_bin=args.aiperf_bin or None,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[aiperf-dual] candidate failed: {exc}", file=sys.stderr)
        return 3
    (candidate_dir / "case_path.txt").write_text(case_il + "\n", encoding="utf-8")

    print("[aiperf-dual] step 3/3: compare candidate vs baseline", file=sys.stderr)
    candidate_summary = json.loads(
        (candidate_dir / "summary.json").read_text(encoding="utf-8")
    )
    result = compare_summaries(
        baseline_summary,
        candidate_summary,
        tok_s_floor=args.tok_s_floor,
        ttft_p95_max_ratio=args.ttft_p95_max_ratio,
        success_rate_min=args.success_rate_min,
    )
    compare_path = suite_dir / "compare.json"
    compare_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if not result["ok"]:
        print(
            f"[aiperf-dual] FAIL: {'; '.join(result.get('reasons') or [])}",
            file=sys.stderr,
        )
        return 1
    print("[aiperf-dual] PASS", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
