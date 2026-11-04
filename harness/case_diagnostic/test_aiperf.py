from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from adapters.aiperf.profile import load_profile
from adapters.aiperf.runner import command, evaluate, run


PROFILES = Path(__file__).parents[1] / "adapters/aiperf/profiles"


def export(*, requests=3, errors=None, input_max=18050, version="0.13.0"):
    result = {
        "aiperf_version": version,
        "was_cancelled": False,
        "request_count": {"avg": requests},
        "request_latency": {"p95": 2500, "unit": "ms"},
        "time_to_first_token": {"p95": 1000, "unit": "ms"},
        "input_sequence_length": {"max": input_max, "unit": "tokens"},
    }
    if errors is not None:
        result["error_request_count"] = {"avg": errors}
    return result


class AIPerfAdapterTests(unittest.TestCase):
    def test_bounded_profiles_and_trace_formats(self):
        tool = load_profile(PROFILES / "agentic_tool_loop.json")
        long = load_profile(PROFILES / "long_prefix.json")
        self.assertEqual(tool.requests, 3)
        self.assertEqual(tool.concurrency, 1)
        self.assertEqual(long.min_input_tokens, 18050)
        self.assertEqual(long.block_size, 2048)

    def test_rejects_unbounded_profile_and_malformed_trace(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            trace = root / "trace.json"
            trace.write_text('[{"timestamp":0,"input_length":32,"output_length":4}]')
            profile = root / "profile.json"
            profile.write_text(json.dumps({"name": "bad", "trace": "trace.json", "requests": 1000, "concurrency": 1, "timeout_sec": 10}))
            with self.assertRaisesRegex(ValueError, "requests"):
                load_profile(profile)
            profile.write_text(json.dumps({"name": "bad", "trace": "trace.json", "requests": 1, "concurrency": 1, "timeout_sec": 10}))
            trace.write_text('[{"timestamp":0,"tools":[],"input_length":32,"output_length":4}]')
            with self.assertRaisesRegex(ValueError, "tools require messages"):
                load_profile(profile)
            trace.write_text('[{"timestamp":0,"messages":[{"role":"user","content":"hi"}],"hash_ids":[1],"output_length":4}]')
            with self.assertRaisesRegex(ValueError, "hash_ids require input_length"):
                load_profile(profile)

    def test_command_is_run_only_and_deterministic(self):
        profile = load_profile(PROFILES / "long_prefix.json")
        args = command(
            profile, base_url="http://127.0.0.1:8000", model="Qwen",
            artifact_dir=Path("/tmp/ci/aiperf"), input_file=Path("/tmp/ci/input.jsonl"),
            tokenizer="/models/Qwen",
        )
        self.assertEqual(args[:2], ["aiperf", "profile"])
        for flag in ("--streaming", "--no-fixed-schedule", "--request-timeout-seconds", "--isl-block-size", "--tokenizer"):
            self.assertIn(flag, args)
        self.assertEqual(args[args.index("--request-count") + 1], "3")
        self.assertNotIn("standup", args)
        self.assertNotIn("teardown", args)
        with self.assertRaisesRegex(ValueError, "--tokenizer is required"):
            command(profile, base_url="http://localhost:8000", model="Qwen", artifact_dir=Path("out"), input_file=Path("input.jsonl"))
        with self.assertRaisesRegex(ValueError, "without credentials"):
            command(profile, base_url="http://user:password@localhost:8000", model="Qwen", artifact_dir=Path("out"), input_file=Path("input.jsonl"), tokenizer="/models/Qwen")

    def test_export_gates_are_strict(self):
        profile = load_profile(PROFILES / "long_prefix.json")
        metrics, failures = evaluate(profile, export())
        self.assertEqual(failures, [])
        self.assertEqual(metrics["requests_error"], 0)
        _, failures = evaluate(profile, export(requests=2, errors=1, input_max=16000))
        self.assertEqual(len(failures), 3)
        _, failures = evaluate(profile, export(version="0.12.0"))
        self.assertIn("expected AIPerf 0.13.0", failures[0])
        with self.assertRaisesRegex(ValueError, "must be finite"):
            evaluate(profile, {**export(), "request_count": {"avg": float("nan")}})

    def test_optional_latency_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "trace.json").write_text('[{"timestamp":0,"input_length":32,"output_length":4}]')
            (root / "profile.json").write_text(json.dumps({
                "name": "latency", "trace": "trace.json", "requests": 1,
                "concurrency": 1, "timeout_sec": 10,
                "gates": {"max_latency_p95_ms": 2000},
            }))
            _, failures = evaluate(load_profile(root / "profile.json"), export(requests=1))
            self.assertIn("latency_p95_ms missing or above 2000", failures)

    def test_run_writes_artifacts_and_manifest(self):
        profile = load_profile(PROFILES / "agentic_tool_loop.json")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = root / "diagnostic-manifest.json"
            manifest.write_text(json.dumps({"case": {"case_path": "case.toml"}, "topology_fingerprint": "abc", "probes": []}))

            def fake_execute(args, log_path, timeout):
                self.assertGreater(timeout, 90)
                self.assertEqual(args[1], "profile")
                log_path.write_text("mock AIPerf run\n")
                (root / "run/aiperf/profile_export_aiperf.json").write_text(json.dumps(export()))
                return 0

            summary = run(
                profile, base_url="http://localhost:8000", model="Qwen",
                output_dir=root / "run", manifest=manifest, executor=fake_execute,
            )
            self.assertEqual(summary["status"], "pass")
            lines = (root / "run/input.jsonl").read_text().splitlines()
            self.assertEqual(len(lines), 3)
            self.assertIn("tools", json.loads(lines[0]))
            self.assertEqual(json.loads((root / "run/summary.json").read_text())["status"], "pass")
            bench = json.loads(manifest.read_text())["bench"]
            self.assertEqual(bench["adapter"], "aiperf")
            self.assertEqual(bench["topology_fingerprint"], "abc")
            self.assertEqual(bench["status"], "pass")

    def test_missing_export_fails_ci(self):
        profile = load_profile(PROFILES / "agentic_tool_loop.json")
        with tempfile.TemporaryDirectory() as tmp:
            summary = run(
                profile, base_url="http://localhost:8000", model="Qwen",
                output_dir=Path(tmp), executor=lambda args, log, timeout: 0,
            )
            self.assertEqual(summary["status"], "fail")
            self.assertIn("AIPerf JSON export is missing", summary["failures"])

    def test_reused_artifact_directory_is_rejected(self):
        profile = load_profile(PROFILES / "agentic_tool_loop.json")
        with tempfile.TemporaryDirectory() as tmp:
            artifact_dir = Path(tmp) / "aiperf"
            artifact_dir.mkdir()
            (artifact_dir / "profile_export_aiperf.json").write_text(json.dumps(export()))
            with self.assertRaisesRegex(ValueError, "must be empty"):
                run(profile, base_url="http://localhost:8000", model="Qwen", output_dir=Path(tmp))


if __name__ == "__main__":
    unittest.main()
