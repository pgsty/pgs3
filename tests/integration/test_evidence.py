#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock


HELPER = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "evidence.py"
CLIENT_CASES = Path(__file__).with_name("client_cases.sh")
SPEC = importlib.util.spec_from_file_location("pgs3_evidence", HELPER)
assert SPEC and SPEC.loader
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class RedactionTests(unittest.TestCase):
    def test_literal_credentials_and_sigv4_fields_are_redacted(self) -> None:
        environment = {
            "PGS3_ACCESS_KEY_A": "PGS3AACCESSKEY0001",
            "PGS3_SECRET_A": "fixed-test-secret-a",
        }
        sample = "\n".join(
            (
                "Authorization: AWS4-HMAC-SHA256 Credential=PGS3AACCESSKEY0001/x, Signature=deadbeef",
                "https://example/?X-Amz-Credential=PGS3AACCESSKEY0001%2Fx&X-Amz-Signature=deadbeef",
                "AWS_ACCESS_KEY_ID=PGS3AACCESSKEY0001 AWS_SECRET_ACCESS_KEY=fixed-test-secret-a",
                '{"AccessKeyId":"AKIAIOSFODNN7EXAMPLE","SecretAccessKey":"hidden","SessionToken":"token"}',
            )
        )
        with mock.patch.dict(os.environ, environment, clear=False):
            redacted = evidence.redact(sample)
        for forbidden in (
            "PGS3AACCESSKEY0001",
            "fixed-test-secret-a",
            "deadbeef",
            "AKIAIOSFODNN7EXAMPLE",
            '"hidden"',
            '"token"',
        ):
            self.assertNotIn(forbidden, redacted)
        self.assertIn("Authorization: [REDACTED]", redacted)

    def test_manifest_command_uses_the_same_redactor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            manifest = {
                "steps": [],
            }
            evidence.save_manifest(run_dir / "manifest.json", manifest)
            arguments = types.SimpleNamespace(
                run_dir=str(run_dir),
                name="secret-command",
                status="FAIL",
                exit_status=1,
                started_at="2026-01-01T00:00:00Z",
                finished_at="2026-01-01T00:00:01Z",
                command="curl -H 'Authorization: secret material' 'http://x/?X-Amz-Signature=abc'",
                command_file=None,
                output="steps/001.log",
            )
            evidence.command_record(arguments)
            stored = json.loads((run_dir / "manifest.json").read_text())
            command = stored["steps"][0]["command"]
            self.assertNotIn("secret material", command)
            self.assertNotIn("Signature=abc", command)


class WorkspaceDigestTests(unittest.TestCase):
    def test_python_cache_does_not_change_source_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            source = repository / "probe.py"
            source.write_text("value = 1\n")
            cache = repository / "__pycache__"
            cache.mkdir()
            compiled = cache / "probe.cpython-314.pyc"
            compiled.write_bytes(b"first generated cache")
            first = evidence.workspace_digest(repository)[2]
            compiled.write_bytes(b"different generated cache")
            second = evidence.workspace_digest(repository)[2]
            self.assertEqual(first, second)
            source.write_text("value = 2\n")
            third = evidence.workspace_digest(repository)[2]
            self.assertNotEqual(first, third)


class ShellEvidenceTests(unittest.TestCase):
    def test_step_cannot_hide_an_early_failed_assertion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repo"
            repository.mkdir()
            environment = os.environ.copy()
            environment["PGS3_TEST_EVIDENCE_LIB"] = str(
                HELPER.with_name("evidence.sh")
            )
            environment["PGS3_TEST_EVIDENCE_REPO"] = str(repository)
            script = r"""
set -Eeuo pipefail
source "$PGS3_TEST_EVIDENCE_LIB"
evidence_init "$PGS3_TEST_EVIDENCE_REPO" assertion-test 17 assertion-test
PGS3_TEST_STEP_STATE=before
false_then_true() {
    PGS3_TEST_STEP_STATE=changed
    false
    PGS3_TEST_STEP_STATE=incorrectly-continued
    printf 'this command must not hide the failed assertion\n'
}
set +e
evidence_run hidden-assertion false_then_true
rc=$?
set -e
if ((rc == 0)); then
    printf 'evidence_run incorrectly passed\n' >&2
    exit 99
fi
if [[ $PGS3_TEST_STEP_STATE != changed ]]; then
    printf 'step state was lost or execution continued: %s\n' "$PGS3_TEST_STEP_STATE" >&2
    exit 98
fi
start_async_failure() {
    (sleep 0.05; false) &
    PGS3_TEST_ASYNC_PID=$!
}
evidence_run async-start start_async_failure
set +e
wait "$PGS3_TEST_ASYNC_PID"
async_rc=$?
set -e
if ((async_rc == 0)); then
    printf 'inherited evidence trap hid asynchronous failure\n' >&2
    exit 97
fi
python3 - "$PGS3_RUN_DIR/manifest.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as stream:
    manifest = json.load(stream)
step = next(step for step in manifest['steps'] if step['name'] == 'hidden-assertion')
assert step['status'] == 'FAIL', step
assert step['exit_status'] != 0, step
PY
evidence_cleanup
"""
            completed = subprocess.run(
                ["bash", "-c", script],
                cwd=HELPER.parents[2],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout)


class ClientCaseHarnessTests(unittest.TestCase):
    def test_command_trace_does_not_contaminate_redirectable_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bin_dir = Path(temporary)
            for name in ("aws", "rclone", "python", "s3fs", "vim"):
                executable = bin_dir / name
                executable.write_text(
                    f"#!/bin/sh\nprintf 'tool={name}\\n'\n", encoding="utf-8"
                )
                executable.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": str(bin_dir),
                    "PGS3_ENDPOINT": "http://127.0.0.1:1",
                    "PGS3_TEST_BUCKET": "stdout-selftest",
                }
            )
            completed = subprocess.run(
                ["/bin/bash", str(CLIENT_CASES), "versions"],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("+ ", completed.stdout)
            self.assertEqual(completed.stdout.count("tool="), 5)
            self.assertEqual(completed.stderr.count("+ "), 5)


if __name__ == "__main__":
    unittest.main()
