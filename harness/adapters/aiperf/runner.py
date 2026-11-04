"""Replay a bounded AIPerf trace against an already-running endpoint."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import signal
import subprocess
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

from .profile import Profile, load_profile, load_trace


PINNED_AIPERF_VERSION = "0.13.0"


def command(
    profile: Profile,
    *,
    base_url: str,
    model: str,
    artifact_dir: Path,
    input_file: Path,
    binary: str = "aiperf",
    tokenizer: str | None = None,
) -> list[str]:
    url = urlsplit(base_url)
    if url.scheme not in ("http", "https") or not url.netloc or url.username or url.password:
        raise ValueError("--base-url must be an HTTP(S) URL without credentials")
    if not model:
        raise ValueError("--model is required")
    if profile.block_size is not None and not tokenizer:
        raise ValueError("--tokenizer is required for hash-id trace synthesis")
    args = [
        binary, "profile", "--model", model, "--endpoint-type", "chat",
        "--streaming", "--url", base_url.rstrip("/"),
        "--input-file", str(input_file), "--custom-dataset-type", "mooncake_trace",
        "--no-fixed-schedule", "--dataset-sampling-strategy", "sequential",
        "--concurrency", str(profile.concurrency),
        "--request-count", str(profile.requests),
        "--request-timeout-seconds", str(profile.timeout_sec),
        "--random-seed", "42", "--output-artifact-dir", str(artifact_dir),
    ]
    if profile.block_size is not None:
        args.extend(("--isl-block-size", str(profile.block_size)))
    if tokenizer:
        args.extend(("--tokenizer", tokenizer))
    return args


def _metric(export: dict, name: str, field: str = "avg") -> float | None:
    entry = export.get(name)
    if entry is None:
        return None
    if not isinstance(entry, dict):
        raise ValueError(f"{name} must be a metric object")
    value = entry.get(field)
    if value is None:
        return None
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"{name}.{field} must be finite")
    return float(value)


def evaluate(profile: Profile, export: dict) -> tuple[dict, list[str]]:
    if not isinstance(export, dict):
        raise ValueError("AIPerf export must be an object")
    metrics = {
        "requests_ok": _metric(export, "request_count"),
        "requests_error": _metric(export, "error_request_count") or 0.0,
        "latency_p95_ms": _metric(export, "request_latency", "p95"),
        "ttft_p95_ms": _metric(export, "time_to_first_token", "p95"),
        "input_tokens_max": _metric(export, "input_sequence_length", "max"),
    }
    failures = []
    if export.get("aiperf_version") != PINNED_AIPERF_VERSION:
        failures.append(f"expected AIPerf {PINNED_AIPERF_VERSION}, got {export.get('aiperf_version')!r}")
    if export.get("was_cancelled"):
        failures.append("AIPerf run was cancelled")
    if metrics["requests_ok"] is None or metrics["requests_ok"] < profile.requests:
        failures.append(f"fewer than {profile.requests} successful requests")
    if metrics["requests_error"] != 0:
        failures.append(f"{metrics['requests_error']:g} request errors")
    for key, limit in (
        ("latency_p95_ms", profile.max_latency_p95_ms),
        ("ttft_p95_ms", profile.max_ttft_p95_ms),
    ):
        if limit is not None and (metrics[key] is None or metrics[key] > limit):
            failures.append(f"{key} missing or above {limit:g}")
    if profile.min_input_tokens is not None and (
        metrics["input_tokens_max"] is None
        or metrics["input_tokens_max"] < profile.min_input_tokens
    ):
        failures.append(f"input_tokens_max below {profile.min_input_tokens}")
    return metrics, failures


def execute(args: list[str], log_path: Path, timeout: int) -> int:
    with log_path.open("w", encoding="utf-8") as log:
        proc = subprocess.Popen(
            args, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=(os.name == "posix"),
        )
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(proc.pid, signal.SIGTERM)
            else:
                proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.kill()
                proc.wait()
            raise


def run(
    profile: Profile,
    *,
    base_url: str,
    model: str,
    output_dir: Path,
    binary: str = "aiperf",
    tokenizer: str | None = None,
    manifest: Path | None = None,
    executor: Callable[[list[str], Path, int], int] = execute,
) -> dict:
    artifact_dir = output_dir / "aiperf"
    input_file = output_dir / "input.jsonl"
    args = command(
        profile, base_url=base_url, model=model, artifact_dir=artifact_dir,
        input_file=input_file, binary=binary, tokenizer=tokenizer,
    )
    if artifact_dir.exists() and any(artifact_dir.iterdir()):
        raise ValueError(f"AIPerf artifact directory must be empty: {artifact_dir}")
    artifact_dir.mkdir(parents=True, exist_ok=True)
    input_file.write_text(
        "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in load_trace(profile)),
        encoding="utf-8",
    )
    export_path = artifact_dir / "profile_export_aiperf.json"
    summary = {
        "adapter": "aiperf", "profile": profile.name, "status": "fail",
        "base_url": base_url, "model": model,
        "trace_sha256": hashlib.sha256(profile.trace.read_bytes()).hexdigest(),
        "expected_requests": profile.requests,
        "artifacts": [str(input_file), str(export_path), str(output_dir / "aiperf.log")],
        "metrics": {}, "failures": [],
    }
    try:
        timeout = profile.requests * profile.timeout_sec + 60
        rc = executor(args, output_dir / "aiperf.log", timeout)
        if rc != 0:
            summary["failures"].append(f"AIPerf exited with code {rc}")
        if not export_path.is_file():
            summary["failures"].append("AIPerf JSON export is missing")
        else:
            export = json.loads(export_path.read_text(encoding="utf-8"))
            summary["aiperf_version"] = export.get("aiperf_version")
            summary["metrics"], gates = evaluate(profile, export)
            summary["failures"].extend(gates)
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        summary["failures"].append(f"{type(exc).__name__}: {exc}")

    if not summary["failures"]:
        summary["status"] = "pass"
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    if manifest is not None:
        document = json.loads(manifest.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise ValueError("diagnostic manifest must be a JSON object")
        document["bench"] = {
            "adapter": "aiperf", "profile": profile.name,
            "client_version": summary.get("aiperf_version", PINNED_AIPERF_VERSION),
            "adapter_mode": "trace_replay", "status": summary["status"],
            "base_url": base_url,
            "case_path": document.get("case", {}).get("case_path", ""),
            "topology_fingerprint": document.get("topology_fingerprint", ""),
            "collection_config": profile.raw,
            "metrics": summary["metrics"],
            "artifacts": [os.path.relpath(input_file, manifest.parent),
                          os.path.relpath(export_path, manifest.parent),
                          os.path.relpath(output_dir / "summary.json", manifest.parent)],
        }
        manifest.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run-only AIPerf trace adapter")
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--aiperf-bin", default="aiperf")
    parser.add_argument("--tokenizer", help="local tokenizer path for offline runners")
    args = parser.parse_args(argv)
    summary = run(
        load_profile(args.profile), base_url=args.base_url, model=args.model,
        output_dir=args.output_dir, binary=args.aiperf_bin,
        tokenizer=args.tokenizer, manifest=args.manifest,
    )
    print(json.dumps({k: summary[k] for k in ("status", "profile", "metrics", "failures")}, indent=2))
    return 0 if summary["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
