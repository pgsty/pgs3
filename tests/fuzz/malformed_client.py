#!/usr/bin/env python3
"""Bounded, deterministic malformed HTTP corpus for acceptance requirement 9.

Credentials are read only from the environment.  Wire requests may contain an
Authorization header, but emitted JSON contains only case metadata, response
classification, sizes, digests, and elapsed time.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import random
import re
import socket
import sys
import time
from typing import Iterable, Mapping
import urllib.parse
import xml.etree.ElementTree as ET


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "integration"
sys.path.insert(0, str(INTEGRATION_DIR))

from sigv4_probe import SigV4Client, _error_code, _s3_path  # noqa: E402


DEFAULT_SEED = "pgs3-acceptance-9-v1"
DEFAULT_RANDOM_CASES = 16
DEFAULT_TIMEOUT_SECONDS = 3.0
MAX_CASE_TIMEOUT_SECONDS = 10.0
MAX_REQUEST_BYTES = 128 * 1024
MAX_RESPONSE_BYTES = 128 * 1024
MAX_RANDOM_CASES = 64
MAX_SEED_BYTES = 128
SENTINEL_BYTES = 4096

REQUIRED_CATEGORIES = frozenset(
    {
        "oversized-header",
        "invalid-xml",
        "content-length-short",
        "content-length-long",
        "incomplete-body",
        "invalid-chunked",
        "request-smuggling",
        "deterministic-random",
    }
)


class FuzzFailure(RuntimeError):
    """An acceptance assertion failed, rather than a tolerated peer close."""


@dataclass(frozen=True)
class CaseSpec:
    name: str
    category: str
    mode: str
    raw: bytes = b""
    body: bytes = b""
    declared_length: int | None = None
    signed_body: bytes | None = None
    allowed_statuses: tuple[int, ...] = (400,)
    allowed_codes: tuple[str, ...] = ("InvalidRequest",)
    allow_connection_close: bool = True

    def fingerprint(self) -> str:
        document = {
            "name": self.name,
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
            "allowed_statuses": self.allowed_statuses,
            "allowed_codes": self.allowed_codes,
            "allow_connection_close": self.allow_connection_close,
        }
        encoded = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()

    def public_record(self) -> dict[str, object]:
        return {
            "name": self.name,
            "category": self.category,
            "mode": self.mode,
            "case_sha256": self.fingerprint(),
            "template_bytes": len(self.raw) + len(self.body),
            "allowed_statuses": list(self.allowed_statuses),
            "allowed_codes": list(self.allowed_codes),
            "allow_connection_close": self.allow_connection_close,
        }


@dataclass(frozen=True)
class WireOutcome:
    kind: str
    response_bytes: int
    elapsed_seconds: float
    status: int | None = None
    s3_error: str | None = None
    connection_failure: str | None = None


def _validate_seed(seed: str) -> str:
    encoded = seed.encode("utf-8")
    if not encoded or len(encoded) > MAX_SEED_BYTES:
        raise FuzzFailure(
            f"seed must contain 1..{MAX_SEED_BYTES} UTF-8 bytes"
        )
    if any(byte < 0x20 or byte == 0x7F for byte in encoded):
        raise FuzzFailure("seed cannot contain control characters")
    return seed


def _random_raw_case(rng: random.Random, index: int) -> CaseSpec:
    token = "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(24))
    choice = rng.randrange(12)
    if choice == 0:
        raw = f"G\x00ET /{token} HTTP/1.1\r\nHost: fuzz.invalid\r\n\r\n".encode()
    elif choice == 1:
        raw = f"GET /{token} HTTP/9.{rng.randrange(2, 10)}\r\nHost: fuzz.invalid\r\n\r\n".encode()
    elif choice == 2:
        raw = f"GET /{token} HTTP/1.1\r\nX-Fuzz: {token}\r\n\r\n".encode()
    elif choice == 3:
        raw = (
            f"GET /{token} HTTP/1.1\r\nHost: one.invalid\r\n"
            "Host: two.invalid\r\n\r\n"
        ).encode()
    elif choice == 4:
        raw = f"GET /{token} HTTP/1.1\r\nBad Header: value\r\nHost: fuzz.invalid\r\n\r\n".encode()
    elif choice == 5:
        raw = f"GET /{token} HTTP/1.1\r\nHost: fuzz.invalid\r\n folded\r\n\r\n".encode()
    elif choice == 6:
        raw = f"GET /bad-%{token[:1]} HTTP/1.1\r\nHost: fuzz.invalid\r\n\r\n".encode()
    elif choice == 7:
        raw = (
            f"POST /{token} HTTP/1.1\r\nHost: fuzz.invalid\r\n"
            "Transfer-Encoding: gzip, chunked\r\n\r\n"
        ).encode()
    elif choice == 8:
        raw = (
            f"POST /{token} HTTP/1.1\r\nHost: fuzz.invalid\r\n"
            "Content-Length: 0\r\nContent-Length: 0\r\n\r\n"
        ).encode()
    elif choice == 9:
        raw = f"GET /{token} HTTP/1.1\nHost: fuzz.invalid\n\n".encode()
    elif choice == 10:
        raw = f"GET /{token} HTTP/1.1\r\nHost: fuzz.invalid\r\nX-Fuzz: \x7f\r\n\r\n".encode()
    else:
        raw = f"GET /{token} HTTP/1.1\r\nHost: fuzz.invalid\r\nX-Truncated: {token}".encode()
    return CaseSpec(
        name=f"random-{index:03d}",
        category="deterministic-random",
        mode="raw",
        raw=raw,
    )


def case_specs(seed: str, random_cases: int) -> tuple[CaseSpec, ...]:
    _validate_seed(seed)
    if not 1 <= random_cases <= MAX_RANDOM_CASES:
        raise FuzzFailure(f"random case count must be in 1..{MAX_RANDOM_CASES}")

    oversized = (
        b"GET / HTTP/1.1\r\nHost: fuzz.invalid\r\nX-Oversized: "
        + b"h" * (70 * 1024)
        + b"\r\n\r\n"
    )
    invalid_xml = (
        b"<?xml version=\"1.0\"?><CreateBucketConfiguration>"
        b"<LocationConstraint>&broken"
    )
    smuggling = (
        b"POST /smuggled HTTP/1.1\r\n"
        b"Host: fuzz.invalid\r\n"
        b"Content-Length: 4\r\n"
        b"Transfer-Encoding: chunked\r\n\r\n"
        b"0\r\n\r\nGET /must-not-run HTTP/1.1\r\nHost: fuzz.invalid\r\n\r\n"
    )
    core = (
        CaseSpec(
            name="oversized-header",
            category="oversized-header",
            mode="raw",
            raw=oversized,
        ),
        CaseSpec(
            name="invalid-xml",
            category="invalid-xml",
            mode="signed-invalid-xml",
            body=invalid_xml,
            declared_length=len(invalid_xml),
            allowed_codes=("MalformedXML",),
            allow_connection_close=False,
        ),
        CaseSpec(
            name="content-length-short",
            category="content-length-short",
            mode="signed-content-length-short",
            body=b"ABCDGET /must-not-run HTTP/1.1\r\nHost: fuzz.invalid\r\n\r\n",
            declared_length=3,
            signed_body=b"ABCD",
            allowed_codes=("XAmzContentSHA256Mismatch",),
            allow_connection_close=False,
        ),
        CaseSpec(
            name="content-length-long",
            category="content-length-long",
            mode="signed-content-length-long",
            body=b"four",
            declared_length=9,
            signed_body=b"four",
            allowed_codes=("IncompleteBody",),
            allow_connection_close=False,
        ),
        CaseSpec(
            name="incomplete-body",
            category="incomplete-body",
            mode="signed-incomplete-chunked",
            body=b"5\r\nabc",
            signed_body=b"abcde",
            allowed_codes=("IncompleteBody",),
            allow_connection_close=False,
        ),
        CaseSpec(
            name="invalid-chunked",
            category="invalid-chunked",
            mode="signed-invalid-chunked",
            body=b"z\r\nnot-a-chunk\r\n0\r\n\r\n",
            signed_body=b"",
            allowed_codes=("InvalidRequest",),
            allow_connection_close=False,
        ),
        CaseSpec(
            name="request-smuggling-cl-te",
            category="request-smuggling",
            mode="raw",
            raw=smuggling,
        ),
        CaseSpec(
            name="request-smuggling-duplicate-cl",
            category="request-smuggling",
            mode="raw",
            raw=(
                b"POST /smuggled HTTP/1.1\r\nHost: fuzz.invalid\r\n"
                b"Content-Length: 0\r\nContent-Length: 43\r\n\r\n"
                b"GET /must-not-run HTTP/1.1\r\nHost: fuzz.invalid\r\n\r\n"
            ),
        ),
    )
    seed_number = int.from_bytes(
        hashlib.sha256(b"pgs3-fuzz-corpus\0" + seed.encode()).digest(), "big"
    )
    rng = random.Random(seed_number)
    random_specs = tuple(_random_raw_case(rng, index) for index in range(random_cases))
    specs = core + random_specs
    if len({spec.name for spec in specs}) != len(specs):
        raise AssertionError("corpus case names must be unique")
    if {spec.category for spec in specs} < REQUIRED_CATEGORIES:
        raise AssertionError("required malformed-request categories are missing")
    if any(len(spec.raw) + len(spec.body) > MAX_REQUEST_BYTES for spec in specs):
        raise AssertionError("a corpus template exceeds MAX_REQUEST_BYTES")
    return specs


def corpus_digest(specs: Iterable[CaseSpec]) -> str:
    digest = hashlib.sha256(b"pgs3-malformed-corpus-v1\0")
    for spec in specs:
        digest.update(spec.name.encode())
        digest.update(b"\0")
        digest.update(spec.fingerprint().encode())
        digest.update(b"\0")
    return digest.hexdigest()


def _credential(name: str) -> str:
    variable = {
        "access": "PGS3_FUZZ_ACCESS_KEY",
        "secret": "PGS3_FUZZ_SECRET",
    }[name]
    value = os.environ.get(variable, "")
    if not value:
        raise FuzzFailure(f"required credential environment variable is empty: {variable}")
    return value


def make_client(endpoint: str, region: str, timeout: float) -> SigV4Client:
    return SigV4Client(
        endpoint,
        _credential("access"),
        _credential("secret"),
        region,
        timeout=timeout,
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
    head = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")
    return head + body


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
    elif spec.mode in {"signed-content-length-short", "signed-content-length-long"}:
        request = _signed_request(
            client,
            "PUT",
            _s3_path(bucket, f"malformed/{spec.name}.bin"),
            spec.body,
            spec.signed_body if spec.signed_body is not None else spec.body,
            content_length=spec.declared_length,
        )
    elif spec.mode in {"signed-incomplete-chunked", "signed-invalid-chunked"}:
        request = _signed_request(
            client,
            "PUT",
            _s3_path(bucket, f"malformed/{spec.name}.bin"),
            spec.body,
            spec.signed_body if spec.signed_body is not None else spec.body,
            content_length=None,
            extra_headers={"transfer-encoding": "chunked"},
        )
    else:
        raise AssertionError(f"unknown case mode: {spec.mode}")
    if len(request) > MAX_REQUEST_BYTES:
        raise FuzzFailure(
            f"case {spec.name} rendered {len(request)} bytes, limit is {MAX_REQUEST_BYTES}"
        )
    return request


def _remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise FuzzFailure("case exceeded its absolute deadline")
    return remaining


def _read_bounded(sock: socket.socket, deadline: float) -> tuple[bytes, str | None]:
    response = bytearray()
    connection_failure = None
    while True:
        sock.settimeout(_remaining(deadline))
        try:
            chunk = sock.recv(16 * 1024)
        except socket.timeout as error:
            raise FuzzFailure("server did not close or respond before the case deadline") from error
        except (ConnectionResetError, BrokenPipeError) as error:
            connection_failure = type(error).__name__
            break
        if not chunk:
            break
        response.extend(chunk)
        if len(response) > MAX_RESPONSE_BYTES:
            raise FuzzFailure(
                f"response exceeded the {MAX_RESPONSE_BYTES}-byte evidence limit"
            )
    return bytes(response), connection_failure


def _parse_error_response(raw: bytes) -> tuple[int, str | None]:
    marker = raw.find(b"\r\n\r\n")
    if marker < 0:
        raise FuzzFailure("peer returned a truncated HTTP response head")
    head, body = raw[:marker], raw[marker + 4 :]
    lines = head.split(b"\r\n")
    match = re.fullmatch(rb"HTTP/1\.[01] ([0-9]{3})(?: [^\r\n]*)?", lines[0])
    if not match:
        raise FuzzFailure("peer returned an invalid HTTP status line")
    status = int(match.group(1))
    headers: dict[bytes, list[bytes]] = {}
    for line in lines[1:]:
        if b":" not in line:
            raise FuzzFailure("peer returned a malformed response header")
        name, value = line.split(b":", 1)
        headers.setdefault(name.strip().lower(), []).append(value.strip())
    lengths = headers.get(b"content-length", [])
    if len(lengths) != 1 or not lengths[0].isdigit():
        raise FuzzFailure("error response must contain one numeric Content-Length")
    expected = int(lengths[0])
    if expected > MAX_RESPONSE_BYTES or expected != len(body):
        raise FuzzFailure(
            f"error response length mismatch: declared={expected} received={len(body)}"
        )
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        raise FuzzFailure("error response body is not bounded S3 XML") from error
    code_node = root.find(".//Code")
    code = code_node.text if code_node is not None else None
    return status, code


def send_case(
    spec: CaseSpec,
    client: SigV4Client,
    bucket: str,
    scratch_bucket: str,
    timeout: float,
) -> WireOutcome:
    if not 0.1 <= timeout <= MAX_CASE_TIMEOUT_SECONDS:
        raise FuzzFailure(
            f"case timeout must be in 0.1..{MAX_CASE_TIMEOUT_SECONDS:.1f} seconds"
        )
    request = render_case(spec, client, bucket, scratch_bucket)
    started = time.monotonic()
    deadline = started + timeout
    response = b""
    connection_failure: str | None = None
    connected = False
    try:
        with socket.create_connection(
            (client.host, client.port), timeout=_remaining(deadline)
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
        raise FuzzFailure("case connection or write exceeded its deadline") from error
    except ConnectionRefusedError as error:
        raise FuzzFailure("S3 endpoint refused the case connection") from error
    except OSError as error:
        if not connected or not spec.allow_connection_close:
            raise FuzzFailure(
                f"unexpected transport failure while sending {spec.name}: {type(error).__name__}"
            ) from error
        connection_failure = type(error).__name__

    elapsed = time.monotonic() - started
    if elapsed > timeout + 0.05:
        raise FuzzFailure(
            f"case elapsed {elapsed:.3f}s, deadline was {timeout:.3f}s"
        )
    if not response:
        if not spec.allow_connection_close:
            raise FuzzFailure(f"{spec.name} closed without a bounded S3 error response")
        return WireOutcome(
            kind="connection-failure",
            response_bytes=0,
            elapsed_seconds=elapsed,
            connection_failure=connection_failure or "EOF",
        )
    status, code = _parse_error_response(response)
    if status not in spec.allowed_statuses:
        raise FuzzFailure(
            f"{spec.name}: expected HTTP {spec.allowed_statuses}, got {status}"
        )
    if code not in spec.allowed_codes:
        raise FuzzFailure(
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


def sentinel_payload(seed: str) -> bytes:
    block = hashlib.sha256(b"pgs3-fuzz-sentinel\0" + seed.encode()).digest()
    return (block * ((SENTINEL_BYTES + len(block) - 1) // len(block)))[:SENTINEL_BYTES]


def _expect_status(operation: str, response, expected: Iterable[int]) -> None:
    statuses = set(expected)
    if response.status not in statuses:
        raise FuzzFailure(
            f"{operation}: expected HTTP {sorted(statuses)}, got {response.status}"
        )


def setup_sentinel(client: SigV4Client, bucket: str, key: str, seed: str) -> None:
    payload = sentinel_payload(seed)
    create = client.request("PUT", _s3_path(bucket))
    _expect_status("CreateBucket sentinel", create, (200,))
    put = client.request("PUT", _s3_path(bucket, key), body=payload)
    _expect_status("PutObject sentinel", put, (200,))
    probe_sentinel(client, bucket, key, seed)
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


def probe_sentinel(client: SigV4Client, bucket: str, key: str, seed: str) -> None:
    expected = sentinel_payload(seed)
    response = client.request("GET", _s3_path(bucket, key))
    _expect_status("GetObject sentinel", response, (200,))
    if response.body != expected:
        raise FuzzFailure("legal sentinel response changed after a malformed request")


def _version_entries(body: bytes) -> list[tuple[str, str]]:
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        raise FuzzFailure("ListObjectVersions cleanup response is not XML") from error
    entries: list[tuple[str, str]] = []
    for tag in ("Version", "DeleteMarker"):
        for node in root.findall(f".//{{*}}{tag}") + root.findall(f".//{tag}"):
            key_node = node.find("{*}Key")
            version_node = node.find("{*}VersionId")
            if key_node is None:
                key_node = node.find("Key")
            if version_node is None:
                version_node = node.find("VersionId")
            if key_node is not None and version_node is not None:
                entries.append((key_node.text or "", version_node.text or ""))
    return entries


def cleanup_sentinel(client: SigV4Client, bucket: str) -> None:
    listing = client.request("GET", _s3_path(bucket), query=(("versions", ""),))
    _expect_status("ListObjectVersions cleanup", listing, (200,))
    entries = _version_entries(listing.body)
    for key, version_id in entries:
        response = client.request(
            "DELETE",
            _s3_path(bucket, key),
            query=(("versionId", version_id),),
        )
        _expect_status("DeleteObject version cleanup", response, (204,))
    deleted = client.request("DELETE", _s3_path(bucket))
    _expect_status("DeleteBucket cleanup", deleted, (204,))
    print(
        json.dumps(
            {
                "operation": "sentinel-cleanup",
                "versions_deleted": len(entries),
                "result": "PASS",
            },
            sort_keys=True,
        ),
        flush=True,
    )


def _validate_bucket(name: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", name):
        raise FuzzFailure("bucket must contain 3..63 lowercase letters, digits, or dashes")
    return name


def _validate_key(key: str) -> str:
    encoded = key.encode("utf-8")
    if not encoded or len(encoded) > 512 or any(byte < 0x20 for byte in encoded):
        raise FuzzFailure("sentinel key must contain 1..512 non-control UTF-8 bytes")
    return key


def _common_runtime(arguments: argparse.Namespace) -> tuple[SigV4Client, str, str]:
    if not 0.1 <= arguments.timeout <= MAX_CASE_TIMEOUT_SECONDS:
        raise FuzzFailure(
            f"timeout must be in 0.1..{MAX_CASE_TIMEOUT_SECONDS:.1f} seconds"
        )
    bucket = _validate_bucket(arguments.bucket)
    key = _validate_key(arguments.key)
    client = make_client(arguments.endpoint, arguments.region, arguments.timeout)
    return client, bucket, key


def command_names(arguments: argparse.Namespace) -> int:
    for spec in case_specs(arguments.seed, arguments.random_cases):
        print(spec.name)
    return 0


def command_describe(arguments: argparse.Namespace) -> int:
    specs = case_specs(arguments.seed, arguments.random_cases)
    record = {
        "schema": "pgs3.malformed-corpus.v1",
        "seed": arguments.seed,
        "random_cases": arguments.random_cases,
        "total_cases": len(specs),
        "max_request_bytes": MAX_REQUEST_BYTES,
        "max_response_bytes": MAX_RESPONSE_BYTES,
        "case_timeout_seconds": arguments.timeout,
        "corpus_sha256": corpus_digest(specs),
        "cases": [spec.public_record() for spec in specs],
    }
    print(json.dumps(record, indent=2, sort_keys=True))
    return 0


def command_setup(arguments: argparse.Namespace) -> int:
    client, bucket, key = _common_runtime(arguments)
    setup_sentinel(client, bucket, key, arguments.seed)
    return 0


def command_probe(arguments: argparse.Namespace) -> int:
    client, bucket, key = _common_runtime(arguments)
    probe_sentinel(client, bucket, key, arguments.seed)
    print(
        json.dumps(
            {
                "operation": "legal-sentinel-probe",
                "bytes": SENTINEL_BYTES,
                "sha256": hashlib.sha256(sentinel_payload(arguments.seed)).hexdigest(),
                "result": "PASS",
            },
            sort_keys=True,
        )
    )
    return 0


def command_case(arguments: argparse.Namespace) -> int:
    client, bucket, key = _common_runtime(arguments)
    specs = {spec.name: spec for spec in case_specs(arguments.seed, arguments.random_cases)}
    try:
        spec = specs[arguments.case]
    except KeyError as error:
        raise FuzzFailure(f"unknown corpus case: {arguments.case}") from error
    scratch_bucket = _validate_bucket(arguments.scratch_bucket)
    outcome = send_case(spec, client, bucket, scratch_bucket, arguments.timeout)
    probe_sentinel(client, bucket, key, arguments.seed)
    record = spec.public_record()
    record.update(
        {
            "outcome": outcome.kind,
            "response_bytes": outcome.response_bytes,
            "elapsed_seconds": round(outcome.elapsed_seconds, 6),
            "status": outcome.status,
            "s3_error": outcome.s3_error,
            "connection_failure": outcome.connection_failure,
            "legal_sentinel": "PASS",
        }
    )
    print(json.dumps(record, sort_keys=True), flush=True)
    return 0


def command_cleanup(arguments: argparse.Namespace) -> int:
    client, bucket, _key = _common_runtime(arguments)
    cleanup_sentinel(client, bucket)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    common_corpus = argparse.ArgumentParser(add_help=False)
    common_corpus.add_argument("--seed", default=DEFAULT_SEED, type=_validate_seed)
    common_corpus.add_argument(
        "--random-cases", type=int, default=DEFAULT_RANDOM_CASES
    )
    common_corpus.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS
    )
    commands = parser.add_subparsers(dest="command", required=True)

    names = commands.add_parser("names", parents=[common_corpus])
    names.set_defaults(function=command_names)
    describe = commands.add_parser("describe", parents=[common_corpus])
    describe.set_defaults(function=command_describe)

    for name, function in (
        ("setup", command_setup),
        ("probe", command_probe),
        ("case", command_case),
        ("cleanup", command_cleanup),
    ):
        command = commands.add_parser(name, parents=[common_corpus])
        command.add_argument("--endpoint", required=True)
        command.add_argument("--region", default="us-east-1")
        command.add_argument("--bucket", required=True)
        command.add_argument("--key", required=True)
        if name == "case":
            command.add_argument("--case", required=True)
            command.add_argument("--scratch-bucket", required=True)
        command.set_defaults(function=function)
    return parser


def main() -> int:
    try:
        arguments = build_parser().parse_args()
        if not 1 <= arguments.random_cases <= MAX_RANDOM_CASES:
            raise FuzzFailure(
                f"random case count must be in 1..{MAX_RANDOM_CASES}"
            )
        return arguments.function(arguments)
    except (FuzzFailure, ValueError) as error:
        print(f"fuzz assertion failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
