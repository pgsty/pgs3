from __future__ import annotations

import hashlib
from pathlib import Path
import socket
import sys
import threading
import unittest


FUZZ_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(FUZZ_DIR))

import malformed_client as fuzz  # noqa: E402


def error_response(code: str = "InvalidRequest") -> bytes:
    body = (
        f"<?xml version=\"1.0\"?><Error><Code>{code}</Code>"
        "<Message>bounded rejection</Message></Error>"
    ).encode()
    return (
        b"HTTP/1.1 400 Bad Request\r\n"
        b"Content-Type: application/xml\r\n"
        + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
        + body
    )


class CorpusTests(unittest.TestCase):
    def test_required_categories_are_present_and_bounded(self) -> None:
        specs = fuzz.case_specs(fuzz.DEFAULT_SEED, 16)
        self.assertEqual(len(specs), 24)
        self.assertTrue(fuzz.REQUIRED_CATEGORIES.issubset({s.category for s in specs}))
        self.assertEqual(len(specs), len({s.name for s in specs}))
        for spec in specs:
            with self.subTest(case=spec.name):
                self.assertRegex(spec.name, r"^[a-z0-9][a-z0-9-]*$")
                self.assertLessEqual(len(spec.raw) + len(spec.body), fuzz.MAX_REQUEST_BYTES)
                self.assertEqual(len(spec.fingerprint()), 64)

    def test_seed_is_reproducible_and_changes_random_corpus(self) -> None:
        first = fuzz.case_specs("repeatable-seed", 12)
        second = fuzz.case_specs("repeatable-seed", 12)
        changed = fuzz.case_specs("different-seed", 12)
        self.assertEqual(fuzz.corpus_digest(first), fuzz.corpus_digest(second))
        self.assertNotEqual(fuzz.corpus_digest(first), fuzz.corpus_digest(changed))
        self.assertEqual(
            [spec.raw for spec in first if spec.category == "deterministic-random"],
            [spec.raw for spec in second if spec.category == "deterministic-random"],
        )

    def test_seed_and_count_limits_fail_closed(self) -> None:
        with self.assertRaises(fuzz.FuzzFailure):
            fuzz.case_specs("", 1)
        with self.assertRaises(fuzz.FuzzFailure):
            fuzz.case_specs("ok", 0)
        with self.assertRaises(fuzz.FuzzFailure):
            fuzz.case_specs("ok", fuzz.MAX_RANDOM_CASES + 1)

    def test_signed_render_is_bounded_and_does_not_copy_secret(self) -> None:
        secret = "literal-secret-must-not-be-copied"
        client = fuzz.SigV4Client(
            "http://127.0.0.1:9000", "FUZZACCESS", secret, timeout=1
        )
        specs = fuzz.case_specs("render-seed", 1)
        for spec in specs:
            request = fuzz.render_case(spec, client, "fuzz-bucket", "fuzz-scratch")
            with self.subTest(case=spec.name):
                self.assertLessEqual(len(request), fuzz.MAX_REQUEST_BYTES)
                self.assertNotIn(secret.encode(), request)
        invalid_xml = next(spec for spec in specs if spec.name == "invalid-xml")
        rendered = fuzz.render_case(invalid_xml, client, "fuzz-bucket", "fuzz-scratch")
        self.assertIn(b"authorization: AWS4-HMAC-SHA256", rendered)
        self.assertIn(b"content-length:", rendered)


class ResponseTests(unittest.TestCase):
    def test_s3_error_response_requires_exact_bounded_framing(self) -> None:
        raw = error_response()
        self.assertEqual(fuzz._parse_error_response(raw), (400, "InvalidRequest"))
        with self.assertRaises(fuzz.FuzzFailure):
            fuzz._parse_error_response(raw + b"extra")
        with self.assertRaises(fuzz.FuzzFailure):
            fuzz._parse_error_response(b"HTTP/1.1 400 Bad Request\r\n\r\n")

    def test_real_socket_case_accepts_bounded_s3_failure(self) -> None:
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        captured = bytearray()

        def serve() -> None:
            connection, _peer = listener.accept()
            with connection:
                while True:
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    captured.extend(chunk)
                connection.sendall(error_response())
            listener.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        spec = fuzz.CaseSpec(
            name="offline-wire",
            category="deterministic-random",
            mode="raw",
            raw=b"GET / HTTP/9.9\r\nHost: fuzz.invalid\r\n\r\n",
            allow_connection_close=False,
        )
        client = fuzz.SigV4Client(
            f"http://127.0.0.1:{port}", "OFFLINEACCESS", "offline-secret", timeout=2
        )
        outcome = fuzz.send_case(spec, client, "fuzz-bucket", "fuzz-scratch", 2)
        thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(bytes(captured), spec.raw)
        self.assertEqual(outcome.kind, "s3-error")
        self.assertEqual(outcome.status, 400)
        self.assertEqual(outcome.s3_error, "InvalidRequest")
        self.assertLess(outcome.elapsed_seconds, 2)

    def test_connection_close_is_explicit_not_a_timeout(self) -> None:
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]

        def serve() -> None:
            connection, _peer = listener.accept()
            connection.close()
            listener.close()

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        spec = fuzz.CaseSpec(
            name="offline-close",
            category="deterministic-random",
            mode="raw",
            raw=b"garbage",
        )
        client = fuzz.SigV4Client(
            f"http://127.0.0.1:{port}", "OFFLINEACCESS", "offline-secret", timeout=2
        )
        outcome = fuzz.send_case(spec, client, "fuzz-bucket", "fuzz-scratch", 2)
        thread.join(timeout=2)
        self.assertEqual(outcome.kind, "connection-failure")
        self.assertIn(outcome.connection_failure, {"EOF", "ConnectionResetError"})


class SentinelTests(unittest.TestCase):
    def test_sentinel_is_deterministic_and_nonempty(self) -> None:
        payload = fuzz.sentinel_payload("sentinel-seed")
        self.assertEqual(len(payload), fuzz.SENTINEL_BYTES)
        self.assertEqual(payload, fuzz.sentinel_payload("sentinel-seed"))
        self.assertNotEqual(
            hashlib.sha256(payload).digest(),
            hashlib.sha256(fuzz.sentinel_payload("other-seed")).digest(),
        )


if __name__ == "__main__":
    unittest.main()
