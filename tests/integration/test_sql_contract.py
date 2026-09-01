#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import unittest


BOOTSTRAP = Path(__file__).resolve().parents[2] / "sql" / "bootstrap.sql"


class NotificationContractTests(unittest.TestCase):
    def test_global_channel_has_one_opaque_emitter(self) -> None:
        source = BOOTSTRAP.read_text(encoding="utf-8")
        emitters = list(
            re.finditer(r"pg_notify\s*\(\s*'pgs3'", source, re.IGNORECASE)
        )
        self.assertEqual(len(emitters), 1)

        helper = re.search(
            r"CREATE FUNCTION pgs3\._notify_change\(p_operation text\).*?\n\$\$;",
            source,
            re.IGNORECASE | re.DOTALL,
        )
        self.assertIsNotNone(helper)
        definition = helper.group(0)
        for forbidden in (
            "bucket",
            "key",
            "version_id",
            "etag",
            "size",
            "actor",
            "access_key",
        ):
            self.assertNotIn(f"'{forbidden}'", definition.lower())
        self.assertRegex(
            definition,
            r"jsonb_build_object\s*\(\s*'op'\s*,\s*p_operation\s*\)",
        )


if __name__ == "__main__":
    unittest.main()
