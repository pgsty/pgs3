#!/usr/bin/env python3
"""Offline tests for the fixed localhost-only HTTP boundary client."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest import mock


ROBUST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(ROBUST_DIR))

import http_boundary as boundary  # noqa: E402
from sigv4_probe import SigV4Client  # noqa: E402


PINNED_CORPUS_SHA256 = (
    "371e7eb2841730327d87a61b2b958dfe6b0e42657fb6927ce0b55b6ab3d406b5"
)


class EndpointSafetyTests(unittest.TestCase):
    def test_accepts_only_explicit_ipv4_loopback_origin(self) -> None:
        self.assertEqual(
            boundary.validate_loopback_endpoint("http://127.0.0.1:1"),
            "http://127.0.0.1:1",
        )
        self.assertEqual(
            boundary.validate_loopback_endpoint("http://127.0.0.1:65535/"),
            "http://127.0.0.1:65535",
        )

    def test_rejects_every_non_loopback_or_non_origin_form(self) -> None:
        rejected = (
            "https://127.0.0.1:9000",
            "http://localhost:9000",
            "http://[::1]:9000",
            "http://127.0.0.2:9000",
            "http://192.0.2.1:9000",
            "http://127.0.0.1",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
            "http://user@127.0.0.1:9000",
            "http://127.0.0.1:9000/path",
            "http://127.0.0.1:9000/?query=1",
            "http://127.0.0.1:9000/#fragment",
        )
        for endpoint in rejected:
            with self.subTest(endpoint=endpoint):
                with self.assertRaises(boundary.BoundaryFailure):
                    boundary.validate_loopback_endpoint(endpoint)

    def test_credentials_must_be_nonempty_environment_values(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(boundary.BoundaryFailure):
                boundary._credential("PGS3_ROBUST_SECRET")
        with mock.patch.dict(os.environ, {"PGS3_ROBUST_SECRET": "fixed"}):
            self.assertEqual(boundary._credential("PGS3_ROBUST_SECRET"), "fixed")


class FixedCorpusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.specs = boundary.case_specs()
        self.client = SigV4Client(
            "http://127.0.0.1:9000", "TESTACCESS", "test-secret", timeout=1.0
        )

    def test_corpus_names_order_and_digest_are_pinned(self) -> None:
        self.assertEqual(len(self.specs), 7)
        self.assertEqual({spec.name for spec in self.specs}, boundary.EXPECTED_CASES)
        self.assertEqual(
            tuple(dict.fromkeys(spec.batch for spec in self.specs)),
            boundary.EXPECTED_BATCHES,
        )
        self.assertEqual(boundary.corpus_digest(self.specs), PINNED_CORPUS_SHA256)

    def test_corpus_has_fixed_small_batches_and_exact_rejections(self) -> None:
        by_name = {spec.name: spec for spec in self.specs}
        self.assertEqual(
            [sum(spec.batch == batch for spec in self.specs) for batch in boundary.EXPECTED_BATCHES],
            [3, 3, 1],
        )
        self.assertEqual(by_name["invalid-xml"].allowed_codes, ("MalformedXML",))
        self.assertEqual(
            by_name["content-length-short"].allowed_codes,
            ("XAmzContentSHA256Mismatch",),
        )
        self.assertEqual(
            by_name["content-length-long"].allowed_codes, ("IncompleteBody",)
        )
        self.assertEqual(
            by_name["incomplete-chunked"].allowed_codes, ("IncompleteBody",)
        )
        self.assertEqual(
            [spec.name for spec in self.specs if spec.allow_connection_close],
            ["oversized-header"],
        )

    def test_every_rendered_request_is_bounded_and_loopback_hosted(self) -> None:
        for spec in self.specs:
            with self.subTest(case=spec.name):
                request = boundary.render_case(
                    spec, self.client, "robust-bucket", "robust-xml-bucket"
                )
                self.assertLessEqual(len(request), boundary.MAX_RENDERED_REQUEST_BYTES)
                self.assertIn(b"host: 127.0.0.1", request.lower())
                self.assertNotIn(b"https://", request.lower())

    def test_describe_is_metadata_only(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(boundary.command_describe(argparse.Namespace()), 0)
        record = json.loads(output.getvalue())
        self.assertEqual(record["total_cases"], 7)
        self.assertEqual(record["corpus_sha256"], PINNED_CORPUS_SHA256)
        lowered = output.getvalue().lower()
        self.assertNotIn("authorization", lowered)
        self.assertNotIn("secret", lowered)
        self.assertNotIn("raw_request", lowered)

    def test_sentinel_is_fixed_and_small(self) -> None:
        first = boundary.sentinel_payload()
        self.assertEqual(first, boundary.sentinel_payload())
        self.assertEqual(len(first), boundary.SENTINEL_BYTES)
        self.assertLessEqual(len(first), 4096)


class ResponseAndDeadlineTests(unittest.TestCase):
    @staticmethod
    def error_response(status: int = 400, code: str = "InvalidRequest") -> bytes:
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>'
            f"<Error><Code>{code}</Code><Message>rejected</Message></Error>"
        ).encode()
        return (
            f"HTTP/1.1 {status} Bad Request\r\n"
            "Content-Type: application/xml\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n"
        ).encode() + body

    def test_parses_bounded_s3_rejection(self) -> None:
        self.assertEqual(
            boundary.parse_error_response(
                self.error_response(400, "XAmzContentSHA256Mismatch")
            ),
            (400, "XAmzContentSHA256Mismatch"),
        )

    def test_rejects_success_malformed_xml_and_length_mismatch(self) -> None:
        invalid_responses = (
            self.error_response(200),
            b"HTTP/1.1 400 Bad Request\r\nContent-Length: 4\r\n\r\nnope",
            b"HTTP/1.1 400 Bad Request\r\nContent-Length: 5\r\n\r\n<e/>",
            b"HTTP/1.1 400 Bad Request\r\n"
            b"Content-Length: 4\r\nContent-Length: 4\r\n\r\n<e/>",
        )
        for response in invalid_responses:
            with self.subTest(response=response[:40]):
                with self.assertRaises(boundary.BoundaryFailure):
                    boundary.parse_error_response(response)

    def test_timeout_must_stay_inside_fixed_ceiling(self) -> None:
        spec = boundary.case_specs()[0]
        client = SigV4Client(
            "http://127.0.0.1:9000", "TESTACCESS", "test-secret", timeout=1.0
        )
        for timeout in (0.0, 0.049, boundary.CASE_TIMEOUT_SECONDS + 0.001):
            with self.subTest(timeout=timeout):
                with self.assertRaises(boundary.BoundaryFailure):
                    boundary.send_case(
                        spec,
                        client,
                        "robust-bucket",
                        "robust-xml-bucket",
                        timeout_seconds=timeout,
                    )

    def test_expired_absolute_deadline_is_rejected(self) -> None:
        with mock.patch.object(boundary.time, "monotonic", return_value=10.0):
            with self.assertRaises(boundary.BoundaryFailure):
                boundary._remaining(9.0)


if __name__ == "__main__":
    unittest.main()
