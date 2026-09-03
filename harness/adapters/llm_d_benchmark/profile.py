"""Load and validate the small adapter workload profiles."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict

import yaml


@dataclass(frozen=True)
class BenchmarkProfile:
    name: str
    requests: int
    concurrency: int
    timeout_sec: float
    stream: bool
    max_tokens: int
    prompt: str
    upstream_harness: str
    upstream_workload: str
    raw: Dict[str, Any]


def load_profile(path: Path) -> BenchmarkProfile:
    """Read a profile and reject unsafe or unbounded values."""
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        raise ValueError("profile must be a YAML mapping")

    def positive_int(key: str, default: int, maximum: int) -> int:
        value = int(raw.get(key, default))
        if value < 1 or value > maximum:
            raise ValueError(f"{key} must be between 1 and {maximum}")
        return value

    requests = positive_int("requests", 10, 1000)
    concurrency = positive_int("concurrency", 2, requests)
    timeout_sec = float(raw.get("timeout_sec", 120))
    if timeout_sec <= 0 or timeout_sec > 3600:
        raise ValueError("timeout_sec must be between 0 and 3600")
    max_tokens = positive_int("max_tokens", 32, 40960)
    prompt = str(raw.get("prompt", "Reply with exactly OK."))
    if not prompt:
        raise ValueError("prompt must not be empty")

    upstream = raw.get("upstream", {}) or {}
    if not isinstance(upstream, dict):
        raise ValueError("upstream must be a YAML mapping")
    upstream_harness = str(upstream.get("harness", "vllm-benchmark"))
    upstream_workload = str(upstream.get("workload", "sanity_random.yaml"))
    if not upstream_harness or not upstream_workload:
        raise ValueError("upstream harness and workload are required")

    return BenchmarkProfile(
        name=path.stem,
        requests=requests,
        concurrency=concurrency,
        timeout_sec=timeout_sec,
        stream=bool(raw.get("stream", True)),
        max_tokens=max_tokens,
        prompt=prompt,
        upstream_harness=upstream_harness,
        upstream_workload=upstream_workload,
        raw=raw,
    )
