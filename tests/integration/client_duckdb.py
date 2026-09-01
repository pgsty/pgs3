#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import urllib.parse

import boto3
from botocore.config import Config
import duckdb


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> int:
    endpoint = os.environ["PGS3_ENDPOINT"]
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "http" or not parsed.netloc:
        raise RuntimeError("DuckDB test endpoint must be cleartext HTTP")
    bucket = os.environ["PGS3_TEST_BUCKET"]
    key = "duckdb/acceptance.parquet"
    parquet = Path("/work/duckdb-acceptance.parquet")

    connection = duckdb.connect()
    connection.execute("LOAD httpfs")
    connection.execute(
        "COPY (SELECT i::BIGINT AS id, 'agent-' || i::VARCHAR AS name "
        "FROM range(1, 1001) t(i)) TO "
        + sql_literal(str(parquet))
        + " (FORMAT PARQUET)"
    )

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            request_checksum_calculation="when_supported",
            response_checksum_validation="when_supported",
        ),
    )
    s3.create_bucket(Bucket=bucket)
    s3.upload_file(str(parquet), bucket, key)
    parquet.unlink()

    connection.execute(
        "CREATE TEMPORARY SECRET pgs3_acceptance ("
        "TYPE S3, KEY_ID "
        + sql_literal(os.environ["AWS_ACCESS_KEY_ID"])
        + ", SECRET "
        + sql_literal(os.environ["AWS_SECRET_ACCESS_KEY"])
        + ", REGION "
        + sql_literal(os.environ.get("AWS_REGION", "us-east-1"))
        + ", ENDPOINT "
        + sql_literal(parsed.netloc)
        + ", URL_STYLE 'path', USE_SSL false)"
    )
    count, total, first_name = connection.execute(
        "SELECT count(*), sum(id), min(name) FROM read_parquet(?)",
        [f"s3://{bucket}/{key}"],
    ).fetchone()
    if (count, total, first_name) != (1000, 500500, "agent-1"):
        raise RuntimeError(
            f"DuckDB httpfs result mismatch: {(count, total, first_name)!r}"
        )
    print(
        json.dumps(
            {
                "client": "duckdb-httpfs",
                "rows": count,
                "sum_id": total,
                "result": "PASS",
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
