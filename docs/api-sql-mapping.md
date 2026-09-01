# S3 API to SQL semantic mapping

## Status and rule

The HTTP layer translates to this SQL semantic layer; it must not reproduce
locking, condition, version, refcount, or tenant logic in Rust. “Implemented in
source” below is intentionally weaker than a client compatibility claim. Live
evidence is named separately.

At the 2026-08-31 checkpoint:

- the required bucket/object/list/version/multipart SQL functions and HTTP route
  adapters are implemented in `sql/bootstrap.sql` and `src/s3/`;
- `pgs3.sha256`, streaming digest helpers, `pgs3.start`, and `pgs3.stop` are pgrx
  Rust functions; dynamic `start()` now targets the caller's current database;
- header and query SigV4, full-hash and unsigned payloads, both required
  aws-chunked modes, S3 XML, RLS role switching, and metrics passed the packaged
  PG17/PG18 HTTP smokes;
- the full PG17 matrix passes aws CLI `s3api`/`s3`, 100 MiB multipart, rclone,
  boto3, DuckDB, and real s3fs FUSE in
  [`clients-pg17-72577`](../artifacts/acceptance/20260831T064443Z-clients-pg17-72577/manifest.json)
  and
  [`clients-pg18-71442`](../artifacts/acceptance/20260831T064421Z-clients-pg18-71442/manifest.json);
- 195 selected bucket/object/list/version/multipart/checksum Ceph cases pass with
  zero selected failure/error/skip in
  [`ceph-s3-tests-pg17-74469`](../artifacts/acceptance/20260831T064550Z-ceph-s3-tests-pg17-74469/manifest.json);
- the fixed seven-case malformed request-head/XML/body/chunked corpus passed with
  stable postmaster and HTTP-worker identity;
- the final PG18 image passes packaged SQL semantic/smoke/concurrency and HTTP
  runtime gates.

## Route selection

Path-style routing is ordered by method, query discriminator, and headers. Query
parameters such as `?delete`, `?uploads`, `?uploadId`, `?partNumber`, `?versions`,
`?location`, and `?versioning` must be detected by **presence**, including an empty
value. CopyObject is distinguished from PutObject by `x-amz-copy-source`.

Never build SQL by interpolating bucket, key, token, version, ETag, metadata, or
XML text. Use parameterized SPI calls in a bounded transaction after authentication
and `SET LOCAL ROLE`.

## Bucket APIs

| S3 operation | HTTP discriminator | SQL semantic call | Current implementation/evidence | Work still required |
| --- | --- | --- | --- | --- |
| ListBuckets | `GET /` | `pgs3.list_buckets()` | SQL/HTTP, two-tenant smoke, required clients, and selected Ceph cases pass | Bucket policies/ACL-derived ownership fields are out of scope. |
| CreateBucket | `PUT /{bucket}` with no key/copy header | `pgs3.create_bucket(name, config)` | Invalid names, same-owner us-east-1 idempotence, cross-owner collision, and 50-way same-name concurrency pass | Regions other than the configured phase-one region are unsupported. |
| DeleteBucket | `DELETE /{bucket}` with no key | `pgs3.delete_bucket(name)` | Empty/nonempty/missing behavior passes clients/Ceph; D023 atomically aborts pending uploads for an otherwise empty bucket | Directory-bucket behavior is out of scope. |
| HeadBucket | `HEAD /{bucket}` | `pgs3.head_bucket(name)` | Success/missing and cross-tenant invisibility pass | No virtual-host routing. |
| GetBucketLocation | `GET /{bucket}?location` | `pgs3.get_bucket_location(name)` | aws `s3api` passes; us-east-1 returns the AWS-compatible empty constraint | Non-default region configuration is not defined. |
| GetBucketVersioning | `GET /{bucket}?versioning` | `pgs3.get_bucket_versioning(name)` | aws `s3api` and versioning suites pass with permanent `Enabled` | Suspension/null-version transitions are intentionally unsupported. |

Bucket operations use the mapped actor and `pg_has_role(..., owner, 'USAGE')`.
The target location/region also participates in SigV4 credential scope; its
configuration is not yet defined.

## Object APIs

