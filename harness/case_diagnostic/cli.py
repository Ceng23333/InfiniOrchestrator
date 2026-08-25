"""validate-case CLI."""

from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from .evidence import (
    capture_mx_smi,
    capture_startup,
    diagnostics_root,
    init_run_dir,
    write_json,
)
from .load import ConfigurationError, default_host, load_case, load_env_file, resolve_services
from .manifest import assemble_manifest, diff_manifests, new_run_id, write_manifest
from .probes import ProbeContext, run_all_probes


def _io_root() -> Path:
    harness_root = Path(__file__).resolve().parents[1]
    return harness_root.parent


def _bench_results_root() -> Path:
    env = os.environ.get("BENCH_RESULTS_ROOT")
    if env:
        return Path(env)
    io_root = _io_root()
    sibling = io_root.parent / "bench-warehouse" / "bench_results"
    return sibling if sibling.parent.exists() else io_root / "bench_results"


def cmd_validate(args: argparse.Namespace) -> int:
    case_path = Path(args.case_path or os.environ.get("CASE_PATH", ""))
    if not case_path.is_file():
        print(f"error: case file not found: {case_path}", file=sys.stderr)
        return 2

    doc = load_case(case_path, require_spec=True)
    if doc.config_errors:
        print("configuration errors:", file=sys.stderr)
        for err in doc.config_errors:
            print(f"  - {err}", file=sys.stderr)
        return 2

    assert doc.spec is not None
    env_file = load_env_file(Path(args.env_file) if args.env_file else None)
    host = default_host(doc, args.host)
    resolve_services(doc.spec, host, env_file)

    case_id = str(doc.identity.get("case_id", "unknown"))
    run_root = diagnostics_root(_bench_results_root(), case_id)
    dirs = init_run_dir(run_root)
    write_json(dirs["configuration"] / "case.json", {
        "identity": doc.identity,
        "spec": {
            "version": doc.spec.version,
            "topology": doc.spec.topology,
            "host_env": doc.spec.host_env,
            "services": [
                {
                    "id": s.id,
                    "role": s.role,
                    "base_url": s.base_url,
                    "resolved_base_url": s.resolved_base_url,
                    "optional": s.optional,
                    "probes": [p.__dict__ for p in s.probes],
                }
                for s in doc.spec.services
            ],
        },
    })

    capture_startup(args.container, dirs["startup"])
    env_extra = capture_mx_smi(run_root)

    started = datetime.now(timezone.utc)
    ctx = ProbeContext(run_root=run_root, evidence_dirs=dirs, timeout=args.timeout)
    results = run_all_probes(doc.spec.services, ctx)
    finished = datetime.now(timezone.utc)

    manifest = assemble_manifest(
        doc,
        run_id=new_run_id(),
        started_at=started,
        finished_at=finished,
        host=host,
        resolved_env=env_file,
        probe_results=results,
        scrape_cache=ctx.scrape_cache,
        evidence_root=run_root,
        io_root=_io_root(),
        environment_extra=env_extra,
    )
    manifest_path = write_manifest(run_root, manifest)

    print(f"diagnostic manifest: {manifest_path}")
    print(f"evidence root: {run_root}")
    print(f"status: {manifest['status']}")
    print(f"topology_fingerprint: {manifest.get('topology_fingerprint')}")
    print(f"export DIAGNOSTIC_MANIFEST={manifest_path}")

    if manifest["status"] == "fail":
        failure = manifest.get("failure", {})
        print(
            f"failure category: {failure.get('category')} — {failure.get('message')}",
            file=sys.stderr,
        )
        return 1
    return 0


def cmd_diff(args: argparse.Namespace) -> int:
    prev = Path(args.prev)
    curr = Path(args.curr)
    if not prev.is_file() or not curr.is_file():
        print("error: both manifest paths must exist", file=sys.stderr)
        return 2
    print(diff_manifests(prev, curr), end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="validate-case")
    sub = parser.add_subparsers(dest="command")

    validate = sub.add_parser("validate", help="validate a running case (default)")
    validate.add_argument("--case-path", help="path to case.toml (or CASE_PATH env)")
    validate.add_argument("--host", help="target host for {host} interpolation")
    validate.add_argument("--env-file", help="dotenv file for ${VAR} interpolation")
    validate.add_argument("--container", help="docker container name for startup capture")
    validate.add_argument("--timeout", type=float, default=10.0, help="probe timeout seconds")
    validate.set_defaults(func=cmd_validate)

    diff = sub.add_parser("diff", help="diff two diagnostic manifests")
    diff.add_argument("prev", help="previous diagnostic-manifest.json")
    diff.add_argument("curr", help="current diagnostic-manifest.json")
    diff.set_defaults(func=cmd_diff)

    # Default command: validate with flat flags for wrapper convenience.
    parser.add_argument("--case-path", dest="case_path_flat", help=argparse.SUPPRESS)
    parser.add_argument("--host", dest="host_flat", help=argparse.SUPPRESS)
    parser.add_argument("--env-file", dest="env_file_flat", help=argparse.SUPPRESS)
    parser.add_argument("--container", dest="container_flat", help=argparse.SUPPRESS)
    parser.add_argument("--timeout", dest="timeout_flat", type=float, help=argparse.SUPPRESS)
    parser.add_argument("--diff", dest="diff_prev", metavar="PREV_MANIFEST", help=argparse.SUPPRESS)
    parser.add_argument("diff_curr", nargs="?", help=argparse.SUPPRESS)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.diff_prev:
        args.prev = args.diff_prev
        args.curr = args.diff_curr or ""
        if not args.curr:
            print("error: --diff requires current manifest path", file=sys.stderr)
            return 2
        return cmd_diff(args)

    if args.command is None:
        # Flat invocation: validate-case --host localhost
        ns = argparse.Namespace(
            case_path=args.case_path_flat or os.environ.get("CASE_PATH"),
            host=args.host_flat,
            env_file=args.env_file_flat,
            container=args.container_flat,
            timeout=args.timeout_flat or 10.0,
        )
        return cmd_validate(ns)

    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
