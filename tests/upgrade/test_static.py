#!/usr/bin/env python3
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[2]
BOOTSTRAP = ROOT / "sql" / "bootstrap.sql"
WORKER_RUNTIME = ROOT / "sql" / "worker_runtime.sql"
FIXTURE = ROOT / "tests" / "fixtures" / "extension" / "pgs3--0.1.0.sql"
UPDATE = ROOT / "sql" / "pgs3--0.1.0--0.1.1.sql"


def embedded_block(source: str, marker: str) -> str:
    start = source.index(marker) + len(marker)
    end = source.index("\n/* </end connected objects> */", start)
    return source[start:end].lstrip("\n") + "\n"


def functions(source: str) -> dict[str, str]:
    result: dict[str, str] = {}
    pattern = re.compile(
        r"(?ms)^CREATE(?: OR REPLACE)? FUNCTION\s+"
        r"(pgs3\.[^(\s]+)\s*\((.*?)\)\s*\n.*?^\$\$;"
    )
    for match in pattern.finditer(source):
        arguments = " ".join(line.strip() for line in match.group(2).splitlines())
        signature = f"{match.group(1)}({arguments})"
        definition = match.group(0).replace(
            "CREATE OR REPLACE FUNCTION", "CREATE FUNCTION", 1
        )
        result[signature] = definition
    return result


class UpgradeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_bytes = FIXTURE.read_bytes()
        cls.fixture = cls.fixture_bytes.decode("utf-8")
        cls.old_bootstrap = embedded_block(cls.fixture, "-- bootstrap\n")
        cls.old_worker = embedded_block(
            cls.fixture,
            "-- requires:\n--   pgs3_bootstrap\n",
        )
        cls.bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
        cls.worker = WORKER_RUNTIME.read_text(encoding="utf-8")
        cls.update = UPDATE.read_text(encoding="utf-8")

    def test_release_versions_have_one_source_of_truth(self) -> None:
        cargo = tomllib.loads((ROOT / "Cargo.toml").read_text(encoding="utf-8"))
        self.assertEqual(cargo["package"]["version"], "0.1.1")
        self.assertIn("default_version = '@CARGO_VERSION@'", (ROOT / "pgs3.control").read_text())
        lock = (ROOT / "Cargo.lock").read_text(encoding="utf-8")
        self.assertRegex(
            lock,
            r'(?ms)^\[\[package\]\]\nname = "pgs3"\nversion = "0\.1\.1"$',
        )

    def test_frozen_baseline_is_the_reviewed_0_1_0_package(self) -> None:
        self.assertEqual(
            hashlib.sha256(self.fixture_bytes).hexdigest(),
            "b4123f4c877cd18879a27073df4301660b5539433d21dc37dce1f72b764c534a",
        )
        self.assertNotIn("pgs3.extension_version", self.fixture)
        self.assertNotIn("pgs3._worker_set_actor", self.fixture)

    def test_blob_fillfactor_is_installed_and_migrated(self) -> None:
        self.assertIn(
            ") WITH (fillfactor = 80);",
            self.bootstrap,
        )
        self.assertNotIn("fillfactor", self.old_bootstrap)
        self.assertIn(
            "ALTER TABLE pgs3.blob SET (fillfactor = 80);",
            self.update,
        )

    def test_update_covers_every_function_delta_exactly(self) -> None:
        old = {
            **functions(self.old_bootstrap),
            **functions(self.old_worker),
        }
        current = {
            **functions(self.bootstrap),
            **functions(self.worker),
        }
        update = functions(self.update)

        added = set(current) - set(old)
        removed = set(old) - set(current)
        changed = {
            signature
            for signature in set(old) & set(current)
            if old[signature] != current[signature]
        }

        self.assertEqual(removed, set())
        self.assertEqual(
            {signature.split("(", 1)[0] for signature in added},
            {
                "pgs3.extension_version",
                "pgs3._worker_set_actor",
                "pgs3._worker_put_chunk",
                "pgs3._worker_complete_upload",
            },
        )
        self.assertEqual(
            {signature.split("(", 1)[0] for signature in changed},
            {
                "pgs3._actor",
                "pgs3._ensure_blob",
                "pgs3._ensure_composite_blob",
                "pgs3._ensure_staged_blob",
                "pgs3.put_part",
                "pgs3._grant_credential_role_membership",
                "pgs3._credential_grant_server_membership",
                "pgs3.fork_bucket",
            },
        )
        self.assertEqual(set(update), added | changed)
        for signature in added | changed:
            self.assertEqual(update[signature], current[signature], signature)

    def test_service_grants_follow_the_configured_restricted_role(self) -> None:
        for source in (self.worker, self.update):
            self.assertIn("current_setting('pgs3.server_role', true)", source)
            self.assertRegex(
                source,
                r"(?:r|v_role)\.rolcanlogin OR (?:r|v_role)\.rolinherit",
            )
            self.assertIn("m.admin_option OR m.inherit_option", source)
            for signature in (
                "pgs3._worker_set_actor(name)",
                "pgs3._worker_put_chunk(name, text, text, uuid, integer, bytea, bytea)",
                "pgs3._worker_complete_upload(name, text, text, uuid, bytea, bytea, text, bigint, bytea[], bigint[])",
            ):
                self.assertIn(
                    f"GRANT EXECUTE ON FUNCTION {signature} TO %I",
                    source,
                )

        self.assertNotRegex(
            self.worker,
            r"GRANT EXECUTE ON FUNCTION pgs3\._worker_(?:set_actor|put_chunk|complete_upload).* TO pgs3_server",
        )
        for source in (self.worker, self.update):
            self.assertIn("GRANT CONNECT ON DATABASE %I TO %I", source)
            self.assertIn("GRANT USAGE ON SCHEMA pgs3 TO %I", source)
            self.assertIn("GRANT SELECT ON TABLE pgs3.credential TO %I", source)
            self.assertIn(
                "GRANT EXECUTE ON FUNCTION pgs3._worker_set_state(text, integer, integer, text, text, integer, text) TO %I",
                source,
            )
            self.assertIn(
                "GRANT EXECUTE ON FUNCTION pgs3._worker_add_metric(text, integer, text, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint) TO %I",
                source,
            )
        self.assertIn(
            "REVOKE CONNECT ON DATABASE %I FROM pgs3_server",
            self.update,
        )
        self.assertIn(
            "REVOKE SELECT ON TABLE pgs3.credential FROM pgs3_server",
            self.update,
        )

    def test_update_is_a_strict_postgres_extension_script(self) -> None:
        self.assertNotRegex(self.update, r"(?m)^\\")
        self.assertNotRegex(self.update, r"(?im)^\s*(BEGIN|COMMIT|ROLLBACK)\s*;")
        self.assertNotIn("IF NOT EXISTS", self.update.upper())
        self.assertNotIn("CREATE OR REPLACE FUNCTION pgs3.extension_version", self.update)
        for function in (
            "_worker_set_actor",
            "_worker_put_chunk",
            "_worker_complete_upload",
        ):
            self.assertIn(
                f"REVOKE ALL ON FUNCTION pgs3.{function}",
                self.update,
            )


if __name__ == "__main__":
    unittest.main()