| S3 operation | HTTP discriminator | SQL semantic call(s) | Current implementation/evidence | Work still required |
| --- | --- | --- | --- | --- |
| PutObject | `PUT /{bucket}/{key}`, no copy/uploadId | eligible <=`min(inline_threshold,64 KiB)`: `pgs3.put(...)`; otherwise `begin_upload` → independent worker-sealed chunk calls → exact-manifest worker completion | Current PG17/18 clients and PG17 Ceph pass both direct and staged forms; boundary/cap/SIGHUP-snapshot tests pass. The final 4 MiB-default sweep passes the 8 MiB PUT gate at 167.894 MiB/s | D026 documents size-dependent multi-error precedence; small-object gates still fail. |
| GetObject | `GET /{bucket}/{key}` without multipart discriminator | `pgs3.get(...)`; range: `pgs3.head(...)` + `pgs3.get_range(...)` / extent reads | Clients, range/date conditions, delete markers, crash recovery, standby reads, and selected Ceph cases pass | Full GET currently materializes one SQL `bytea`/Rust `Vec`; a bounded response cursor is still needed. Multi-range is out of scope. |
| HeadObject | `HEAD /{bucket}/{key}` | `pgs3.head(...)` | Conditions, zero-byte objects, delete-marker headers, clients, and selected Ceph cases pass | Broader optional checksum algorithms follow D024. |
| DeleteObject | `DELETE /{bucket}/{key}` without uploadId | `pgs3.delete(bucket, key, version_id)` | Current/delete-marker and explicit-version behavior pass SQL, clients, and selected Ceph cases | Versioning is always enabled. |
| DeleteObjects | `POST /{bucket}?delete` | version-aware `pgs3.delete_many(...)` | Ordered/idempotent/version-aware bounded batches pass aws CLI and selected Ceph cases | Maximum batch remains 1,000 entries. |
| CopyObject | `PUT /{dst_bucket}/{dst_key}` plus `x-amz-copy-source` | `pgs3.copy(...)` | Canonical blobs are shared; metadata directives, conditions, versions, self-copy rules, and cross-tenant non-disclosure pass selected Ceph cases | UploadPartCopy is out of scope. |

### Present object SQL signatures

The useful source-level contract is:

```sql
pgs3.put(
    bucket text, key text, body bytea,
    content_type text default 'application/octet-stream',
    meta jsonb default '{}',
    if_none_match text default null,
    if_match text default null,
    checksum_sha256 bytea default null
) returns pgs3.object_info

pgs3.head(
    bucket text, key text, version_id bigint default null,
    if_match text default null, if_none_match text default null
) returns pgs3.object_info

pgs3.get(same identity/etag condition arguments)
    returns pgs3.object_data

pgs3.get_range(
    bucket text, key text, start bigint, end bigint default null,
    version_id bigint default null,
    if_match text default null, if_none_match text default null
) returns bytea

pgs3.delete(bucket text, key text, version_id bigint default null)
    returns pgs3.delete_result

pgs3.delete_many(bucket text, keys text[])
    returns setof pgs3.delete_result

pgs3.delete_many(bucket text, keys text[], version_ids bigint[])
    returns setof pgs3.delete_result

pgs3.copy(
    source_bucket text, source_key text,
    destination_bucket text, destination_key text,
    source_version_id bigint default null,
    content_type text default null, meta jsonb default null,
    if_none_match text default null, if_match text default null,
    source_if_match text default null
) returns pgs3.object_info
```

The client checksum parameter is only a comparison. `put` computes SHA-256 over
the supplied body first and computes the single-upload MD5 ETag server-side.

### Conditional and range translation

Write `If-None-Match: *` and destination `If-Match` must be passed into the same
semantic mutation that takes the key lock. A separate `head` followed by `put` is
incorrect. HTTP maps the semantic precondition SQLSTATE to 412.

The HTTP retrieval adapter parses wildcard/list entity tags and HTTP dates and
applies RFC ordering for `If-Match`, `If-None-Match`, `If-Modified-Since`,
`If-Unmodified-Since`, and `If-Range`. Atomic write conditions are still passed
into the locked SQL mutation; only the required `If-None-Match: *` and one exact
`If-Match` value are proven there, including selected Ceph success/failure cases.
The non-AWS wildcard/arbitrary-tag variants excluded by the fixed selection do
not justify an unlocked pre-read.

`get_range` accepts a zero-based inclusive start and inclusive/NULL end. The HTTP
adapter must parse one `bytes=` range, use object size to convert suffix ranges,
and emit `Content-Range`, `Accept-Ranges`, correct length, and 416 for
unsatisfiable ranges. Multi-range behavior needs an explicit compatibility test;
it must not allocate an arbitrary multipart response accidentally.

