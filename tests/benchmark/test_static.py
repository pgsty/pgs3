#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / "tests" / "benchmark"


class StaticPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = (BENCH / "run.sh").read_text(encoding="utf-8")
        cls.harness = (BENCH / "harness_lib.sh").read_text(encoding="utf-8")
        cls.client = (BENCH / "benchmark.py").read_text(encoding="utf-8")
        cls.environment = (BENCH / "environment.py").read_text(encoding="utf-8")

    def test_static_only_exits_before_any_docker_requirement(self) -> None:
        static = self.runner.index("if ((static_only)); then")
        docker = self.runner.index("bench_require_command docker")
        self.assertLess(static, docker)
        self.assertIn("benchmark_suite=http-benchmark-static", self.runner)

    def test_minio_default_is_immutable_digest(self) -> None:
        match = re.search(r"minio_image=\$\{PGS3_BENCH_MINIO_IMAGE:-([^}]+)\}", self.runner)
        self.assertIsNotNone(match)
        self.assertRegex(match.group(1), r"@sha256:[0-9a-f]{64}$")
        self.assertIn("PGS3_BENCH_MINIO_IMAGE must be immutable", self.runner)

    def test_runtime_never_pulls_and_does_not_prune(self) -> None:
        combined = self.runner + self.harness
        self.assertGreaterEqual(combined.count("--pull never"), 5)
        for forbidden in (
            "docker system prune",
            "docker container prune",
            "docker network prune",
            "docker volume prune",
            "--pull always",
            "/var/run/docker.sock",
        ):
            self.assertNotIn(forbidden, combined)

    def test_cleanup_validates_labels_for_every_resource_kind(self) -> None:
        # Five creations (network, two volumes, two containers) plus one label
        # check for each resource kind.
        self.assertGreaterEqual(self.harness.count("pgs3.benchmark.run"), 8)
        self.assertIn("refusing to remove container with unexpected benchmark label", self.harness)
        self.assertIn("refusing to remove volume with unexpected benchmark label", self.harness)
        self.assertIn("refusing to remove network with unexpected benchmark label", self.harness)
        self.assertNotIn("rm -rf", self.harness)

    def test_environment_evidence_omits_container_env(self) -> None:
        self.assertIn("Config.Env is deliberately omitted", self.environment)
        self.assertNotIn('"env": config.get("Env")', self.environment)
        self.assertIn('"power_loss_protected_nvme": "NOT_VERIFIED"', self.environment)
        self.assertIn('"normalization_applied": False', self.environment)

    def test_smoke_profile_is_hard_not_run_for_acceptance(self) -> None:
        self.assertIn('"status": "NOT_RUN"', self.client)
        self.assertIn("smoke profile cannot satisfy acceptance requirements", self.client)
        self.assertIn("acceptance size sweep must remain fixed", self.client)

    def test_raw_and_summary_artifacts_are_explicit(self) -> None:
        self.assertIn('raw_path = output / "raw-samples.jsonl"', self.client)
        self.assertIn('summary_path = output / "summary.json"', self.client)
        self.assertIn('"percentile_method": "nearest-rank', self.client)
        self.assertIn('"request_retries": 0', self.client)
        self.assertIn("to avoid content-addressed deduplication bias", self.client)

    def test_acceptance_thresholds_are_literal_and_strict(self) -> None:
        self.assertIn('"12_get_small_p50_ms": 0.5', self.client)
        self.assertIn('"12_get_small_ops_per_second": 30_000.0', self.client)
        self.assertIn('"13_put_small_ops_per_second": 5_000.0', self.client)
        self.assertIn('"14_put_8mib_mib_per_second": 150.0', self.client)
        self.assertIn('max_get_p50 < THRESHOLDS["12_get_small_p50_ms"]', self.client)

    def test_evidence_run_is_not_used_as_a_shell_condition(self) -> None:
        combined = self.runner + self.harness
        self.assertIsNone(re.search(r"(?:if|while)\s+evidence_run\b", combined))


if __name__ == "__main__":
    unittest.main()
