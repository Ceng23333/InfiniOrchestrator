"""Map adapter output into the case diagnostic manifest bench block."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict


def build_bench_block(
    *,
    profile: str,
    client_version: str,
    collection_config: Dict[str, Any],
    base_url: str,
    case_path: str,
    topology_fingerprint: str,
    metrics: Dict[str, Any],
    artifacts: list[str],
    adapter_mode: str,
) -> Dict[str, Any]:
    return {
        "adapter": "llm_d_benchmark",
        "profile": profile,
        "client_version": client_version,
        "adapter_mode": adapter_mode,
        "collection_config": collection_config,
        "base_url": base_url,
        "case_path": case_path,
        "topology_fingerprint": topology_fingerprint,
        "metrics": metrics,
        "artifacts": artifacts,
    }


def update_manifest(path: Path, bench: Dict[str, Any]) -> None:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("diagnostic manifest must be a JSON object")
    manifest["bench"] = bench
    path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
