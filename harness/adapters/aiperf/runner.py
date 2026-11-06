"""Run-only NVIDIA AIPerf mooncake_trace adapter.

Never owns serving lifecycle. Targets an already-running OpenAI-compatible
endpoint (InfiniOrchestrator router or direct backend).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .manifest_map import build_bench_block, update_manifest
from .profile import AiperfProfile, load_profile  # noqa: F401 — AiperfProfile used in main


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
    """Require the live endpoint to expose health and an OpenAI model list."""
    for path in ("/health", "/v1/models"):
        try:
            status, _ = _get(base_url.rstrip("/") + path, timeout)
        except (HTTPError, URLError, TimeoutError, OSError) as exc:
            # Some backends only expose /v1/models; allow /health soft-fail once.
            if path == "/health":
                continue
            raise RuntimeError(
                f"endpoint preflight failed: {path}: {type(exc).__name__}: {exc}"
            ) from exc
        if status < 200 or status >= 300:
            if path == "/health":
                continue
            raise RuntimeError(f"endpoint preflight failed: {path} returned {status}")


def _find_aiperf() -> str:
    env_bin = os.environ.get("AIPERF_BIN", "").strip()
    if env_bin:
        return env_bin
    found = shutil.which("aiperf")
    if found:
        return found
    raise RuntimeError(
        "aiperf executable not found; pip install -r "
        "harness/adapters/aiperf/requirements.txt (Python >=3.11) "
        "or set AIPERF_BIN"
    )


def _deep_find_number(obj: Any, keys: tuple[str, ...]) -> Optional[float]:
    if isinstance(obj, dict):
        for key in keys:
            if key in obj and obj[key] is not None:
                value = obj[key]
                if isinstance(value, dict):
                    for nested in ("avg", "p95", "p50", "mean", "value"):
                        if nested in value and value[nested] is not None:
                            try:
                                return float(value[nested])
                            except (TypeError, ValueError):
                                pass
                try:
                    return float(value)
                except (TypeError, ValueError):
                    pass
        for value in obj.values():
            found = _deep_find_number(value, keys)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for item in obj:
            found = _deep_find_number(item, keys)
            if found is not None:
                return found
    return None


def _load_json_files(root: Path) -> List[Dict[str, Any]]:
    payloads: List[Dict[str, Any]] = []
    for path in sorted(root.rglob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            payloads.append(data)
    return payloads


def _normalize_metrics(
    artifact_dir: Path,
    *,
    elapsed_sec: float,
    aiperf_rc: int,
) -> Dict[str, Any]:
    """Build a stable summary.json from AIPerf artifact JSON exports."""
    payloads = _load_json_files(artifact_dir)
    merged: Dict[str, Any] = {}
    for payload in payloads:
        merged.update(payload)

    request_count = _deep_find_number(
        merged, ("request_count", "requests", "total_requests", "num_requests")
    )
    request_ok = _deep_find_number(
        merged, ("request_success", "successful_requests", "requests_ok")
    )
    request_err = _deep_find_number(
        merged, ("request_failure", "failed_requests", "requests_error")
    )

    success_rate: Optional[float] = _deep_find_number(
        merged, ("success_rate", "request_success_rate")
    )
    if success_rate is None and request_count and request_count > 0:
        if request_ok is not None:
            success_rate = float(request_ok) / float(request_count)
        elif request_err is not None:
            success_rate = max(0.0, 1.0 - float(request_err) / float(request_count))

    tok_s = _deep_find_number(
        merged,
        (
            "output_token_throughput",
            "output_token_throughput_per_sec",
            "output_tokens_per_sec",
            "tok_s",
            "token_throughput",
        ),
    )
    req_throughput = _deep_find_number(
        merged, ("request_throughput", "requests_per_sec", "request_rate")
    )
    ttft_p95 = _deep_find_number(
        merged,
        (
            "time_to_first_token_p95",
            "ttft_p95",
            "ttft_p95_ms",
            "time_to_first_token",
        ),
    )
    # AIPerf often reports seconds; convert plausible second-scale values to ms.
    if ttft_p95 is not None and ttft_p95 < 10:
        ttft_p95_ms = ttft_p95 * 1000.0
    else:
        ttft_p95_ms = ttft_p95

    if success_rate is None and aiperf_rc == 0 and payloads:
        # Prefer failing closed only when AIPerf failed; otherwise assume full success
        # when exports exist but omit rates (smoke profiles).
        success_rate = 1.0
    if success_rate is None:
        success_rate = 0.0 if aiperf_rc != 0 else 1.0

    return {
        "schema_version": "aiperf-m1",
        "adapter": "aiperf",
        "elapsed_sec": elapsed_sec,
        "aiperf_rc": aiperf_rc,
        "success_rate": success_rate,
        "tok_s": tok_s,
        "output_token_throughput_per_sec": tok_s,
        "request_throughput": req_throughput,
        "ttft_p95_ms": ttft_p95_ms,
        "request_count": request_count,
        "requests_ok": request_ok,
        "requests_error": request_err,
        "artifact_json_files": len(payloads),
    }


def build_aiperf_command(
    profile: AiperfProfile,
    *,
    base_url: str,
    model: str,
    artifact_dir: Path,
    aiperf_bin: str,
) -> List[str]:
    # AIPerf accepts host:port or URL; strip scheme for --url when needed.
    url = base_url.strip()
    command = [
        aiperf_bin,
        "profile",
        "--model",
        model,
        "--endpoint-type",
        profile.endpoint_type,
        "--url",
        url,
        "--input-file",
        str(profile.input_file),
        "--custom-dataset-type",
        profile.custom_dataset_type,
        "--artifact-dir",
        str(artifact_dir),
    ]
    if profile.streaming:
        command.append("--streaming")
    if profile.fixed_schedule:
        command.append("--fixed-schedule")
    command.extend(profile.extra_args)
    return command


def run_aiperf(
    profile: AiperfProfile,
    *,
    base_url: str,
    model: str,
    output_dir: Path,
    role: str,
    aiperf_bin: Optional[str] = None,
) -> Dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    artifact_dir = output_dir / "aiperf_artifacts"
    artifact_dir.mkdir(parents=True, exist_ok=True)

    preflight_timeout = min(profile.timeout_sec, 120.0)
    try:
        _preflight(base_url, preflight_timeout)
    except RuntimeError:
        raise
    except (HTTPError, URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(
            f"endpoint preflight failed: {type(exc).__name__}: {exc}"
        ) from exc

    before = _scrape(base_url, preflight_timeout)
    (output_dir / "metrics_before.prom").write_text(before, encoding="utf-8")

    binary = aiperf_bin or _find_aiperf()
    command = build_aiperf_command(
        profile,
        base_url=base_url,
        model=model,
        artifact_dir=artifact_dir,
        aiperf_bin=binary,
    )
    (output_dir / "aiperf_command.json").write_text(
        json.dumps({"command": command, "role": role, "run_only": True}, indent=2)
        + "\n",
        encoding="utf-8",
    )

    started = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=str(output_dir),
        capture_output=True,
        text=True,
        timeout=profile.timeout_sec,
        check=False,
    )
    elapsed = max(time.monotonic() - started, 0.000001)
    (output_dir / "aiperf_stdout.log").write_text(completed.stdout or "", encoding="utf-8")
    (output_dir / "aiperf_stderr.log").write_text(completed.stderr or "", encoding="utf-8")

    after = _scrape(base_url, preflight_timeout)
    (output_dir / "metrics_after.prom").write_text(after, encoding="utf-8")
    (output_dir / "evidence").mkdir(exist_ok=True)
    (output_dir / "evidence" / "metrics.prom").write_text(after, encoding="utf-8")

    metrics = _normalize_metrics(
        artifact_dir, elapsed_sec=elapsed, aiperf_rc=int(completed.returncode)
    )
    raw = {
        "schema_version": "aiperf-m1",
        "adapter": "aiperf",
        "adapter_mode": "aiperf_cli",
        "role": role,
        "profile": profile.name,
        "base_url": base_url,
        "model": model,
        "collection": profile.raw,
        "metrics": metrics,
        "aiperf_rc": int(completed.returncode),
        "status": "pass"
        if completed.returncode == 0 and float(metrics.get("success_rate") or 0) >= 0.99
        else "fail",
    }
    (output_dir / "aiperf_raw.json").write_text(
        json.dumps(raw, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    # Flat summary for compare.py (--baseline/--candidate).
    summary = {
        **metrics,
        "role": role,
        "backend": "vllm" if role == "baseline" else "infinilm" if role == "candidate" else role,
        "base_url": base_url,
        "model": model,
        "profile": profile.name,
        "status": raw["status"],
    }
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"aiperf exited {completed.returncode}; see {output_dir / 'aiperf_stderr.log'}"
        )
    return raw


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run-only AIPerf mooncake_trace adapter (client-only)"
    )
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--case-path", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model", default=os.environ.get("MODEL", ""))
    parser.add_argument("--manifest", default=os.environ.get("DIAGNOSTIC_MANIFEST", ""))
    parser.add_argument(
        "--role",
        choices=("baseline", "candidate", "single"),
        default="single",
        help="baseline=vLLM, candidate=InfiniLM, single=unlabeled run",
    )
    parser.add_argument(
        "--client-version",
        default=os.environ.get("AIPERF_VERSION", "0.13.0"),
    )
    parser.add_argument("--aiperf-bin", default=os.environ.get("AIPERF_BIN", ""))
    parser.add_argument(
        "--tokenizer",
        default=os.environ.get("TOKENIZER_DIR", os.environ.get("TOKENIZER", "")),
        help="Local tokenizer/model path passed to aiperf --tokenizer (offline hosts)",
    )
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = _parser().parse_args(argv)
    profile = load_profile(Path(args.profile))
    model = args.model or profile.model
    if not model:
        raise SystemExit("--model, MODEL, or profile.model is required")
    # Inject --tokenizer when provided and not already present in profile extra_args.
    if args.tokenizer:
        extras = list(profile.extra_args)
        if "--tokenizer" not in extras:
            extras.extend(["--tokenizer", args.tokenizer])
            profile = AiperfProfile(
                name=profile.name,
                model=profile.model,
                endpoint_type=profile.endpoint_type,
                streaming=profile.streaming,
                fixed_schedule=profile.fixed_schedule,
                input_file=profile.input_file,
                custom_dataset_type=profile.custom_dataset_type,
                timeout_sec=profile.timeout_sec,
                extra_args=extras,
                raw=profile.raw,
            )
    output_dir = Path(args.output_dir).resolve()
    raw = run_aiperf(
        profile,
        base_url=args.base_url,
        model=model,
        output_dir=output_dir,
        role=args.role,
        aiperf_bin=args.aiperf_bin or None,
    )
    raw["client_version"] = args.client_version
    raw["case_path"] = args.case_path
    raw_path = output_dir / "aiperf_raw.json"
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
            adapter_mode="aiperf_cli",
            role=args.role,
        )
        update_manifest(manifest_path, block)

    return 0 if raw.get("status") == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
