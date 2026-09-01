#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import json
import os
import urllib.request
import zlib

import boto3
from botocore.config import Config


def client():
    return boto3.client(
        "s3",
        endpoint_url=os.environ["PGS3_ENDPOINT"],
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            retries={"max_attempts": 1},
            request_checksum_calculation="when_supported",
            response_checksum_validation="when_supported",
        ),
    )


def main() -> int:
    bucket = os.environ["PGS3_TEST_BUCKET"]
    s3 = client()
    payload = b"boto3 acceptance payload\n" + bytes(range(256))
    key = "boto3/nested/object.bin"
    flexible_key = "boto3/flexible-checksum.bin"
    flexible_payload = b"boto3 flexible checksum payload\x00" + bytes(range(251)) * 41
    presigned_key = "boto3/presigned.bin"
    checksum_crc32 = base64.b64encode(
        (zlib.crc32(flexible_payload) & 0xFFFF_FFFF).to_bytes(4, "big")
    ).decode()

    s3.create_bucket(Bucket=bucket)
    checksum_sha256 = base64.b64encode(hashlib.sha256(payload).digest()).decode()
    put = s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=payload,
        ContentType="application/octet-stream",
        Metadata={"client": "boto3"},
        ChecksumSHA256=checksum_sha256,
    )
    if not put.get("ETag"):
        raise RuntimeError("boto3 PutObject did not return ETag")
    if put.get("ChecksumSHA256") != checksum_sha256:
        raise RuntimeError("boto3 PutObject did not echo the verified SHA256 checksum")
    received = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    if received != payload:
        raise RuntimeError("boto3 GetObject payload mismatch")
    head = s3.head_object(Bucket=bucket, Key=key)
    if head["ContentLength"] != len(payload) or head["Metadata"].get("client") != "boto3":
        raise RuntimeError("boto3 HeadObject metadata mismatch")
    listed = s3.list_objects_v2(Bucket=bucket, Prefix="boto3/", Delimiter="/")
    if not any(item.get("Prefix") == "boto3/nested/" for item in listed.get("CommonPrefixes", [])):
        raise RuntimeError("boto3 delimiter listing omitted nested common prefix")

    multipart_key = "boto3/list-parts.bin"
    initiated = s3.create_multipart_upload(Bucket=bucket, Key=multipart_key)
    upload_id = initiated["UploadId"]
    uploaded_etags: dict[int, str] = {}
    try:
        part_template = bytes(range(256)) * (5 * 1024 * 1024 // 256)
        for part_number in (1, 2, 3):
            part = bytes([part_number]) + part_template[1:]
            uploaded = s3.upload_part(
                Bucket=bucket,
                Key=multipart_key,
                UploadId=upload_id,
                PartNumber=part_number,
                Body=part,
            )
            uploaded_etags[part_number] = uploaded["ETag"]

        first_page = s3.list_parts(
            Bucket=bucket,
            Key=multipart_key,
            UploadId=upload_id,
            MaxParts=2,
        )
        if [part["PartNumber"] for part in first_page.get("Parts", [])] != [1, 2]:
            raise RuntimeError("ListParts first page returned the wrong part numbers")
        if not first_page.get("IsTruncated") or first_page.get("NextPartNumberMarker") != 2:
            raise RuntimeError("ListParts first page returned the wrong pagination markers")
        for part in first_page["Parts"]:
            if part["ETag"] != uploaded_etags[part["PartNumber"]]:
                raise RuntimeError("ListParts first page returned the wrong ETag")

        second_page = s3.list_parts(
            Bucket=bucket,
            Key=multipart_key,
            UploadId=upload_id,
            PartNumberMarker=2,
            MaxParts=2,
        )
        if [part["PartNumber"] for part in second_page.get("Parts", [])] != [3]:
            raise RuntimeError("ListParts second page returned the wrong part numbers")
        if second_page.get("IsTruncated"):
            raise RuntimeError("ListParts terminal page was incorrectly truncated")
        if second_page["Parts"][0]["ETag"] != uploaded_etags[3]:
            raise RuntimeError("ListParts terminal page returned the wrong ETag")
    finally:
        s3.abort_multipart_upload(
            Bucket=bucket,
            Key=multipart_key,
            UploadId=upload_id,
        )

    safe_wire_headers: dict[str, str] = {}
    recorded_names = {
        "content-encoding",
        "x-amz-checksum-crc32",
        "x-amz-content-sha256",
        "x-amz-decoded-content-length",
        "x-amz-sdk-checksum-algorithm",
        "x-amz-trailer",
    }

    def record_flexible_checksum_request(request, **_kwargs) -> None:
        safe_wire_headers.clear()
        for name, value in request.headers.items():
            lowered = name.lower()
            if lowered not in recorded_names:
                continue
            if isinstance(value, bytes):
                value = value.decode("ascii")
            safe_wire_headers[lowered] = str(value)

    event = "before-send.s3.PutObject"
    event_id = "pgs3-flexible-checksum-wire-proof"
    s3.meta.events.register(event, record_flexible_checksum_request, unique_id=event_id)
    try:
        flexible_put = s3.put_object(
            Bucket=bucket,
            Key=flexible_key,
            Body=flexible_payload,
            ContentType="application/octet-stream",
        )
    finally:
        s3.meta.events.unregister(event, unique_id=event_id)
    expected_wire_headers = {
        "x-amz-checksum-crc32": checksum_crc32,
        "x-amz-content-sha256": hashlib.sha256(flexible_payload).hexdigest(),
        "x-amz-sdk-checksum-algorithm": "CRC32",
    }
    if safe_wire_headers != expected_wire_headers:
        raise RuntimeError(
            "boto3 did not send the expected cleartext flexible-checksum request: "
            + json.dumps(safe_wire_headers, sort_keys=True)
        )
    if flexible_put.get("ChecksumCRC32") != checksum_crc32:
        raise RuntimeError("boto3 flexible-checksum PutObject returned the wrong CRC32")
    flexible_received = s3.get_object(Bucket=bucket, Key=flexible_key)["Body"].read()
    if flexible_received != flexible_payload:
        raise RuntimeError("boto3 flexible-checksum payload mismatch")

    put_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": bucket, "Key": presigned_key},
        ExpiresIn=60,
    )
    request = urllib.request.Request(put_url, data=b"boto3 presigned payload", method="PUT")
    with urllib.request.urlopen(request, timeout=15) as response:
        if response.status != 200:
            raise RuntimeError(f"boto3 presigned PUT returned {response.status}")
    get_url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": presigned_key},
        ExpiresIn=60,
    )
    with urllib.request.urlopen(get_url, timeout=15) as response:
        if response.read() != b"boto3 presigned payload":
            raise RuntimeError("boto3 presigned GET payload mismatch")

    print(
        json.dumps(
            {
                "client": "boto3",
                "bucket": bucket,
                "etag": put["ETag"],
                "bytes": len(payload),
                "flexible_checksum": flexible_put["ChecksumCRC32"],
                "flexible_payload_mode": "header-crc32-full-payload-hash",
                "list_parts_pages": [2, 1],
                "result": "PASS",
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
