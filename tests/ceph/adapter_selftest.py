#!/usr/bin/env python3
"""Exercise the narrow versioning adapter inside the pinned client image."""

from __future__ import annotations

import os
from urllib.parse import parse_qs, urlsplit


def main() -> int:
    import boto3
    import botocore.compat
    from botocore.client import Config
    import pgs3_adapter

    assert os.environ.get("BOTO_DISABLE_CRT", "").lower() == "true"
    assert not botocore.compat.HAS_CRT

    pgs3_adapter.pytest_configure(None)
    original = pgs3_adapter._original_make_api_call
    assert original is not None
    client = boto3.client(
        "s3",
        aws_access_key_id="adapter-access",
        aws_secret_access_key="adapter-secret",
        endpoint_url="http://adapter-must-not-use-network.invalid",
        region_name="us-east-1",
        config=Config(signature_version="s3v4"),
    )
    response = client.put_bucket_versioning(
        Bucket="adapter-bucket",
        VersioningConfiguration={"Status": "Enabled", "MFADelete": "Disabled"},
    )
    assert response["ResponseMetadata"]["HTTPStatusCode"] == 200

    # The pinned upstream expiry case deliberately asks botocore for a
    # negative lifetime.  CRT asserts locally, whereas the pure-Python signer
    # preserves the fixture so pgs3 can reject it over HTTP with 403.
    expired_url = client.generate_presigned_url(
        ClientMethod="put_object",
        Params={"Bucket": "adapter-bucket", "Key": "expired"},
        ExpiresIn=-1000,
        HttpMethod="PUT",
    )
    query = parse_qs(urlsplit(expired_url).query)
    assert query["X-Amz-Expires"] == ["-1000"]

    forwarded: list[tuple[str, dict]] = []

    def sentinel(_client, operation_name, api_params):
        forwarded.append((operation_name, api_params))
        return {"forwarded": True}

    pgs3_adapter._original_make_api_call = sentinel
    response = client.put_bucket_versioning(
        Bucket="adapter-bucket",
        VersioningConfiguration={"Status": "Suspended"},
    )
    assert response == {"forwarded": True}
    assert forwarded[0][0] == "PutBucketVersioning"
    pgs3_adapter._original_make_api_call = original
    pgs3_adapter.pytest_unconfigure(None)
    print("versioning adapter and pure-Python negative-expiry signer self-test: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
