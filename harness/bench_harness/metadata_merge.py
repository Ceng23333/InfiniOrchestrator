"""Helpers for merging GET /metadata into warehouse rows."""

from __future__ import annotations

import json
import re
from typing import Any

from bench_harness.registry import (
    BUILD_INFO_COLUMNS,
    FRONTEND_METADATA_KEY,
    RUNTIME_PROBE_COLUMNS,
    SERVER_CONFIG_COLUMN,
    SERVER_RUNTIME_ENV_COLUMN,
)

_IMAGE_TAG_SHA_RE = re.compile(
    r"([0-9a-f]{7,40})-([0-9a-f]{7,40})(?:-(\d{8}))?\s*$",
    re.I,
)


def parse_shas_from_image_tag(image_tag: str) -> dict[str, str]:
    out: dict[str, str] = {}
    m = _IMAGE_TAG_SHA_RE.search(image_tag)
    if m:
        out["il_sha"] = m.group(1)
        out["ic_sha"] = m.group(2)
        if m.group(3):
            out["build_ts"] = m.group(3)
    return out


def _json_blob(val: Any) -> str:
    if not val:
        return ""
    return json.dumps(val, sort_keys=True, separators=(",", ":"))


def merge_metadata_into_row(row: dict[str, Any], meta: dict[str, Any]) -> None:
    """Promote GET /metadata fields into a warehouse emit row."""
    if meta.get(FRONTEND_METADATA_KEY):
        row[FRONTEND_METADATA_KEY] = str(meta[FRONTEND_METADATA_KEY])
    if not row.get("model") and meta.get("model_id"):
        row["model"] = str(meta["model_id"])
    if not row.get("base_url") and meta.get("host") and meta.get("port"):
        row["base_url"] = f"http://{meta['host']}:{meta['port']}"

    build_info = meta.get("build_info") or {}
    for col in BUILD_INFO_COLUMNS:
        val = build_info.get(col, "")
        if val:
            row[col] = str(val)
    if not any(row.get(c) for c in BUILD_INFO_COLUMNS):
        parsed = parse_shas_from_image_tag(str(row.get("image_tag", "")))
        for col in BUILD_INFO_COLUMNS:
            if parsed.get(col) and not row.get(col):
                row[col] = parsed[col]

    runtime_env = meta.get("runtime_env") or {}
    for col in RUNTIME_PROBE_COLUMNS:
        val = runtime_env.get(col, "")
        if val:
            row[col] = str(val)
    if runtime_env.get("arch") and not row.get("arch"):
        row["arch"] = str(runtime_env["arch"])
    if runtime_env.get("gpu_model") and not row.get("gpu_model"):
        row["gpu_model"] = str(runtime_env["gpu_model"])

    config = meta.get("config") or {
        "startup": meta.get("startup_args", {}),
        "env": {},
    }
    row[SERVER_CONFIG_COLUMN] = _json_blob(config)
    row[SERVER_RUNTIME_ENV_COLUMN] = _json_blob(runtime_env)
