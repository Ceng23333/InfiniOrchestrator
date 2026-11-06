"""Load and validate AIPerf mooncake_trace workload profiles."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict

import yaml


ADAPTER_ROOT = Path(__file__).resolve().parent


@dataclass(frozen=True)
class AiperfProfile:
    name: str
    model: str
    endpoint_type: str
    streaming: bool
    fixed_schedule: bool
    input_file: Path
    custom_dataset_type: str
    timeout_sec: float
    extra_args: list[str]
    raw: Dict[str, Any]


def _resolve_trace(path_value: str, profile_path: Path) -> Path:
    candidate = Path(path_value)
    if candidate.is_file():
        return candidate.resolve()
    relative = (profile_path.parent / candidate).resolve()
    if relative.is_file():
        return relative
    from_adapter = (ADAPTER_ROOT / candidate).resolve()
    if from_adapter.is_file():
        return from_adapter
    raise FileNotFoundError(f"trace input file not found: {path_value}")


def load_profile(path: Path) -> AiperfProfile:
    """Read a profile and reject unsafe or unbounded values."""
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        raise ValueError("profile must be a YAML mapping")

    model = str(raw.get("model", "")).strip()
    if not model:
        raise ValueError("model is required")

    endpoint_type = str(raw.get("endpoint_type", "chat")).strip() or "chat"
    streaming = bool(raw.get("streaming", True))
    fixed_schedule = bool(raw.get("fixed_schedule", True))
    dataset_type = str(raw.get("custom_dataset_type", "mooncake_trace")).strip()
    if dataset_type != "mooncake_trace":
        raise ValueError("custom_dataset_type must be mooncake_trace for this adapter")

    timeout_sec = float(raw.get("timeout_sec", 7200))
    if timeout_sec <= 0 or timeout_sec > 86400:
        raise ValueError("timeout_sec must be between 0 and 86400")

    input_file_raw = raw.get("input_file")
    if not input_file_raw:
        raise ValueError("input_file is required")
    input_file = _resolve_trace(str(input_file_raw), path)

    extra = raw.get("extra_args", []) or []
    if not isinstance(extra, list) or not all(isinstance(item, str) for item in extra):
        raise ValueError("extra_args must be a list of strings")

    return AiperfProfile(
        name=str(raw.get("name") or path.stem),
        model=model,
        endpoint_type=endpoint_type,
        streaming=streaming,
        fixed_schedule=fixed_schedule,
        input_file=input_file,
        custom_dataset_type=dataset_type,
        timeout_sec=timeout_sec,
        extra_args=list(extra),
        raw=raw,
    )


def default_profile_path(name: str) -> Path:
    return ADAPTER_ROOT / "profiles" / f"{name}.yaml"
