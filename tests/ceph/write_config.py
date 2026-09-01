#!/usr/bin/env python3
"""Write an ephemeral s3-tests configuration from environment credentials."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys


REQUIRED_ENVIRONMENT = (
    "PGS3_ACCESS_KEY_A",
    "PGS3_SECRET_A",
    "PGS3_ACCESS_KEY_B",
    "PGS3_SECRET_B",
)


def environment_value(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"required environment variable is empty: {name}")
    if "\n" in value or "\r" in value:
        raise ValueError(f"environment variable contains a newline: {name}")
    return value


def validate_host(host: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9.-]+", host) or ".." in host:
        raise ValueError(f"invalid endpoint host: {host!r}")
    return host


def validate_stem(stem: str) -> str:
    normalized = stem.lower()
    if not re.fullmatch(r"[a-z0-9-]{3,18}", normalized):
        raise ValueError("bucket stem must contain 3-18 lowercase letters, digits or dashes")
    if normalized[0] == "-" or normalized[-1] == "-":
        raise ValueError("bucket stem cannot start or end with a dash")
    return normalized


def render(host: str, port: int, bucket_stem: str) -> str:
    access_a, secret_a, access_b, secret_b = (
        environment_value(name) for name in REQUIRED_ENVIRONMENT
    )
    # IAM sections are parsed unconditionally by this upstream commit even when
    # no IAM tests are selected.  Their deliberately invalid credentials are
    # never used by a selected case; teardown's best-effort IAM cleanup catches
    # the unsupported endpoint response.
    return f"""[DEFAULT]
host = {validate_host(host)}
port = {port}
is_secure = False
ssl_verify = False

[fixtures]
bucket prefix = {validate_stem(bucket_stem)}-{{random}}-
iam name prefix = pgs3-ceph-{{random}}-
iam path prefix = /pgs3-ceph/

[s3 main]
display_name = pgs3 tenant a
user_id = pgs3_tenant_a
email = tenant-a@example.invalid
api_name = us-east-1
access_key = {access_a}
secret_key = {secret_a}

[s3 alt]
display_name = pgs3 tenant b
user_id = pgs3_tenant_b
email = tenant-b@example.invalid
access_key = {access_b}
secret_key = {secret_b}

[s3 tenant]
display_name = pgs3 tenant b
user_id = pgs3_tenant_b
email = tenant-b@example.invalid
tenant = pgs3_tenant_b
access_key = {access_b}
secret_key = {secret_b}

[iam]
display_name = unused
user_id = unused
email = unused@example.invalid
access_key = PGS3UNUSEDIAM00001
secret_key = pgs3-unused-iam-secret

[iam root]
user_id = unused-root
email = unused-root@example.invalid
account_id = PGS300000000000000001
access_key = PGS3UNUSEDROOT0001
secret_key = pgs3-unused-root-secret

[iam alt root]
user_id = unused-alt-root
email = unused-alt-root@example.invalid
account_id = PGS300000000000000002
access_key = PGS3UNUSEDALTROOT1
secret_key = pgs3-unused-alt-root-secret
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bucket-stem", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if not 1 <= arguments.port <= 65535:
        parser.error("port must be in 1..65535")
    try:
        contents = render(arguments.host, arguments.port, arguments.bucket_stem)
    except ValueError as error:
        print(f"configuration error: {error}", file=sys.stderr)
        return 2
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        arguments.output,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(contents)
    print(f"wrote ephemeral s3-tests configuration to {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
