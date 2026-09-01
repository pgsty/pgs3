#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import copy
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


selection = load_module("pgs3_ceph_selection", HERE / "selection.py")
summarize = load_module("pgs3_ceph_summarize", HERE / "summarize.py")
write_config = load_module("pgs3_ceph_config", HERE / "write_config.py")


class SelectionTests(unittest.TestCase):
    def test_committed_selection_is_large_and_unique(self) -> None:
        document = selection.load_json(HERE / "selection.json")
        cases = selection.flatten(document)
        self.assertEqual(document["schema"], "pgs3.ceph-s3-tests.selection.v2")
        self.assertEqual(len(cases), 195)
        self.assertEqual(len(cases), len({case["nodeid"] for case in cases}))
        self.assertEqual(
            document["upstream"]["commit"],
            "5522d1c351f75bc00ae0f64f742f3f095f5939d9",
        )
        self.assertIn("always_enabled_versioning", document["adapters"])
        self.assertIn("pure_python_negative_expiry_signer", document["adapters"])
        self.assertEqual(len(document["excluded_cases"]), 14)
        self.assertEqual(document["candidate_audit"]["candidate_count"], 209)
        self.assertEqual(document["gates"]["minimum_selected"], 195)
        self.assertEqual(document["gates"]["minimum_executed"], 150)
        self.assertEqual(document["gates"]["minimum_passed"], 150)
        self.assertFalse(document["gates"]["allow_failures"])
        self.assertFalse(document["gates"]["allow_errors"])
        self.assertFalse(document["gates"]["allow_skips"])
        self.assertFalse(document["gates"]["allow_not_run"])

    def test_exact_source_justified_exclusions_are_recorded(self) -> None:
        document = selection.load_json(HERE / "selection.json")
        excluded = document["excluded_cases"]
        expected = {
            "test_bucket_list_unordered",
            "test_bucket_listv2_unordered",
            "test_bucket_list_return_data",
            "test_bucket_list_return_data_versioning",
            "test_put_object_ifmatch_overwrite_existed_good",
            "test_put_object_ifmatch_nonexisted_failed",
            "test_put_object_ifnonmatch_good",
            "test_put_object_ifnonmatch_failed",
            "test_object_copy_not_owned_bucket",
            "test_bucket_get_location",
            "test_multipart_upload_small",
            "test_multipart_upload",
            "test_multipart_resend_first_finishes_last",
            "test_multipart_reupload_checksum_and_etag",
        }
        self.assertEqual({nodeid.rsplit("::", 1)[1] for nodeid in excluded}, expected)
        for definition in excluded.values():
            self.assertIn(definition["first_run_status"], {"FAIL", "ERROR"})
            self.assertTrue(definition["reason"])
            self.assertTrue(definition["source_contains"])
            self.assertIn(definition["class"], document["excluded_classes"])
        first_run_statuses = [
            definition["first_run_status"] for definition in excluded.values()
        ]
        self.assertEqual(first_run_statuses.count("FAIL"), 10)
        self.assertEqual(first_run_statuses.count("ERROR"), 4)
        selected = {case["nodeid"] for case in selection.flatten(document)}
        self.assertFalse(selected.intersection(excluded))
        self.assertIn(
            "s3tests/functional/test_s3.py::test_object_raw_put_authenticated_expired",
            selected,
        )
        self.assertIn(
            "s3tests/functional/test_s3.py::test_multipart_checksum_sha256",
            selected,
        )

    def test_negative_expiry_case_uses_the_pure_python_signer(self) -> None:
        runtime = (HERE / "container_run.sh").read_text(encoding="utf-8")
        collection = (HERE / "collect-only.sh").read_text(encoding="utf-8")
        selftest = (HERE / "adapter_selftest.py").read_text(encoding="utf-8")
        self.assertIn("export BOTO_DISABLE_CRT=true", runtime)
        self.assertGreaterEqual(collection.count("--env BOTO_DISABLE_CRT=true"), 2)
        self.assertIn('ExpiresIn=-1000', selftest)
        self.assertIn('query["X-Amz-Expires"] == ["-1000"]', selftest)

    def test_candidate_audit_arithmetic_cannot_drift(self) -> None:
        document = selection.load_json(HERE / "selection.json")
        cases = selection.flatten(document)
        selection.validate_candidate_audit(document, len(cases), document["excluded_cases"])
        changed = copy.deepcopy(document)
        changed["candidate_audit"]["first_run"]["retained_counts"]["failed"] -= 1
        with self.assertRaises(selection.SelectionError):
            selection.validate_candidate_audit(
                changed, len(cases), changed["excluded_cases"]
            )

    def test_historical_first_run_remains_failing_after_honest_exclusions(self) -> None:
        document = selection.load_json(HERE / "selection.json")
        cases = selection.flatten(document)
        retained_statuses = ["PASS"] * 133 + ["FAIL"] * 29 + ["ERROR"] * 33
        historical_cases = [
            {"nodeid": case["nodeid"], "status": status}
            for case, status in zip(cases, retained_statuses, strict=True)
        ]
        historical_cases.extend(
            {"nodeid": nodeid, "status": definition["first_run_status"]}
            for nodeid, definition in document["excluded_cases"].items()
        )
        report = selection.audit_historical_results(
            document,
            cases,
            {
                "upstream": document["upstream"],
                "cases": historical_cases,
            },
        )
        self.assertEqual(report["result"], "PASS")
        self.assertEqual(report["selected_count"], 195)
        self.assertEqual(report["excluded_count"], 14)
        self.assertEqual(report["retained_counts"]["passed"], 133)
        self.assertEqual(report["retained_counts"]["failed"], 29)
        self.assertEqual(report["retained_counts"]["errors"], 33)

    def test_materialized_manifest_keeps_exclusion_audit(self) -> None:
        document = selection.load_json(HERE / "selection.json")
        cases = selection.flatten(document)
        manifest = selection.materialized_manifest(
            HERE / "selection.json", document, cases
        )
        self.assertEqual(manifest["schema"], "pgs3.ceph-s3-tests.suite-manifest.v2")
        self.assertEqual(manifest["candidate_count"], 209)
        self.assertEqual(manifest["selected_count"], 195)
        self.assertEqual(manifest["excluded_count"], 14)
        self.assertEqual(len(manifest["excluded_cases"]), 14)


