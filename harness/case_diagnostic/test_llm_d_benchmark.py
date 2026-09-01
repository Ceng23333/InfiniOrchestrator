from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from adapters.llm_d_benchmark.manifest_map import build_bench_block, update_manifest
from adapters.llm_d_benchmark.profile import load_profile
from adapters.llm_d_benchmark.runner import _metrics, run_upstream


class AdapterTests(unittest.TestCase):
    def test_profile_is_bounded(self) -> None:
        profile = load_profile(
            Path(__file__).parents[1]
            / "adapters/llm_d_benchmark/profiles/m1_http_smoke.yaml"
        )
        self.assertEqual(profile.requests, 10)
        self.assertEqual(profile.concurrency, 2)
        self.assertLessEqual(profile.requests, 1000)

    def test_metrics_include_core_fields(self) -> None:
        result = _metrics(
            [
                {"ok": True, "latency_ms": 10, "ttft_ms": 4, "chunks": 3},
                {"ok": False, "latency_ms": 20},
            ],
            1.0,
        )
        self.assertEqual(result["requests_total"], 2)
        self.assertEqual(result["requests_ok"], 1)
        self.assertEqual(result["requests_error"], 1)
        self.assertIn("latency_p99_ms", result)
        self.assertIn("ttft_p50_ms", result)

    def test_manifest_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "diagnostic-manifest.json"
            path.write_text(json.dumps({"topology_fingerprint": "abc"}), encoding="utf-8")
            block = build_bench_block(
                profile="m1_http_smoke",
                client_version="v0.8.0",
                collection_config={"requests": 10},
                base_url="http://127.0.0.1:8800",
                case_path="case.toml",
                topology_fingerprint="abc",
                metrics={"success_rate": 1.0},
                artifacts=["evidence/client/llmd_raw.json"],
                adapter_mode="http",
            )
            update_manifest(path, block)
            manifest = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["bench"]["adapter"], "llm_d_benchmark")
            self.assertEqual(manifest["bench"]["adapter_mode"], "http")

    def test_upstream_command_is_run_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = root / ".venv/bin/llmdbenchmark"
            workload = root / "workload/profiles/vllm-benchmark/sanity_random.yaml"
            executable.parent.mkdir(parents=True)
            workload.parent.mkdir(parents=True)
            executable.touch()
            workload.touch()
            with patch("subprocess.call", return_value=0) as call:
                rc = run_upstream(
                    load_profile(
                        Path(__file__).parents[1]
                        / "adapters/llm_d_benchmark/profiles/m1_http_smoke.yaml"
                    ),
                    root,
                    "http://127.0.0.1:8800",
                    "Qwen3-32B",
                    root / "out",
                    120,
                )
            self.assertEqual(rc, 0)
            command = call.call_args.args[0]
            self.assertEqual(command[1], "run")
            self.assertIn("--endpoint-url", command)
            self.assertNotIn("standup", command)
            self.assertNotIn("teardown", command)


if __name__ == "__main__":
    unittest.main()
