#!/usr/bin/env python3
"""Reproducible, dependency-free HTTP benchmark for pgs3 and MinIO.

The acceptance profile is deliberately fixed.  The smoke profile exists only to
exercise the harness and always reports acceptance requirements as NOT_RUN.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import datetime as dt
import hashlib
import hmac
import http.client
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import threading
import time
from typing import Callable, Iterable, Mapping, Sequence
import urllib.parse


SCHEMA = "pgs3.http-benchmark.v1"
RAW_SCHEMA = "pgs3.http-benchmark-sample.v1"
REGION = "us-east-1"
SERVICE = "s3"
ALGORITHM = "AWS4-HMAC-SHA256"
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()

REQUIRED_SIZES = (
    4 * 1024,
    16 * 1024,
    64 * 1024 - 1,
    64 * 1024,
    64 * 1024 + 1,
    256 * 1024,
    1 * 1024 * 1024,
    4 * 1024 * 1024,
    8 * 1024 * 1024,
    16 * 1024 * 1024,
    64 * 1024 * 1024,
)

# Enough small samples for stable tail percentiles without allowing the complete
# sweep to silently become an unbounded multi-gigabyte load.
ACCEPTANCE_SAMPLES = {
    4 * 1024: 4_000,
    16 * 1024: 4_000,
    64 * 1024 - 1: 3_000,
    64 * 1024: 3_000,
    64 * 1024 + 1: 3_000,
    256 * 1024: 500,
    1 * 1024 * 1024: 100,
    4 * 1024 * 1024: 20,
    8 * 1024 * 1024: 8,
    16 * 1024 * 1024: 4,
    64 * 1024 * 1024: 2,
}
ACCEPTANCE_WARMUPS = 3
DEFAULT_SMOKE_SIZES = (4 * 1024, 64 * 1024 - 1, 64 * 1024, 64 * 1024 + 1, 256 * 1024)

THRESHOLDS = {
    "12_get_small_p50_ms": 0.5,
    "12_get_small_ops_per_second": 30_000.0,
    "13_put_small_ops_per_second": 5_000.0,
    "14_put_8mib_mib_per_second": 150.0,
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def deterministic_body(size: int, index: int = 0, namespace: str = "measured") -> bytes:
    if size < 0:
        raise ValueError("size must be nonnegative")
    if index < 0 or not namespace:
        raise ValueError("index must be nonnegative and namespace must be nonempty")
    seed = b"\0".join(
        (
            b"pgs3-http-benchmark-body-v2",
            str(size).encode("ascii"),
            str(index).encode("ascii"),
            namespace.encode("utf-8"),
        )
    )
    return hashlib.shake_256(seed).digest(size)


def size_label(size: int) -> str:
    if size % (1024 * 1024) == 0:
        return f"{size // (1024 * 1024)}MiB"
    if size % 1024 == 0:
        return f"{size // 1024}KiB"
    return f"{size}B"


def percentile_nearest_rank(values: Sequence[int], percentile: float) -> int:
    if not values:
        raise ValueError("percentile requires at least one value")
    if not 0 < percentile <= 100:
        raise ValueError("percentile must be in (0, 100]")
    ordered = sorted(values)
    rank = max(1, math.ceil((percentile / 100.0) * len(ordered)))
    return ordered[rank - 1]


def _aws_quote(value: str, *, slash_safe: bool = False) -> str:
    safe = "-_.~/" if slash_safe else "-_.~"
    return urllib.parse.quote(value, safe=safe, encoding="utf-8", errors="strict")


def _canonical_query(parameters: Sequence[tuple[str, str]]) -> str:
    encoded = [(_aws_quote(name), _aws_quote(value)) for name, value in parameters]
    encoded.sort()
    return "&".join(f"{name}={value}" for name, value in encoded)


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date: str, region: str = REGION) -> bytes:
    date_key = _sign(("AWS4" + secret).encode("utf-8"), date)
    region_key = _sign(date_key, region)
    service_key = _sign(region_key, SERVICE)
    return _sign(service_key, "aws4_request")


class BenchmarkError(RuntimeError):
    pass


class HttpStatusError(BenchmarkError):
    def __init__(self, status: int, reason: str, body: bytes) -> None:
        excerpt = body[:256].decode("utf-8", "replace").replace("\n", " ")
        super().__init__(f"HTTP {status} {reason}: {excerpt}")
        self.status = status


@dataclasses.dataclass(frozen=True)
class Response:
    status: int
    reason: str
    headers: tuple[tuple[str, str], ...]
    body: bytes


class S3Connection:
    """One persistent HTTP/1.1 connection with SigV4 signing."""

    def __init__(
        self,
        endpoint: str,
        access_key: str,
        secret: str,
        *,
        timeout: float,
    ) -> None:
        parsed = urllib.parse.urlsplit(endpoint)
        if parsed.scheme != "http" or not parsed.hostname or parsed.path not in ("", "/"):
            raise ValueError("endpoint must be an http://host[:port] origin")
        self.host = parsed.hostname
        self.port = parsed.port or 80
        self.host_header = parsed.netloc
        self.access_key = access_key
        self.secret = secret
        self.timeout = timeout
        self.connection: http.client.HTTPConnection | None = None

    def _connect(self) -> http.client.HTTPConnection:
        if self.connection is None:
            self.connection = http.client.HTTPConnection(
                self.host, self.port, timeout=self.timeout
            )
        return self.connection

    def close(self) -> None:
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def _headers(
        self,
        method: str,
        path: str,
        query: Sequence[tuple[str, str]],
        payload_sha256: str,
        when: dt.datetime | None = None,
    ) -> dict[str, str]:
        now = (when or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date = now.strftime("%Y%m%d")
        canonical_headers = (
            f"host:{self.host_header}\n"
            f"x-amz-content-sha256:{payload_sha256}\n"
            f"x-amz-date:{amz_date}\n"
        )
        signed_headers = "host;x-amz-content-sha256;x-amz-date"
        canonical_request = "\n".join(
            (
                method,
                path,
                _canonical_query(query),
                canonical_headers,
                signed_headers,
                payload_sha256,
            )
        )
        scope = f"{date}/{REGION}/{SERVICE}/aws4_request"
        string_to_sign = "\n".join(
            (
                ALGORITHM,
                amz_date,
                scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            )
        )
        signature = hmac.new(
            _signing_key(self.secret, date),
            string_to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        return {
            "host": self.host_header,
            "x-amz-content-sha256": payload_sha256,
            "x-amz-date": amz_date,
            "authorization": (
                f"{ALGORITHM} Credential={self.access_key}/{scope}, "
                f"SignedHeaders={signed_headers}, Signature={signature}"
            ),
        }

    def request(
        self,
        method: str,
        path: str,
        *,
        query: Sequence[tuple[str, str]] = (),
        body: bytes = b"",
        payload_sha256: str = EMPTY_SHA256,
        expected_status: Iterable[int] = (200,),
        content_type: str | None = None,
    ) -> Response:
        canonical_path = _aws_quote(path, slash_safe=True)
        target = canonical_path
        if query:
            target += "?" + _canonical_query(query)
        headers = self._headers(method, canonical_path, query, payload_sha256)
        headers["content-length"] = str(len(body))
        if content_type:
            headers["content-type"] = content_type
        try:
            connection = self._connect()
            connection.request(method, target, body=body, headers=headers)
            incoming = connection.getresponse()
            response = Response(
                incoming.status,
                incoming.reason,
                tuple(incoming.getheaders()),
                incoming.read(),
            )
        except Exception:
            self.close()
            raise
        if response.status not in set(expected_status):
            raise HttpStatusError(response.status, response.reason, response.body)
        return response

    def create_bucket(self, bucket: str) -> None:
        self.request("PUT", f"/{bucket}")

    def enable_versioning(self, bucket: str) -> None:
        body = (
            b'<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            b"<Status>Enabled</Status></VersioningConfiguration>"
        )
        self.request(
            "PUT",
            f"/{bucket}",
            query=(("versioning", ""),),
            body=body,
            payload_sha256=hashlib.sha256(body).hexdigest(),
            content_type="application/xml",
        )

    def head_bucket(self, bucket: str) -> None:
        self.request("HEAD", f"/{bucket}", expected_status=(200,))

    def put_object(self, bucket: str, key: str, body: bytes, sha256_hex: str) -> int:
        response = self.request(
            "PUT",
            f"/{bucket}/{key}",
            body=body,
            payload_sha256=sha256_hex,
            content_type="application/octet-stream",
        )
        return response.status

    def get_object(self, bucket: str, key: str) -> tuple[int, bytes]:
        response = self.request("GET", f"/{bucket}/{key}")
        return response.status, response.body


@dataclasses.dataclass(frozen=True)
class Endpoint:
    name: str
    url: str
    bucket: str
    enable_versioning: bool


def key_for(size: int, index: int, *, warmup: bool = False) -> str:
    category = "warmup" if warmup else "measured"
    return f"{category}/{size:09d}/{index:08d}.bin"


def put_concurrency(size: int) -> int:
    if size >= 8 * 1024 * 1024:
        return 1
    if size >= 4 * 1024 * 1024:
        return 4
    return 16


def get_concurrency(size: int) -> int:
    if size >= 64 * 1024 * 1024:
        return 1
    if size >= 16 * 1024 * 1024:
        return 2
    if size >= 4 * 1024 * 1024:
        return 4
    return 16


def _sample_error(error: BaseException) -> tuple[str, str, int | None]:
    status = error.status if isinstance(error, HttpStatusError) else None
    return type(error).__name__, str(error)[:512], status


def run_phase(
    *,
    endpoint: Endpoint,
    operation: str,
    size: int,
    count: int,
    concurrency: int,
    payloads: Sequence[bytes],
    payload_sha256: Sequence[str],
    client_factory: Callable[[], S3Connection],
    max_errors: int = 10,
) -> tuple[dict[str, object], list[dict[str, object]]]:
    if operation not in {"PUT", "GET"}:
        raise ValueError("operation must be PUT or GET")
    if count < 1 or concurrency < 1:
        raise ValueError("count and concurrency must be positive")
    if len(payloads) != count or len(payload_sha256) != count:
        raise ValueError("payload and digest arrays must match count")
    if any(len(payload) != size for payload in payloads):
        raise ValueError("every payload must match size")
    concurrency = min(concurrency, count)
    clients = [client_factory() for _ in range(concurrency)]
    for client in clients:
        client.head_bucket(endpoint.bucket)

    ready = threading.Barrier(concurrency + 1)
    start_event = threading.Event()
    abort_event = threading.Event()
    samples: list[dict[str, object]] = []
    samples_lock = threading.Lock()
    errors = 0

    def worker(worker_id: int, client: S3Connection) -> None:
        nonlocal errors
        ready.wait()
        start_event.wait()
        for index in range(worker_id, count, concurrency):
            if abort_event.is_set():
                break
            key = key_for(size, index)
            started_ns = time.perf_counter_ns()
            status: int | None = None
            request_succeeded = False
            content_verified: bool | None = None
            error_type: str | None = None
            error_message: str | None = None
            received_bytes = 0
            expected_body = payloads[index]
            expected_sha256 = payload_sha256[index]
            try:
                if operation == "PUT":
                    status = client.put_object(
                        endpoint.bucket, key, expected_body, expected_sha256
                    )
                    received_bytes = size
                    request_succeeded = status == 200
                else:
                    status, received = client.get_object(endpoint.bucket, key)
                    received_bytes = len(received)
                    request_succeeded = status == 200
                    content_verified = received == expected_body
                    if not content_verified:
                        raise BenchmarkError(
                            f"content mismatch: expected {size} bytes/{expected_sha256}, "
                            f"got {len(received)} bytes/{hashlib.sha256(received).hexdigest()}"
                        )
            except BaseException as error:  # record every request-level failure
                error_type, error_message, error_status = _sample_error(error)
                status = status if status is not None else error_status
                with samples_lock:
                    errors += 1
                    if errors >= max_errors:
                        abort_event.set()
            latency_ns = time.perf_counter_ns() - started_ns
            sample = {
                "schema": RAW_SCHEMA,
                "system": endpoint.name,
                "operation": operation,
                "size_bytes": size,
                "sample_index": index,
                "worker": worker_id,
                "latency_ns": latency_ns,
                "status": status,
                "bytes": received_bytes,
                "content_sha256": expected_sha256,
                "request_succeeded": request_succeeded,
                "content_verified": content_verified,
                "error_type": error_type,
                "error": error_message,
            }
            with samples_lock:
                samples.append(sample)

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
            futures = [
                executor.submit(worker, worker_id, clients[worker_id])
                for worker_id in range(concurrency)
            ]
            ready.wait()
            wall_started_ns = time.perf_counter_ns()
            start_event.set()
            for future in futures:
                future.result()
            wall_ns = time.perf_counter_ns() - wall_started_ns
    finally:
        for client in clients:
            client.close()

    samples.sort(key=lambda sample: int(sample["sample_index"]))
    successful = [sample for sample in samples if sample["error_type"] is None]
    latencies = [int(sample["latency_ns"]) for sample in successful]
    success_count = len(successful)
    wall_seconds = wall_ns / 1_000_000_000
    payload_mib = (success_count * size) / (1024 * 1024)
    metrics: dict[str, object] = {
        "system": endpoint.name,
        "operation": operation,
        "size_bytes": size,
        "size_label": size_label(size),
        "planned_samples": count,
        "attempted_samples": len(samples),
        "successful_samples": success_count,
        "errors": len(samples) - success_count,
        "aborted_by_error_budget": abort_event.is_set(),
        "concurrency": concurrency,
        "wall_seconds": wall_seconds,
        "ops_per_second": (success_count / wall_seconds) if wall_seconds else None,
        "attempts_per_second": (len(samples) / wall_seconds) if wall_seconds else None,
        "mib_per_second": (payload_mib / wall_seconds) if wall_seconds else None,
        "p50_ms": percentile_nearest_rank(latencies, 50) / 1_000_000 if latencies else None,
        "p95_ms": percentile_nearest_rank(latencies, 95) / 1_000_000 if latencies else None,
        "p99_ms": percentile_nearest_rank(latencies, 99) / 1_000_000 if latencies else None,
        "mean_ms": statistics.fmean(latencies) / 1_000_000 if latencies else None,
        "distinct_payloads": len(set(payload_sha256)),
        "content_sha256_first": payload_sha256[0],
        "content_sha256_last": payload_sha256[-1],
        "all_requests_succeeded": bool(successful)
        and all(bool(sample["request_succeeded"]) for sample in successful),
        "all_content_verified": (
            bool(successful)
            and all(sample["content_verified"] is True for sample in successful)
            if operation == "GET"
            else None
        ),
    }
    return metrics, samples


def _result_by(
    summary: Mapping[str, object], system: str, operation: str, size: int
) -> Mapping[str, object] | None:
    systems = summary.get("systems", {})
    if not isinstance(systems, Mapping):
        return None
    record = systems.get(system, {})
    if not isinstance(record, Mapping):
        return None
    results = record.get("results", [])
    if not isinstance(results, Sequence):
        return None
    for result in results:
        if (
            isinstance(result, Mapping)
            and result.get("operation") == operation
            and result.get("size_bytes") == size
        ):
            return result
    return None


def _complete(result: Mapping[str, object] | None) -> bool:
    return bool(
        result
        and result.get("errors") == 0
        and result.get("attempted_samples") == result.get("planned_samples")
        and result.get("successful_samples") == result.get("planned_samples")
        and result.get("all_requests_succeeded") is True
        and (
            result.get("operation") == "PUT"
            or result.get("all_content_verified") is True
        )
    )


def evaluate_acceptance(summary: Mapping[str, object], profile: str) -> dict[str, object]:
    if profile != "acceptance":
        return {
            "profile": profile,
            "thresholds": THRESHOLDS,
            "requirements": {
                str(number): {
                    "status": "NOT_RUN",
                    "reason": "smoke profile cannot satisfy acceptance requirements",
                }
                for number in (12, 13, 14, 17)
            },
        }

    small_sizes = [size for size in REQUIRED_SIZES if size <= 64 * 1024]
    get_small = [_result_by(summary, "pgs3", "GET", size) for size in small_sizes]
    put_small = [_result_by(summary, "pgs3", "PUT", size) for size in small_sizes]
    get_complete = all(_complete(result) for result in get_small)
    put_complete = all(_complete(result) for result in put_small)
    max_get_p50 = (
        max(float(result["p50_ms"]) for result in get_small if result)
        if get_complete
        else None
    )
    min_get_ops = (
        min(float(result["ops_per_second"]) for result in get_small if result)
        if get_complete
        else None
    )
    min_put_ops = (
        min(float(result["ops_per_second"]) for result in put_small if result)
        if put_complete
        else None
    )
    put_8mib = _result_by(summary, "pgs3", "PUT", 8 * 1024 * 1024)
    get_8mib = _result_by(summary, "pgs3", "GET", 8 * 1024 * 1024)
    put_8mib_complete = bool(
        _complete(put_8mib)
        and _complete(get_8mib)
        and put_8mib
        and put_8mib.get("concurrency") == 1
    )
    put_8mib_rate = float(put_8mib["mib_per_second"]) if put_8mib_complete else None

    curve_complete = all(
        _complete(_result_by(summary, system, operation, size))
        for system in ("pgs3", "minio")
        for operation in ("PUT", "GET")
        for size in REQUIRED_SIZES
    )

    requirement_12_pass = bool(
        get_complete
        and max_get_p50 is not None
        and max_get_p50 < THRESHOLDS["12_get_small_p50_ms"]
        and min_get_ops is not None
        and min_get_ops >= THRESHOLDS["12_get_small_ops_per_second"]
    )
    requirement_13_pass = bool(
        put_complete
        and get_complete
        and min_put_ops is not None
        and min_put_ops >= THRESHOLDS["13_put_small_ops_per_second"]
    )
    requirement_14_pass = bool(
        put_8mib_complete
        and put_8mib_rate is not None
        and put_8mib_rate >= THRESHOLDS["14_put_8mib_mib_per_second"]
    )
    return {
        "profile": profile,
        "thresholds": THRESHOLDS,
        "requirements": {
            "12": {
                "status": "PASS" if requirement_12_pass else "FAIL",
                "sizes_bytes": small_sizes,
                "max_p50_ms": max_get_p50,
                "min_aggregate_ops_per_second": min_get_ops,
                "complete": get_complete,
            },
            "13": {
                "status": "PASS" if requirement_13_pass else "FAIL",
                "sizes_bytes": small_sizes,
                "min_aggregate_ops_per_second": min_put_ops,
                "complete": put_complete,
            },
            "14": {
                "status": "PASS" if requirement_14_pass else "FAIL",
                "size_bytes": 8 * 1024 * 1024,
                "client_concurrency": put_8mib.get("concurrency") if put_8mib else None,
                "mib_per_second": put_8mib_rate,
                "complete": put_8mib_complete,
            },
            "17": {
                "status": "PASS" if curve_complete else "FAIL",
                "sizes_bytes": list(REQUIRED_SIZES),
                "systems": ["pgs3", "minio"],
                "complete": curve_complete,
                "note": "No relative-performance threshold; losses to MinIO remain visible.",
            },
        },
    }


def comparison_rows(summary: Mapping[str, object]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    workload = summary.get("workload", {})
    measured = workload.get("sizes_bytes", REQUIRED_SIZES) if isinstance(workload, Mapping) else REQUIRED_SIZES
    for size in measured:
        for operation in ("PUT", "GET"):
            pgs3 = _result_by(summary, "pgs3", operation, size)
            minio = _result_by(summary, "minio", operation, size)
            row: dict[str, object] = {"size_bytes": size, "operation": operation}
            if pgs3 and minio:
                pgs3_p50 = pgs3.get("p50_ms")
                minio_p50 = minio.get("p50_ms")
                pgs3_ops = pgs3.get("ops_per_second")
                minio_ops = minio.get("ops_per_second")
                row["pgs3_to_minio_p50_ratio"] = (
                    float(pgs3_p50) / float(minio_p50)
                    if pgs3_p50 is not None and minio_p50 not in (None, 0)
                    else None
                )
                row["pgs3_to_minio_ops_ratio"] = (
                    float(pgs3_ops) / float(minio_ops)
                    if pgs3_ops is not None and minio_ops not in (None, 0)
                    else None
                )
            rows.append(row)
    return rows


def write_json(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    os.replace(temporary, path)


def parse_sizes(value: str) -> tuple[int, ...]:
    try:
        sizes = tuple(int(part.strip()) for part in value.split(",") if part.strip())
    except ValueError as error:
        raise argparse.ArgumentTypeError("sizes must be comma-separated integers") from error
    if not sizes or any(size < 1 or size > 64 * 1024 * 1024 for size in sizes):
        raise argparse.ArgumentTypeError("sizes must be in 1..67108864")
    if len(set(sizes)) != len(sizes):
        raise argparse.ArgumentTypeError("sizes must be unique")
    return sizes


def profile_config(arguments: argparse.Namespace) -> tuple[tuple[int, ...], dict[int, int], int]:
    if arguments.profile == "acceptance":
        return REQUIRED_SIZES, dict(ACCEPTANCE_SAMPLES), ACCEPTANCE_WARMUPS
    sizes = arguments.smoke_sizes
    return sizes, {size: arguments.smoke_samples for size in sizes}, arguments.smoke_warmups


def run_benchmark(arguments: argparse.Namespace) -> int:
    access_key = os.environ.get("PGS3_BENCH_ACCESS_KEY", "")
    secret = os.environ.get("PGS3_BENCH_SECRET", "")
    if not access_key or not secret:
        raise SystemExit("PGS3_BENCH_ACCESS_KEY and PGS3_BENCH_SECRET are required")
    output = Path(arguments.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    raw_path = output / "raw-samples.jsonl"
    summary_path = output / "summary.json"
    sizes, counts, warmups = profile_config(arguments)
    if arguments.profile == "acceptance" and tuple(sizes) != REQUIRED_SIZES:
        raise AssertionError("acceptance size sweep must remain fixed")

    tag = re.sub(r"[^a-z0-9-]", "-", arguments.run_tag.lower()).strip("-")[:30]
    if not tag:
        raise SystemExit("run tag has no S3-safe characters")
    endpoints = (
        Endpoint("pgs3", arguments.pgs3_endpoint, f"pgs3-bench-{tag}", False),
        Endpoint("minio", arguments.minio_endpoint, f"minio-bench-{tag}", True),
    )
    summary: dict[str, object] = {
        "schema": SCHEMA,
        "profile": arguments.profile,
        "started_at": utc_now(),
        "finished_at": None,
        "result": "RUNNING",
        "run_tag": tag,
        "client": {
            "implementation": "Python stdlib persistent HTTP/1.1 SigV4",
            "python": platform.python_version(),
            "platform": platform.platform(),
            "percentile_method": "nearest-rank over successful request latency",
            "request_retries": 0,
            "timeout_seconds": arguments.timeout,
        },
        "workload": {
            "body_generator": (
                "SHAKE256('pgs3-http-benchmark-body-v2\\0' || decimal_size || "
                "'\\0' || decimal_sample_index || '\\0' || namespace)"
            ),
            "payload_identity": (
                "same size/index payload on pgs3 and MinIO; distinct payload per sample "
                "to avoid content-addressed deduplication bias"
            ),
            "sizes_bytes": list(sizes),
            "samples_per_size": {str(size): counts[size] for size in sizes},
            "warmups_per_size": warmups,
            "acceptance_required_sizes_bytes": list(REQUIRED_SIZES),
            "put_concurrency": {
                str(size): (
                    put_concurrency(size)
                    if arguments.profile == "acceptance"
                    else min(arguments.smoke_concurrency, counts[size])
                )
                for size in sizes
            },
            "get_concurrency": {
                str(size): (
                    get_concurrency(size)
                    if arguments.profile == "acceptance"
                    else min(arguments.smoke_concurrency, counts[size])
                )
                for size in sizes
            },
        },
        "raw_samples": raw_path.name,
        "systems": {
            endpoint.name: {
                "endpoint": endpoint.url,
                "bucket": endpoint.bucket,
                "versioning": "enabled",
                "results": [],
            }
            for endpoint in endpoints
        },
        "environment": None,
        "fatal_error": None,
    }
    environment_path = Path(arguments.environment).resolve() if arguments.environment else None
    if environment_path and environment_path.is_file():
        summary["environment"] = {
            "file": environment_path.name,
            "sha256": hashlib.sha256(environment_path.read_bytes()).hexdigest(),
        }

    client_factory_by_name = {
        endpoint.name: (
            lambda endpoint=endpoint: S3Connection(
                endpoint.url, access_key, secret, timeout=arguments.timeout
            )
        )
        for endpoint in endpoints
    }
    raw_stream = raw_path.open("w", encoding="utf-8")
    try:
        for endpoint in endpoints:
            setup = client_factory_by_name[endpoint.name]()
            try:
                setup.create_bucket(endpoint.bucket)
                if endpoint.enable_versioning:
                    setup.enable_versioning(endpoint.bucket)
                setup.head_bucket(endpoint.bucket)
            finally:
                setup.close()

        for size_index, size in enumerate(sizes):
            payloads = [deterministic_body(size, index) for index in range(counts[size])]
            payload_sha256 = [hashlib.sha256(payload).hexdigest() for payload in payloads]
            if len(set(payload_sha256)) != len(payload_sha256):
                raise BenchmarkError(f"payload generator collision at size {size}")
            warmup_payloads = [
                deterministic_body(size, index, "warmup") for index in range(warmups)
            ]
            ordered_endpoints = endpoints if size_index % 2 == 0 else tuple(reversed(endpoints))
            for endpoint in ordered_endpoints:
                warm = client_factory_by_name[endpoint.name]()
                try:
                    for index in range(warmups):
                        warm_key = key_for(size, index, warmup=True)
                        warm_body = warmup_payloads[index]
                        warm.put_object(
                            endpoint.bucket,
                            warm_key,
                            warm_body,
                            hashlib.sha256(warm_body).hexdigest(),
                        )
                        _, returned = warm.get_object(endpoint.bucket, warm_key)
                        if returned != warm_body:
                            raise BenchmarkError(
                                f"warmup content mismatch for {endpoint.name}/{size}/{index}"
                            )
                finally:
                    warm.close()

                for operation in ("PUT", "GET"):
                    concurrency = (
                        put_concurrency(size) if operation == "PUT" else get_concurrency(size)
                    )
                    if arguments.profile == "smoke":
                        concurrency = arguments.smoke_concurrency
                    metrics, samples = run_phase(
                        endpoint=endpoint,
                        operation=operation,
                        size=size,
                        count=counts[size],
                        concurrency=concurrency,
                        payloads=payloads,
                        payload_sha256=payload_sha256,
                        client_factory=client_factory_by_name[endpoint.name],
                    )
                    system = summary["systems"][endpoint.name]  # type: ignore[index]
                    system["results"].append(metrics)  # type: ignore[index]
                    for sample in samples:
                        raw_stream.write(json.dumps(sample, sort_keys=True) + "\n")
                    raw_stream.flush()
                    print(json.dumps(metrics, sort_keys=True), flush=True)

        acceptance = evaluate_acceptance(summary, arguments.profile)
        summary["acceptance"] = acceptance
        summary["comparison"] = comparison_rows(summary)
        requirement_statuses = [
            record["status"]
            for record in acceptance["requirements"].values()  # type: ignore[index,union-attr]
        ]
        any_errors = any(
            result["errors"]
            for system in summary["systems"].values()  # type: ignore[union-attr]
            for result in system["results"]  # type: ignore[index]
        )
        summary["result"] = (
            "FAIL"
            if any_errors
            or (arguments.profile == "acceptance" and "FAIL" in requirement_statuses)
            else "PASS"
        )
    except BaseException as error:
        summary["result"] = "FAIL"
        summary["fatal_error"] = {
            "type": type(error).__name__,
            "message": str(error)[:1024],
        }
        raise
    finally:
        raw_stream.close()
        summary["finished_at"] = utc_now()
        summary.setdefault("acceptance", evaluate_acceptance(summary, arguments.profile))
        summary.setdefault("comparison", comparison_rows(summary))
        write_json(summary_path, summary)
        print(f"raw_samples={raw_path}")
        print(f"summary={summary_path}")
        print(f"result={summary['result']}")
    return 0 if summary["result"] == "PASS" else 1


def describe(arguments: argparse.Namespace) -> int:
    sizes, counts, warmups = profile_config(arguments)
    print(
        json.dumps(
            {
                "schema": SCHEMA,
                "profile": arguments.profile,
                "sizes_bytes": list(sizes),
                "samples_per_size": {str(size): counts[size] for size in sizes},
                "warmups_per_size": warmups,
                "thresholds": THRESHOLDS,
                "smoke_acceptance_status": (
                    "NOT_RUN" if arguments.profile == "smoke" else "measured"
                ),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    for name in ("run", "describe"):
        command = commands.add_parser(name)
        command.add_argument("--profile", choices=("acceptance", "smoke"), default="acceptance")
        command.add_argument(
            "--smoke-sizes",
            type=parse_sizes,
            default=DEFAULT_SMOKE_SIZES,
            help="comma-separated byte sizes; ignored by acceptance profile",
        )
        command.add_argument("--smoke-samples", type=int, default=3)
        command.add_argument("--smoke-warmups", type=int, default=1)
        command.add_argument("--smoke-concurrency", type=int, default=2)
        if name == "run":
            command.add_argument("--pgs3-endpoint", required=True)
            command.add_argument("--minio-endpoint", required=True)
            command.add_argument("--run-tag", required=True)
            command.add_argument("--output-dir", required=True)
            command.add_argument("--environment")
            command.add_argument("--timeout", type=float, default=180.0)
            command.set_defaults(function=run_benchmark)
        else:
            command.set_defaults(function=describe)
    return root


def main() -> int:
    arguments = parser().parse_args()
    for name in ("smoke_samples", "smoke_warmups", "smoke_concurrency"):
        value = getattr(arguments, name)
        minimum = 0 if name == "smoke_warmups" else 1
        if value < minimum:
            raise SystemExit(f"{name.replace('_', '-')} must be >= {minimum}")
    return arguments.function(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