## Listing and versions

| S3 operation | HTTP discriminator | SQL semantic call | Current implementation/evidence | Work still required |
| --- | --- | --- | --- | --- |
| ListObjects V1 | `GET /{bucket}` without `list-type=2`/other subresource | `pgs3.list_objects_v1(bucket,prefix,delimiter,marker,max_keys)` | aws/s3fs plus selected ordering/prefix/delimiter/encoding/pagination Ceph cases pass | Ceph-only `allow-unordered` is intentionally unsupported. |
| ListObjectsV2 | `GET /{bucket}?list-type=2` | `pgs3.list_objects_v2(bucket,prefix,delimiter,start_after,continuation_token,max_keys)` | Clients, crash/standby, encoding/pagination/zero-page Ceph cases, and million-key scale pass | Continuation tokens still need authentication. |
| ListObjectVersions | `GET /{bucket}?versions` | `pgs3.list_versions(bucket,prefix,delimiter,key_marker,version_id_marker,max_keys)` | Versions/delete markers, pagination, special names, copies, and selected concurrent Ceph cases pass | Versioning suspension is out of scope. |

`pgs3.list(...)` is the shared V2-shaped primitive. It performs procedural index
jumps for delimiter common prefixes rather than scanning and DISTINCTing. Returned
`list_entry` rows represent either an object (`key` set) or common prefix
(`common_prefix` set), and include a token for the following seek position.

Current continuation tokens are base64-encoded JSON bound to bucket/prefix/
delimiter when parsed, but they are **not authenticated**; a caller can forge seek
state. D014 requires a versioned tamper-evident token. For a full page, the
database adapter performs a one-row probe behind the same bucket/RLS boundary and
clears the terminal token when no further row exists. Explicit `max-keys=0`
returns an empty non-truncated page without continuation fields.

The current million-key SQL scale run passes both latency gates: ordinary
LIST took 2.358 ms and delimiter LIST took 9.487 ms. The latter returned 1,000
prefixes while touching 5,139 shared blocks. See
[`scale-pg17-90791`](../artifacts/acceptance/20260831T065441Z-scale-pg17-90791/manifest.json).
These are single SQL executions; repeated-distribution and HTTP-route scale
measurements remain separate work.

## Version-only SQL operations

These are part of the SQL asset even where phase-one S3 has no separate HTTP
extension route:

| Operation | SQL call | Current state | Notes/gaps |
| --- | --- | --- | --- |
| Restore old version | `pgs3.restore(bucket,key,version_id,if_match)` | Implemented and SQL-tested | Creates a new latest version referencing selected canonical content; never mutates old history. HTTP restore is a pgs3 extension route, not a required S3 restore-service implementation. |
| Fork bucket | `pgs3.fork_bucket(source,destination,config)` | Implemented; 100k sharing/independence passed, golden-image timing failed | A materialized DML CTE copies latest metadata/blob IDs and updates refcounts set-wise; blob fillfactor is 80. Golden-image timing is 1944.071 ms. A same-final-source pre-golden iteration reached 865.495 ms, proving variance/optimization potential rather than a final PASS. |

Version IDs cross HTTP as base-10 strings but remain opaque to clients. Ordinary
GET/LIST hides a latest delete marker. An explicit GET/HEAD of a delete-marker
version uses S3-compatible missing/deletion status and `x-amz-delete-marker` /
version headers; selected Ceph delete-marker cases pass.

## Multipart and pending uploads

| S3 operation | HTTP discriminator | SQL semantic call(s) | Current implementation/evidence | Work still required |
| --- | --- | --- | --- | --- |
| CreateMultipartUpload | `POST /{bucket}/{key}?uploads` | `pgs3.begin_upload(..., multipart => true, ...)` | Required clients and selected Ceph create/overwrite/checksum cases pass | Non-SHA final checksum gap is D024. |
| UploadPart | `PUT ...?partNumber=N&uploadId=U` | repeated `pgs3.put_chunk(...)` transactions then `pgs3.complete_part(...)`; lease renewal while reading | 13-part 100 MiB aws upload, replacement, validation, and selected Ceph cases pass | Supplied per-part checksums are verified; non-SHA digests are not retained for final composition. |
| CompleteMultipartUpload | `POST ...?uploadId=U` | `pgs3.complete_multipart_upload(...)` | Exact 13-part ETag/download/rclone and SHA256 `COMPOSITE` selected Ceph case pass | A consumed upload ID returns `NoSuchUpload`; repeat-success completion receipts are not retained. |
| AbortMultipartUpload | `DELETE ...?uploadId=U` | `pgs3.abort_upload(...)` | Existing/missing behavior passes selected Ceph cases | No separate directory-bucket semantics. |
| ListParts | `GET ...?uploadId=U` | `pgs3.list_parts(...)` plus HTTP paging | Target-bound authorization and a two-page boto3 paging case pass in both PG17 and PG18 client matrices | No separate standby ListParts runtime case. |

