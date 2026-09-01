#!/usr/bin/env python3

from __future__ import annotations

import datetime as dt
from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))
import benchmark as bench  # noqa: E402


class FakeClient:
    def __init__(self, storage: dict[tuple[str, str], bytes], fail: bool = False) -> None:
        self.storage = storage
        self.fail = fail

    def head_bucket(self, _bucket: str) -> None:
        return None

    def put_object(self, bucket: str, key: str, body: bytes, _digest: str) -> int:
        if self.fail:
            raise ConnectionError("synthetic failure")
        self.storage[(bucket, key)] = body
        return 200

    def get_object(self, bucket: str, key: str) -> tuple[int, bytes]:
        if self.fail:
            raise ConnectionError("synthetic failure")
        return 200, self.storage[(bucket, key)]

    def close(self) -> None:
        return None


def passing_result(system: str, operation: str, size: int) -> dict[str, object]:
    concurrency = 1 if operation == "PUT" and size >= 8 * 1024 * 1024 else 16
    return {
        "system": system,
        "operation": operation,
        "size_bytes": size,
        "planned_samples": 10,
        "attempted_samples": 10,
        "successful_samples": 10,
        "errors": 0,
        "concurrency": concurrency,
        "p50_ms": 0.1,
        "p95_ms": 0.2,
        "p99_ms": 0.3,
        "ops_per_second": 40_000.0 if operation == "GET" else 6_000.0,
        "mib_per_second": 200.0,
        "all_requests_succeeded": True,
        "all_content_verified": True if operation == "GET" else None,
    }


def passing_summary() -> dict[str, object]:
    return {
        "systems": {
            system: {
                "results": [
                    passing_result(system, operation, size)
                    for size in bench.REQUIRED_SIZES
                    for operation in ("PUT", "GET")
                ]
            }
            for system in ("pgs3", "minio")
        }
    }


