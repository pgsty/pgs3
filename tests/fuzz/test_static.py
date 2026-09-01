from __future__ import annotations

from pathlib import Path
import unittest


FUZZ_DIR = Path(__file__).resolve().parent
RUNNER = FUZZ_DIR / "run.sh"
HARNESS = FUZZ_DIR / "harness_lib.sh"
CLIENT = FUZZ_DIR / "malformed_client.py"


class HarnessSafetyTests(unittest.TestCase):
    def test_runtime_entrypoint_has_cleanup_trap(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("trap fuzz_cleanup EXIT INT TERM", source)

    def test_resources_are_labeled_and_verified_before_removal(self) -> None:
        source = HARNESS.read_text(encoding="utf-8")
        # The runtime owns exactly two Docker resources: one container and one
        # network. Each is labeled at creation and its label is read back
        # before removal, so four independent references are required.
        self.assertGreaterEqual(source.count("pgs3.fuzz.run"), 4)
        self.assertIn("refusing to remove container with unexpected fuzz label", source)
        self.assertIn("refusing to remove network with unexpected fuzz label", source)

    def test_no_broad_docker_or_filesystem_cleanup(self) -> None:
        combined = "\n".join(
            path.read_text(encoding="utf-8") for path in (RUNNER, HARNESS)
        )
        for forbidden in (
            "docker system prune",
            "docker volume prune",
            "docker network prune",
            "rm -rf /",
            "rm -rf ~",
            "rm -rf $HOME",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, combined)

    def test_credentials_are_environment_only_and_audited(self) -> None:
        source = HARNESS.read_text(encoding="utf-8")
        self.assertIn("--env PGS3_FUZZ_SECRET", source)
        self.assertNotIn("--env PGS3_FUZZ_SECRET=", source)
        self.assertIn("PGS3_REDACT_ENV_NAMES", source)
        self.assertIn("fuzz-final-redaction-audit", source)

    def test_runtime_identity_is_exact_not_only_a_worker_count(self) -> None:
        harness = HARNESS.read_text(encoding="utf-8")
        runner = RUNNER.read_text(encoding="utf-8")
        self.assertIn("pg_postmaster_start_time()", harness)
        self.assertIn("FUZZ_BASE_POSTMASTER_START", harness)
        self.assertIn("FUZZ_BASE_WORKER_PIDS", harness)
        self.assertIn("[[ ${pids} == \"${FUZZ_BASE_WORKER_PIDS}\" ]]", harness)
        self.assertIn("/proc/${pid}/stat", harness)
        self.assertIn("fuzz-runtime-before-${case_name}", runner)
        self.assertIn("fuzz-runtime-after-${case_name}", runner)
        self.assertIn("fuzz_run_case", runner)

    def test_corpus_has_hard_time_and_size_limits(self) -> None:
        source = CLIENT.read_text(encoding="utf-8")
        self.assertIn("MAX_CASE_TIMEOUT_SECONDS = 10.0", source)
        self.assertIn("MAX_REQUEST_BYTES = 128 * 1024", source)
        self.assertIn("MAX_RESPONSE_BYTES = 128 * 1024", source)
        self.assertIn("DEFAULT_SEED = \"pgs3-acceptance-9-v1\"", source)
        self.assertIn("server did not close or respond before the case deadline", source)

    def test_every_case_performs_a_legal_sentinel_probe(self) -> None:
        source = CLIENT.read_text(encoding="utf-8")
        self.assertIn("outcome = send_case", source)
        self.assertIn("probe_sentinel(client, bucket, key, arguments.seed)", source)
        self.assertIn('"legal_sentinel": "PASS"', source)


if __name__ == "__main__":
    unittest.main()