class ConfigurationTests(unittest.TestCase):
    def test_config_uses_two_environment_credentials(self) -> None:
        environment = {
            "PGS3_ACCESS_KEY_A": "access-a",
            "PGS3_SECRET_A": "secret-a",
            "PGS3_ACCESS_KEY_B": "access-b",
            "PGS3_SECRET_B": "secret-b",
        }
        with mock.patch.dict(os.environ, environment, clear=False):
            rendered = write_config.render("pgs3-under-test", 9000, "pgs3-ceph-test")
        self.assertIn("access_key = access-a", rendered)
        self.assertIn("access_key = access-b", rendered)
        self.assertIn("host = pgs3-under-test", rendered)
        self.assertIn("api_name = us-east-1", rendered)
        self.assertNotIn("secret_key = access", rendered)


class SummaryTests(unittest.TestCase):
    def test_committed_suite_can_reach_the_150_case_gate(self) -> None:
        document = selection.load_json(HERE / "selection.json")
        cases = selection.flatten(document)
        manifest = selection.materialized_manifest(
            HERE / "selection.json", document, cases
        )
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            manifest_path = temporary / "suite-manifest.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            testcases = "".join(
                f'<testcase classname="s3tests.functional.test_s3" name="{case["nodeid"].rsplit("::", 1)[1]}" time="0" />'
                for case in cases
            )
            junit_path = temporary / "junit.xml"
            junit_path.write_text(
                f'<testsuites><testsuite tests="{len(cases)}">{testcases}</testsuite></testsuites>',
                encoding="utf-8",
            )
            report, status = summarize.summarize(
                self.arguments(manifest_path, junit_path)
            )
        self.assertEqual(status, 0)
        self.assertEqual(report["schema"], "pgs3.ceph-s3-tests.results.v2")
        self.assertEqual(report["candidate_count"], 209)
        self.assertEqual(report["excluded_count"], 14)
        self.assertEqual(report["counts"]["executed"], len(cases))
        self.assertGreaterEqual(report["counts"]["passed"], 150)

    def suite_manifest(self, temporary: Path, *, strict: bool) -> Path:
        cases = []
        for ordinal, name in enumerate(("pass_case", "fail_case", "error_case", "skip_case", "missing_case"), 1):
            cases.append(
                {
                    "ordinal": ordinal,
                    "category": "probe",
                    "requirement": "report every selected case",
                    "nodeid": f"s3tests/functional/test_s3.py::{name}",
                }
            )
        manifest = {
            "selection_sha256": "0" * 64,
            "upstream": {"commit": "1" * 40},
            "gates": {
                "minimum_selected": 5,
                "minimum_executed": 3,
                "minimum_passed": 1,
                "allow_failures": not strict,
                "allow_errors": not strict,
                "allow_skips": not strict,
                "allow_not_run": not strict,
            },
            "cases": cases,
        }
        path = temporary / "suite-manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path

    def junit(self, temporary: Path) -> Path:
        path = temporary / "junit.xml"
        path.write_text(
            """<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite tests="4">
  <testcase classname="s3tests.functional.test_s3" name="pass_case" time="0.1" />
  <testcase classname="s3tests.functional.test_s3" name="fail_case" time="0.2"><failure message="bad">trace</failure></testcase>
  <testcase classname="s3tests.functional.test_s3" name="error_case" time="0.3"><error message="boom" /></testcase>
  <testcase classname="s3tests.functional.test_s3" name="skip_case" time="0"><skipped message="reason" /></testcase>
</testsuite></testsuites>
""",
            encoding="utf-8",
        )
        return path

    def arguments(self, manifest: Path, junit: Path) -> types.SimpleNamespace:
        return types.SimpleNamespace(
            manifest=manifest,
            junit=junit,
            pg_major=17,
            pytest_exit_status=0,
            harness_error=[],
        )

    def test_every_selected_case_gets_an_explicit_outcome(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            report, status = summarize.summarize(
                self.arguments(
                    self.suite_manifest(temporary, strict=False),
                    self.junit(temporary),
                )
            )
        self.assertEqual(status, 0)
        self.assertEqual(report["counts"]["executed"], 3)
        self.assertEqual(report["counts"]["skipped"], 1)
        self.assertEqual(report["counts"]["not_run"], 1)
        self.assertEqual(
            [case["status"] for case in report["cases"]],
            ["PASS", "FAIL", "ERROR", "SKIP", "NOT_RUN"],
        )

    def test_strict_gate_cannot_hide_core_failures_or_skips(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            report, status = summarize.summarize(
                self.arguments(
                    self.suite_manifest(temporary, strict=True),
                    self.junit(temporary),
                )
            )
        self.assertEqual(status, 1)
        self.assertEqual(report["result"], "FAIL")
        issues = "\n".join(report["gate_issues"])
        self.assertIn("allow_failures=false", issues)
        self.assertIn("allow_errors=false", issues)
        self.assertIn("allow_skips=false", issues)
        self.assertIn("allow_not_run=false", issues)


if __name__ == "__main__":
    unittest.main()
