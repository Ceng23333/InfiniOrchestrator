"""Diagnostic manifest assembly, fingerprint, and diff."""

from __future__ import annotations

import hashlib
import json
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .evidence import write_json, write_text
from .load import CaseDocument, CaseSpec, ServiceSpec
from .probes import ProbeResult


def topology_fingerprint(spec: CaseSpec) -> str:
    parts: list[str] = [spec.topology, spec.version]
    for svc in spec.services:
        parts.append(svc.id)
        parts.append(svc.role)
        parts.append(svc.resolved_base_url or svc.base_url)
        parts.extend(svc.expect_services)
    digest = hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()
    return digest[:16]


def _git_sha(io_root: Path) -> str:
    try:
        proc = subprocess.run(
            ["git", "-C", str(io_root), "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        return (proc.stdout or "").strip() or "unknown"
    except OSError:
        return "unknown"


def build_block(
    doc: CaseDocument,
    scrape_cache: dict[str, Any],
    io_root: Path,
) -> dict[str, Any]:
    block: dict[str, Any] = {
        "worktree": doc.identity.get("worktree", ""),
        "io_git_sha": _git_sha(io_root),
    }
    import os

    if tag := os.environ.get("IMAGE_TAG"):
        block["image_tag"] = tag
    if base := os.environ.get("BASE_IMAGE"):
        block["base_image"] = base
    for key, meta in scrape_cache.items():
        if key.endswith("/metadata") and isinstance(meta, dict):
            if bi := meta.get("build_info"):
                block["entrypoint_build_info"] = bi
            block["server_id"] = meta.get("server_id", "")
            break
    return block


def assemble_manifest(
    doc: CaseDocument,
    *,
    run_id: str,
    started_at: datetime,
    finished_at: datetime,
    host: str,
    resolved_env: dict[str, str],
    probe_results: list[ProbeResult],
    scrape_cache: dict[str, Any],
    evidence_root: Path,
    io_root: Path,
    environment_extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    assert doc.spec is not None
    failures = [r for r in probe_results if r.status == "fail"]
    status = "pass" if not failures else "fail"
    failure_block: dict[str, Any] | None = None
    if failures:
        first = failures[0]
        failure_block = {
            "category": first.category,
            "message": first.message,
            "first_failed_probe": f"{first.service_id}:{first.path}",
        }

    env_block: dict[str, Any] = {
        "host": host,
        "resolved_env": resolved_env,
    }
    if environment_extra:
        env_block.update(environment_extra)

    manifest: dict[str, Any] = {
        "contract_version": doc.spec.version,
        "run_id": run_id,
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "status": status,
        "topology_fingerprint": topology_fingerprint(doc.spec),
        "case": {
            **doc.identity,
            "case_path": str(doc.path),
        },
        "build": build_block(doc, scrape_cache, io_root),
        "topology": {
            "kind": doc.spec.topology,
            "services": [
                {
                    "id": s.id,
                    "role": s.role,
                    "base_url": s.resolved_base_url,
                    "optional": s.optional,
                }
                for s in doc.spec.services
            ],
        },
        "environment": env_block,
        "probes": [
            {
                "service_id": r.service_id,
                "path": r.path,
                "kind": r.kind,
                "status": r.status,
                "category": r.category,
                "latency_ms": r.latency_ms,
                "message": r.message,
                "evidence": r.evidence,
            }
            for r in probe_results
        ],
        "evidence_root": str(evidence_root),
    }
    if failure_block:
        manifest["failure"] = failure_block
    return manifest


def write_summary(run_root: Path, manifest: dict[str, Any]) -> None:
    lines = [
        "# Case diagnostic summary",
        "",
        f"- **case_id:** {manifest['case'].get('case_id')}",
        f"- **status:** {manifest['status']}",
        f"- **topology:** {manifest['topology']['kind']}",
        f"- **fingerprint:** {manifest.get('topology_fingerprint')}",
        "",
        "## Probes",
        "",
        "| Service | Path | Status | Category | Evidence |",
        "|---------|------|--------|----------|----------|",
    ]
    for p in manifest.get("probes", []):
        lines.append(
            f"| {p['service_id']} | {p['path']} | {p['status']} | {p['category']} | {p.get('evidence','')} |"
        )
    if manifest.get("failure"):
        f = manifest["failure"]
        lines.extend(
            [
                "",
                "## Failure",
                "",
                f"- **category:** {f.get('category')}",
                f"- **message:** {f.get('message')}",
                f"- **probe:** {f.get('first_failed_probe')}",
            ]
        )
    write_text(run_root / "summary.md", "\n".join(lines) + "\n")


def write_manifest(run_root: Path, manifest: dict[str, Any]) -> Path:
    path = run_root / "diagnostic-manifest.json"
    write_json(path, manifest)
    write_summary(run_root, manifest)
    return path


def diff_manifests(prev_path: Path, curr_path: Path) -> str:
    prev = json.loads(prev_path.read_text(encoding="utf-8"))
    curr = json.loads(curr_path.read_text(encoding="utf-8"))
    lines = ["# Diagnostic manifest diff", ""]

    fp_prev = prev.get("topology_fingerprint")
    fp_curr = curr.get("topology_fingerprint")
    if fp_prev != fp_curr:
        lines.append(f"topology_fingerprint: {fp_prev} -> {fp_curr}")
    else:
        lines.append(f"topology_fingerprint: unchanged ({fp_curr})")

    lines.append(f"status: {prev.get('status')} -> {curr.get('status')}")
    lines.append("")

    def probe_key(p: dict[str, Any]) -> str:
        return f"{p.get('service_id')}:{p.get('path')}"

    prev_map = {probe_key(p): p for p in prev.get("probes", [])}
    curr_map = {probe_key(p): p for p in curr.get("probes", [])}
    all_keys = sorted(set(prev_map) | set(curr_map))
    lines.append("| Probe | Prev | Curr |")
    lines.append("|-------|------|------|")
    for key in all_keys:
        p0 = prev_map.get(key, {})
        p1 = curr_map.get(key, {})
        lines.append(
            f"| {key} | {p0.get('status', '-')} | {p1.get('status', '-')} |"
        )
    return "\n".join(lines) + "\n"


def new_run_id() -> str:
    return str(uuid.uuid4())
