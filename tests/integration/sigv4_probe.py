#!/usr/bin/env python3
"""Dependency-free SigV4 probe for the packaged pgs3 HTTP endpoint.

The probe uses a fresh connection for every request so a keep-alive bug cannot
hide protocol correctness.  Credentials come only from environment variables;
the JSON output never includes Authorization, signatures, or secrets.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import hmac
import http.client
import json
import os
import re
import sys
import unittest
import urllib.parse
import xml.etree.ElementTree as ET
import zlib
from dataclasses import dataclass
from typing import Iterable, Mapping, Sequence


ALGORITHM = "AWS4-HMAC-SHA256"
CHUNK_ALGORITHM = "AWS4-HMAC-SHA256-PAYLOAD"
SERVICE = "s3"
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
STREAMING_SIGNED = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
STREAMING_UNSIGNED_TRAILER = "STREAMING-UNSIGNED-PAYLOAD-TRAILER"


def _aws_quote(value: str, *, slash_safe: bool = False) -> str:
    safe = "-_.~" + ("/" if slash_safe else "")
    return urllib.parse.quote(value, safe=safe, encoding="utf-8", errors="strict")


def _canonical_query(parameters: Iterable[tuple[str, str]]) -> str:
    encoded = [(_aws_quote(key), _aws_quote(value)) for key, value in parameters]
    encoded.sort()
    return "&".join(f"{key}={value}" for key, value in encoded)


def _normalize_header(value: str) -> str:
    return " ".join(value.strip().split())


def _signing_key(secret: str, date: str, region: str) -> bytes:
    date_key = hmac.new(("AWS4" + secret).encode(), date.encode(), hashlib.sha256).digest()
    region_key = hmac.new(date_key, region.encode(), hashlib.sha256).digest()
    service_key = hmac.new(region_key, SERVICE.encode(), hashlib.sha256).digest()
    return hmac.new(service_key, b"aws4_request", hashlib.sha256).digest()


def _signature(
    secret: str,
    date: str,
    region: str,
    amz_date: str,
    scope: str,
    canonical_request: str,
) -> str:
    string_to_sign = "\n".join(
        (
            ALGORITHM,
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode()).hexdigest(),
        )
    )
    return hmac.new(
        _signing_key(secret, date, region), string_to_sign.encode(), hashlib.sha256
    ).hexdigest()


def _payload_chunks(payload: bytes, chunk_size: int) -> Iterable[bytes]:
    if chunk_size < 1:
        raise ValueError("chunk_size must be positive")
    for offset in range(0, len(payload), chunk_size):
        yield payload[offset : offset + chunk_size]


def _streaming_chunk_signature(
    signing_key: bytes,
    amz_date: str,
    scope: str,
    previous_signature: str,
    payload: bytes,
) -> str:
    if not re.fullmatch(r"[0-9a-f]{64}", previous_signature):
        raise ValueError("previous_signature must be 64 lowercase hex characters")
    string_to_sign = "\n".join(
        (
            CHUNK_ALGORITHM,
            amz_date,
            scope,
            previous_signature,
            EMPTY_SHA256,
            hashlib.sha256(payload).hexdigest(),
        )
    )
    return hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()


def _signed_chunked_body(
    payload: bytes,
    *,
    chunk_size: int,
    signing_key: bytes,
    amz_date: str,
    scope: str,
    seed_signature: str,
) -> bytes:
    previous_signature = seed_signature
    encoded = bytearray()
    for chunk in _payload_chunks(payload, chunk_size):
        signature = _streaming_chunk_signature(
            signing_key, amz_date, scope, previous_signature, chunk
        )
        encoded.extend(
            f"{len(chunk):x};chunk-signature={signature}\r\n".encode("ascii")
        )
        encoded.extend(chunk)
        encoded.extend(b"\r\n")
        previous_signature = signature
    final_signature = _streaming_chunk_signature(
        signing_key, amz_date, scope, previous_signature, b""
    )
    encoded.extend(f"0;chunk-signature={final_signature}\r\n\r\n".encode("ascii"))
    return bytes(encoded)


def _unsigned_trailer_body(payload: bytes, *, chunk_size: int) -> tuple[bytes, str]:
    checksum = base64.b64encode(
        (zlib.crc32(payload) & 0xFFFF_FFFF).to_bytes(4, "big")
    ).decode("ascii")
    encoded = bytearray()
    for chunk in _payload_chunks(payload, chunk_size):
        encoded.extend(f"{len(chunk):x}\r\n".encode("ascii"))
        encoded.extend(chunk)
        encoded.extend(b"\r\n")
    encoded.extend(
        f"0\r\nx-amz-checksum-crc32:{checksum}\r\n\r\n".encode("ascii")
    )
    return bytes(encoded), checksum


def _mutate_first_chunk_signature(body: bytes) -> bytes:
    match = re.search(br"chunk-signature=([0-9a-f]{64})", body)
    if match is None:
        raise ValueError("body contains no aws-chunked signature")
    offset = match.start(1)
    replacement = b"0" if body[offset : offset + 1] != b"0" else b"1"
    return body[:offset] + replacement + body[offset + 1 :]


def _mutate_crc32_trailer(body: bytes) -> bytes:
    match = re.search(br"x-amz-checksum-crc32:([^\r\n]+)", body)
    if match is None:
        raise ValueError("body contains no CRC32 trailer")
    offset = match.start(1)
    replacement = b"A" if body[offset : offset + 1] != b"A" else b"B"
    return body[:offset] + replacement + body[offset + 1 :]


def _s3_path(bucket: str | None = None, key: str | None = None) -> str:
    if bucket is None:
        return "/"
    path = "/" + _aws_quote(bucket)
    if key is not None:
        path += "/" + _aws_quote(key, slash_safe=True)
    return path


@dataclass(frozen=True)
class ProbeResponse:
    status: int
    reason: str
    headers: tuple[tuple[str, str], ...]
    body: bytes

    def header(self, name: str) -> str | None:
        wanted = name.lower()
        for key, value in self.headers:
            if key.lower() == wanted:
                return value
        return None


class SigV4Client:
    def __init__(
        self,
        endpoint: str,
        access_key: str,
        secret: str,
        region: str = "us-east-1",
        timeout: float = 10.0,
    ) -> None:
        parsed = urllib.parse.urlsplit(endpoint)
        if parsed.scheme != "http" or not parsed.hostname or parsed.path not in ("", "/"):
            raise ValueError("endpoint must be an http://host[:port] origin without a path")
        self.host = parsed.hostname
        self.port = parsed.port or 80
        self.host_header = parsed.netloc
        self.endpoint = f"http://{parsed.netloc}"
        self.access_key = access_key
        self.secret = secret
        self.region = region
        self.timeout = timeout

    @staticmethod
    def _now() -> dt.datetime:
        return dt.datetime.now(dt.timezone.utc)

    def signed_headers(
        self,
        method: str,
        path: str,
        query: Sequence[tuple[str, str]],
        payload_hash: str,
        extra_headers: Mapping[str, str] | None = None,
        when: dt.datetime | None = None,
    ) -> dict[str, str]:
        when = (when or self._now()).astimezone(dt.timezone.utc)
        amz_date = when.strftime("%Y%m%dT%H%M%SZ")
        date = when.strftime("%Y%m%d")
        headers = {
            "host": self.host_header,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
        }
        for key, value in (extra_headers or {}).items():
            lowered = key.lower()
            if lowered == "authorization":
                raise ValueError("Authorization is generated by the signer")
            headers[lowered] = value
        canonical_headers = "".join(
            f"{key}:{_normalize_header(headers[key])}\n" for key in sorted(headers)
        )
        signed_header_names = ";".join(sorted(headers))
        canonical_request = "\n".join(
            (
                method,
                path,
                _canonical_query(query),
                canonical_headers,
                signed_header_names,
                payload_hash,
            )
        )
        scope = f"{date}/{self.region}/{SERVICE}/aws4_request"
        signature = _signature(
            self.secret, date, self.region, amz_date, scope, canonical_request
        )
        headers["authorization"] = (
            f"{ALGORITHM} Credential={self.access_key}/{scope}, "
            f"SignedHeaders={signed_header_names}, Signature={signature}"
        )
        return headers

    def request(
        self,
        method: str,
        path: str,
        *,
        query: Sequence[tuple[str, str]] = (),
        body: bytes = b"",
        signed_body: bytes | None = None,
        extra_headers: Mapping[str, str] | None = None,
        mutate_authorization: bool = False,
        when: dt.datetime | None = None,
    ) -> ProbeResponse:
        payload_hash = hashlib.sha256(body if signed_body is None else signed_body).hexdigest()
        headers = self.signed_headers(
            method, path, query, payload_hash, extra_headers=extra_headers, when=when
        )
        if mutate_authorization:
            authorization = headers["authorization"]
            last = "0" if authorization[-1] != "0" else "1"
            headers["authorization"] = authorization[:-1] + last
        return self._wire_request(method, path, query, body, headers)

    def streaming_signed_wire(
        self,
        method: str,
        path: str,
        *,
        body: bytes,
        chunk_size: int = 16 * 1024,
        mutate_chunk_signature: bool = False,
        when: dt.datetime | None = None,
    ) -> tuple[dict[str, str], bytes]:
        when = (when or self._now()).astimezone(dt.timezone.utc)
        amz_date = when.strftime("%Y%m%dT%H%M%SZ")
        date = when.strftime("%Y%m%d")
        scope = f"{date}/{self.region}/{SERVICE}/aws4_request"
        signing_key = _signing_key(self.secret, date, self.region)

        # Signatures have a fixed width, so a body made with an inert seed has
        # exactly the same encoded length as the final signature chain.
        length_template = _signed_chunked_body(
            body,
            chunk_size=chunk_size,
            signing_key=bytes(32),
            amz_date=amz_date,
            scope=scope,
            seed_signature="0" * 64,
        )
        headers = self.signed_headers(
            method,
            path,
            (),
            STREAMING_SIGNED,
            extra_headers={
                "content-encoding": "aws-chunked",
                "content-length": str(len(length_template)),
                "x-amz-decoded-content-length": str(len(body)),
            },
            when=when,
        )
        seed_match = re.search(r"Signature=([0-9a-f]{64})$", headers["authorization"])
        if seed_match is None:
            raise ValueError("generated Authorization header has no seed signature")
        encoded = _signed_chunked_body(
            body,
            chunk_size=chunk_size,
            signing_key=signing_key,
            amz_date=amz_date,
            scope=scope,
            seed_signature=seed_match.group(1),
        )
        if len(encoded) != len(length_template):
            raise AssertionError("aws-chunked encoded length changed after signing")
        if mutate_chunk_signature:
            encoded = _mutate_first_chunk_signature(encoded)
        return headers, encoded

    def streaming_signed_request(
        self,
        method: str,
        path: str,
        *,
        body: bytes,
        chunk_size: int = 16 * 1024,
        mutate_chunk_signature: bool = False,
        when: dt.datetime | None = None,
    ) -> ProbeResponse:
        headers, encoded = self.streaming_signed_wire(
            method,
            path,
            body=body,
            chunk_size=chunk_size,
            mutate_chunk_signature=mutate_chunk_signature,
            when=when,
        )
        return self._wire_request(method, path, (), encoded, headers)

    def streaming_unsigned_trailer_wire(
        self,
        method: str,
        path: str,
        *,
        body: bytes,
        chunk_size: int = 16 * 1024,
        mutate_checksum: bool = False,
        when: dt.datetime | None = None,
    ) -> tuple[dict[str, str], bytes, str]:
        encoded, checksum = _unsigned_trailer_body(body, chunk_size=chunk_size)
        headers = self.signed_headers(
            method,
            path,
            (),
            STREAMING_UNSIGNED_TRAILER,
            extra_headers={
                "content-encoding": "aws-chunked",
                "content-length": str(len(encoded)),
                "x-amz-decoded-content-length": str(len(body)),
                "x-amz-sdk-checksum-algorithm": "CRC32",
                "x-amz-trailer": "x-amz-checksum-crc32",
            },
            when=when,
        )
        if mutate_checksum:
            encoded = _mutate_crc32_trailer(encoded)
        return headers, encoded, checksum

    def streaming_unsigned_trailer_request(
        self,
        method: str,
        path: str,
        *,
        body: bytes,
        chunk_size: int = 16 * 1024,
        mutate_checksum: bool = False,
        when: dt.datetime | None = None,
    ) -> ProbeResponse:
        headers, encoded, _ = self.streaming_unsigned_trailer_wire(
            method,
            path,
            body=body,
            chunk_size=chunk_size,
            mutate_checksum=mutate_checksum,
            when=when,
        )
        return self._wire_request(method, path, (), encoded, headers)

    def presigned_target(
        self,
        method: str,
        path: str,
        *,
        expires: int = 60,
        when: dt.datetime | None = None,
    ) -> str:
        if expires < 1 or expires > 604800:
            raise ValueError("expires must be between 1 and 604800 seconds")
        when = (when or self._now()).astimezone(dt.timezone.utc)
        amz_date = when.strftime("%Y%m%dT%H%M%SZ")
        date = when.strftime("%Y%m%d")
        scope = f"{date}/{self.region}/{SERVICE}/aws4_request"
        parameters = [
            ("X-Amz-Algorithm", ALGORITHM),
            ("X-Amz-Credential", f"{self.access_key}/{scope}"),
            ("X-Amz-Date", amz_date),
            ("X-Amz-Expires", str(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        canonical = _canonical_query(parameters)
        canonical_request = "\n".join(
            (
                method,
                path,
                canonical,
                f"host:{self.host_header}\n",
                "host",
                "UNSIGNED-PAYLOAD",
            )
        )
        signature = _signature(
            self.secret, date, self.region, amz_date, scope, canonical_request
        )
        parameters.append(("X-Amz-Signature", signature))
        return f"{path}?{_canonical_query(parameters)}"

    def presigned_request(
        self,
        method: str,
        target: str,
        *,
        body: bytes = b"",
    ) -> ProbeResponse:
        split = urllib.parse.urlsplit(target)
        query = urllib.parse.parse_qsl(split.query, keep_blank_values=True)
        return self._wire_request(
            method,
            split.path,
            query,
            body,
            {"host": self.host_header},
        )

    def _wire_request(
        self,
        method: str,
        path: str,
        query: Sequence[tuple[str, str]],
        body: bytes,
        headers: Mapping[str, str],
    ) -> ProbeResponse:
        target = path
        if query:
            target += "?" + _canonical_query(query)
        connection = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        try:
            connection.request(method, target, body=body, headers=dict(headers))
            response = connection.getresponse()
            response_body = response.read()
            return ProbeResponse(
                response.status,
                response.reason,
                tuple(response.getheaders()),
                response_body,
            )
        finally:
            connection.close()


class ProbeFailure(RuntimeError):
    pass


def _error_code(response: ProbeResponse) -> str | None:
    if not response.body:
        return None
    try:
        root = ET.fromstring(response.body)
    except ET.ParseError:
        return None
    node = root.find(".//Code")
    return node.text if node is not None else None


def _expect(
    operation: str,
    response: ProbeResponse,
    statuses: int | Iterable[int],
) -> ProbeResponse:
    expected = {statuses} if isinstance(statuses, int) else set(statuses)
    record = {
        "operation": operation,
        "status": response.status,
        "content_length": response.header("content-length"),
    }
    code = _error_code(response)
    if code:
        record["s3_error"] = code
    print(json.dumps(record, sort_keys=True), flush=True)
    if response.status not in expected:
        excerpt = response.body[:512].decode("utf-8", "replace")
        raise ProbeFailure(
            f"{operation}: expected HTTP {sorted(expected)}, got "
            f"{response.status} {response.reason}: {excerpt}"
        )
    return response


def _bucket_names(response: ProbeResponse) -> set[str]:
    try:
        root = ET.fromstring(response.body)
    except ET.ParseError as error:
        raise ProbeFailure(f"ListBuckets returned invalid XML: {error}") from error
    return {
        node.text or ""
        for node in root.findall(".//{*}Bucket/{*}Name")
        + root.findall(".//Bucket/Name")
    }


def _object_versions(response: ProbeResponse) -> list[tuple[str, str]]:
    try:
        root = ET.fromstring(response.body)
    except ET.ParseError as error:
        raise ProbeFailure(f"ListObjectVersions returned invalid XML: {error}") from error
    versions: list[tuple[str, str]] = []
    for tag in ("Version", "DeleteMarker"):
        for node in root.findall(f".//{{*}}{tag}") + root.findall(f".//{tag}"):
            key_node = node.find("{*}Key")
            version_node = node.find("{*}VersionId")
            if key_node is None:
                key_node = node.find("Key")
            if version_node is None:
                version_node = node.find("VersionId")
            if key_node is not None and version_node is not None:
                versions.append((key_node.text or "", version_node.text or ""))
    return versions


def run_suite(arguments: argparse.Namespace) -> int:
    access_a = os.environ.get("PGS3_ACCESS_KEY_A", "")
    secret_a = os.environ.get("PGS3_SECRET_A", "")
    access_b = os.environ.get("PGS3_ACCESS_KEY_B", "")
    secret_b = os.environ.get("PGS3_SECRET_B", "")
    if not all((access_a, secret_a, access_b, secret_b)):
        raise ProbeFailure(
            "PGS3_ACCESS_KEY_A/PGS3_SECRET_A/PGS3_ACCESS_KEY_B/PGS3_SECRET_B are required"
        )
    if not re.fullmatch(r"[a-z0-9-]{1,30}", arguments.suffix):
        raise ProbeFailure("suffix must contain only lowercase letters, digits, and hyphens")

    client_a = SigV4Client(arguments.endpoint, access_a, secret_a, arguments.region)
    client_b = SigV4Client(arguments.endpoint, access_b, secret_b, arguments.region)
    bucket_a = f"probe-a-{arguments.suffix}"
    bucket_b = f"probe-b-{arguments.suffix}"
    key = "dir/unicode-\u2603.txt"
    payload = b"pgs3 stdlib SigV4 probe\n"
    presigned_key = "presigned-put.bin"
    presigned_payload = bytes(range(256)) * 17
    tampered_key = "must-not-exist.bin"
    signed_stream_key = "streaming/signed-payload.bin"
    signed_stream_payload = b"signed stream\x00" + bytes(range(251)) * 97
    bad_signed_stream_key = "streaming/bad-signed-payload.bin"
    trailer_stream_key = "streaming/unsigned-trailer.bin"
    trailer_stream_payload = b"unsigned trailer\x00" + bytes(range(253)) * 89
    bad_trailer_stream_key = "streaming/bad-unsigned-trailer.bin"

    _expect("CreateBucket tenant A", client_a.request("PUT", _s3_path(bucket_a)), 200)
    _expect("CreateBucket tenant B", client_b.request("PUT", _s3_path(bucket_b)), 200)

    listed_a = _expect("ListBuckets tenant A", client_a.request("GET", "/"), 200)
    listed_b = _expect("ListBuckets tenant B", client_b.request("GET", "/"), 200)
    names_a = _bucket_names(listed_a)
    names_b = _bucket_names(listed_b)
    if bucket_a not in names_a or bucket_b in names_a:
        raise ProbeFailure(f"tenant A bucket isolation failed: {sorted(names_a)}")
    if bucket_b not in names_b or bucket_a in names_b:
        raise ProbeFailure(f"tenant B bucket isolation failed: {sorted(names_b)}")

    content_md5 = base64.b64encode(hashlib.md5(payload, usedforsecurity=False).digest()).decode()
    put = _expect(
        "PutObject header SigV4",
        client_a.request(
            "PUT",
            _s3_path(bucket_a, key),
            body=payload,
            extra_headers={"content-md5": content_md5, "content-type": "text/plain"},
        ),
        200,
    )
    if not put.header("etag"):
        raise ProbeFailure("PutObject omitted ETag")

    fetched = _expect(
        "GetObject header SigV4", client_a.request("GET", _s3_path(bucket_a, key)), 200
    )
    if fetched.body != payload:
        raise ProbeFailure("GetObject payload does not match PutObject payload")
    headed = _expect(
        "HeadObject header SigV4", client_a.request("HEAD", _s3_path(bucket_a, key)), 200
    )
    if headed.body:
        raise ProbeFailure("HeadObject returned a response body")
    if headed.header("content-length") != str(len(payload)):
        raise ProbeFailure("HeadObject Content-Length does not equal object size")

    signed_stream_put = _expect(
        "PutObject STREAMING-AWS4-HMAC-SHA256-PAYLOAD",
        client_a.streaming_signed_request(
            "PUT",
            _s3_path(bucket_a, signed_stream_key),
            body=signed_stream_payload,
            chunk_size=8 * 1024,
        ),
        200,
    )
    if not signed_stream_put.header("etag"):
        raise ProbeFailure("signed streaming PutObject omitted ETag")
    signed_stream_get = _expect(
        "GetObject after signed streaming PutObject",
        client_a.request("GET", _s3_path(bucket_a, signed_stream_key)),
        200,
    )
    if signed_stream_get.body != signed_stream_payload:
        raise ProbeFailure("signed aws-chunked payload round trip mismatch")
    _expect(
        "tampered signed aws-chunked signature",
        client_a.streaming_signed_request(
            "PUT",
            _s3_path(bucket_a, bad_signed_stream_key),
            body=signed_stream_payload,
            chunk_size=8 * 1024,
            mutate_chunk_signature=True,
        ),
        (400, 403),
    )
    _expect(
        "tampered signed stream is not visible",
        client_a.request("GET", _s3_path(bucket_a, bad_signed_stream_key)),
        404,
    )

    _, _, trailer_checksum = client_a.streaming_unsigned_trailer_wire(
        "PUT",
        _s3_path(bucket_a, trailer_stream_key),
        body=trailer_stream_payload,
        chunk_size=8 * 1024,
    )
    trailer_stream_put = _expect(
        "PutObject STREAMING-UNSIGNED-PAYLOAD-TRAILER",
        client_a.streaming_unsigned_trailer_request(
            "PUT",
            _s3_path(bucket_a, trailer_stream_key),
            body=trailer_stream_payload,
            chunk_size=8 * 1024,
        ),
        200,
    )
    if trailer_stream_put.header("x-amz-checksum-crc32") != trailer_checksum:
        raise ProbeFailure("unsigned trailer PutObject omitted the verified CRC32")
    trailer_stream_get = _expect(
        "GetObject after unsigned-trailer streaming PutObject",
        client_a.request("GET", _s3_path(bucket_a, trailer_stream_key)),
        200,
    )
    if trailer_stream_get.body != trailer_stream_payload:
        raise ProbeFailure("unsigned-trailer aws-chunked payload round trip mismatch")
    _expect(
        "tampered aws-chunked checksum trailer",
        client_a.streaming_unsigned_trailer_request(
            "PUT",
            _s3_path(bucket_a, bad_trailer_stream_key),
            body=trailer_stream_payload,
            chunk_size=8 * 1024,
            mutate_checksum=True,
        ),
        (400, 403),
    )
    _expect(
        "tampered trailer stream is not visible",
        client_a.request("GET", _s3_path(bucket_a, bad_trailer_stream_key)),
        404,
    )

    listing_v1 = _expect(
        "ListObjects V1",
        client_a.request("GET", _s3_path(bucket_a), query=(("prefix", "dir/"),)),
        200,
    )
    listing_v2 = _expect(
        "ListObjects V2",
        client_a.request(
            "GET",
            _s3_path(bucket_a),
            query=(("list-type", "2"), ("prefix", "dir/"), ("max-keys", "1000")),
        ),
        200,
    )
    if key.encode() not in listing_v1.body or key.encode() not in listing_v2.body:
        raise ProbeFailure("object key missing from ListObjects response")

    put_target = client_a.presigned_target("PUT", _s3_path(bucket_a, presigned_key))
    _expect(
        "presigned PutObject",
        client_a.presigned_request("PUT", put_target, body=presigned_payload),
        200,
    )
    get_target = client_a.presigned_target("GET", _s3_path(bucket_a, presigned_key))
    presigned_get = _expect(
        "presigned GetObject", client_a.presigned_request("GET", get_target), 200
    )
    if presigned_get.body != presigned_payload:
        raise ProbeFailure("presigned GET payload mismatch")

    _expect(
        "cross-tenant HeadBucket",
        client_b.request("HEAD", _s3_path(bucket_a)),
        (403, 404),
    )
    _expect(
        "cross-tenant GetObject",
        client_b.request("GET", _s3_path(bucket_a, key)),
        (403, 404),
    )
    _expect(
        "cross-tenant ListObjects",
        client_b.request("GET", _s3_path(bucket_a), query=(("list-type", "2"),)),
        (403, 404),
    )
    cross_presign = client_b.presigned_target("GET", _s3_path(bucket_a, key))
    _expect(
        "cross-tenant presigned GetObject",
        client_b.presigned_request("GET", cross_presign),
        (403, 404),
    )

    _expect(
        "invalid signature",
        client_a.request(
            "GET", _s3_path(bucket_a, key), mutate_authorization=True
        ),
        403,
    )
    old = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)
    expired = client_a.presigned_target(
        "GET", _s3_path(bucket_a, key), expires=1, when=old
    )
    _expect(
        "expired presigned GetObject",
        client_a.presigned_request("GET", expired),
        403,
    )
    _expect(
        "tampered signed body",
        client_a.request(
            "PUT",
            _s3_path(bucket_a, tampered_key),
            body=b"wire payload was changed",
            signed_body=b"payload that was signed",
        ),
        (400, 403),
    )
    _expect(
        "tampered body is not visible",
        client_a.request("GET", _s3_path(bucket_a, tampered_key)),
        404,
    )

    _expect("DeleteObject", client_a.request("DELETE", _s3_path(bucket_a, key)), 204)
    _expect(
        "DeleteObject presigned key",
        client_a.request("DELETE", _s3_path(bucket_a, presigned_key)),
        204,
    )
    version_listing = _expect(
        "ListObjectVersions for cleanup",
        client_a.request("GET", _s3_path(bucket_a), query=(("versions", ""),)),
        200,
    )
    versions = _object_versions(version_listing)
    if not versions:
        raise ProbeFailure("ListObjectVersions returned no versions after object deletion")
    for version_key, version_id in versions:
        _expect(
            "DeleteObject version cleanup",
            client_a.request(
                "DELETE",
                _s3_path(bucket_a, version_key),
                query=(("versionId", version_id),),
            ),
            204,
        )
    _expect("DeleteBucket tenant A", client_a.request("DELETE", _s3_path(bucket_a)), 204)
    _expect("DeleteBucket tenant B", client_b.request("DELETE", _s3_path(bucket_b)), 204)
    print(json.dumps({"suite": "stdlib-sigv4", "result": "PASS"}, sort_keys=True))
    return 0


class OfflineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.client = SigV4Client(
            "http://127.0.0.1:9000",
            "AKIDEXAMPLE",
            "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        )
        self.when = dt.datetime(2015, 8, 30, 12, 36, tzinfo=dt.timezone.utc)

    def test_aws_encoding_and_duplicate_sorting(self) -> None:
        self.assertEqual(
            _canonical_query((("x", "/"), ("prefix", "a b"), ("x", "+"))),
            "prefix=a%20b&x=%2B&x=%2F",
        )
        self.assertEqual(_s3_path("bucket", "a b/\u2603"), "/bucket/a%20b/%E2%98%83")

    def test_header_signature_is_deterministic_and_payload_bound(self) -> None:
        first = self.client.signed_headers(
            "PUT", "/bucket/key", (), hashlib.sha256(b"one").hexdigest(), when=self.when
        )
        second = self.client.signed_headers(
            "PUT", "/bucket/key", (), hashlib.sha256(b"two").hexdigest(), when=self.when
        )
        self.assertRegex(first["authorization"], r"Signature=[0-9a-f]{64}$")
        self.assertNotEqual(first["authorization"], second["authorization"])
        self.assertNotIn(self.client.secret, first["authorization"])

    def test_signed_chunks_match_official_aws_signature_chain(self) -> None:
        secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        body = _signed_chunked_body(
            b"a" * 66_560,
            chunk_size=65_536,
            signing_key=_signing_key(secret, "20130524", "us-east-1"),
            amz_date="20130524T000000Z",
            scope="20130524/us-east-1/s3/aws4_request",
            seed_signature=(
                "4f232c4386841ef735655705268965c44"
                "a0e4690baa4adea153f7db9fa80a0a9"
            ),
        )
        self.assertEqual(
            [
                value.decode("ascii")
                for value in re.findall(br"chunk-signature=([0-9a-f]{64})", body)
            ],
            [
                "ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648",
                "0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497",
                "b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9",
            ],
        )
        self.assertIn(b"10000;chunk-signature=", body)
        self.assertIn(b"\r\n400;chunk-signature=", body)
        self.assertTrue(body.endswith(b"\r\n\r\n"))

    def test_signed_stream_wire_is_length_bound_and_tamperable(self) -> None:
        headers, body = self.client.streaming_signed_wire(
            "PUT",
            "/bucket/key",
            body=b"abcdefghij",
            chunk_size=4,
            when=self.when,
        )
        tampered_headers, tampered = self.client.streaming_signed_wire(
            "PUT",
            "/bucket/key",
            body=b"abcdefghij",
            chunk_size=4,
            mutate_chunk_signature=True,
            when=self.when,
        )
        self.assertEqual(headers, tampered_headers)
        self.assertEqual(headers["x-amz-content-sha256"], STREAMING_SIGNED)
        self.assertEqual(headers["content-encoding"], "aws-chunked")
        self.assertEqual(headers["x-amz-decoded-content-length"], "10")
        self.assertEqual(headers["content-length"], str(len(body)))
        self.assertEqual(len(body), len(tampered))
        self.assertEqual(sum(left != right for left, right in zip(body, tampered)), 1)
        self.assertNotEqual(body, tampered)

    def test_unsigned_trailer_wire_uses_crc32_and_is_tamperable(self) -> None:
        headers, body, checksum = self.client.streaming_unsigned_trailer_wire(
            "PUT",
            "/bucket/key",
            body=b"123456789",
            chunk_size=4,
            when=self.when,
        )
        tampered_headers, tampered, tampered_checksum = (
            self.client.streaming_unsigned_trailer_wire(
                "PUT",
                "/bucket/key",
                body=b"123456789",
                chunk_size=4,
                mutate_checksum=True,
                when=self.when,
            )
        )
        self.assertEqual(headers, tampered_headers)
        self.assertEqual(checksum, "y/Q5Jg==")
        self.assertEqual(tampered_checksum, checksum)
        self.assertEqual(headers["x-amz-content-sha256"], STREAMING_UNSIGNED_TRAILER)
        self.assertEqual(headers["x-amz-sdk-checksum-algorithm"], "CRC32")
        self.assertEqual(headers["x-amz-trailer"], "x-amz-checksum-crc32")
        self.assertEqual(headers["content-length"], str(len(body)))
        self.assertEqual(
            body,
            b"4\r\n1234\r\n4\r\n5678\r\n1\r\n9\r\n"
            b"0\r\nx-amz-checksum-crc32:y/Q5Jg==\r\n\r\n",
        )
        self.assertEqual(len(body), len(tampered))
        self.assertEqual(sum(left != right for left, right in zip(body, tampered)), 1)
        self.assertNotEqual(body, tampered)

    def test_streaming_helpers_reject_invalid_inputs(self) -> None:
        with self.assertRaises(ValueError):
            _unsigned_trailer_body(b"payload", chunk_size=0)
        with self.assertRaises(ValueError):
            _mutate_first_chunk_signature(b"not aws-chunked")
        with self.assertRaises(ValueError):
            _mutate_crc32_trailer(b"not aws-chunked")

    def test_presign_is_deterministic_and_has_no_secret(self) -> None:
        first = self.client.presigned_target("GET", "/bucket/key", expires=60, when=self.when)
        second = self.client.presigned_target("GET", "/bucket/key", expires=60, when=self.when)
        self.assertEqual(first, second)
        self.assertIn("X-Amz-Signature=", first)
        self.assertNotIn(self.client.secret, first)

    def test_invalid_endpoint_and_expiry_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            SigV4Client("https://example.test", "key", "secret")
        with self.assertRaises(ValueError):
            self.client.presigned_target("GET", "/", expires=0)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    root.add_argument("--self-test", action="store_true")
    root.add_argument("--endpoint", default=os.environ.get("PGS3_ENDPOINT", "http://127.0.0.1:9000"))
    root.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    root.add_argument("--suffix", default=os.environ.get("PGS3_TEST_SUFFIX", "local"))
    return root


def main() -> int:
    arguments = parser().parse_args()
    if arguments.self_test:
        program = unittest.main(argv=[sys.argv[0]], exit=False)
        return 0 if program.result.wasSuccessful() else 1
    return run_suite(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ProbeFailure, OSError, http.client.HTTPException) as error:
        print(json.dumps({"suite": "stdlib-sigv4", "result": "FAIL", "error": str(error)}))
        raise SystemExit(1)
