from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "tests" / "reliability" / "run.sh"
HARNESS = REPO / "tests" / "reliability" / "harness_lib.sh"
SCENARIOS = REPO / "tests" / "reliability" / "scenarios.sh"
SHELL_SOURCES = tuple(sorted((REPO / "scripts").rglob("*.sh"))) + tuple(
    sorted((REPO / "tests").rglob("*.sh"))
)


def shell_structure(source: str) -> str:
    """Erase quoted text and comments while preserving source line numbers."""

    quoted = re.compile(r"'(?:[^']*)'|\"(?:\\.|[^\"\\])*\"", re.DOTALL)

    def erase(match: re.Match[str]) -> str:
        return "".join("\n" if character == "\n" else " " for character in match.group())

    source = quoted.sub(erase, source)
    return re.sub(r"(?m)(?<!\\)#.*$", "", source)


class HarnessSafetyTests(unittest.TestCase):
    def test_runtime_entrypoint_has_cleanup_trap(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("trap rel_cleanup EXIT INT TERM", source)

    def test_resources_are_labeled_and_checked_before_removal(self) -> None:
        source = HARNESS.read_text(encoding="utf-8")
        self.assertGreaterEqual(source.count("pgs3.reliability.run"), 5)
        self.assertIn("refusing to remove container with unexpected label", source)
        self.assertIn("refusing to remove volume with unexpected label", source)
        self.assertIn("refusing to remove network with unexpected label", source)

    def test_no_broad_docker_or_filesystem_cleanup(self) -> None:
        combined = "\n".join(
            path.read_text(encoding="utf-8") for path in (RUNNER, HARNESS, SCENARIOS)
        )
        forbidden = (
            "docker system prune",
            "docker volume prune",
            "docker network prune",
            "rm -rf /",
            "rm -rf ~",
            "rm -rf $HOME",
        )
        for command in forbidden:
            with self.subTest(command=command):
                self.assertNotIn(command, combined)

    def test_secrets_are_passed_by_environment_name(self) -> None:
        source = HARNESS.read_text(encoding="utf-8")
        self.assertIn("--env PGS3_TEST_SECRET_A", source)
        self.assertNotRegex(source, re.compile(r"--env\s+PGS3_TEST_SECRET_A="))
        self.assertIn("PGS3_REDACT_ENV_NAMES", source)
        self.assertIn("final-redaction-audit", source)

    def test_runtime_assertions_are_not_softened(self) -> None:
        source = SCENARIOS.read_text(encoding="utf-8")
        self.assertIn("docker kill --signal=KILL", source)
        self.assertIn("lease_expires_at = clock_timestamp() - interval '1 minute'", source)
        self.assertIn("((elapsed < 5000))", source)
        self.assertIn("--status 503 --code ServiceUnavailable", source)
        self.assertIn("--status 503 --code SlowDown", source)
        self.assertNotIn("|| echo PASS", source)

    def test_fast_stop_distinguishes_namespace_teardown_from_timeout(self) -> None:
        source = SCENARIOS.read_text(encoding="utf-8")
        self.assertIn("timeout --signal=TERM 7s docker exec", source)
        self.assertNotIn("timeout --signal=KILL 7s docker run", source)
        self.assertRegex(source, re.compile(r"\n\s*124\)"))
        self.assertRegex(source, re.compile(r"\n\s*137\)"))
        self.assertIn("[[ ${wait_status} == 0 ]]", source)
        self.assertIn("[[ ${state} == 'exited|0|false|' ]]", source)
        self.assertIn("fast shutdown request log count", source)
        self.assertIn("clean shutdown log count", source)

    def test_reload_checks_the_container_listener_not_the_host_proxy(self) -> None:
        harness = HARNESS.read_text(encoding="utf-8")
        scenarios = SCENARIOS.read_text(encoding="utf-8")
        self.assertIn("rel_wait_container_listener_gone", harness)
        self.assertIn("/proc/net/tcp", harness)
        self.assertIn("reload-old-listener-gone", scenarios)
        self.assertNotIn("reload-old-port-closed", scenarios)
        self.assertIn("pg_sleep(30)", scenarios)
        self.assertIn("pg_cancel_backend", scenarios)
        self.assertNotIn("pg_sleep(4)", scenarios)

    def test_evidence_run_is_never_used_as_a_conditional_command(self) -> None:
        continuation = r"(?:[^;\n]|\\\n)"
        forbidden = re.compile(
            rf"""
            ^[ \t]*(?:if|elif|while|until)(?:[ \t]|\\\n)+!?
                (?:[ \t]|\\\n)*evidence_run\b
            |(?:^|[;(|&])[ \t]*!(?:[ \t]|\\\n)*evidence_run\b
            |\bevidence_run\b{continuation}*(?:&&|\|\|)
            |(?:&&|\|\|)(?:[ \t\n]|\\\n)*evidence_run\b
            """,
            re.MULTILINE | re.VERBOSE,
        )
        violations: list[str] = []
        for path in SHELL_SOURCES:
            source = path.read_text(encoding="utf-8")
            structure = shell_structure(source)
            for match in forbidden.finditer(structure):
                line = structure.count("\n", 0, match.start()) + 1
                violations.append(f"{path.relative_to(REPO)}:{line}")
        self.assertEqual(
            violations,
            [],
            "evidence_run must be a simple command; use evidence_try and "
            f"PGS3_EVIDENCE_LAST_RC instead: {', '.join(violations)}",
        )

if __name__ == "__main__":
    unittest.main()
