"""Append bench rows to raw/<YYYY-MM-DD>/<suite_prefix>.tsv."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench_harness.frontend import FRONTEND_INFINILM

from bench_harness.deploy_tier import apply_deploy_tier
from bench_harness.hw_profile import apply_profile_to_row
from bench_harness.metadata_merge import merge_metadata_into_row
from bench_harness.partition import (
    date_from_row,
    harness_from_bench_id,
    hw_profile_json,
    parse_bench_model,
    raw_data_path,
)
from bench_harness.registry import (
    BENCH_ARGS_COLUMN,
    BENCH_PROFILE_KEYS,
    FRONTEND_METADATA_KEY,
    SERVER_ARGS_COLUMN,
    SERVER_PROFILE_KEYS,
    bench_family,
    data_columns,
    harness_raw_columns,
)
from bench_harness.server_client import metrics_json_to_row
from bench_harness.staging import parse_ceval_staging, parse_longbench_staging, parse_throughput_staging

TSV = "\t"


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_summary_started(summary_path: Path) -> str | None:
    if not summary_path.is_file():
        return None
    for line in summary_path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^- started:\s*(.+)$", line.strip())
        if m:
            return m.group(1).strip()
    return None


def _parse_summary_field(summary_path: Path, field: str) -> str | None:
    if not summary_path.is_file():
        return None
    pat = re.compile(rf"^- {re.escape(field)}:\s*(.+)$")
    for line in summary_path.read_text(encoding="utf-8").splitlines():
        m = pat.match(line.strip())
        if m:
            return m.group(1).strip()
    return None


def _scenario_status(staging_dir: Path, scenario: str) -> tuple[str, str]:
    results = staging_dir / "results.tsv"
    if not results.is_file():
        return "UNKNOWN", ""
    with results.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            if row.get("scenario") == scenario:
                return row.get("status", "UNKNOWN"), row.get("detail", "") or ""
    return "UNKNOWN", ""


def _read_tsv_rows(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        return [dict(row) for row in reader]


def _write_tsv(path: Path, columns: list[str], rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=columns, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def _dedupe_key(row: dict[str, Any]) -> tuple[str, str]:
    return (str(row.get("server_id", "")), str(row.get("started_at", "")))


def _parse_case_toml(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip().strip('"').strip("'")
        if key:
            out[key] = val
    return out


def _apply_case_metadata(row: dict[str, Any]) -> None:
    """Attach case metadata from playground/case.schema.toml + optional case.toml."""
    from bench_harness.schema_load import loaded_playground_fields

    case_path = os.environ.get("CASE_PATH", "").strip()
    case_file = Path(case_path) if case_path else None
    toml: dict[str, str] = _parse_case_toml(case_file) if case_file else {}
    row.setdefault("case_path", case_path or row.get("case_path", ""))

    missing_required: list[str] = []
    for fld in loaded_playground_fields():
        val = ""
        for env_key in fld.env:
            val = os.environ.get(env_key, "").strip()
            if val:
                break
        if not val:
            val = toml.get(fld.name, "").strip()
        if not val and fld.required and case_path:
            missing_required.append(fld.name)
        if fld.type == "enum" and val and fld.values and val not in fld.values:
            raise ValueError(
                f"case field {fld.name}={val!r} not in schema values {fld.values}"
            )
        if fld.emit == "model_id":
            row.setdefault(fld.emit, val or row.get("model", ""))
        else:
            row.setdefault(fld.emit, val)

    if missing_required:
        print(
            f"[emit] WARN: CASE_PATH={case_path}: missing required case.toml fields: "
            + ", ".join(missing_required),
            flush=True,
        )

    apply_profile_to_row(row)


_CASE_PROFILE_ENV: dict[str, tuple[str, ...]] = {
    "router_url": ("ROUTER_URL",),
    "metrics_url": ("BENCH_METRICS_URL", "INFERENCE_SERVER_BASE_URL"),
    "num_prompts": ("NUM_PROMPTS",),
    "max_concurrency": ("MAX_CONCURRENCY",),
    "num_concurrent": ("NUM_CONCURRENT",),
    "ceval_limit1": ("CEVAL_LIMIT1",),
    "input_len_min": ("INPUT_LEN_MIN",),
    "input_len_max": ("INPUT_LEN_MAX",),
    "output_len": ("OUTPUT_LEN",),
    "max_gen_toks": ("MAX_GEN_TOKS",),
    "longbench_length": ("LONGBENCH_LENGTH",),
    "longbench_difficulty": ("LONGBENCH_DIFFICULTY",),
    "max_input_tokens": ("MAX_INPUT_TOKENS",),
    "limit": ("LIMIT",),
}


def _profile_dict_from_env(keys: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for key in keys:
        val = ""
        for env_key in _CASE_PROFILE_ENV.get(key, (key.upper(),)):
            val = os.environ.get(env_key, "")
            if val:
                break
        if key == "ceval_limit1" and not val:
            ceval_full = os.environ.get("CEVAL_FULL", "")
            if ceval_full == "1":
                val = "0"
            elif ceval_full == "0":
                val = "1"
        if val:
            out[key] = str(val)
    return out


def _args_json_from_env(keys: list[str]) -> str:
    profile = _profile_dict_from_env(keys)
    if not profile:
        return ""
    return json.dumps(profile, sort_keys=True, separators=(",", ":"))


def _enrich_emit_row(row: dict[str, Any], bench_id: str) -> None:
    bench, model = parse_bench_model(bench_id, str(row.get("model", "")))
    date = date_from_row(row)
    row["bench_id"] = bench_id
    row["bench"] = bench
    row["bench_family"] = bench_family(bench_id)
    row["date"] = date
    if not row.get("model"):
        row["model"] = model
    if not row.get("model_id"):
        row["model_id"] = model
    row.setdefault("hw_profile", hw_profile_json(row))
    _apply_case_metadata(row)


def append_row(
    repo_root: Path,
    bench_id: str,
    row: dict[str, Any],
    dedupe: bool = True,
) -> Path:
    _enrich_emit_row(row, bench_id)
    date = str(row["date"])
    harness = harness_from_bench_id(bench_id)
    data_path = raw_data_path(repo_root, date, harness)

    columns = harness_raw_columns(bench_id)
    for col in data_columns(bench_id):
        if col not in columns:
            columns.append(col)

    existing = _read_tsv_rows(data_path)
    if dedupe:
        keys = {_dedupe_key(r) for r in existing}
        if _dedupe_key(row) not in keys:
            existing.append(row)
    else:
        existing.append(row)
    _write_tsv(data_path, columns, existing)
    return data_path


def _merge_server_metadata(
    row: dict[str, Any],
    staging_dir: Path,
    metadata_path: Path | None = None,
) -> None:
    candidates: list[Path] = []
    if metadata_path is not None:
        candidates.append(metadata_path)
    candidates.extend([staging_dir / "metadata.json", staging_dir.parent / "metadata.json"])
    for path in candidates:
        if not path.is_file():
            continue
        try:
            meta = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        merge_metadata_into_row(row, meta)
        return


def _merge_server_metrics(row: dict[str, Any], staging_dir: Path) -> None:
    server_dir = staging_dir / "server"
    period_path = server_dir / "metrics_period_summary.json"
    if period_path.is_file():
        try:
            summary = json.loads(period_path.read_text(encoding="utf-8"))
            for key, val in summary.items():
                if key.startswith("srv_") and val not in (None, ""):
                    row[key] = str(val)
            return
        except (json.JSONDecodeError, OSError):
            pass

    metrics_path = server_dir / "metrics_after.json"
    if not metrics_path.is_file():
        return
    try:
        metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
        row.update(metrics_json_to_row(metrics))
    except (json.JSONDecodeError, OSError, ValueError):
        pass


def build_row_from_staging(
    *,
    server_id: str,
    host_id: str,
    platform: str,
    bench_id: str,
    staging_dir: Path,
    started_at: str | None = None,
    finished_at: str | None = None,
    base_url: str | None = None,
    model: str | None = None,
    worker_container: str | None = None,
    image_tag: str | None = None,
    arch: str | None = None,
    gpu_model: str | None = None,
    lan_ip: str | None = None,
    role: str | None = None,
    deployment_case: str | None = None,
    suite_started_at: str | None = None,
    metadata_path: Path | None = None,
    metrics_override: dict[str, Any] | None = None,
) -> dict[str, Any]:
    summary = staging_dir / "summary.md"
    scenario = bench_id.split("__", 1)[1] if "__" in bench_id else bench_id
    status, _ = _scenario_status(staging_dir, scenario)
    started = started_at or _parse_summary_started(summary) or _utc_now_iso()
    finished = finished_at or _utc_now_iso()

    row: dict[str, Any] = {
        "server_id": server_id,
        "started_at": started,
        "finished_at": finished,
        "status": status,
        "base_url": base_url or _parse_summary_field(summary, "BASE_URL") or "",
        "model": model or _parse_summary_field(summary, "MODEL") or "",
        "worker_container": worker_container or _parse_summary_field(summary, "WORKER_CONTAINER") or "",
        "image_tag": image_tag or os.environ.get("IMAGE_TAG", ""),
        "host_id": host_id,
        "platform": platform,
        "arch": arch or os.environ.get("ARCH", ""),
        "gpu_model": gpu_model or os.environ.get("GPU_MODEL", ""),
        "lan_ip": lan_ip or os.environ.get("LAN_IP", ""),
        "role": role or os.environ.get("ROLE", ""),
        "deployment_case": deployment_case or os.environ.get("DEPLOYMENT_CASE", ""),
        "suite_started_at": suite_started_at or _parse_summary_started(summary) or started,
        SERVER_ARGS_COLUMN: _args_json_from_env(SERVER_PROFILE_KEYS),
        BENCH_ARGS_COLUMN: _args_json_from_env(BENCH_PROFILE_KEYS),
    }

    family = bench_family(bench_id)
    if family == "resilience":
        row["gate_pass"] = "1" if status == "PASS" else "0"
        row["step_loop_fatal"] = "0"
    elif family == "correctness":
        row["gate_pass"] = "1" if status == "PASS" else "0"
    elif family == "latency":
        metrics = metrics_override or parse_throughput_staging(staging_dir)
        for k, v in metrics.items():
            if k == "status" and v:
                row["status"] = v
            elif v:
                row[k] = v
        if row.get("status") == "UNKNOWN" and (
            metrics.get("req_per_s") or metrics.get("ttft_p50_ms")
        ):
            row["status"] = "PASS"
    elif family == "accuracy":
        metrics = metrics_override or parse_ceval_staging(staging_dir)
        for k, v in metrics.items():
            if k == "status" and v:
                row["status"] = v
            elif v:
                row[k] = v
        if row.get("status") == "UNKNOWN" and metrics.get("ceval_em"):
            row["status"] = "PASS"
    elif family == "quality_dyn":
        metrics = metrics_override or parse_longbench_staging(staging_dir)
        for k, v in metrics.items():
            if k == "status" and v:
                row["status"] = v
            elif v:
                row[k] = v
        if row.get("status") == "UNKNOWN" and (
            metrics.get("lb_em") or metrics.get("req_per_s") or metrics.get("ttft_p50_ms")
        ):
            row["status"] = "PASS"
    _merge_server_metadata(row, staging_dir, metadata_path)
    if not row.get(FRONTEND_METADATA_KEY):
        row[FRONTEND_METADATA_KEY] = (
            os.environ.get("BENCH_FRONTEND", "").strip() or FRONTEND_INFINILM
        )
    _merge_server_metrics(row, staging_dir)
    apply_deploy_tier(row)
    return row


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Emit bench row to raw/<date>/<harness>.tsv")
    parser.add_argument("--server-id", required=True)
    parser.add_argument("--host-id", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--bench-id", required=True)
    parser.add_argument("--staging-dir", type=Path, required=True)
    parser.add_argument("--repo-root", type=Path, default=None)
    parser.add_argument("--started-at", default=None)
    parser.add_argument("--finished-at", default=None)
    parser.add_argument("--base-url", default=None)
    parser.add_argument("--model", default=None)
    parser.add_argument("--worker-container", default=None)
    parser.add_argument("--image-tag", default=None)
    parser.add_argument("--suite-started-at", default=None)
    parser.add_argument(
        "--metadata-json",
        type=Path,
        default=None,
        help="GET /metadata snapshot (server_id linkage)",
    )
    parser.add_argument("--metrics-json", type=Path, default=None, help="client bench metrics override")
    parser.add_argument("--no-dedupe", action="store_true")
    args = parser.parse_args(argv)

    metrics_override = None
    if args.metrics_json and args.metrics_json.is_file():
        metrics_override = json.loads(args.metrics_json.read_text(encoding="utf-8"))

    repo = args.repo_root or Path(
        os.environ.get("BENCH_WAREHOUSE_REPO", Path(__file__).resolve().parents[1])
    )
    row = build_row_from_staging(
        server_id=args.server_id,
        host_id=args.host_id,
        platform=args.platform,
        bench_id=args.bench_id,
        staging_dir=args.staging_dir,
        started_at=args.started_at,
        finished_at=args.finished_at,
        base_url=args.base_url,
        model=args.model,
        worker_container=args.worker_container,
        image_tag=args.image_tag,
        suite_started_at=args.suite_started_at or os.environ.get("SUITE_STARTED_AT"),
        metadata_path=args.metadata_json,
        metrics_override=metrics_override,
    )
    path = append_row(
        repo,
        args.bench_id,
        row,
        dedupe=not args.no_dedupe,
    )
    print(f"[emit] {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