The lower-level lifecycle also supports a streaming non-multipart PutObject:

```sql
pgs3.begin_upload(...) returns uuid
pgs3.renew_upload(upload_id) returns timestamptz
pgs3.put_chunk(upload_id, seq, data, part_number default 0,
               checksum_sha256 default null) returns bigint
pgs3.complete_upload(upload_id, parts default null, part_etags default null,
                     checksum_sha256 default null) returns pgs3.object_info
pgs3.abort_upload(upload_id) returns boolean
```

Each `put_chunk` invocation must be committed independently by the worker; calling
several in one outer SQL transaction defeats the crash/long-transaction design.
Only final `complete_upload` publishes the object/latest/refcount transition.
`upload_id` is also the attempt/lease identity. Every locked upload operation
renews `lease_expires_at` by five minutes; complete and abort delete it. While an
HTTP worker is reading without committing chunks, a target-bound
`renew_upload(bucket,key,upload_id,require_multipart)` becomes due after 60 seconds
and is committed on the next body-progress callback; a chunk commit resets that
schedule. It returns the absolute deadline and uses `P3U01`/`NoSuchUpload` for an
unknown, unauthorized, non-pending, or target-mismatched attempt.

The public SQL signatures keep server authority by hashing the supplied/stored
bytes in PostgreSQL/Rust digest helpers. D027 adds internal
`_worker_put_chunk(actor,...,body,server_sha256)` and
`_worker_complete_upload(actor,...,server_sha256,server_md5,server_size,
chunk_blob_ids,chunk_sizes)` capabilities only for non-multipart HTTP PutObject.
Each chunk call receives the digest beside the exact `bytea`, installs/reuses that
canonical blob under the trusted worker capability, and returns the blob ID/size
actually committed. Finalization locks the upload and requires the exact ordered
arrays, dense sequence, and total size to match before using the whole-body
digest. The functions are revoked from PUBLIC, granted only to the configured
service role, and fail unless its session identity and SET-only actor membership
are valid. UploadPart continues through public `put_chunk` and its ordinary
completion readback.

Fixed `Content-Length` input reaches this adapter as borrowed framing slices;
staged buffers grow progressively and reuse the full-chunk allocation after each
SPI call. SHA-256 and ETag MD5 are always accumulated. SHA-1, CRC32, CRC32C, and
CRC64NVME state is initialized only if an accepted header/trailer declares it,
and AArch64 builds enable the pinned SHA-2 assembly backend. Chunked and
aws-chunked payloads retain their owned verification buffers.

The packaged path provides Rust-backed `hash_upload_part` and
`hash_blob_sequence` helpers and publishes extent metadata rather than copying
final payload rows. A SQL-only fallback still has an explicit 128 MiB transient
hash bound. The packaged 100 MiB client path uses the Rust helpers and now passes
with exact ETag and end-to-end body verification.

SHA256 multipart negotiation is distinct from the canonical full-content SHA-256:
the server validates stored per-part SHA256 values and publishes
`base64(SHA256(concat(raw_part_sha256)))-N` as `COMPOSITE`. Automatic CRC32 or
CRC64-family selection is currently accepted without echoing/storing a final
checksum; any checksum actually supplied on UploadPart is still verified. This
provisional compatibility choice and the work needed for full non-SHA composition
are recorded in D024.

## Presigned URLs

| S3 operation | HTTP form | SQL mapping | Current state/evidence |
| --- | --- | --- | --- |
| Presigned GET | `GET object` with `X-Amz-*` query authentication | same `head/get/get_range` calls as signed-header GET | Implemented; valid, expired, and cross-tenant PG17 smoke cases passed. |
| Presigned PUT | `PUT object` with `X-Amz-*` query authentication | same pending upload/`put` semantics as signed-header PUT | Implemented; valid body and tampered-body invisibility cases passed. |

