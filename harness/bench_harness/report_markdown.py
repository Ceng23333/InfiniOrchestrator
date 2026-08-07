"""Markdown rollup reports for best-on model and platform index."""

from __future__ import annotations

import json
from pathlib import Path

from bench_harness.deploy_tier import DEPLOY_TIERS, ORCHESTRATOR_IMAGE_TAG_PREFIX
from bench_harness.registry import (
    BUILD_INFO_COLUMNS,
    FRONTEND_METADATA_KEY,
    RUNTIME_PROBE_COLUMNS,
    SERVER_CONFIG_COLUMN,
)
from bench_harness.reports import build_best_metric_rows

_DEPLOYMENT_FIELDS = [
    "host_id",
    "base_url",
    "deployment_case",
    "worker_container",
    "role",
    "lan_ip",
]

_SOFTWARE_FIELDS = ["image_tag", *BUILD_INFO_COLUMNS, "deploy_tier"]

_ENVIRONMENT_FIELDS = [
    *RUNTIME_PROBE_COLUMNS,
    "arch",
    "gpu_model",
]


def raw_data_relpath(
    from_path: Path,
    platform: str,
    bench: str,
    model: str,
    date: str,
    *,
    fe: str = "",
) -> str:
    """Relative link from a warehouse markdown file to raw ``data.tsv``."""
    from bench_harness.partition import raw_data_path

    warehouse_root = from_path.resolve()
    while warehouse_root.name != "warehouse" and warehouse_root.parent != warehouse_root:
        warehouse_root = warehouse_root.parent
    if warehouse_root.name != "warehouse":
        repo_root = from_path.resolve()
        while repo_root.name not in ("bench-warehouse", "raw") and repo_root.parent != repo_root:
            repo_root = repo_root.parent
        if (repo_root / "raw").is_dir():
            pass
        else:
            raise ValueError(f"cannot locate warehouse root from {from_path}")
    else:
        repo_root = warehouse_root.parent
    raw_target = raw_data_path(repo_root, date)
    if not raw_target.is_file():
        for candidate in (repo_root / "raw").rglob("data.tsv"):
            if candidate.parent.name == date:
                raw_target = candidate
                break
    link_dir = from_path.resolve().parent
    up = len(link_dir.relative_to(repo_root).parts)
    down = raw_target.relative_to(repo_root)
    return Path(*([".."] * up), *down.parts).as_posix()


def _raw_link(
    from_path: Path,
    platform: str,
    bench: str,
    model: str,
    bench_id: str,
    date: str,
    *,
    fe: str = "",
) -> str:
    bench_seg = bench or bench_id
    rel = raw_data_relpath(
        from_path,
        platform,
        bench_seg,
        model or bench_id.split("__")[-1],
        date,
        fe=fe,
    )
    return f"[data.tsv]({rel})"


def group_best_rows_by_server(rows: list[dict[str, str]]) -> dict[str, list[dict[str, str]]]:
    """Group best-on rows by winning ``server_id``."""
    grouped: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        sid = row.get("server_id", "")
        grouped.setdefault(sid, []).append(row)
    for sid in grouped:
        grouped[sid].sort(key=lambda r: (r.get("best_on", ""), r.get("bench_id", "")))
    return dict(sorted(grouped.items()))


def _escape_md_cell(val: str) -> str:
    return val.replace("|", "\\|")


def _field_table(title: str, row: dict[str, str], fields: list[str]) -> list[str]:
    lines: list[str] = []
    pairs = [(f, row.get(f, "")) for f in fields if row.get(f, "")]
    if not pairs:
        return lines
    lines.append(f"### {title}")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("|-------|-------|")
    for col, val in pairs:
        lines.append(f"| {_escape_md_cell(col)} | {_escape_md_cell(val)} |")
    lines.append("")
    return lines


def _kv_subtable(title: str, data: dict[str, object]) -> list[str]:
    lines: list[str] = []
    pairs = [(k, data[k]) for k in sorted(data) if data[k] not in (None, "")]
    if not pairs:
        return lines
    lines.append(f"#### {title}")
    lines.append("")
    lines.append("| key | value |")
    lines.append("|-----|-------|")
    for key, val in pairs:
        lines.append(f"| {_escape_md_cell(str(key))} | {_escape_md_cell(str(val))} |")
    lines.append("")
    return lines


def _config_section(row: dict[str, str]) -> list[str]:
    raw = row.get(SERVER_CONFIG_COLUMN, "")
    if not raw:
        return []
    try:
        config = json.loads(raw)
    except json.JSONDecodeError:
        return []
    if not isinstance(config, dict):
        return []
    lines = ["### Config", ""]
    startup = config.get("startup")
    env = config.get("env")
    if isinstance(startup, dict):
        lines.extend(_kv_subtable("startup", startup))
    if isinstance(env, dict):
        lines.extend(_kv_subtable("env", env))
    return lines


