"""Standardized evidence directory layout for diagnostic runs."""

from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def diagnostics_root(bench_results_root: Path, case_id: str) -> Path:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return bench_results_root / "diagnostics" / f"{case_id}_{ts}"


def init_run_dir(root: Path) -> dict[str, Path]:
    dirs = {
        "root": root,
        "evidence": root / "evidence",
        "configuration": root / "evidence" / "configuration",
        "startup": root / "evidence" / "startup",
        "health": root / "evidence" / "health",
        "metadata": root / "evidence" / "metadata",
        "client": root / "evidence" / "client",
    }
    for path in dirs.values():
        path.mkdir(parents=True, exist_ok=True)
    return dirs


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def relative_evidence(run_root: Path, path: Path) -> str:
    return str(path.relative_to(run_root))


def capture_startup(container_name: str | None, startup_dir: Path) -> None:
    if not container_name:
        return
    try:
        ps = subprocess.run(
            ["docker", "ps", "-a", "--filter", f"name={container_name}", "--no-trunc"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        write_text(startup_dir / "docker_ps.txt", ps.stdout or ps.stderr)
        logs = subprocess.run(
            ["docker", "logs", "--tail", "200", container_name],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        write_text(startup_dir / "container_logs_tail.txt", logs.stdout or logs.stderr)
    except (OSError, subprocess.TimeoutExpired):
        pass


def capture_mx_smi(run_root: Path) -> dict[str, Any]:
    info: dict[str, Any] = {}
    try:
        proc = subprocess.run(
            ["mx-smi"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        text = proc.stdout or proc.stderr
        if text:
            write_text(run_root / "evidence" / "startup" / "mx_smi.txt", text)
            if "MetaX C550" in text:
                info["accelerator"] = "MetaX C550"
            gpu_lines = [ln for ln in text.splitlines() if "Attached GPUs" in ln]
            if gpu_lines:
                parts = gpu_lines[0].split(":")
                if len(parts) > 1:
                    try:
                        info["gpu_count"] = int(parts[1].strip())
                    except ValueError:
                        pass
    except (OSError, subprocess.TimeoutExpired):
        pass
    return info