Presigning is an authentication mode, never a bypass or separate authorization
path. The credential must still be enabled, the expiry/scope/signature must pass,
and the mapped role's RLS/GRANT visibility applies. A URL cannot be reinterpreted
for another method/path/query after verification.

## Administrative and maintenance SQL

| Function | Current state/evidence | Intended privilege/status |
| --- | --- | --- |
| `pgs3.extension_version()` | SQL function added in 0.1.1 | PUBLIC stable catalog probe; reads `pg_extension.extversion`, not the loaded library version. |
| `pgs3.start()` | Rust function present and exercised by PG17 HTTP smoke | Operator-only dynamic launcher control; targets the current database and waits for launcher startup. Finalize SQL revokes PUBLIC. |
| `pgs3.stop()` | Rust function present | Operator-only; discovers current-database launcher/children rather than relying on a backend-local handle. Dedicated cross-session lifecycle evidence remains desirable. |
| `pgs3.sha256(bytea)` | Rust function present | Immutable helper used for server-authoritative hash; hashing a full bytea is not streaming. |
| `pgs3.gc_pending_uploads(max_age,limit)` | SQL present | PUBLIC explicitly revoked; deletes only pending rows older than `max_age` whose explicit lease expired, claiming a bounded batch with `FOR UPDATE SKIP LOCKED`. |
| `pgs3.gc_blobs(limit)` | SQL present | PUBLIC explicitly revoked; bounded zero-ref delete with SKIP LOCKED, untested under races. |
| credential create/rotate/role/enable/delete API | SQL functions present; HTTP harness uses `create_credential` | Operator-only and revoked from PUBLIC. Functions return booleans and never return the secret; backup secrecy remains operationally critical. |
| `pgs3.stats` | SQL view over worker state and bounded operation counters | PG17 smoke verifies requests, errors, bytes, in-flight gauge, cumulative latency histogram, heartbeat, and state. Table-backed standby request metrics remain intentionally absent. |
| `_worker_set_actor`, `_worker_put_chunk`, `_worker_complete_upload` | SQL worker bridge added in 0.1.1 | PUBLIC revoked; dynamically granted only to the configured restricted service role. Exact manifest matching prevents a short-transaction chunk replacement from being sealed under stale whole-body digests. |

Internal functions beginning `_` are explicitly revoked from PUBLIC by bootstrap
DDL, as are both GC functions. Tables/sequences are revoked. Tenant semantic APIs
intentionally retain PostgreSQL's default EXECUTE grant to PUBLIC, so any role
with database CONNECT may create a bucket it owns; existing-bucket membership and
RLS still isolate rows (D021). The installed catalog must prove this exact grant
shape and separately restrict `start`/`stop` plus credential maintenance to
operators.

## SQL result types to protocol values

| SQL type/field | S3 representation |
| --- | --- |
| `bucket_info.name` | `<Name>` or routed bucket |
| `bucket_info.created_at` | ISO-8601 `<CreationDate>` |
| `object_info.version_id bigint` | decimal `x-amz-version-id` / `<VersionId>` string |
| `object_info.etag` | quote for HTTP `ETag` and XML `<ETag>` as required |
| `object_info.sha256 bytea` | internal/server checksum; encode only for the matching S3 checksum header contract |
| `object_info.meta jsonb` | validated `x-amz-meta-*` headers; do not expose internal JSON fields |
| `list_entry.key` | XML-escaped key, optionally URL-encoded when `encoding-type=url` is supported |
| `list_entry.common_prefix` | XML `<CommonPrefixes><Prefix>` entry |
| `delete_result` | `<Deleted>` or per-item `<Error>` in DeleteObjects XML |
| `part_info.etag` | quoted UploadPart/ListParts ETag |

XML escaping and URL encoding are separate. Never place a raw key, error message,
or metadata string into XML.

## Expected SQLSTATE to S3 mapping

The HTTP layer maps stable semantic error identity, not arbitrary English text.
The current SQLSTATE/DETAIL namespace is:

