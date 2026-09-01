from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest


SCALE_DIR = Path(__file__).resolve().parent
REPO = SCALE_DIR.parents[1]
RUNNER = SCALE_DIR / "run.sh"
CHECKER = SCALE_DIR / "plan_check.py"
BOOTSTRAP = REPO / "sql" / "bootstrap.sql"

SPEC = importlib.util.spec_from_file_location("pgs3_scale_plan_check", CHECKER)
assert SPEC and SPEC.loader
plan_check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(plan_check)


def explain_document(execution_ms: float = 4.9, rows: int = 1000) -> dict:
    return {
        "Plan": {
            "Node Type": "Function Scan",
            "Actual Rows": rows,
            "Actual Loops": 1,
            "Shared Hit Blocks": 4012,
            "Shared Read Blocks": 0,
            "WAL Records": 0,
        },
        "Planning Time": 0.1,
        "Execution Time": execution_ms,
    }


class PlanGateTests(unittest.TestCase):
    def test_fixed_threshold_passes_with_real_rows_and_buffers(self) -> None:
        summary, errors = plan_check.evaluate_plan(
            explain_document(), "list", 1000
        )
        self.assertEqual(errors, [])
        self.assertEqual(summary["result"], "PASS")
        self.assertEqual(summary["buffers"]["Shared Hit Blocks"], 4012)
        self.assertEqual(summary["shared_blocks_touched"], 4012)
        self.assertEqual(summary["shared_blocks_per_output_row"], 4.012)

    def test_threshold_is_strict(self) -> None:
        summary, errors = plan_check.evaluate_plan(
            explain_document(execution_ms=10.0), "delimiter", 1000
        )
        self.assertEqual(summary["result"], "FAIL")
        self.assertTrue(any("not below" in error for error in errors))

    def test_row_mismatch_fails(self) -> None:
        summary, errors = plan_check.evaluate_plan(
            explain_document(rows=999), "list", 1000
        )
        self.assertEqual(summary["result"], "FAIL")
        self.assertTrue(any("Actual Rows" in error for error in errors))

    def test_missing_buffers_is_not_accepted(self) -> None:
        document = explain_document()
        document["Plan"].pop("Shared Hit Blocks")
        document["Plan"].pop("Shared Read Blocks")
        with self.assertRaises(plan_check.PlanError):
            plan_check.evaluate_plan(document, "list", 1000)

    def test_loader_rejects_non_explain_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "plan.json"
            path.write_text(json.dumps({"Execution Time": 1}), encoding="utf-8")
            with self.assertRaises(plan_check.PlanError):
                plan_check.load_explain(path)


