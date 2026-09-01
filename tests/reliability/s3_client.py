#!/usr/bin/env python3
"""Small, dependency-free S3 client used by the reliability gates.

The signer is shared with the integration probe.  This file deliberately never
prints request headers or credentials; its JSON output contains only operation
results, object sizes, and content digests.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "integration"
sys.path.insert(0, str(INTEGRATION_DIR))

from sigv4_probe import (  # noqa: E402 - local test helper path is intentional
    SigV4Client,
    _error_code,
    _s3_path,
)


class ReliabilityFailure(RuntimeError):
    """A failed acceptance assertion, as distinct from a client transport error."""


def _credential(name: str) -> str:
    aliases = {
        "access": ("PGS3_TEST_ACCESS_KEY_A", "PGS3_ACCESS_KEY_A"),
        "secret": ("PGS3_TEST_SECRET_A", "PGS3_SECRET_A"),
    }
    for variable in aliases[name]:
        value = os.environ.get(variable, "")
        if value:
            return value
    raise ReliabilityFailure(f"a test {name} credential environment variable is required")


def client(arguments: argparse.Namespace) -> SigV4Client:
    return SigV4Client(
        arguments.endpoint,
        _credential("access"),
        _credential("secret"),
        arguments.region,
        timeout=arguments.timeout,
    )


def pattern_block(seed: str) -> bytes:
    encoded = seed.encode("utf-8")
    return hashlib.sha256(b"pgs3-reliability\0" + encoded).digest() + encoded + b"\n"


def iter_pattern(size: int, seed: str, chunk_size: int = 1024 * 1024):
    if size < 0:
        raise ValueError("size must be nonnegative")
    block = pattern_block(seed)
    offset = 0
    while offset < size:
        wanted = min(chunk_size, size - offset)
        phase = offset % len(block)
        repeats = (phase + wanted + len(block) - 1) // len(block)
        yield (block * repeats)[phase : phase + wanted]
        offset += wanted


def pattern_bytes(size: int, seed: str) -> bytes:
    return b"".join(iter_pattern(size, seed))


def pattern_sha256(size: int, seed: str) -> str:
    digest = hashlib.sha256()
    for chunk in iter_pattern(size, seed):
        digest.update(chunk)
    return digest.hexdigest()


def xml_message(body: bytes) -> str | None:
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return None
    node = root.find(".//{*}Message")
    if node is None:
        node = root.find(".//Message")
    return node.text if node is not None else None


def object_keys(body: bytes) -> set[str]:
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        raise ReliabilityFailure(f"list response is not XML: {error}") from error
    nodes = root.findall(".//{*}Contents/{*}Key") + root.findall(".//Contents/Key")
    return {node.text or "" for node in nodes}


def emit(**record: object) -> None:
    print(json.dumps(record, sort_keys=True), flush=True)


def require_status(operation: str, response, expected: int) -> None:
    code = _error_code(response)
    emit(
        operation=operation,
        status=response.status,
        s3_error=code,
        content_length=response.header("content-length"),
    )
    if response.status != expected:
        excerpt = response.body[:512].decode("utf-8", "replace")
        raise ReliabilityFailure(
            f"{operation}: expected HTTP {expected}, got {response.status}: {excerpt}"
        )


def command_create_bucket(arguments: argparse.Namespace) -> int:
    response = client(arguments).request("PUT", _s3_path(arguments.bucket))
    require_status("CreateBucket", response, 200)
    return 0


def command_put(arguments: argparse.Namespace) -> int:
    payload = pattern_bytes(arguments.size, arguments.seed)
    expected = hashlib.sha256(payload).hexdigest()
    response = client(arguments).request(
        "PUT", _s3_path(arguments.bucket, arguments.key), body=payload
    )
    require_status("PutObject", response, 200)
    if not response.header("etag"):
        raise ReliabilityFailure("PutObject omitted ETag")
    emit(operation="PutObjectDigest", size=len(payload), sha256=expected)
    return 0


def command_get(arguments: argparse.Namespace) -> int:
    response = client(arguments).request("GET", _s3_path(arguments.bucket, arguments.key))
    require_status("GetObject", response, 200)
    actual = hashlib.sha256(response.body).hexdigest()
    expected = arguments.sha256 or pattern_sha256(arguments.size, arguments.seed)
    if len(response.body) != arguments.size:
        raise ReliabilityFailure(
            f"GetObject size mismatch: expected {arguments.size}, got {len(response.body)}"
        )
    if actual != expected:
        raise ReliabilityFailure(f"GetObject SHA-256 mismatch: expected {expected}, got {actual}")
    emit(operation="GetObjectDigest", size=len(response.body), sha256=actual)
    return 0


def command_list_contains(arguments: argparse.Namespace) -> int:
    response = client(arguments).request(
        "GET",
        _s3_path(arguments.bucket),
        query=(("list-type", "2"), ("prefix", arguments.prefix)),
    )
    require_status("ListObjectsV2", response, 200)
    keys = object_keys(response.body)
    if arguments.key not in keys:
        raise ReliabilityFailure(f"ListObjectsV2 did not contain {arguments.key!r}: {sorted(keys)}")
    emit(operation="ListContains", key=arguments.key, listed=True)
    return 0


def command_not_visible(arguments: argparse.Namespace) -> int:
    signed = client(arguments)
    response = signed.request("GET", _s3_path(arguments.bucket, arguments.key))
    require_status("GetMissingObject", response, 404)
    if _error_code(response) != "NoSuchKey":
        raise ReliabilityFailure(
            f"missing object returned S3 error {_error_code(response)!r}, expected NoSuchKey"
        )
    listing = signed.request(
        "GET",
        _s3_path(arguments.bucket),
        query=(("list-type", "2"), ("prefix", arguments.key)),
    )
    require_status("ListObjectsV2Missing", listing, 200)
    keys = object_keys(listing.body)
    if arguments.key in keys:
        raise ReliabilityFailure("partially uploaded key was visible in ListObjectsV2")
    emit(operation="ObjectNotVisible", key=arguments.key, listed=False)
    return 0


def command_expect_error(arguments: argparse.Namespace) -> int:
    body = pattern_bytes(arguments.size, arguments.seed)
    signed = client(arguments)
    path = _s3_path(arguments.bucket, arguments.key) if arguments.key else _s3_path(arguments.bucket)
    query = (("list-type", "2"),) if arguments.list_v2 else ()
    started = time.monotonic()
    response = signed.request(arguments.method, path, query=query, body=body)
    elapsed = time.monotonic() - started
    require_status(arguments.operation, response, arguments.status)
    code = _error_code(response)
    message = xml_message(response.body)
    if code != arguments.code:
        raise ReliabilityFailure(f"expected S3 error {arguments.code}, got {code!r}")
    if arguments.message and arguments.message.lower() not in (message or "").lower():
        raise ReliabilityFailure(
            f"S3 error message did not contain {arguments.message!r}: {message!r}"
        )
    if arguments.max_elapsed is not None and elapsed >= arguments.max_elapsed:
        raise ReliabilityFailure(
            f"request took {elapsed:.3f}s, expected less than {arguments.max_elapsed:.3f}s"
        )
    emit(
        operation=f"{arguments.operation}Assertion",
        status=response.status,
        s3_error=code,
        message=message,
        elapsed_seconds=round(elapsed, 6),
    )
    return 0


def command_early_put_error(arguments: argparse.Namespace) -> int:
    """Send only a signed PutObject head and require a final error response.

    With Expect: 100-continue, a writable primary would send the interim response
    and wait for the entity.  A standby must instead reject the operation from
    the authenticated head, before any payload byte is transmitted.
    """

    signed = client(arguments)
    path = _s3_path(arguments.bucket, arguments.key)
    payload_hash = pattern_sha256(arguments.size, arguments.seed)
    headers = signed.signed_headers(
        "PUT", path, (), payload_hash, extra_headers={"expect": "100-continue"}
    )
    connection = http.client.HTTPConnection(signed.host, signed.port, timeout=arguments.timeout)
    started = time.monotonic()
    try:
        connection.putrequest("PUT", path, skip_host=True, skip_accept_encoding=True)
        for name, value in headers.items():
            connection.putheader(name, value)
        connection.putheader("content-length", str(arguments.size))
        connection.endheaders()
        response = connection.getresponse()
        body = response.read()
    finally:
        connection.close()
    elapsed = time.monotonic() - started
    proxy = type("Response", (), {"body": body})()
    code = _error_code(proxy)
    message = xml_message(body)
    emit(
        operation="EarlyPutObjectRejection",
        status=response.status,
        s3_error=code,
        message=message,
        declared_bytes=arguments.size,
        bytes_sent=0,
        elapsed_seconds=round(elapsed, 6),
    )
    if response.status != arguments.status or code != arguments.code:
        raise ReliabilityFailure(
            f"expected early HTTP {arguments.status}/{arguments.code}, got "
            f"{response.status}/{code}"
        )
    if arguments.message and arguments.message.lower() not in (message or "").lower():
        raise ReliabilityFailure(
            f"S3 error message did not contain {arguments.message!r}: {message!r}"
        )
    return 0


def command_slow_put(arguments: argparse.Namespace) -> int:
    signed = client(arguments)
    path = _s3_path(arguments.bucket, arguments.key)
    payload_hash = pattern_sha256(arguments.size, arguments.seed)
    headers = signed.signed_headers("PUT", path, (), payload_hash)
    connection = http.client.HTTPConnection(signed.host, signed.port, timeout=arguments.timeout)
    sent = 0
    try:
        connection.putrequest("PUT", path, skip_host=True, skip_accept_encoding=True)
        for name, value in headers.items():
            connection.putheader(name, value)
        connection.putheader("content-length", str(arguments.size))
        connection.endheaders()
        emit(
            operation="SlowPutStarted",
            key=arguments.key,
            size=arguments.size,
            sha256=payload_hash,
        )
        for chunk in iter_pattern(arguments.size, arguments.seed, arguments.chunk_size):
            connection.send(chunk)
            sent += len(chunk)
            if arguments.delay_ms:
                time.sleep(arguments.delay_ms / 1000)
        response = connection.getresponse()
        body = response.read()
        emit(
            operation="SlowPutFinished",
            status=response.status,
            s3_error=_error_code(
                type("Response", (), {"body": body})()  # minimal probe-compatible object
            ),
            bytes_sent=sent,
        )
        if response.status != 200:
            raise ReliabilityFailure(f"slow PutObject returned HTTP {response.status}")
        return 0
    except (BrokenPipeError, ConnectionError, http.client.HTTPException, OSError, socket.timeout) as error:
        emit(
            operation="SlowPutTransportFailure",
            error=type(error).__name__,
            bytes_sent=sent,
        )
        return 75
    finally:
        connection.close()


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--timeout", type=float, default=10.0)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create-bucket")
    add_common(create)
    create.add_argument("--bucket", required=True)
    create.set_defaults(function=command_create_bucket)

    put = commands.add_parser("put")
    add_common(put)
    put.add_argument("--bucket", required=True)
    put.add_argument("--key", required=True)
    put.add_argument("--size", type=int, required=True)
    put.add_argument("--seed", required=True)
    put.set_defaults(function=command_put)

    get = commands.add_parser("get")
    add_common(get)
    get.add_argument("--bucket", required=True)
    get.add_argument("--key", required=True)
    get.add_argument("--size", type=int, required=True)
    get.add_argument("--seed", required=True)
    get.add_argument("--sha256")
    get.set_defaults(function=command_get)

    listed = commands.add_parser("list-contains")
    add_common(listed)
    listed.add_argument("--bucket", required=True)
    listed.add_argument("--key", required=True)
    listed.add_argument("--prefix", default="")
    listed.set_defaults(function=command_list_contains)

    missing = commands.add_parser("not-visible")
    add_common(missing)
    missing.add_argument("--bucket", required=True)
    missing.add_argument("--key", required=True)
    missing.set_defaults(function=command_not_visible)

    expected = commands.add_parser("expect-error")
    add_common(expected)
    expected.add_argument("--operation", default="ExpectedError")
    expected.add_argument("--method", choices=("GET", "HEAD", "PUT", "POST", "DELETE"), required=True)
    expected.add_argument("--bucket", required=True)
    expected.add_argument("--key")
    expected.add_argument("--list-v2", action="store_true")
    expected.add_argument("--size", type=int, default=0)
    expected.add_argument("--seed", default="error-body")
    expected.add_argument("--status", type=int, required=True)
    expected.add_argument("--code", required=True)
    expected.add_argument("--message")
    expected.add_argument("--max-elapsed", type=float)
    expected.set_defaults(function=command_expect_error)

    early = commands.add_parser("early-put-error")
    add_common(early)
    early.add_argument("--bucket", required=True)
    early.add_argument("--key", required=True)
    early.add_argument("--size", type=int, required=True)
    early.add_argument("--seed", required=True)
    early.add_argument("--status", type=int, required=True)
    early.add_argument("--code", required=True)
    early.add_argument("--message")
    early.set_defaults(function=command_early_put_error)

    slow = commands.add_parser("slow-put")
    add_common(slow)
    slow.add_argument("--bucket", required=True)
    slow.add_argument("--key", required=True)
    slow.add_argument("--size", type=int, required=True)
    slow.add_argument("--seed", required=True)
    slow.add_argument("--chunk-size", type=int, default=65536)
    slow.add_argument("--delay-ms", type=float, default=50.0)
    slow.set_defaults(function=command_slow_put)

    return root


def main() -> int:
    arguments = parser().parse_args()
    if getattr(arguments, "size", 0) < 0:
        raise ReliabilityFailure("size must be nonnegative")
    if getattr(arguments, "chunk_size", 1) < 1:
        raise ReliabilityFailure("chunk-size must be positive")
    return arguments.function(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReliabilityFailure as error:
        print(f"reliability assertion failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
