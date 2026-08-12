"""Load hardware profiles from HARDWARE_PROFILE_REPO/profiles/*.yaml.

Band files are ``{vendor}-{gpu.model}.yaml`` with shared ``gpu``/``abbr`` and a ``hosts``
list. Host major id is ``ip``; optional ``id`` is a stable alias. Requires PyYAML
for list parsing.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

_PROFILE_CACHE: dict[str, dict[str, Any]] = {}
_INDEXED = False


def hardware_profile_repo(explicit: Path | None = None) -> Path:
    if explicit is not None:
        return explicit
    env = os.environ.get("HARDWARE_PROFILE_REPO", "")
    if env:
        return Path(env)
    return Path(__file__).resolve().parents[3] / "hardware-profile"


def _load_yaml_file(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError(
            "PyYAML is required to load hardware-profile hosts[] lists"
        ) from exc
    data = yaml.safe_load(text)
    return data if isinstance(data, dict) else {}


def _section(obj: dict[str, Any], name: str) -> dict[str, Any]:
    val = obj.get(name)
    return val if isinstance(val, dict) else {}


def _merge_host(band: dict[str, Any], host_entry: dict[str, Any]) -> dict[str, Any]:
    """Merge shared GPU band + one host entry into a denormalize-ready dict."""
    ip = str(host_entry.get("ip", "") or "").strip()
    alias = str(host_entry.get("id", "") or "").strip()
    gpu = dict(_section(band, "gpu"))
    if "driver" in host_entry:
        gpu["driver"] = host_entry.get("driver")

    host_meta = dict(_section(host_entry, "host"))
    host_meta["ip"] = ip

    return {
        "abbr": band.get("abbr"),
        "hw_profile_id": alias or ip,
        "gpu": gpu,
        "cpu": dict(_section(host_entry, "cpu")),
        "os": dict(_section(host_entry, "os")),
        "host": host_meta,
        "interconnect": dict(_section(host_entry, "interconnect")),
        "image_hints": dict(_section(host_entry, "image_hints")),
    }


def _band_only(band: dict[str, Any]) -> dict[str, Any]:
    """Shared GPU fields only (abbr lookup without selecting a host)."""
    return {
        "abbr": band.get("abbr"),
        "hw_profile_id": "",
        "gpu": dict(_section(band, "gpu")),
        "cpu": {},
        "os": {},
        "host": {},
        "interconnect": {},
        "image_hints": {},
    }


def _index_profiles(repo: Path) -> None:
    global _INDEXED
    profiles_dir = repo / "profiles"
    if not profiles_dir.is_dir():
        _INDEXED = True
        return

    for path in sorted(profiles_dir.glob("*.yaml")):
        data = _load_yaml_file(path)
        if not isinstance(data, dict):
            continue

        abbr = str(data.get("abbr", "") or "").strip()
        if abbr:
            _PROFILE_CACHE[abbr] = _band_only(data)

        hosts = data.get("hosts")
        if not isinstance(hosts, list):
            continue
        for entry in hosts:
            if not isinstance(entry, dict):
                continue
            ip = str(entry.get("ip", "") or "").strip()
            if not ip:
                continue
            merged = _merge_host(data, entry)
            _PROFILE_CACHE[ip] = merged
            alias = str(entry.get("id", "") or "").strip()
            if alias:
                _PROFILE_CACHE[alias] = merged

    _INDEXED = True


def load_profile(
    *,
    hw_profile_id: str | None = None,
    hw_abbr: str | None = None,
    repo: Path | None = None,
) -> dict[str, Any]:
    """Resolve a profile by host IP / alias id, or band abbr (GPU-only)."""
    global _INDEXED
    repo_path = hardware_profile_repo(repo)
    if not _INDEXED:
        _index_profiles(repo_path)

    # Prefer host IP / alias over band abbr when both are supplied.
    if hw_profile_id and hw_profile_id in _PROFILE_CACHE:
        return dict(_PROFILE_CACHE[hw_profile_id])
    if hw_abbr and hw_abbr in _PROFILE_CACHE:
        return dict(_PROFILE_CACHE[hw_abbr])
    return {}


def denormalize_profile(profile: dict[str, Any]) -> dict[str, str]:
    """Flatten nested gpu/cpu/os/host/interconnect fields onto row columns."""
    if not profile:
        return {}

    def _sec(name: str) -> dict[str, Any]:
        val = profile.get(name)
        return val if isinstance(val, dict) else {}

    gpu = _sec("gpu")
    cpu = _sec("cpu")
    os_info = _sec("os")
    host = _sec("host")
    ic = _sec("interconnect")

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
        "prof_host_ip": _str(host.get("ip")),
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


def reset_profile_cache() -> None:
    """Clear cached index (tests / reload after catalog edits)."""
    global _INDEXED
    _PROFILE_CACHE.clear()
    _INDEXED = False
