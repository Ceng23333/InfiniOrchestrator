"""Unit tests for case_diagnostic package."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from case_diagnostic.load import (
    interpolate_url,
    load_case,
    resolve_services,
    validate_identity,
    validate_spec,
    CaseDocument,
    CaseSpec,
    ServiceSpec,
    ProbeSpec,
)
from case_diagnostic.manifest import diff_manifests, topology_fingerprint
from case_diagnostic.probes import ProbeContext, run_probe


FIXTURE_CASE = """
case_id = "test-case"
category = "Standalone"
n = 1
model_id = "m1"
hw_profile_id = "hw1"
hw_abbr = "c550"
be_abbr = "vllm"
worktree = "v2026.08.12"

[spec]
version = "0.1"
topology = "entrypoint_wrap"
host_env = "BENCH_TARGET_HOST"

[[spec.services]]
id = "entrypoint"
role = "entrypoint"
base_url = "http://{host}:18181"
probes = [{ path = "/metadata", kind = "metadata_uuid" }]
"""


class LoadTests(unittest.TestCase):
    def test_interpolate_host_and_env(self) -> None:
        url = interpolate_url(
            "http://{host}:${ROUTER_PORT:-8800}/health",
            "localhost",
            {"ROUTER_PORT": "9000"},
        )
        self.assertEqual(url, "http://localhost:9000/health")

    def test_load_case_valid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            case_dir = Path(tmp) / "Standalone" / "test-case"
            case_dir.mkdir(parents=True)
            case_path = case_dir / "case.toml"
            case_path.write_text(FIXTURE_CASE, encoding="utf-8")
            doc = load_case(case_path)
            self.assertEqual(doc.identity["case_id"], "test-case")
            assert doc.spec is not None
            self.assertEqual(doc.spec.topology, "entrypoint_wrap")
            self.assertEqual(len(doc.spec.services), 1)

    def test_validate_identity_mismatch(self) -> None:
        doc = CaseDocument(
            path=Path("/tmp/Standalone/wrong-name/case.toml"),
            identity={
                "case_id": "test-case",
                "category": "Standalone",
                "n": 1,
                "model_id": "m",
                "hw_profile_id": "h",
                "hw_abbr": "c550",
                "be_abbr": "vllm",
                "worktree": "w",
            },
        )
        errors = validate_identity(doc)
        self.assertTrue(any("directory name" in e for e in errors))

    def test_validate_spec_requires_services(self) -> None:
        spec = CaseSpec(version="0.1", topology="direct", services=[])
        errors = validate_spec(spec)
        self.assertIn("spec.services must not be empty", errors)

    def test_resolve_services(self) -> None:
        spec = CaseSpec(
            version="0.1",
            topology="entrypoint_wrap",
            services=[
                ServiceSpec(
                    id="inf",
                    role="inference",
                    base_url="http://{host}:18180",
                    probes=[ProbeSpec(path="/v1/models", kind="json_snapshot")],
                )
            ],
        )
        resolve_services(spec, "10.0.0.1", {})
        self.assertEqual(spec.services[0].resolved_base_url, "http://10.0.0.1:18180")


class ManifestTests(unittest.TestCase):
    def test_topology_fingerprint_stable(self) -> None:
        spec = CaseSpec(
            version="0.1",
            topology="entrypoint_wrap",
            services=[
                ServiceSpec(
                    id="a",
                    role="entrypoint",
                    base_url="http://h:1",
                    resolved_base_url="http://h:1",
                    probes=[],
                )
            ],
        )
        fp1 = topology_fingerprint(spec)
        fp2 = topology_fingerprint(spec)
        self.assertEqual(fp1, fp2)
        self.assertEqual(len(fp1), 16)

    def test_diff_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev.json"
            curr = Path(tmp) / "curr.json"
            base = {
                "topology_fingerprint": "abc",
                "status": "pass",
                "probes": [
                    {"service_id": "r", "path": "/health", "status": "pass"},
                ],
            }
            prev.write_text(json.dumps(base), encoding="utf-8")
            changed = dict(base)
            changed["status"] = "fail"
            changed["probes"] = [
                {"service_id": "r", "path": "/health", "status": "fail"},
            ]
            curr.write_text(json.dumps(changed), encoding="utf-8")
            out = diff_manifests(prev, curr)
            self.assertIn("pass -> fail", out)
            self.assertIn("r:/health", out)


class ProbeTests(unittest.TestCase):
    def test_metadata_uuid_fail_on_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            run_root = Path(tmp)
            dirs = {"evidence": run_root / "evidence"}
            dirs["evidence"].mkdir(parents=True)
            svc = ServiceSpec(
                id="ep",
                role="entrypoint",
                resolved_base_url="http://127.0.0.1:9",
                probes=[],
            )
            probe = ProbeSpec(path="/metadata", kind="metadata_uuid")
            ctx = ProbeContext(run_root=run_root, evidence_dirs=dirs, timeout=0.1)
            # Unreachable host -> fail with message
            result = run_probe(svc, probe, ctx)
            self.assertEqual(result.status, "fail")
            self.assertEqual(result.category, "backend_readiness")


if __name__ == "__main__":
    unittest.main()