class HarnessStaticTests(unittest.TestCase):
    def test_acceptance_defaults_and_durability_are_explicit(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        for assignment in (
            "PGS3_SCALE_FORK_OBJECTS:-100000",
            "PGS3_SCALE_LIST_KEYS:-1000000",
            "PGS3_SCALE_CHILD_PREFIXES:-1000",
            "PGS3_SCALE_PAGE_SIZE:-1000",
            "-c fsync=on",
            "-c full_page_writes=on",
            "-c synchronous_commit=on",
        ):
            self.assertIn(assignment, source)
        self.assertEqual(
            plan_check.THRESHOLDS_MS,
            {"fork": 1000.0, "list": 5.0, "delimiter": 10.0},
        )

    def test_cleanup_is_scoped_to_the_labeled_container(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn('pgs3.scale.run=${SCALE_RUN_TAG}', source)
        self.assertIn("refusing to remove container with unexpected label", source)
        self.assertIn("trap scale_cleanup EXIT INT TERM", source)
        for forbidden in (
            "docker system prune",
            "docker container prune",
            "docker volume prune",
            "rm -rf /",
            "rm -rf ~",
            "rm -rf $HOME",
        ):
            self.assertNotIn(forbidden, source)

    def test_evidence_manifest_uses_workspace_digest_helper(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn('source "${repo_dir}/scripts/lib/evidence.sh"', source)
        self.assertRegex(
            source,
            re.compile(r'evidence_init "\$\{repo_dir\}" scale "\$\{pg_major\}"'),
        )

    def test_fork_measurement_has_an_explicit_hot_data_warmup(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        warmup = source.index("evidence_run fork-source-warmup")
        measured = source.index("evidence_try fork-explain-analyze")
        self.assertLess(warmup, measured)
        self.assertIn("octet_length(o.meta::text)", source)
        self.assertIn("octet_length(blob.inline)", source)

    def test_measured_sql_calls_public_functions_with_real_explain(self) -> None:
        expectations = {
            "plan_fork.sql": "pgs3.fork_bucket(",
            "plan_list.sql": "pgs3.list_objects_v2(",
            "plan_delimiter.sql": "pgs3.list_objects_v2(",
        }
        for filename, function_call in expectations.items():
            with self.subTest(filename=filename):
                source = (SCALE_DIR / filename).read_text(encoding="utf-8")
                self.assertRegex(source, re.compile(r"EXPLAIN\s*\(\s*ANALYZE, BUFFERS", re.I))
                self.assertIn("TIMING OFF", source)
                self.assertIn("FORMAT JSON", source)
                self.assertIn(function_call, source)
                self.assertNotIn("pg_sleep", source)

    def test_fixture_keeps_refcount_triggers_enabled(self) -> None:
        source = (SCALE_DIR / "load.sql").read_text(encoding="utf-8")
        self.assertIn("INSERT INTO pgs3.blob", source)
        self.assertIn("INSERT INTO pgs3.object", source)
        self.assertNotRegex(source, re.compile(r"DISABLE\s+TRIGGER", re.I))
        self.assertNotRegex(source, re.compile(r"session_replication_role", re.I))

    def test_latest_live_index_also_covers_list_projection(self) -> None:
        source = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            re.compile(
                r"CREATE UNIQUE INDEX object_latest_live_uniq\s+"
                r"ON pgs3\.object \(bucket_id, key\)\s+"
                r"INCLUDE \(version_id, size, etag, content_type, created_at\)\s+"
                r"WHERE is_latest AND NOT delete_marker",
                re.I,
            ),
        )
        self.assertNotIn("CREATE INDEX object_list_idx", source)

    def test_fork_bulk_path_restores_triggers_and_reconciles_refs(self) -> None:
        source = BOOTSTRAP.read_text(encoding="utf-8")
        start = source.index("CREATE FUNCTION pgs3.fork_bucket(")
        end = source.index("CREATE FUNCTION pgs3._make_list_token(", start)
        fork = source[start:end]
        self.assertIn("SET work_mem = '64MB'", fork)
        self.assertIn(
            "v_replication_role := current_setting('session_replication_role')",
            fork,
        )
        self.assertGreaterEqual(
            fork.count("'session_replication_role', v_replication_role, true"),
            2,
        )
        self.assertIn("WITH inserted AS MATERIALIZED", fork)
        self.assertIn("RETURNING blob_id", fork)
        self.assertIn("FROM inserted AS i", fork)
        self.assertIn("SELECT count(*) INTO STRICT v_count FROM inserted", fork)
        self.assertNotIn("o.bucket_id = v_destination_bucket_id", fork)
        self.assertIn("SET refcount = b.refcount + refs.n", fork)
        self.assertNotRegex(fork, re.compile(r"DISABLE\s+TRIGGER", re.I))

    def test_list_plans_warm_the_same_persistent_backend(self) -> None:
        for filename in ("plan_list.sql", "plan_delimiter.sql"):
            with self.subTest(filename=filename):
                source = (SCALE_DIR / filename).read_text(encoding="utf-8")
                warmup = source.index("\\g /dev/null")
                measured = source.index("EXPLAIN (")
                self.assertLess(warmup, measured)

    def test_list_emits_only_the_page_continuation_token(self) -> None:
        source = BOOTSTRAP.read_text(encoding="utf-8")
        start = source.index("CREATE FUNCTION pgs3.list(")
        end = source.index("CREATE FUNCTION pgs3.list_objects_v1(", start)
        listing = source[start:end]
        self.assertIn("page.ordinal = p_max_keys", listing)
        self.assertGreaterEqual(
            listing.count("v_emitted + 1 = p_max_keys"), 2
        )

    def test_independence_uses_public_mutation_and_read_apis(self) -> None:
        source = (SCALE_DIR / "verify_independence.sql").read_text(encoding="utf-8")
        for call in (
            "pgs3.get(",
            "pgs3.put(",
            "pgs3.delete(",
            "pgs3.list_objects_v2(",
        ):
            self.assertIn(call, source)


if __name__ == "__main__":
    unittest.main()