class BenchmarkTests(unittest.TestCase):
    def test_required_sweep_includes_exact_boundary_and_range(self) -> None:
        self.assertEqual(bench.REQUIRED_SIZES[0], 4 * 1024)
        self.assertEqual(bench.REQUIRED_SIZES[-1], 64 * 1024 * 1024)
        self.assertIn(65_535, bench.REQUIRED_SIZES)
        self.assertIn(65_536, bench.REQUIRED_SIZES)
        self.assertIn(65_537, bench.REQUIRED_SIZES)
        self.assertEqual(set(bench.REQUIRED_SIZES), set(bench.ACCEPTANCE_SAMPLES))

    def test_body_is_deterministic_exact_and_incompressible_shaped(self) -> None:
        first = bench.deterministic_body(65_537, 7)
        second = bench.deterministic_body(65_537, 7)
        other = bench.deterministic_body(65_537, 8)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 65_537)
        self.assertNotEqual(first, other)
        self.assertGreater(len(set(first[:4096])), 240)

    def test_nearest_rank_percentiles(self) -> None:
        values = list(range(1, 101))
        self.assertEqual(bench.percentile_nearest_rank(values, 50), 50)
        self.assertEqual(bench.percentile_nearest_rank(values, 95), 95)
        self.assertEqual(bench.percentile_nearest_rank(values, 99), 99)
        with self.assertRaises(ValueError):
            bench.percentile_nearest_rank([], 50)

    def test_signature_is_deterministic_and_does_not_embed_secret(self) -> None:
        client = bench.S3Connection(
            "http://example.test:9000", "ACCESS", "secret-value", timeout=1
        )
        when = dt.datetime(2026, 8, 31, tzinfo=dt.timezone.utc)
        first = client._headers("GET", "/bucket/key", (), bench.EMPTY_SHA256, when)
        second = client._headers("GET", "/bucket/key", (), bench.EMPTY_SHA256, when)
        self.assertEqual(first, second)
        self.assertNotIn("secret-value", first["authorization"])
        self.assertIn("Credential=ACCESS/20260831/us-east-1/s3/aws4_request", first["authorization"])

    def test_smoke_profile_can_never_claim_acceptance(self) -> None:
        result = bench.evaluate_acceptance({}, "smoke")
        self.assertEqual(
            {record["status"] for record in result["requirements"].values()},
            {"NOT_RUN"},
        )

    def test_acceptance_evaluator_passes_only_complete_fixed_curve(self) -> None:
        summary = passing_summary()
        result = bench.evaluate_acceptance(summary, "acceptance")
        self.assertEqual(
            {record["status"] for record in result["requirements"].values()},
            {"PASS"},
        )
        pgs3_results = summary["systems"]["pgs3"]["results"]
        next(
            item
            for item in pgs3_results
            if item["operation"] == "PUT" and item["size_bytes"] == 8 * 1024 * 1024
        )["concurrency"] = 2
        result = bench.evaluate_acceptance(summary, "acceptance")
        self.assertEqual(result["requirements"]["14"]["status"], "FAIL")

    def test_threshold_miss_remains_fail_even_with_complete_samples(self) -> None:
        summary = passing_summary()
        small_get = next(
            item
            for item in summary["systems"]["pgs3"]["results"]
            if item["operation"] == "GET" and item["size_bytes"] == 4096
        )
        small_get["p50_ms"] = 0.5
        result = bench.evaluate_acceptance(summary, "acceptance")
        self.assertEqual(result["requirements"]["12"]["status"], "FAIL")

    def test_run_phase_records_raw_verified_samples(self) -> None:
        storage: dict[tuple[str, str], bytes] = {}
        endpoint = bench.Endpoint("fake", "http://fake", "bucket", False)
        payloads = [bench.deterministic_body(4096, index) for index in range(6)]
        digests = [__import__("hashlib").sha256(body).hexdigest() for body in payloads]
        factory = lambda: FakeClient(storage)  # noqa: E731
        put_metrics, put_samples = bench.run_phase(
            endpoint=endpoint,
            operation="PUT",
            size=4096,
            count=6,
            concurrency=2,
            payloads=payloads,
            payload_sha256=digests,
            client_factory=factory,
        )
        get_metrics, get_samples = bench.run_phase(
            endpoint=endpoint,
            operation="GET",
            size=4096,
            count=6,
            concurrency=2,
            payloads=payloads,
            payload_sha256=digests,
            client_factory=factory,
        )
        self.assertEqual(put_metrics["errors"], 0)
        self.assertEqual(get_metrics["errors"], 0)
        self.assertEqual(len(put_samples), 6)
        self.assertTrue(all(sample["content_verified"] for sample in get_samples))
        self.assertTrue(all(sample["content_verified"] is None for sample in put_samples))
        self.assertTrue(all(sample["schema"] == bench.RAW_SCHEMA for sample in get_samples))

    def test_error_budget_aborts_phase_honestly(self) -> None:
        endpoint = bench.Endpoint("fake", "http://fake", "bucket", False)
        payloads = [bytes((index,)) for index in range(100)]
        digests = [__import__("hashlib").sha256(body).hexdigest() for body in payloads]
        metrics, samples = bench.run_phase(
            endpoint=endpoint,
            operation="PUT",
            size=1,
            count=100,
            concurrency=4,
            payloads=payloads,
            payload_sha256=digests,
            client_factory=lambda: FakeClient({}, fail=True),
            max_errors=3,
        )
        self.assertTrue(metrics["aborted_by_error_budget"])
        self.assertGreaterEqual(metrics["errors"], 3)
        self.assertLess(len(samples), 100)

    def test_parse_sizes_rejects_duplicates_and_out_of_range(self) -> None:
        self.assertEqual(bench.parse_sizes("4096,65536"), (4096, 65536))
        with self.assertRaises(Exception):
            bench.parse_sizes("4096,4096")
        with self.assertRaises(Exception):
            bench.parse_sizes("0")


if __name__ == "__main__":
    unittest.main()
