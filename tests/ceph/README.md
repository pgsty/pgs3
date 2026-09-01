# Ceph `s3-tests` Phase 1 gate

This suite runs an explicit allow-list from Ceph `s3-tests` commit
`5522d1c351f75bc00ae0f64f742f3f095f5939d9`. The commit and all Python client
versions in `requirements.lock` are baked into a dedicated container image. A
mutable branch, marker expression, or broad directory is never used as the
release selection.

The fixed first-run candidate set contains 209 data-plane cases. Exact pinned
source checks exclude 14 cases whose assertions require an API outside Phase 1
or conflict with an explicit pgs3/AWS invariant, leaving 195 selected cases.
They cover bucket and object basics, ListObjects V1/V2 (including
`MaxKeys=0`), SigV4 failures, metadata and conditional requests, CopyObject,
DeleteObjects, multipart uploads, ranges, `Expect: 100-continue`, versioning,
races, and client-supplied checksums. The exact node ids, exclusions, and
category requirements are in `selection.json`.

The gate is intentionally strict:

- pytest must collect exactly the 195 selected pinned node ids;
- at least 150 cases must actually execute (collection skips do not count);
- at least 150 cases must pass; and
- no selected core case may fail, error, skip, or disappear from the report.

A core failure remains a failure. It is not converted to `xfail`, filtered by
an upstream `fails_on_*` marker, or reclassified as out of scope. The
`excluded_classes` and `excluded_cases` record every reason plus exact upstream
decorators and source signatures. In addition to APIs outside Phase 1, the
record covers the us-east-1 null LocationConstraint wire representation,
repeat-success completion of consumed multipart upload IDs, and a race fixture
that submits duplicate PartNumber entries to a strictly ordered completion.

There are two narrow, recorded compatibility accommodations. Stock Ceph
versioning tests first issue `PutBucketVersioning(Status=Enabled)`, but pgs3
versioning is permanently enabled and Phase 1 intentionally has no PUT
versioning route. The adapter returns a local success only for `Enabled` (and
optional `MFADelete=Disabled`); suspension and every other operation still
reach the endpoint. The pinned awscrt release also asserts locally on the
suite's deliberate `ExpiresIn=-1000` fixture, so the harness sets
`BOTO_DISABLE_CRT=true` and uses pinned botocore's pure-Python SigV4 signer.
An offline self-test proves that it preserves `X-Amz-Expires=-1000`; explicit
precomputed CRC64NVME cases remain selected. Both contracts are embedded in
`suite-manifest.json`.

Run the PostgreSQL 17 gate with:

```sh
make ceph-test PG_MAJOR=17
```

Reuse already-built server and Ceph client images with:

```sh
PGS3_SKIP_BUILD=1 PGS3_SKIP_CEPH_BUILD=1 make ceph-test PG_MAJOR=17
```

`PGS3_CEPH_TIMEOUT_SECONDS` changes the default 3600-second outer timeout.
`PGS3_CEPH_IMAGE` can change the local image tag, but the runner still rejects
an image whose OCI revision label is not the pinned commit.

Every run creates `artifacts/acceptance/<run-id>/`. The `ceph/` directory
contains:

- `suite-manifest.json`: fixed commit, selection digest, gates, exclusions,
  category, requirement, and ordinal for every case;
- `collection.json` and `collection.txt`: exact-collection audit;
- `junit.xml`: credential-redacted pytest JUnit;
- `results.json`: a PASS/FAIL/ERROR/SKIP/NOT_RUN outcome and reason for every
  selected case, plus executed/pass counts and gate failures; and
- `summary.txt`: short human-readable counts.

The top-level acceptance `manifest.json` records the dirty-workspace digest,
image identity, commands, timestamps, return statuses, server logs, and runtime
statistics. Configuration credentials live only in a mode-0600 temporary file.
Raw JUnit lives in container-local `/tmp`; only its redacted copy is published.

For static harness checks without starting PostgreSQL, run `make ceph-lint`.
After building the client image, `make ceph-collect` performs a real pytest
collection and exact-node audit without contacting an S3 endpoint. Image builds
also run this collection check automatically. To audit the selection against a
local checkout:

```sh
python3 tests/ceph/selection.py validate \
  --selection tests/ceph/selection.json \
  --upstream /path/to/s3-tests
```
