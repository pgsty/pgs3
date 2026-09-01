#!/usr/bin/env python3
"""Offline source-policy tests for the local robustness harness."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


ROBUST_DIR = Path(__file__).resolve().parent
RUN = (ROBUST_DIR / "run.sh").read_text()
HARNESS = (ROBUST_DIR / "harness_lib.sh").read_text()
CLIENT = (ROBUST_DIR / "http_boundary.py").read_text()
ALL_SOURCE = "\n".join((RUN, HARNESS, CLIENT))


class EntrypointPolicyTests(unittest.TestCase):
    def test_exit_trap_and_evidence_helper_are_mandatory(self) -> None:
        self.assertIn('source "${repo_dir}/scripts/lib/evidence.sh"', HARNESS)
        self.assertIn("trap robust_cleanup EXIT INT TERM", RUN)
        self.assertIn("evidence_init", RUN)
        self.assertIn("evidence_finalize", HARNESS)
        self.assertIn("robustness-final-redaction-audit", HARNESS)

    def test_static_only_is_offline_and_precedes_all_runtime_work(self) -> None:
        static_exit = RUN.index(
            "if ((static_only)); then\n    ROBUST_RESULT=PASS\n    exit 0\nfi"
        )
        self.assertLess(static_exit, RUN.index("robust_require_command docker"))
        self.assertLess(static_exit, RUN.index("robustness-server-image-inspect"))
        self.assertLess(static_exit, RUN.index("robust_init_runtime"))
        prefix = RUN[:static_exit]
        self.assertNotIn("docker ", prefix)
        self.assertIn("robustness-bash-syntax", prefix)
        self.assertIn("robustness-python-compile", prefix)
        self.assertIn("robustness-offline-tests", prefix)
        self.assertIn("robustness-corpus-description", prefix)

    def test_runtime_has_no_user_supplied_target_or_discovery_option(self) -> None:
        parser = RUN[RUN.index("while (($#))") : RUN.index("case ${pg_major}")]
        self.assertNotIn("--endpoint)", parser)
        self.assertNotIn("--host)", parser)
        self.assertNotIn("--target)", parser)
        self.assertNotIn("--cidr)", parser)
        self.assertIn("There is no target option, discovery, or scan.", RUN)
        self.assertNotIn("build-images.sh", RUN)
        self.assertNotIn("docker build", ALL_SOURCE)
        self.assertNotIn("docker pull", ALL_SOURCE)


class DockerScopeAndCleanupTests(unittest.TestCase):
    def test_container_is_created_by_the_harness_and_only_loopback_is_published(self) -> None:
        self.assertIn("docker run --detach", HARNESS)
        self.assertIn("--pull never", HARNESS)
        self.assertIn('--publish "127.0.0.1:${ROBUST_HOST_PORT}:9000/tcp"', HARNESS)
        self.assertIn('--name "${ROBUST_CONTAINER}"', HARNESS)
        self.assertIn('--restart no', HARNESS)
        self.assertIn('listener.bind(("127.0.0.1", 0))', HARNESS)

    def test_runtime_network_is_dedicated_and_run_labeled(self) -> None:
        self.assertIn("docker network create \\\n        --label", HARNESS)
        self.assertGreaterEqual(
            HARNESS.count('pgs3.robustness.run=${ROBUST_RUN_TAG}'), 2
        )
        self.assertIn('{{.Internal}}|{{index .Labels "pgs3.robustness.run"}}', HARNESS)
        self.assertIn('[[ ${network_scope} == "false|${ROBUST_RUN_TAG}" ]]', HARNESS)

    def test_cleanup_checks_labels_before_exact_resource_removal(self) -> None:
        self.assertIn("robust_safe_remove_container", HARNESS)
        self.assertIn("robust_safe_remove_network", HARNESS)
        self.assertIn(
            'label=$(docker container inspect "${ROBUST_CONTAINER}"', HARNESS
        )
        self.assertIn('label=$(docker network inspect "${ROBUST_NETWORK}"', HARNESS)
        self.assertIn(
            "refusing to remove container with unexpected robustness label", HARNESS
        )
        self.assertIn(
            "refusing to remove network with unexpected robustness label", HARNESS
        )
        self.assertIn(
            'docker rm --force --volumes \\\n        "${ROBUST_CONTAINER}"', HARNESS
        )
        self.assertIn('docker network rm "${ROBUST_NETWORK}"', HARNESS)

    def test_no_broad_docker_or_filesystem_cleanup(self) -> None:
        forbidden = (
            "docker system prune",
            "docker container prune",
            "docker network prune",
            "docker volume prune",
            "docker rm $(",
            "docker rm -f $(",
        )
        for token in forbidden:
            with self.subTest(token=token):
                self.assertNotIn(token, ALL_SOURCE)
        self.assertEqual(HARNESS.count("rm -rf --"), 1)
        guard = HARNESS.index('"${TMPDIR:-/tmp}"/pgs3-robustness.*)')
        removal = HARNESS.index('rm -rf -- "${ROBUST_TMP_DIR}"')
        self.assertLess(guard, removal)


class NetworkAndBoundaryPolicyTests(unittest.TestCase):
    def test_client_socket_target_is_literal_loopback(self) -> None:
        self.assertIn(
            '("127.0.0.1", client.port), timeout=_remaining(deadline)', CLIENT
        )
        self.assertIn('parsed.hostname != "127.0.0.1"', CLIENT)
        self.assertIn(
            '"endpoint must be an explicit http://127.0.0.1:PORT origin"', CLIENT
        )
        self.assertNotIn("getaddrinfo", CLIENT)
        self.assertNotIn("gethostbyname", CLIENT)
        self.assertNotIn("boundary.invalid", CLIENT)

    def test_no_scanner_or_external_fetch_primitive_exists(self) -> None:
        forbidden_commands = ("curl", "wget", "nmap", "masscan", "nikto", "ffuf")
        for command in forbidden_commands:
            with self.subTest(command=command):
                self.assertIsNone(
                    re.search(rf"(?m)(?:^|[;&|\s]){command}(?:\s|$)", ALL_SOURCE)
                )
        urls = re.findall(r"https?://[^\s`'\"<>]+", ALL_SOURCE)
        self.assertTrue(urls)
        self.assertTrue(
            all(url.startswith("http://127.0.0.1:") for url in urls), urls
        )

    def test_corpus_and_wire_io_are_strictly_bounded(self) -> None:
        self.assertIn('FIXED_SEED = "pgs3-http-boundary-v1"', CLIENT)
        self.assertIn("CASE_TIMEOUT_SECONDS = 2.0", CLIENT)
        self.assertIn("MAX_RENDERED_REQUEST_BYTES = 96 * 1024", CLIENT)
        self.assertIn("MAX_RESPONSE_BYTES = 128 * 1024", CLIENT)
        self.assertIn("sock.settimeout(_remaining(deadline))", CLIENT)
        self.assertIn("if len(response) > MAX_RESPONSE_BYTES", CLIENT)
        self.assertNotIn("import random", CLIENT)


class RuntimeInvariantPolicyTests(unittest.TestCase):
    def test_baseline_captures_start_time_worker_counts_and_pid_set(self) -> None:
        self.assertIn("pg_postmaster_start_time()", HARNESS)
        self.assertIn("ROBUST_BASE_POSTMASTER_START", HARNESS)
        self.assertIn("ROBUST_BASE_HTTP_ACTIVITY", HARNESS)
        self.assertIn("ROBUST_BASE_HTTP_DESIRED", HARNESS)
        self.assertIn("ROBUST_BASE_WORKER_PIDS", HARNESS)
        self.assertIn("backend_type = 'pgs3 http'", HARNESS)
        self.assertIn('[[ ${active} == "${ROBUST_BASE_HTTP_ACTIVITY}" ]]', HARNESS)
        self.assertIn('[[ ${desired} == "${ROBUST_BASE_HTTP_DESIRED}" ]]', HARNESS)
        self.assertIn('[[ ${pids} == "${ROBUST_BASE_WORKER_PIDS}" ]]', HARNESS)

    def test_every_fixed_group_is_followed_by_signed_probe_and_runtime_check(self) -> None:
        self.assertIn(
            "ROBUST_BATCHES=(request-head message-body chunked-body)", RUN
        )
        loop = RUN[RUN.index('for batch in "${ROBUST_BATCHES[@]}"') :]
        malformed = loop.index('robust_run_batch "${batch}"')
        legal = loop.index('robust_probe_sentinel', malformed)
        invariant = loop.index('robust_assert_runtime', legal)
        self.assertLess(malformed, legal)
        self.assertLess(legal, invariant)
        self.assertIn('"robustness-legal-after-${batch}"', loop)
        self.assertIn('"robustness-runtime-after-${batch}"', loop)


if __name__ == "__main__":
    unittest.main()
