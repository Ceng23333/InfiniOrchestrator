"""Bounded workload profiles for an existing OpenAI-compatible endpoint."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Profile:
    name: str
    trace: Path
    requests: int
    concurrency: int
    timeout_sec: int
    block_size: int | None
    min_input_tokens: int | None
    max_latency_p95_ms: float | None
    max_ttft_p95_ms: float | None
    raw: dict


def _int(raw: dict, key: str, minimum: int, maximum: int) -> int:
    value = raw.get(key)
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{key} must be an integer between {minimum} and {maximum}")
    return value


def _optional_limit(raw: dict, key: str) -> float | None:
    value = raw.get(key)
    if value is None:
        return None
    if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"{key} must be a positive finite number")
    return float(value)


def load_profile(path: Path) -> Profile:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError("profile must be a JSON object")
    name = raw.get("name")
    if not isinstance(name, str) or not name:
        raise ValueError("profile name is required")
    trace_name = raw.get("trace")
    if not isinstance(trace_name, str) or not trace_name:
        raise ValueError("trace path is required")
    trace = (path.parent / trace_name).resolve()
    requests = _int(raw, "requests", 1, 32)
    concurrency = _int(raw, "concurrency", 1, requests)
    timeout_sec = _int(raw, "timeout_sec", 1, 600)
    block_size = raw.get("block_size")
    if block_size is not None:
        block_size = _int(raw, "block_size", 1, 8192)
    gates = raw.get("gates", {})
    if not isinstance(gates, dict):
        raise ValueError("gates must be an object")
    min_input_tokens = gates.get("min_input_tokens")
    if min_input_tokens is not None:
        if type(min_input_tokens) is not int or min_input_tokens < 1:
            raise ValueError("min_input_tokens must be a positive integer")
    profile = Profile(
        name=name,
        trace=trace,
        requests=requests,
        concurrency=concurrency,
        timeout_sec=timeout_sec,
        block_size=block_size,
        min_input_tokens=min_input_tokens,
        max_latency_p95_ms=_optional_limit(gates, "max_latency_p95_ms"),
        max_ttft_p95_ms=_optional_limit(gates, "max_ttft_p95_ms"),
        raw=raw,
    )
    load_trace(profile)
    return profile


def load_trace(profile: Profile) -> list[dict]:
    if not profile.trace.is_file():
        raise ValueError(f"trace does not exist: {profile.trace}")
    rows = json.loads(profile.trace.read_text(encoding="utf-8"))
    if not isinstance(rows, list):
        raise ValueError("trace fixture must be a JSON array")
    if len(rows) != profile.requests:
        raise ValueError(f"trace has {len(rows)} rows; expected {profile.requests}")
    for index, row in enumerate(rows, 1):
        if not isinstance(row, dict):
            raise ValueError(f"trace row {index} must be an object")
        if (type(row.get("timestamp")) not in (int, float)
                or not math.isfinite(row["timestamp"]) or row["timestamp"] < 0):
            raise ValueError(f"trace row {index} needs a nonnegative timestamp")
        if type(row.get("output_length")) is not int or not 1 <= row["output_length"] <= 4096:
            raise ValueError(f"trace row {index} needs output_length in 1..4096")
        messages = row.get("messages")
        length = row.get("input_length")
        if length is not None and (type(length) is not int or not 1 <= length <= 65536):
            raise ValueError(f"trace row {index}: input_length must be in 1..65536")
        if (isinstance(messages, list) and bool(messages)) == (type(length) is int and length > 0):
            raise ValueError(f"trace row {index} needs either messages or input_length")
        if "tools" in row and not isinstance(messages, list):
            raise ValueError(f"trace row {index}: tools require messages")
        if isinstance(messages, list) and any(
            not isinstance(message, dict) or not isinstance(message.get("role"), str)
            for message in messages
        ):
            raise ValueError(f"trace row {index}: each message needs a role")
        if "tools" in row and (not isinstance(row["tools"], list) or not row["tools"]):
            raise ValueError(f"trace row {index}: tools must be a nonempty list")
        if "hash_ids" in row and length is None:
            raise ValueError(f"trace row {index}: hash_ids require input_length")
        if "hash_ids" in row and not isinstance(row["hash_ids"], list):
            raise ValueError(f"trace row {index}: hash_ids must be a list")
        if "hash_ids" in row and any(type(item) is not int for item in row["hash_ids"]):
            raise ValueError(f"trace row {index}: hash_ids must contain integers")
        if "hash_ids" in row and profile.block_size is not None:
            expected = (length + profile.block_size - 1) // profile.block_size
            if len(row["hash_ids"]) != expected:
                raise ValueError(f"trace row {index}: expected {expected} hash_ids")
    return rows
