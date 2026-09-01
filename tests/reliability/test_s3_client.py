from __future__ import annotations

import argparse
import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import os
import sys
from pathlib import Path
import threading
import unittest


RELIABILITY_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(RELIABILITY_DIR))

import s3_client  # noqa: E402


class PayloadTests(unittest.TestCase):
    def test_streamed_pattern_matches_materialized_pattern(self) -> None:
        for size in (0, 1, 31, 32, 33, 4097, 1024 * 1024 + 17):
            with self.subTest(size=size):
                payload = s3_client.pattern_bytes(size, "fixed-seed")
                self.assertEqual(len(payload), size)
                self.assertEqual(
                    s3_client.pattern_sha256(size, "fixed-seed"),
                    hashlib.sha256(payload).hexdigest(),
                )
                for chunk_size in (1, 7, 4093, 65536):
                    self.assertEqual(
                        b"".join(s3_client.iter_pattern(size, "fixed-seed", chunk_size)),
                        payload,
                    )

    def test_pattern_changes_with_seed(self) -> None:
        self.assertNotEqual(
            s3_client.pattern_sha256(4096, "one"),
            s3_client.pattern_sha256(4096, "two"),
        )


class XmlTests(unittest.TestCase):
    def test_namespaced_keys_and_error_message(self) -> None:
        listing = b"""<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Contents><Key>a</Key></Contents><Contents><Key>b/c</Key></Contents>
        </ListBucketResult>"""
        self.assertEqual(s3_client.object_keys(listing), {"a", "b/c"})
        error = b"<Error><Code>ServiceUnavailable</Code><Message>read-only standby</Message></Error>"
        self.assertEqual(s3_client.xml_message(error), "read-only standby")

    def test_invalid_listing_xml_fails_closed(self) -> None:
        with self.assertRaises(s3_client.ReliabilityFailure):
            s3_client.object_keys(b"not xml")


class WireTests(unittest.TestCase):
    def test_slow_put_streams_the_exact_signed_payload(self) -> None:
        captured: dict[str, object] = {}

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                length = int(self.headers["content-length"])
                captured["path"] = self.path
                captured["authorization"] = self.headers.get("authorization")
                captured["body"] = self.rfile.read(length)
                self.send_response(200)
                self.send_header("etag", '"wire-test"')
                self.send_header("content-length", "0")
                self.end_headers()

            def log_message(self, _format: str, *args: object) -> None:
                del args

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()
        old_access = os.environ.get("PGS3_TEST_ACCESS_KEY_A")
        old_secret = os.environ.get("PGS3_TEST_SECRET_A")
        os.environ["PGS3_TEST_ACCESS_KEY_A"] = "WIRETESTACCESS"
        os.environ["PGS3_TEST_SECRET_A"] = "wire-test-secret"
        arguments = argparse.Namespace(
            endpoint=f"http://127.0.0.1:{server.server_port}",
            region="us-east-1",
            timeout=2.0,
            bucket="wire-bucket",
            key="slow.bin",
            size=131_089,
            seed="wire-seed",
            chunk_size=4093,
            delay_ms=0,
        )
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(s3_client.command_slow_put(arguments), 0)
        finally:
            if old_access is None:
                os.environ.pop("PGS3_TEST_ACCESS_KEY_A", None)
            else:
                os.environ["PGS3_TEST_ACCESS_KEY_A"] = old_access
            if old_secret is None:
                os.environ.pop("PGS3_TEST_SECRET_A", None)
            else:
                os.environ["PGS3_TEST_SECRET_A"] = old_secret
            server.server_close()
            thread.join(timeout=2)

        expected = s3_client.pattern_bytes(arguments.size, arguments.seed)
        self.assertEqual(captured["path"], "/wire-bucket/slow.bin")
        self.assertEqual(captured["body"], expected)
        self.assertRegex(str(captured["authorization"]), r"Signature=[0-9a-f]{64}$")

    def test_early_put_error_sends_headers_but_no_body(self) -> None:
        captured: dict[str, object] = {}

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                captured["expect"] = self.headers.get("expect")
                captured["content_length"] = self.headers.get("content-length")
                captured["authorization"] = self.headers.get("authorization")
                body = (
                    b"<Error><Code>ServiceUnavailable</Code>"
                    b"<Message>read-only standby</Message></Error>"
                )
                self.send_response(503)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *args: object) -> None:
                del args

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.handle_request, daemon=True)
        thread.start()
        old_access = os.environ.get("PGS3_TEST_ACCESS_KEY_A")
        old_secret = os.environ.get("PGS3_TEST_SECRET_A")
        os.environ["PGS3_TEST_ACCESS_KEY_A"] = "WIRETESTACCESS"
        os.environ["PGS3_TEST_SECRET_A"] = "wire-test-secret"
        arguments = argparse.Namespace(
            endpoint=f"http://127.0.0.1:{server.server_port}",
            region="us-east-1",
            timeout=2.0,
            bucket="wire-bucket",
            key="forbidden.bin",
            size=4096,
            seed="not-sent",
            status=503,
            code="ServiceUnavailable",
            message="read-only standby",
        )
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(s3_client.command_early_put_error(arguments), 0)
        finally:
            if old_access is None:
                os.environ.pop("PGS3_TEST_ACCESS_KEY_A", None)
            else:
                os.environ["PGS3_TEST_ACCESS_KEY_A"] = old_access
            if old_secret is None:
                os.environ.pop("PGS3_TEST_SECRET_A", None)
            else:
                os.environ["PGS3_TEST_SECRET_A"] = old_secret
            server.server_close()
            thread.join(timeout=2)

        self.assertEqual(captured["expect"], "100-continue")
        self.assertEqual(captured["content_length"], "4096")
        self.assertRegex(str(captured["authorization"]), r"Signature=[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
