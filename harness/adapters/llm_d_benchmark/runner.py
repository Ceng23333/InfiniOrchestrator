"""Run a bounded HTTP profile or the pinned upstream llmdbenchmark CLI.

The adapter never owns serving lifecycle. The upstream mode may create a
benchmark harness container, but it never invokes standup or teardown for the
target case. The local HTTP mode is useful on hosts where upstream's optional
Kubernetes/planner dependencies are unavailable.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import math
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .manifest_map import build_bench_block, update_manifest
from .profile import BenchmarkProfile, load_profile


def _percentile(values: List[float], percentile: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * percentile / 100.0
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def _get(url: str, timeout: float) -> Tuple[int, bytes]:
    request = Request(url, method="GET")
    with urlopen(request, timeout=timeout) as response:
        return int(response.status), response.read()


def _scrape(url: str, timeout: float) -> str:
    try:
        status, body = _get(url.rstrip("/") + "/metrics", timeout)
        return f"# http_status {status}\n" + body.decode("utf-8", errors="replace")
    except (HTTPError, URLError, TimeoutError, OSError) as exc:
        return f"# metrics_unavailable {type(exc).__name__}: {exc}\n"


def _preflight(base_url: str, timeout: float) -> None:
    """Require the live router to expose health and an OpenAI model list."""
    for path in ("/health", "/v1/models"):
        status, _ = _get(base_url.rstrip("/") + path, timeout)
        if status < 200 or status >= 300:
            raise RuntimeError(f"endpoint preflight failed: {path} returned {status}")


def _request(
    base_url: str, model: str, prompt: str, max_tokens: int, stream: bool, timeout: float
) -> Dict[str, Any]:
    started = time.monotonic()
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": stream,
    }
    request = Request(
        base_url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    first_byte: Optional[float] = None
    chunks = 0
    usage: Dict[str, Any] = {}
    try:
        with urlopen(request, timeout=timeout) as response:
            if stream:
                for raw_line in response:
                    if first_byte is None:
                        first_byte = time.monotonic()
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        continue
                    chunks += 1
                    try:
                        item = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(item.get("usage"), dict):
                        usage = item["usage"]
            else:
                first = response.read(1)
                if first:
                    first_byte = time.monotonic()
                body = first + response.read()
                item = json.loads(body.decode("utf-8"))
                if isinstance(item.get("usage"), dict):
                    usage = item["usage"]
        finished = time.monotonic()
        return {
            "ok": True,
            "status": 200,
            "latency_ms": (finished - started) * 1000,
            "ttft_ms": ((first_byte or finished) - started) * 1000,
            "chunks": chunks,
            "usage": usage,
        }
    except (HTTPError, URLError, TimeoutError, OSError, ValueError) as exc:
        finished = time.monotonic()
        status = int(getattr(exc, "code", 0) or 0)
        return {
            "ok": False,
            "status": status,
            "latency_ms": (finished - started) * 1000,
            "error": f"{type(exc).__name__}: {exc}",
        }


def _metrics(results: List[Dict[str, Any]], elapsed: float) -> Dict[str, Any]:
    successes = [item for item in results if item.get("ok")]
    latencies = [float(item["latency_ms"]) for item in successes]
    ttfts = [float(item["ttft_ms"]) for item in successes if "ttft_ms" in item]
    itls: List[float] = []
    for item in successes:
        chunks = int(item.get("chunks", 0))
        if chunks > 1:
            itls.append((float(item["latency_ms"]) - float(item["ttft_ms"])) / (chunks - 1))
    total = len(results)
    output_tokens = sum(
        int(item.get("usage", {}).get("completion_tokens", 0) or 0)
        for item in successes
    )
    return {
        "request_rate": round(len(successes) / elapsed, 6) if elapsed > 0 else 0,
        "success_rate": len(successes) / total if total else 0,
        "error_rate": (total - len(successes)) / total if total else 0,
        "latency_p50_ms": _percentile(latencies, 50),
        "latency_p95_ms": _percentile(latencies, 95),
        "latency_p99_ms": _percentile(latencies, 99),
        "ttft_p50_ms": _percentile(ttfts, 50),
        "ttft_p95_ms": _percentile(ttfts, 95),
        "ttft_p99_ms": _percentile(ttfts, 99),
        "itl_p50_ms": _percentile(itls, 50),
        "tpot_p50_ms": _percentile(itls, 50),
        "output_tokens": output_tokens,
        "endpoint_distribution": {"router": len(successes)},
        "router_overhead_ms": None,
        "requests_total": total,
        "requests_ok": len(successes),
        "requests_error": total - len(successes),
    }


def run_http(
    profile: BenchmarkProfile, base_url: str, model: str, output_dir: Path
) -> Dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        _preflight(base_url, profile.timeout_sec)
    except (HTTPError, URLError, TimeoutError, OSError, RuntimeError) as exc:
        raise RuntimeError(f"endpoint preflight failed: {type(exc).__name__}: {exc}") from exc
    before = _scrape(base_url, profile.timeout_sec)
    (output_dir / "metrics_before.prom").write_text(before, encoding="utf-8")
    started = time.monotonic()
    results: List[Dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=profile.concurrency) as pool:
        futures = [
            pool.submit(
                _request,
                base_url,
                model,
                profile.prompt,
                profile.max_tokens,
                profile.stream,
                profile.timeout_sec,
            )
            for _ in range(profile.requests)
        ]
        for future in futures:
            results.append(future.result())
    elapsed = max(time.monotonic() - started, 0.000001)
    after = _scrape(base_url, profile.timeout_sec)
    (output_dir / "metrics_after.prom").write_text(after, encoding="utf-8")
    (output_dir / "evidence").mkdir(exist_ok=True)
    (output_dir / "evidence" / "metrics.prom").write_text(after, encoding="utf-8")

    metrics = _metrics(results, elapsed)
    raw = {
        "schema_version": "m1",
        "adapter": "llm_d_benchmark",
        "adapter_mode": "http",
        "profile": profile.name,
        "base_url": base_url,
        "model": model,
        "collection": profile.raw,
        "metrics": metrics,
        "requests": results,
    }
    (output_dir / "llmd_raw.json").write_text(
        json.dumps(raw, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (output_dir / "summary.json").write_text(
        json.dumps(metrics, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return raw


def run_upstream(
    profile: BenchmarkProfile,
    upstream_root: Path,
    base_url: str,
    model: str,
    output_dir: Path,
    timeout: int,
) -> int:
    """Invoke only upstream's run command in endpoint/no-Kubernetes mode."""
    executable = upstream_root / ".venv" / "bin" / "llmdbenchmark"
    if not executable.is_file():
        raise RuntimeError(f"pinned upstream CLI missing: {executable}")
    workload = upstream_root / "workload" / "profiles" / "vllm-benchmark" / profile.upstream_workload
    if not workload.is_file():
        template = Path(str(workload) + ".in")
        if template.is_file():
            workload = template
        else:
            raise RuntimeError(f"upstream workload missing: {workload}")
    output_dir.mkdir(parents=True, exist_ok=True)
    command = [
        str(executable),
        "run",
        "--methods",
        "nok8s",
        "--endpoint-url",
        base_url,
        "--harness",
        profile.upstream_harness,
        "--workload-file-path",
        str(workload),
        "--model",
        model,
        "--output",
        str(output_dir),
        "--wait-timeout",
        str(timeout),
    ]
    (output_dir / "upstream_command.json").write_text(
        json.dumps({"command": command, "run_only": True}, indent=2) + "\n",
        encoding="utf-8",
    )
    return subprocess.call(command, cwd=str(upstream_root))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run-only llm-d benchmark adapter")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--case-path", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model", default=os.environ.get("MODEL", ""))
    parser.add_argument("--manifest", default=os.environ.get("DIAGNOSTIC_MANIFEST", ""))
    parser.add_argument("--upstream-root", type=Path)
    parser.add_argument("--client-version", default=os.environ.get("LLMD_BENCHMARK_VERSION", "v0.8.0"))
    parser.add_argument("--driver", choices=("http", "upstream"), default="http")
    parser.add_argument("--timeout", type=int, default=120)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = _parser().parse_args(argv)
    if not args.model:
        raise SystemExit("--model or MODEL is required")
    profile = load_profile(Path(args.profile))
    output_dir = Path(args.output_dir).resolve()
    if args.driver == "upstream":
        if args.upstream_root is None:
            raise SystemExit("--upstream-root is required for --driver upstream")
        rc = run_upstream(profile, args.upstream_root.resolve(), args.base_url, args.model, output_dir, args.timeout)
        if rc != 0:
            return rc
        raw_path = output_dir / "llmd_raw.json"
        if not raw_path.is_file():
            raise SystemExit(f"upstream run completed without {raw_path}")
        raw = json.loads(raw_path.read_text(encoding="utf-8"))
        adapter_mode = "upstream"
    else:
        raw = run_http(profile, args.base_url, args.model, output_dir)
        adapter_mode = "http"

    if float(raw.get("metrics", {}).get("error_rate", 0) or 0) > 0:
        raw["status"] = "fail"
    else:
        raw["status"] = "pass"

    raw["client_version"] = args.client_version
    raw["case_path"] = args.case_path
    raw_path = output_dir / "llmd_raw.json"
    raw_path.write_text(json.dumps(raw, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.manifest:
        manifest_path = Path(args.manifest).resolve()
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        block = build_bench_block(
            profile=profile.name,
            client_version=args.client_version,
            collection_config=profile.raw,
            base_url=args.base_url,
            case_path=args.case_path,
            topology_fingerprint=str(manifest.get("topology_fingerprint", "")),
            metrics=raw.get("metrics", {}),
            artifacts=[os.path.relpath(raw_path, manifest_path.parent)],
            adapter_mode=adapter_mode,
        )
        update_manifest(manifest_path, block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
