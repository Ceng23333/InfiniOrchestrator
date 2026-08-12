"""Load per-benchmark-case warehouse schemas and playground case.schema.toml."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any


def harness_root() -> Path:
    """InfiniOrchestrator/harness root (parent of bench_harness package)."""
    return Path(__file__).resolve().parent.parent


def io_root() -> Path:
    return harness_root().parent


def _parse_simple_yaml(text: str) -> dict[str, Any]:
    """Minimal YAML subset: scalars, booleans, and ``- item`` lists under a key."""
    root: dict[str, Any] = {}
    current_list_key: str | None = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if re.match(r"^\s+-\s+", line):
            if current_list_key is None:
                raise ValueError(f"list item without key: {line!r}")
            item = line.strip()[1:].strip().strip('"').strip("'")
            root.setdefault(current_list_key, []).append(item)
            continue
        m = re.match(r"^([A-Za-z0-9_]+):\s*(.*)$", line)
        if not m:
            raise ValueError(f"unsupported yaml line: {line!r}")
        key, val = m.group(1), m.group(2).strip()
        if val == "":
            current_list_key = key
            root[key] = []
            continue
        current_list_key = None
        if val in ("true", "True"):
            root[key] = True
        elif val in ("false", "False"):
            root[key] = False
        else:
            root[key] = val.strip('"').strip("'")
    return root


@dataclass
class WarehouseCaseSchema:
    suite_prefix: str
    family: str
    metric_columns: list[str]
    model_in_bench_id: bool = True
    path: Path | None = None


@dataclass
class PlaygroundField:
    name: str
    emit: str
    env: list[str] = field(default_factory=list)
    required: bool = False
    type: str = "string"
    values: list[str] = field(default_factory=list)


def discover_warehouse_schemas(cases_root: Path | None = None) -> dict[str, WarehouseCaseSchema]:
    """Map suite_prefix → schema from ``cases/*/schema/warehouse.yaml``."""
    if cases_root is None:
        cases_root = harness_root() / "scenarios" / "benchmark" / "cases"
    out: dict[str, WarehouseCaseSchema] = {}
    if not cases_root.is_dir():
        return out
    for case_dir in sorted(cases_root.iterdir()):
        schema_path = case_dir / "schema" / "warehouse.yaml"
        if not schema_path.is_file():
            continue
        data = _parse_simple_yaml(schema_path.read_text(encoding="utf-8"))
        suite = str(data.get("suite_prefix") or "").strip()
        family = str(data.get("family") or "").strip()
        metrics = data.get("metric_columns") or []
        if not suite or not family:
            raise ValueError(f"invalid warehouse schema (need suite_prefix+family): {schema_path}")
        if not isinstance(metrics, list):
            raise ValueError(f"metric_columns must be a list: {schema_path}")
        model_in = data.get("model_in_bench_id", True)
        if not isinstance(model_in, bool):
            model_in = str(model_in).lower() in ("1", "true", "yes")
        out[suite] = WarehouseCaseSchema(
            suite_prefix=suite,
            family=family,
            metric_columns=[str(m) for m in metrics],
            model_in_bench_id=bool(model_in),
            path=schema_path,
        )
    return out


@lru_cache(maxsize=1)
def loaded_warehouse_schemas() -> dict[str, WarehouseCaseSchema]:
    schemas = discover_warehouse_schemas()
    if not schemas:
        raise RuntimeError(
            "no warehouse schemas found under "
            f"{harness_root() / 'scenarios' / 'benchmark' / 'cases'}"
        )
    return schemas


def playground_case_schema_path() -> Path:
    override = os.environ.get("PLAYGROUND_CASE_SCHEMA", "").strip()
    if override:
        return Path(override)
    return io_root() / "playground" / "case.schema.toml"


def _parse_playground_case_schema(text: str) -> list[PlaygroundField]:
    """Parse ``[fields.*]`` tables from case.schema.toml (Python 3.9-safe)."""
    fields: list[PlaygroundField] = []
    current: dict[str, Any] | None = None
    field_name: str | None = None

    def _flush() -> None:
        nonlocal current, field_name
        if not field_name or current is None:
            return
        emit = str(current.get("emit") or field_name)
        env_raw = current.get("env") or []
        if isinstance(env_raw, str):
            env_list = [env_raw]
        else:
            env_list = [str(x) for x in env_raw]
        values_raw = current.get("values") or []
        if isinstance(values_raw, str):
            values = [values_raw]
        else:
            values = [str(x) for x in values_raw]
        fields.append(
            PlaygroundField(
                name=field_name,
                emit=emit,
                env=env_list,
                required=bool(current.get("required", False)),
                type=str(current.get("type") or "string"),
                values=values,
            )
        )
        current = None
        field_name = None

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[fields\.([A-Za-z0-9_]+)\]$", line)
        if m:
            _flush()
            field_name = m.group(1)
            current = {}
            continue
        if current is None:
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            items: list[str] = []
            if inner:
                for part in inner.split(","):
                    items.append(part.strip().strip('"').strip("'"))
            current[key] = items
        elif val in ("true", "True"):
            current[key] = True
        elif val in ("false", "False"):
            current[key] = False
        else:
            current[key] = val.strip('"').strip("'")
    _flush()
    return fields


@lru_cache(maxsize=1)
def loaded_playground_fields() -> tuple[PlaygroundField, ...]:
    path = playground_case_schema_path()
    if not path.is_file():
        raise FileNotFoundError(f"playground case schema missing: {path}")
    return tuple(_parse_playground_case_schema(path.read_text(encoding="utf-8")))
