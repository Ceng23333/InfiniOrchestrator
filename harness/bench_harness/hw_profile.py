"""Load hardware profiles from HARDWARE_PROFILE_REPO/profiles/*.yaml."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

_PROFILE_CACHE: dict[str, dict[str, Any]] = {}


def hardware_profile_repo(explicit: Path | None = None) -> Path:
    if explicit is not None:
        return explicit
    env = os.environ.get("HARDWARE_PROFILE_REPO", "")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[3] / "hardware-profile"


def _parse_yaml_scalar(value: str) -> Any:
    text = value.strip()
    if text in ("null", "~", ""):
        return None
    if text in ("true", "false"):
        return text == "true"
    if re.fullmatch(r"-?[0-9]+", text):
        return int(text)
    if re.fullmatch(r"-?[0-9]+\.[0-9]+", text):
        return float(text)
    if (text.startswith('"') and text.endswith('"')) or (
        text.startswith("'") and text.endswith("'")
    ):
        return text[1:-1]
    return text


def _load_yaml_minimal(text: str) -> dict[str, Any]:
    """Parse simple nested key: value YAML (no lists/anchors)."""
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, root)]

    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip())
        line = raw_line.strip()
        if ":" not in line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        if not key:
            continue

        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]

        if rest.strip():
            parent[key] = _parse_yaml_scalar(rest)
        else:
            child: dict[str, Any] = {}
            parent[key] = child
            stack.append((indent, child))

    return root


def _load_yaml_file(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text)
        return data if isinstance(data, dict) else {}
    except ImportError:
        return _load_yaml_minimal(text)


def _index_profiles(repo: Path) -> None:
    profiles_dir = repo / "profiles"
    if not profiles_dir.is_dir():
        return
    for path in sorted(profiles_dir.glob("*.yaml")):
        data = _load_yaml_file(path)
        if not isinstance(data, dict):
            continue
        pid = str(data.get("hw_profile_id", "") or path.stem)
        _PROFILE_CACHE[pid] = data
        abbr = str(data.get("abbr", "") or "")
        if abbr:
            _PROFILE_CACHE[abbr] = data


def load_profile(
    *,
    hw_profile_id: str | None = None,
    hw_abbr: str | None = None,
    repo: Path | None = None,
) -> dict[str, Any]:
    """Resolve a profile dict by ``hw_profile_id`` or ``abbr``."""
    repo_path = hardware_profile_repo(repo)
    if not _PROFILE_CACHE:
        _index_profiles(repo_path)

    for key in (hw_profile_id, hw_abbr):
        if key and key in _PROFILE_CACHE:
            return dict(_PROFILE_CACHE[key])

    profiles_dir = repo_path / "profiles"
    if profiles_dir.is_dir():
        for path in sorted(profiles_dir.glob("*.yaml")):
            data = _load_yaml_file(path)
            if not isinstance(data, dict):
                continue
            if hw_profile_id and str(data.get("hw_profile_id", "")) == hw_profile_id:
                return data
            if hw_abbr and str(data.get("abbr", "")) == hw_abbr:
                return data
            if hw_profile_id and path.stem == hw_profile_id:
                return data
            if hw_abbr and path.stem == hw_abbr:
                return data
    return {}


def denormalize_profile(profile: dict[str, Any]) -> dict[str, str]:
    """Flatten nested gpu/cpu/os/host/interconnect fields onto row columns."""
    if not profile:
        return {}

    def _section(name: str) -> dict[str, Any]:
        val = profile.get(name)
        return val if isinstance(val, dict) else {}

    gpu = _section("gpu")
    cpu = _section("cpu")
    os_info = _section("os")
    host = _section("host")
    ic = _section("interconnect")

    def _str(val: Any) -> str:
        if val is None:
            return ""
        return str(val)

    out = {
        "hw_profile_id": _str(profile.get("hw_profile_id", "")),
        "hw_abbr": _str(profile.get("abbr", "")),
        "prof_gpu_vendor": _str(gpu.get("vendor")),
        "prof_gpu_model": _str(gpu.get("model")),
        "prof_gpu_arch": _str(gpu.get("arch")),
        "prof_gpu_driver": _str(gpu.get("driver")),
        "prof_gpu_memory_gb": _str(gpu.get("memory_gb")),
        "prof_cpu_vendor": _str(cpu.get("vendor")),
        "prof_cpu_model": _str(cpu.get("model")),
        "prof_cpu_arch": _str(cpu.get("arch")),
        "prof_cpu_cores": _str(cpu.get("cores")),
        "prof_os_name": _str(os_info.get("name")),
        "prof_os_version": _str(os_info.get("version")),
        "prof_os_kernel": _str(os_info.get("kernel")),
        "prof_host_platform": _str(host.get("platform")),
        "prof_host_class": _str(host.get("host_class")),
        "prof_interconnect_type": _str(ic.get("type")),
    }
    return out


def apply_profile_to_row(row: dict[str, Any], *, repo: Path | None = None) -> None:
    """Resolve profile from row keys or env and merge denormalized fields in-place."""
    pid = str(row.get("hw_profile_id", "") or os.environ.get("HW_PROFILE_ID", ""))
    abbr = str(row.get("hw_abbr", "") or os.environ.get("HW_ABBR", ""))
    profile = load_profile(hw_profile_id=pid or None, hw_abbr=abbr or None, repo=repo)
    if profile:
        row.update(denormalize_profile(profile))