| SQLSTATE | Semantic meaning | HTTP / S3 mapping |
| --- | --- | --- |
| `P3B01` | inaccessible/missing bucket | 404 `NoSuchBucket` |
| `P3K01` | missing key or version/source marker | 404 `NoSuchKey` or `NoSuchVersion` selected by allow-listed `pgs3.error` DETAIL token |
| `P3C01` | failed ETag/write precondition | 412 `PreconditionFailed` |
| `P3N01` | conditional read not modified | 304 with no XML body |
| `P3R01` | unsatisfiable/invalid range | 416 `InvalidRange` |
| `P3E01` | bucket name collision | 409 `BucketAlreadyExists` / `BucketAlreadyOwnedByYou` according to owner visibility |
| `P3F01` | nonempty bucket | 409 `BucketNotEmpty` |
| `P3H01` | server/client digest mismatch | 400 `BadDigest` |
| `P3P01` | invalid/misordered/small multipart part | 400 `InvalidPart`, `InvalidPartOrder`, or `EntityTooSmall`, selected by allow-listed DETAIL token |
| `P3U01` | missing/invalid upload | 404 `NoSuchUpload` |
| `P3S01` | size limit | 400 `EntityTooLarge` |
| `42501` | PostgreSQL privilege/RLS denial | 403 `AccessDenied`, without SQL detail |
| `25006` | read-only transaction/recovery | 503 `ServiceUnavailable` with read-only-standby message |
| timeout/cancel | statement/recovery/client timeout | bounded 503/500-class S3 error according to cause; never leak query text |
| unexpected `XX...`/panic | corruption/internal failure | 500 `InternalError`, request ID logged, details redacted |

Shared SQLSTATEs now carry allow-listed constant `pgs3.error=<Code>` DETAIL tokens,
which the pgrx boundary preserves even when its coarse error class becomes
`XX000`. New errors must follow that pattern and must never embed request data.
Every response error body uses S3 XML with `Code`, `Message`, `Resource`, and
`RequestId`, except bodyless HTTP statuses such as HEAD/304 where compatibility
dictates.

## Transaction mapping

| Request class | Database transaction boundary |
| --- | --- |
| bucket metadata, HEAD, DELETE, copy, list, version operations | one request transaction with `SET LOCAL ROLE` and statement timeout |
| SQL convenience `put(bytea)` | one transaction; suitable only for bounded bodies/tests |
| eligible bounded direct PutObject | authenticate, buffer/verify <=`min(inline_threshold,64 KiB)` without a DB transaction, then one atomic `pgs3.put` transaction |
| streaming PutObject | `begin_upload`, independently committed worker-sealed full chunks, then one final transaction that stores any buffered last chunk and locks/exactly matches the ordered `(blob_id,size)` manifest before publication; public SQL completion still rehashes |
| UploadPart streaming | each chunk independently committed; part metadata finalized separately |
| CompleteMultipartUpload | one final semantic transaction; Rust digest helpers hash ordered extents, with an explicitly bounded SQL fallback |
| GET/Range | one read transaction; full GET materializes one SQL `bytea`/Rust `Vec`, while Range bounds the selected slice; a streaming cursor is still required |

A checksum/signature/body failure after chunks commit aborts or abandons only
pending state; it must never expose an object. The GC later removes abandoned
state. A request transaction must be rolled back before a worker reuses its SPI/
connection state.

Direct and staged PutObject intentionally differ when both body integrity and
target access are invalid. Direct PUT can return the body/checksum error before
its first bucket/RLS/key lookup; staged PUT can return the `begin_upload` target
error first. Both paths verify every byte and defer visibility/conditions to an
atomic SQL mutation. See D026.

## Extension version transition

The current direct install version is 0.1.1. The shipped
`pgs3--0.1.0--0.1.1.sql` update adds the catalog-version probe and worker-sealed
bridge, updates the affected semantic/helper definitions, replays credential
SET-only membership grants, and grants the configured custom service role its
narrow runtime ACL. `tests/upgrade/run.sh` temporarily installs a frozen,
checksummed 0.1.0 fixture in a disposable package image, builds inline/chunked/
multipart/copy/fork/restore/delete-marker/pending/cross-tenant data, executes
`ALTER EXTENSION ... UPDATE TO '0.1.1'`, and compares its catalog and semantics
with a direct 0.1.1 install. The harness is the required gate; its presence alone
is not a recorded PG17/PG18 PASS.

## Completion evidence for this mapping

For each row above, completion requires all four layers:

1. installed SQL function regression tests, including error and race paths;
2. HTTP route/SigV4/XML integration test;
3. one or more required real clients or ceph s3-tests cases;
4. current implementation status updated here with no unresolved gap in the row.

An HTTP response synthesized without its required SQL semantic operation does not
satisfy the SQL-first design.