def render_model_best_markdown(
    platform: str,
    model: str,
    grouped: dict[str, list[dict[str, str]]],
    md_path: Path,
    *,
    tier: str = "",
) -> str:
    """Render best-on markdown for one model."""
    tier_label = f", {tier}" if tier else ""
    tier_note = ""
    if tier == "production":
        tier_note = " (io_sha or orchestrator image_tag)"
    elif tier == "dev":
        tier_note = " (not orchestrator production)"

    other_tier = "dev" if tier == "production" else "production"
    other_link = ""
    if tier in DEPLOY_TIERS:
        other_link = f" · [{other_tier} report](../{other_tier}/report_{model}.md)"

    lines: list[str] = [
        f"# {model} — best-on ({platform}{tier_label})",
        "",
        f"Tier: {tier or 'all'}{tier_note}{other_link}",
        "",
        f"[Platform report](../../report_{platform}.md) · [TSV](report_{model}.tsv)",
        "",
    ]
    for server_id, win_rows in grouped.items():
        anchor = win_rows[0]
        lines.append(f"## Server `{server_id}`")
        lines.append("")
        lines.extend(_field_table("Deployment", anchor, _DEPLOYMENT_FIELDS))
        lines.extend(_field_table("Software", anchor, _SOFTWARE_FIELDS))
        lines.extend(_field_table("Environment", anchor, _ENVIRONMENT_FIELDS))
        lines.extend(_config_section(anchor))
        lines.append("### Best-on wins")
        lines.append("")
        lines.append("| best_on | value |")
        lines.append("|---------|-------|")
        raw_keys: list[tuple[str, str]] = []
        seen_raw: set[tuple[str, str]] = set()
        for row in win_rows:
            bid = row.get("bench_id", "")
            dt = row.get("date", "")
            key = (bid, dt)
            if key not in seen_raw:
                seen_raw.add(key)
                raw_keys.append(key)
            cells = [
                _escape_md_cell(row.get("best_on", "")),
                _escape_md_cell(row.get("value", "")),
            ]
            lines.append("| " + " | ".join(cells) + " |")
        if raw_keys:
            lines.append("")
            lines.append("**Raw data**")
            for bid, dt in raw_keys:
                model_name = anchor.get("model", "")
                bench_seg = anchor.get("bench", "") or bid
                raw = _raw_link(
                    md_path,
                    platform,
                    bench_seg,
                    model_name,
                    bid,
                    dt,
                    fe=anchor.get(FRONTEND_METADATA_KEY, ""),
                )
                lines.append(f"- `{bid}` / {dt}: {raw}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def render_platform_index_markdown(
    platform: str,
    models: list[tuple[str, str, Path]],
    rollup_dir: Path,
) -> str:
    """Render platform hub markdown listing all model reports by tier."""
    lines: list[str] = [
        f"# {platform} — rollup reports",
        "",
        "All-time latest per `(server_id, bench_id)`; best-on winners grouped by model and tier.",
        "",
        "Tier rule: **production** = `io_sha` set, or `image_tag` starts with "
        f"`{ORCHESTRATOR_IMAGE_TAG_PREFIX}`, or orchestrator `deployment_case`; **dev** otherwise.",
        "",
        "## Related artifacts",
        "",
        f"- [Platform long TSV](report_{platform}.tsv)",
        f"- [Platform wide by server](report_{platform}_by_server.tsv)",
        f"- [Latest by server](latest_by_server.tsv)",
        "",
        "## Models",
        "",
        "| model | tier | markdown | TSV |",
        "|-------|------|----------|-----|",
    ]
    for model, tier, md_path in sorted(models, key=lambda m: (m[0], m[1])):
        md_rel = md_path.relative_to(rollup_dir).as_posix()
        tsv_rel = (rollup_dir / platform / tier / f"report_{model}.tsv").relative_to(
            rollup_dir
        ).as_posix()
        lines.append(
            f"| {_escape_md_cell(model)} | {tier} | [{md_rel}]({md_rel}) | [{tsv_rel}]({tsv_rel}) |"
        )
    lines.append("")
    return "\n".join(lines) + "\n"


def write_model_best_markdown_reports(
    out_dir: Path,
    platform: str,
    rows: list[dict[str, str]],
    *,
    tier: str = "",
) -> list[Path]:
    """Write ``<out_dir>/<platform>/report_<model>.md`` best-on files."""
    plat_rows = [r for r in rows if r.get("platform") == platform]
    if not plat_rows:
        return []

    best_rows = build_best_metric_rows(plat_rows)
    if not best_rows:
        return []

    by_model: dict[str, list[dict[str, str]]] = {}
    for row in best_rows:
        model = row.get("model", "")
        by_model.setdefault(model, []).append(row)

    written: list[Path] = []
    plat_dir = out_dir if tier else out_dir / platform
    plat_dir.mkdir(parents=True, exist_ok=True)
    for model in sorted(by_model):
        md_path = plat_dir / f"report_{model}.md"
        grouped = group_best_rows_by_server(by_model[model])
        content = render_model_best_markdown(
            platform, model, grouped, md_path, tier=tier
        )
        md_path.write_text(content, encoding="utf-8")
        written.append(md_path)
    return written


def write_platform_markdown_index(
    rollup_dir: Path,
    platform: str,
    model_entries: list[tuple[str, str, Path]],
) -> Path:
    """Write ``<rollup_dir>/report_<platform>.md`` platform hub."""
    content = render_platform_index_markdown(platform, model_entries, rollup_dir)
    out_path = rollup_dir / f"report_{platform}.md"
    out_path.write_text(content, encoding="utf-8")
    return out_path
