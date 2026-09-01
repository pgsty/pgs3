#!/usr/bin/env python3
"""Fixed, bounded malformed-HTTP regression client for a local pgs3 container.

This is deliberately a regression corpus, not a fuzzer or scanner.  The only
accepted endpoint is an explicit ``http://127.0.0.1:PORT`` origin, every socket
has one absolute deadline, and emitted evidence contains no request headers.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import sys
import time
from typing import Iterable, Mapping
import urllib.parse
import xml.etree.ElementTree as ET


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "integration"
sys.path.insert(0, str(INTEGRATION_DIR))

from sigv4_probe import SigV4Client, _s3_path  # noqa: E402


FIXED_SEED = "pgs3-http-boundary-v1"
CASE_TIMEOUT_SECONDS = 2.0
HTTP_TIMEOUT_SECONDS = 3.0
MAX_TEMPLATE_BYTES = 80 * 1024
MAX_RENDERED_REQUEST_BYTES = 96 * 1024
MAX_RESPONSE_BYTES = 128 * 1024
SENTINEL_BYTES = 4096

EXPECTED_CASES = frozenset(
    {
        "oversized-header",
        "duplicate-content-length",
        "content-length-transfer-encoding",
        "invalid-xml",
        "content-length-short",
        "content-length-long",
        "incomplete-chunked",
    }
)
EXPECTED_BATCHES = ("request-head", "message-body", "chunked-body")


class BoundaryFailure(RuntimeError):
    """A safety or acceptance assertion failed."""


@dataclass(frozen=True)
class CaseSpec:
    name: str
    batch: str
    category: str
    mode: str
    raw: bytes = b""
    body: bytes = b""
    declared_length: int | None = None
    signed_body: bytes | None = None
    allowed_codes: tuple[str, ...] = ("InvalidRequest",)
    allow_connection_close: bool = False

    def fingerprint(self) -> str:
        document = {
            "name": self.name,
            "batch": self.batch,
            "category": self.category,
            "mode": self.mode,
            "raw_sha256": hashlib.sha256(self.raw).hexdigest(),
            "raw_bytes": len(self.raw),
            "body_sha256": hashlib.sha256(self.body).hexdigest(),
            "body_bytes": len(self.body),
            "declared_length": self.declared_length,
            "signed_body_sha256": (
                hashlib.sha256(self.signed_body).hexdigest()
                if self.signed_body is not None
                else None
            ),
            "allowed_codes": self.allowed_codes,
            "allow_connection_close": self.allow_connection_close,
        }
        encoded = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def public_record(self) -> dict[str, object]:
        return {
            "name": self.name,
            "batch": self.batch,
            "category": self.category,
            "mode": self.mode,
            "case_sha256": self.fingerprint(),
            "template_bytes": len(self.raw) + len(self.body),
            "allow_connection_close": self.allow_connection_close,
            "allowed_codes": list(self.allowed_codes),
        }


@dataclass(frozen=True)
class WireOutcome:
    kind: str
    response_bytes: int
    elapsed_seconds: float
    status: int | None = None
    s3_error: str | None = None
    connection_failure: str | None = None


def case_specs() -> tuple[CaseSpec, ...]:
    oversized = (
        b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Oversized: "
        + b"h" * (68 * 1024)
        + b"\r\n\r\n"
    )
    invalid_xml = (
        b'<?xml version="1.0"?><CreateBucketConfiguration>'
        b"<LocationConstraint>&broken"
    )
    specs = (
        CaseSpec(
            name="oversized-header",
            batch="request-head",
            category="oversized-header",
            mode="raw",
            raw=oversized,
            allow_connection_close=True,
        ),
        CaseSpec(
            name="duplicate-content-length",
            batch="request-head",
            category="duplicate-length",
            mode="raw",
            raw=(
                b"POST /boundary HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Content-Length: 0\r\n"
                b"Content-Length: 1\r\n\r\nX"
            ),
        ),
        CaseSpec(
            name="content-length-transfer-encoding",
            batch="request-head",
            category="length-transfer-encoding-conflict",
            mode="raw",
            raw=(
                b"POST /boundary HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\n"
                b"Content-Length: 4\r\n"
                b"Transfer-Encoding: chunked\r\n\r\n"
                b"0\r\n\r\n"
            ),
        ),
        CaseSpec(
            name="invalid-xml",
            batch="message-body",
            category="invalid-xml",
            mode="signed-invalid-xml",
            body=invalid_xml,
            declared_length=len(invalid_xml),
            allowed_codes=("MalformedXML",),
        ),
        CaseSpec(
            name="content-length-short",
            batch="message-body",
            category="content-length-mismatch",
            mode="signed-object",
            body=b"ABCD",
            declared_length=3,
            signed_body=b"ABCD",
            allowed_codes=("XAmzContentSHA256Mismatch",),
        ),
        CaseSpec(
            name="content-length-long",
            batch="message-body",
            category="content-length-mismatch",
            mode="signed-object",
            body=b"four",
            declared_length=9,
            signed_body=b"four",
            allowed_codes=("IncompleteBody",),
        ),
        CaseSpec(
            name="incomplete-chunked",
            batch="chunked-body",
            category="incomplete-chunked",
            mode="signed-chunked",
            body=b"5\r\nabc",
            signed_body=b"abcde",
            allowed_codes=("IncompleteBody",),
        ),
    )
    if {spec.name for spec in specs} != EXPECTED_CASES:
        raise AssertionError("the fixed boundary corpus changed unexpectedly")
    if tuple(dict.fromkeys(spec.batch for spec in specs)) != EXPECTED_BATCHES:
        raise AssertionError("the fixed boundary batch order changed unexpectedly")
    if len(specs) != len({spec.name for spec in specs}):
        raise AssertionError("boundary case names must be unique")
    if any(len(spec.raw) + len(spec.body) > MAX_TEMPLATE_BYTES for spec in specs):
        raise AssertionError("a fixed boundary template exceeds MAX_TEMPLATE_BYTES")
    return specs


def corpus_digest(specs: Iterable[CaseSpec] | None = None) -> str:
    digest = hashlib.sha256(b"pgs3-http-boundary-corpus-v1\0")
    for spec in specs if specs is not None else case_specs():
        digest.update(spec.name.encode())
        digest.update(b"\0")
        digest.update(spec.fingerprint().encode())
        digest.update(b"\0")
    return digest.hexdigest()


def _credential(variable: str) -> str:
    value = os.environ.get(variable, "")
    if not value:
        raise BoundaryFailure(f"required credential environment variable is empty: {variable}")
    return value


def validate_loopback_endpoint(endpoint: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(endpoint)
        port = parsed.port
    except ValueError as error:
        raise BoundaryFailure("endpoint contains an invalid port") from error
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or port is None
        or not 1 <= port <= 65535
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise BoundaryFailure(
            "endpoint must be an explicit http://127.0.0.1:PORT origin"
        )
    return f"http://127.0.0.1:{port}"


def make_client(endpoint: str) -> SigV4Client:
    return SigV4Client(
        validate_loopback_endpoint(endpoint),
        _credential("PGS3_ROBUST_ACCESS_KEY"),
        _credential("PGS3_ROBUST_SECRET"),
        timeout=HTTP_TIMEOUT_SECONDS,
    )


def _signed_request(
    client: SigV4Client,
    method: str,
    path: str,
    body: bytes,
    signed_body: bytes,
    *,
    content_length: int | None,
    extra_headers: Mapping[str, str] | None = None,
) -> bytes:
    payload_hash = hashlib.sha256(signed_body).hexdigest()
    headers = client.signed_headers(
        method, path, (), payload_hash, extra_headers=extra_headers
    )
    lines = [f"{method} {path} HTTP/1.1"]
    for name in sorted(headers):
        lines.append(f"{name}: {headers[name]}")
    if content_length is not None:
        lines.append(f"content-length: {content_length}")
    return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + body


def render_case(
    spec: CaseSpec,
    client: SigV4Client,
    bucket: str,
    scratch_bucket: str,
) -> bytes:
    if spec.mode == "raw":
        request = spec.raw
    elif spec.mode == "signed-invalid-xml":
        request = _signed_request(
            client,
            "PUT",
            _s3_path(scratch_bucket),
            spec.body,
            spec.signed_body if spec.signed_body is not None else spec.body,
            content_length=spec.declared_length,
            extra_headers={"content-type": "application/xml"},
        )
    elif spec.mode == "signed-object":
        request = _signed_request(
            client,
            "PUT",
            _s3_path(bucket, f"boundary/{spec.name}.bin"),
            spec.body,
            spec.signed_body if spec.signed_body is not None else spec.body,
            content_length=spec.declared_length,
        )
    elif spec.mode == "signed-chunked":
        request = _signed_request(
            client,
            "PUT",
            _s3_path(bucket, f"boundary/{spec.name}.bin"),
            spec.body,
            spec.signed_body if spec.signed_body is not None else spec.body,
            content_length=None,
            extra_headers={"transfer-encoding": "chunked"},
        )
    else:
        raise AssertionError(f"unknown boundary case mode: {spec.mode}")
    if len(request) > MAX_RENDERED_REQUEST_BYTES:
        raise BoundaryFailure(
            f"case {spec.name} rendered {len(request)} bytes, "
            f"limit is {MAX_RENDERED_REQUEST_BYTES}"
        )
    return request


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise BoundaryFailure("boundary connection exceeded its absolute deadline")
    return remaining


def _read_bounded(sock: socket.socket, deadline: float) -> tuple[bytes, str | None]:
    response = bytearray()
    connection_failure = None
    while True:
        sock.settimeout(_remaining(deadline))
        try:
            chunk = sock.recv(16 * 1024)
        except socket.timeout as error:
            raise BoundaryFailure(
                "server did not reject and close before the connection deadline"
            ) from error
        except (ConnectionResetError, BrokenPipeError) as error:
            connection_failure = type(error).__name__
            break
        if not chunk:
            break
        response.extend(chunk)
        if len(response) > MAX_RESPONSE_BYTES:
            raise BoundaryFailure(
                f"response exceeded the {MAX_RESPONSE_BYTES}-byte evidence limit"
            )
    return bytes(response), connection_failure


def parse_error_response(raw: bytes) -> tuple[int, str | None]:
    if len(raw) > MAX_RESPONSE_BYTES:
        raise BoundaryFailure("HTTP response exceeds the parser resource limit")
    marker = raw.find(b"\r\n\r\n")
    if marker < 0:
        raise BoundaryFailure("peer returned a truncated HTTP response head")
    head, body = raw[:marker], raw[marker + 4 :]
    lines = head.split(b"\r\n")
    match = re.fullmatch(rb"HTTP/1\.[01] ([0-9]{3})(?: [^\r\n]*)?", lines[0])
    if match is None:
        raise BoundaryFailure("peer returned an invalid HTTP status line")
    status = int(match.group(1))
    if not 400 <= status <= 499:
        raise BoundaryFailure(f"malformed request was not rejected: HTTP {status}")
    headers: dict[bytes, list[bytes]] = {}
    for line in lines[1:]:
        if b":" not in line:
            raise BoundaryFailure("peer returned a malformed response header")
        name, value = line.split(b":", 1)
        headers.setdefault(name.strip().lower(), []).append(value.strip())
    lengths = headers.get(b"content-length", [])
    if len(lengths) != 1 or not lengths[0].isdigit():
        raise BoundaryFailure("error response must contain one numeric Content-Length")
    declared = int(lengths[0])
    if declared > MAX_RESPONSE_BYTES or declared != len(body):
        raise BoundaryFailure(
            f"error response length mismatch: declared={declared} received={len(body)}"
        )
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        raise BoundaryFailure("error response body is not bounded S3 XML") from error
    code = None
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] == "Code":
            code = node.text
            break
    return status, code


def send_case(
    spec: CaseSpec,
    client: SigV4Client,
    bucket: str,
    scratch_bucket: str,
    timeout_seconds: float = CASE_TIMEOUT_SECONDS,
) -> WireOutcome:
    if not 0.05 <= timeout_seconds <= CASE_TIMEOUT_SECONDS:
        raise BoundaryFailure(
            f"connection deadline must be in 0.05..{CASE_TIMEOUT_SECONDS:.1f} seconds"
        )
    request = render_case(spec, client, bucket, scratch_bucket)
    started = time.monotonic()
    deadline = started + timeout_seconds
    response = b""
    connection_failure: str | None = None
    connected = False
    try:
        with socket.create_connection(
            ("127.0.0.1", client.port), timeout=_remaining(deadline)
        ) as sock:
            connected = True
            sock.settimeout(_remaining(deadline))
            try:
                sock.sendall(request)
            except (ConnectionResetError, BrokenPipeError) as error:
                connection_failure = type(error).__name__
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError as error:
                if error.errno not in (errno.ENOTCONN, errno.EPIPE, errno.EINVAL):
                    raise
                connection_failure = connection_failure or type(error).__name__
            if connection_failure is None:
                response, connection_failure = _read_bounded(sock, deadline)
    except socket.timeout as error:
        raise BoundaryFailure("connection or write exceeded its deadline") from error
    except ConnectionRefusedError as error:
        raise BoundaryFailure("local disposable endpoint refused the connection") from error
    except OSError as error:
        if not connected or not spec.allow_connection_close:
            raise BoundaryFailure(
                f"unexpected transport failure for {spec.name}: {type(error).__name__}"
            ) from error
        connection_failure = type(error).__name__

    elapsed = time.monotonic() - started
    if elapsed > timeout_seconds + 0.05:
        raise BoundaryFailure(
            f"case elapsed {elapsed:.3f}s, deadline was {timeout_seconds:.3f}s"
        )
    if not response:
        if not spec.allow_connection_close:
            raise BoundaryFailure(
                f"{spec.name} closed without a bounded S3 error response"
            )
        return WireOutcome(
            kind="bounded-close",
            response_bytes=0,
            elapsed_seconds=elapsed,
            connection_failure=connection_failure or "EOF",
        )
    status, code = parse_error_response(response)
    if code not in spec.allowed_codes:
        raise BoundaryFailure(
            f"{spec.name}: expected S3 error {spec.allowed_codes}, got {code!r}"
        )
    return WireOutcome(
        kind="s3-error",
        response_bytes=len(response),
        elapsed_seconds=elapsed,
        status=status,
        s3_error=code,
        connection_failure=connection_failure,
    )


def sentinel_payload() -> bytes:
    block = hashlib.sha256(b"pgs3-robust-sentinel\0" + FIXED_SEED.encode()).digest()
    return (block * ((SENTINEL_BYTES + len(block) - 1) // len(block)))[:SENTINEL_BYTES]


def _expect_status(operation: str, response: object, expected: Iterable[int]) -> None:
    statuses = set(expected)
    status = getattr(response, "status")
    if status not in statuses:
        raise BoundaryFailure(
            f"{operation}: expected HTTP {sorted(statuses)}, got {status}"
        )


def setup_sentinel(client: SigV4Client, bucket: str, key: str) -> None:
    payload = sentinel_payload()
    create = client.request("PUT", _s3_path(bucket))
    _expect_status("CreateBucket sentinel", create, (200,))
    put = client.request("PUT", _s3_path(bucket, key), body=payload)
    _expect_status("PutObject sentinel", put, (200,))
    probe_sentinel(client, bucket, key)
    print(
        json.dumps(
            {
                "operation": "sentinel-setup",
                "bucket_sha256": hashlib.sha256(bucket.encode()).hexdigest(),
                "key": key,
                "bytes": len(payload),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "result": "PASS",
            },
            sort_keys=True,
        ),
        flush=True,
    )


def probe_sentinel(client: SigV4Client, bucket: str, key: str) -> None:
    expected = sentinel_payload()
    response = client.request("GET", _s3_path(bucket, key))
    _expect_status("signed GetObject sentinel", response, (200,))
    if response.body != expected:
        raise BoundaryFailure("signed sentinel GET returned unexpected bytes")


def _validate_bucket(bucket: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", bucket):
        raise BoundaryFailure("bucket must contain 3..63 lowercase letters, digits, or dashes")
    return bucket


def _validate_key(key: str) -> str:
    encoded = key.encode("utf-8")
    if not encoded or len(encoded) > 512 or any(byte < 0x20 for byte in encoded):
        raise BoundaryFailure("sentinel key must contain 1..512 non-control UTF-8 bytes")
    return key


def _runtime(arguments: argparse.Namespace) -> tuple[SigV4Client, str, str]:
    return (
        make_client(arguments.endpoint),
        _validate_bucket(arguments.bucket),
        _validate_key(arguments.key),
    )


def command_describe(_arguments: argparse.Namespace) -> int:
    specs = case_specs()
    record = {
        "schema": "pgs3.http-boundary-corpus.v1",
        "seed": FIXED_SEED,
        "batches": list(EXPECTED_BATCHES),
        "total_cases": len(specs),
        "case_timeout_seconds": CASE_TIMEOUT_SECONDS,
        "max_template_bytes": MAX_TEMPLATE_BYTES,
        "max_rendered_request_bytes": MAX_RENDERED_REQUEST_BYTES,
        "max_response_bytes": MAX_RESPONSE_BYTES,
        "corpus_sha256": corpus_digest(specs),
        "cases": [spec.public_record() for spec in specs],
    }
    print(json.dumps(record, indent=2, sort_keys=True))
    return 0


def command_setup(arguments: argparse.Namespace) -> int:
    client, bucket, key = _runtime(arguments)
    setup_sentinel(client, bucket, key)
    return 0


def command_probe(arguments: argparse.Namespace) -> int:
    client, bucket, key = _runtime(arguments)
    probe_sentinel(client, bucket, key)
    print(
        json.dumps(
            {
                "operation": "signed-sentinel-get",
                "bytes": SENTINEL_BYTES,
                "sha256": hashlib.sha256(sentinel_payload()).hexdigest(),
                "result": "PASS",
            },
            sort_keys=True,
        ),
        flush=True,
    )
    return 0


def command_batch(arguments: argparse.Namespace) -> int:
    client, bucket, _key = _runtime(arguments)
    scratch_bucket = _validate_bucket(arguments.scratch_bucket)
    specs = [spec for spec in case_specs() if spec.batch == arguments.batch]
    if not specs:
        raise BoundaryFailure(f"unknown or empty boundary batch: {arguments.batch}")
    for spec in specs:
        outcome = send_case(spec, client, bucket, scratch_bucket)
        record = spec.public_record()
        record.update(
            {
                "outcome": outcome.kind,
                "response_bytes": outcome.response_bytes,
                "elapsed_seconds": round(outcome.elapsed_seconds, 6),
                "status": outcome.status,
                "s3_error": outcome.s3_error,
                "connection_failure": outcome.connection_failure,
                "result": "PASS",
            }
        )
        print(json.dumps(record, sort_keys=True), flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    describe = commands.add_parser("describe")
    describe.set_defaults(function=command_describe)

    runtime = argparse.ArgumentParser(add_help=False)
    runtime.add_argument("--endpoint", required=True)
    runtime.add_argument("--bucket", required=True)
    runtime.add_argument("--key", required=True)
    setup = commands.add_parser("setup", parents=[runtime])
    setup.set_defaults(function=command_setup)
    probe = commands.add_parser("probe", parents=[runtime])
    probe.set_defaults(function=command_probe)
    batch = commands.add_parser("batch", parents=[runtime])
    batch.add_argument("--batch", required=True, choices=EXPECTED_BATCHES)
    batch.add_argument("--scratch-bucket", required=True)
    batch.set_defaults(function=command_batch)
    return parser


def main() -> int:
    try:
        arguments = build_parser().parse_args()
        return arguments.function(arguments)
    except (BoundaryFailure, ValueError) as error:
        print(f"HTTP boundary assertion failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
