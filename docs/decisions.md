# pgs3 architecture decisions

This is the first project document. It records decisions before implementation so
that a convenient implementation cannot silently narrow the specification. The
normative project specification remains the acceptance contract; an entry here
only changes it when the entry identifies a real PostgreSQL or protocol conflict,
gives a reason, and states the resulting behavior.

Status terms:

- **Accepted**: the implementation and tests must converge on this choice.
- **Provisional**: a concrete initial choice that may change after measurement.
- **Open conflict**: mutually incompatible requirements have been identified. No
  implementation may claim both are satisfied until the conflict is resolved.
- **Planned, not implemented**: required target behavior recorded here, not a
  statement about the current implementation.

Unless an entry says otherwise, all runtime behavior below is planned and must be
verified by tests before it is described as working.

## Decision index

| ID | Status | Decision |
| --- | --- | --- |
| D001 | Accepted | SQL functions are the semantic boundary; HTTP only authenticates, parses, translates, and streams. |
| D002 | Accepted | One endpoint serves exactly one configured database and schema `pgs3`. |
| D003 | Accepted conflict resolution | Preload mode uses `pgs3.target_database`; manual start uses the current database. |
| D004 | Accepted | Each HTTP worker is a PostgreSQL process with a single-threaded nonblocking reactor; only its main thread may touch PostgreSQL. |
| D005 | Accepted conflict resolution | Streaming uploads use multiple short transactions although they are one HTTP request. |
| D006 | Accepted | Version IDs are monotonic `bigint` values, exposed as unsigned-looking decimal strings. |
| D007 | Accepted | Per-key transaction advisory locks serialize all mutations and make conditions atomic. |
| D008 | Accepted | Server-computed SHA-256 is the sole deduplication identity; MD5 supplies S3 ETags. |
| D009 | Accepted conflict resolution | `pgs3.blob` is canonical for all content; `object.inline` remains compatibility-only and NULL. |
| D010 | Accepted conflict resolution | Multipart assembly needs a manifest/extent indirection in addition to the required chunk table. |
| D011 | Accepted | Delete markers are versions and exactly one row, marker or object, is latest. |
| D012 | Accepted | Credentials are initially stored reversibly in a tightly protected table. |
| D013 | Accepted | Tenant authority is PostgreSQL role membership, grants, and default-deny RLS. |
| D014 | Accepted | Prefix/delimiter listing uses repeated index seeks and a real lexical prefix successor. |
| D015 | Accepted | Standbys serve reads and reject mutations as S3 `ServiceUnavailable`. |
| D016 | Accepted | TLS and virtual-host addressing remain outside pgs3. |
| D017 | Accepted | Pending-upload GC requires age and lease expiry, claims rows with `SKIP LOCKED`, and is safe to repeat. |
| D018 | Accepted | API errors cross the SQL/HTTP boundary as stable SQLSTATE/detail data, then become S3 XML. |
| D019 | Accepted | Statistics distinguish operation, outcome, latency bucket, bytes, and worker state. |
| D020 | Accepted | Publish reproducible raw performance without normalization; current HTTP curves are complete, gate 14 passes, and gates 12--13/16 fail. |
| D021 | Provisional | Tenant semantic functions retain EXECUTE PUBLIC; any database-connected role may create buckets it owns. |
| D022 | Accepted | Name-scoped shared/exclusive lifecycle locks serialize bucket creation/deletion without serializing keys. |
| D023 | Accepted | Deleting an otherwise empty general-purpose bucket atomically aborts its pending uploads. |
| D024 | Provisional | Multipart SHA256 is persisted as COMPOSITE; automatic non-SHA checksum selection is accepted without claiming a stored final checksum. |
| D025 | Accepted | The global NOTIFY channel carries only an operation class; tenant details remain behind RLS. |
| D026 | Accepted | Eligible PUTs up to `min(inline_threshold,64 KiB)` use bounded direct publication; other body forms stay staged. |
| D027 | Accepted | A restricted HTTP worker may seal server-computed chunk and whole-body digests; exact manifests preserve SQL authority without completion-time rereads. |
| D028 | Accepted | 0.1.1 has a real 0.1.0 update script, frozen-baseline harness, and direct-current-install comparison. |
| D029 | Accepted | Fork uses one materialized DML CTE and blob fillfactor 80; sequence caching may not weaken observable version order. |

## D001 — SQL is the semantic boundary

**Status:** Accepted.

Every object operation is first a callable SQL function under `pgs3`: bucket
operations, `put`, `get`, `get_range`, `head`, deletion, bulk deletion, copy,
both list forms, version listing and restoration, bucket fork, and the pending
upload/multipart lifecycle. These functions own locking, conditions, versioning,
refcounts, RLS-visible access, and event creation.

The HTTP layer owns SigV4, HTTP framing, XML, conditional/range header parsing,
streaming, and conversion between S3 values and SQL values. It must not implement
a second version of object semantics. SQL-level tests are therefore the first
correctness gate and do not require an HTTP worker.

## D002 — one endpoint, one database

**Status:** Accepted.

An endpoint is bound to one PostgreSQL database containing one installation of
the `pgs3` extension. Workers connect to that database and use its `pgs3` schema.
Serving several databases through one listen socket is explicitly out of scope.
Several endpoints may be configured on distinct address/port pairs.

Supported release targets are PostgreSQL 17 and 18; PostgreSQL 16 is best effort.
The build and package matrix must not describe 16 as supported until it passes.

## D003 — how a preload launcher finds its database

**Status:** Accepted conflict resolution.

The specification requires both per-database installation and automatic startup
from `shared_preload_libraries`. At postmaster initialization there is no current
database and PostgreSQL cannot infer which databases contain an extension.
Consequently preload mode requires the postmaster-level string GUC
`pgs3.target_database` (initial default `postgres`). The launcher connects only to
that database and verifies the extension before it starts the worker pool.

`SELECT pgs3.start()` instead targets the database of the calling session and
starts dynamic workers for it. The function rejects a conflicting running pool
on the same address/port. `pgs3.start()` and `pgs3.stop()` are idempotent from the
operator's point of view. Manual workers do not survive a postmaster restart.

This extra GUC is necessary PostgreSQL configuration, not multi-database routing.

## D004 — worker and asynchronous-I/O boundary

**Status:** Implemented for writable workers; standby export remains incomplete.

The launcher starts `pgs3.workers` dynamic background-worker **processes**. Each
worker connects as the dedicated server role, sets up a nonblocking listening
socket with `SO_REUSEPORT`, and owns a single-threaded reactor integrated with
PostgreSQL latches. No Rust task or OS thread other than the worker main thread
may call SPI, allocate in PostgreSQL memory contexts, use PostgreSQL error
machinery, or invoke any PostgreSQL internal function.

The reactor may interleave network I/O, but SPI sections are synchronous and
bounded. Panics are caught at the request boundary and converted to a 500-class
S3 XML response when the connection remains usable. SIGTERM sets the latch,
stops accepts, cancels/drains bounded work, and exits. SIGHUP reloads reloadable
GUCs. The PG17 lifecycle gate proves worker-count reconciliation and safe
bind-before-swap address/port rebinding. A connected launcher still cannot change
database, and a connected worker cannot change its server-role identity.

Clean HTTP/1.1 connections support sequential reuse. HTTP/1.0, explicit close or
upgrade, errors, unread/ambiguous framing, and coalesced pipelined bytes close
after one response. This keeps persistent clients worker-affine without accepting
pipelining or reinterpreting a request suffix.

`SO_REUSEPORT` behavior is platform-specific. The supported deployment target is
Linux; portability is not claimed without a platform test.

## D005 — upload transactions

**Status:** Accepted conflict resolution; implemented and crash/client tested.

Two hard statements conflict for a large `PutObject`: “one request, one
transaction” and “each chunk is stored in an independent transaction; never hold
a long transaction for an upload.” A network request cannot commit chunks and
also remain one PostgreSQL transaction.

The short-transaction and crash-safety requirement wins for staged body-bearing
upload requests:

1. authenticate headers and create a pending upload in a short transaction;
2. stream and verify the body, committing bounded chunks independently;
3. on any framing, signature, checksum, size, or timeout failure, mark/abort the
   pending upload; no object row becomes visible;
4. after the complete server-computed digests are known, publish the object row,
   latest-version transition, and refcounts in one final transaction.

All non-streaming requests use one database transaction. `UploadPart` follows the
same short-transaction rule. `CompleteMultipartUpload` performs its metadata
publication atomically in one transaction. The HTTP connection/request remains
one protocol operation even when its internal storage work uses several database
transactions.

Each HTTP upload transaction also revalidates the tuple
`(bucket, key, upload_id, multipart)` under the mapped role.  Possession of an
otherwise authorized upload UUID is not authority to use it through another
object URL.  A target mismatch has the same `P3U01`/`NoSuchUpload` identity as
an unknown upload and does not reveal the upload's real target.  The original
upload-id-only functions remain available as the lower-level direct SQL API;
HTTP uses target-bound overloads for UploadPart chunk/finalize, Complete, Abort,
and ListParts.

D026 adds one bounded exception without reintroducing a long transaction. An
eligible known-length PutObject at or below the snapshotted direct cap consumes
and verifies at most 64 KiB outside a database transaction, then calls atomic
`pgs3.put` once. Larger, unknown-length, Expect, HTTP-chunked, and aws-chunked
requests retain the pending-upload sequence above and snapshot `pgs3.chunk_size`
for all staged chunk commits. Reload affects only requests accepted afterward;
physical blobs retain their recorded layout.

## D006 — version identifiers

**Status:** Accepted.

`version_id` is `bigint`, allocated from a PostgreSQL sequence while the per-key
mutation lock is held. A global sequence is simpler than a per-key counter, is
monotonic for each key because same-key mutations serialize, and tolerates gaps
from rollback. It is rendered in S3 XML and headers as a base-10 string. Clients
must treat it as opaque. Sequence exhaustion is an operational error rather than
wraparound.

The lock is acquired before allocating the ID. Commit order and latest-row
updates therefore cannot invert two successful mutations of the same key.

The sequence deliberately retains PostgreSQL's default `CACHE 1`. A measured
`CACHE 1024` fork-throughput experiment let different HTTP worker backends reserve
disjoint ranges, so ListObjectVersions no longer reflected the required newest
mutation order. One selected Ceph versioning case failed (194/195 overall). The
experiment was reverted; the golden-image run passes 195/195. Sequence gaps remain
valid, but backend-local cache ranges may not substitute allocation order for
observable version order.

## D007 — same-key serialization and conditions

**Status:** Accepted.

Every operation that changes a `(bucket, key)` acquires a transaction-scoped
advisory lock derived from the bucket's immutable numeric ID and the full key.
Hash collisions may serialize unrelated keys but may never weaken correctness.
The current latest row, `If-None-Match: *`, and `If-Match: <etag>` are evaluated
only after the lock is held. A partial unique index remains a final invariant, not
the primary check.

Bulk delete acquires locks in a stable bytewise `(bucket_id, key COLLATE "C")`
order to avoid deadlocks. Copy locks source for a consistent read and destination
for mutation in stable global order. Bucket create/delete/fork coordination is the
separate shared/exclusive lifecycle protocol in D022; it does not replace or
coarsen per-key serialization.

The required concurrency acceptance tests (50 contenders, exactly one success,
20 repetitions) are not replaced by unit tests of the condition expression.

## D008 — digest and ETag authority

**Status:** Accepted.

The server reads every byte and computes SHA-256 itself. Only that value can
select an existing blob. Client checksum headers and aws-chunked trailers are
comparisons against server results; they can reject a request but can never cause
the body to be skipped or authorize access to a matching blob.

For a non-multipart object, ETag is lowercase MD5 hex of the exact payload.
For multipart, it is lowercase MD5 of the binary per-part MD5 digests followed
by `-N`. Quotes are an HTTP/XML representation detail and are not stored as part
of the ETag. SHA-256, MD5, content length, SigV4 payload/trailer verification, and
declared flexible checksums must all succeed before publication.

MD5 is used solely for S3 compatibility, never for trust or deduplication.

## D009 — inline storage versus deduplication and zero-copy fork

**Status:** Accepted conflict resolution (2026-08-31).

The requested per-version `object.inline bytea` gives a one-row read for small
objects. Three other requirements say equal content is stored only once,
CopyObject shares content without copying, and `fork_bucket` copies 100,000 latest
metadata rows with zero data copying. PostgreSQL heap and TOAST values are owned
by rows and cannot be safely shared as one refcounted datum across arbitrary
rows. Repeating `inline` bytes in versions therefore violates the latter three
requirements.

The project-owner direction on 2026-08-31 chose global deduplication and
metadata-only Copy/Restore/Fork over the one-row small-GET shape. `pgs3.blob` is
therefore canonical for **all** live content. A physical blob at or below
`pgs3.inline_threshold` stores its one payload copy in `blob.inline`; larger
physical blobs store bytes in the required hash-partitioned `chunk` rows. Logical
stream/multipart blobs may instead consist of immutable `blob_extent` rows over
physical blobs. Every non-delete `object` row has `blob_id = sha256` and its
catalog-compatibility `object.inline bytea` is constrained to NULL.

Consequently identical uploads, new versions, CopyObject, restoration, and bucket
fork share one blob identity regardless of size. The semantic regression uploads
100 identical small and 100 identical large objects, copies/forks them, checks one
canonical payload for each, removes every version, and checks transitive GC to
zero. That suite passed against live PostgreSQL 17 and 18 containers using the
bootstrap SQL and an equivalent SHA-256 SQL test shim on 2026-08-31. This is SQL
storage evidence; packaged PG17/18 SQL/HTTP gates and the required PG17 client
matrix now provide separate integration evidence. The identical suite also passed
PostgreSQL 16 as a best-effort compatibility run.

The accepted cost is a second indexed lookup for a small GET. The current
Docker Desktop benchmark measures that path and fails the fixed small-object
latency/throughput targets; it does not justify repopulating `object.inline` as a
cache without a new design that proves no per-version payload duplication.

## D010 — zero-copy multipart needs extents

**Status:** Accepted conflict resolution; extents and packaged hash helpers implemented.

With only `chunk(blob_id, seq, data)`, multipart parts are stored before the final
whole-object SHA-256—and thus its `blob_id`—is known. Reassigning the rows to the
final hash can rewrite partitioned heap/TOAST data and is not reliably zero-copy.
The storage model therefore adds a manifest relation (called `blob_extent` in
the design) that maps a logical final blob and sequence to already stored source
blobs (inline, chunked, or composite). The required
`pgs3.chunk(blob_id, seq, data)` remains the physical
chunk store and is hash-partitioned by physical `blob_id`.

`put_chunk` now hashes every supplied byte before any client checksum is trusted
and stores that chunk as a canonical physical blob. `upload_chunk` owns only a
blob reference and size. Completing a part creates/reuses a logical part blob over
those sources; completing multipart creates/reuses the final logical blob over the
ordered part blobs. `blob_extent(final_blob_id, seq, logical_offset,
source_blob_id, source_offset, length)` is metadata only. The part/final steps do
not insert final payload chunks or rewrite source TOAST values. Large ordinary
streaming PUT uses the same extent mechanism. Small ordinary streamed payloads
perform one deliberately bounded consolidation (at most `inline_threshold`) so
their final canonical representation remains `blob.inline`.

Completion validates part order, ETags, sizes, and the 5 MiB non-final-part rule;
reads every logical byte to recompute the whole SHA-256; and computes the exact S3
multipart ETag from binary part MD5 values. Extent and pending references count as
blob owners. Deleting a composite cascades its extents, decrements its sources,
and lets one iterative bounded `gc_blobs` call walk final → part → physical blobs.
The two-part SQL test includes a legal 5 MiB first part, an extent-boundary range
read, exact multipart ETag/SHA checks, no final payload chunks, and transitive GC;
it passed on live PostgreSQL 17 and 18 on 2026-08-31.
The same extent/GC suite also passed PostgreSQL 16 on a best-effort basis.

PostgreSQL supplies no incremental SHA-256/MD5 aggregate over a cursor. The current
honest fallback assembles at most `pgs3.sql_hash_fallback_limit` (default 128 MiB)
in a transient `bytea` while hashing; it does not persist a second payload. Values
above the bound fail with SQLSTATE `0A000`, rather than pretending to be streaming.
The packaged Rust helper contracts are:

- `pgs3.hash_upload_part(uuid, integer) RETURNS TABLE (sha256 bytea, md5 text,
  total_size bigint)`, streaming canonical `upload_chunk` blobs in `seq` order;
- `pgs3.hash_blob_sequence(bytea[]) RETURNS TABLE (sha256 bytea,
  total_size bigint)`, streaming the listed logical blobs in array order.

Each helper returns exactly one row, uses bounded SPI cursors through nested
extents, and reads every byte. The packaged 100 MiB/13-part HTTP path completes
with exact ETag, SHA-256, download equality, and rclone verification. That proves
the required path, while the SQL-only fallback remains deliberately bounded.

## D011 — latest rows and delete markers

**Status:** Accepted.

Versions are never disabled. Delete without an explicit version creates a new
delete-marker version and makes it latest. A latest delete marker makes ordinary
GET/HEAD behave as missing while remaining visible to version listing. Exactly
one version—data or marker—is latest for an existing key history.

In addition to the mandated unique index on live latest objects, the schema must
enforce `UNIQUE (bucket_id, key) WHERE is_latest`; otherwise multiple latest
delete markers would satisfy the narrower mandated index. Restoring a version
creates a new version referencing the selected content rather than mutating
history. Deleting an explicit version, if exposed, repairs the latest pointer in
the same locked transaction.

## D012 — credential storage

**Status:** Accepted.

SigV4 needs the original secret, so one-way password hashing cannot work. The
initial design stores the secret reversibly in `pgs3.credential`, revokes all
public access, and permits only the dedicated server role to read it before
`SET LOCAL ROLE`. Application roles can manage credentials only through
security-definer functions with fixed `search_path`, explicit authorization, and
redacted return values.

Creating or changing a credential rejects target roles with SUPERUSER,
BYPASSRLS, CREATEROLE, CREATEDB, or REPLICATION and safely grants that role to
the configured `pgs3.server_role` with `SET TRUE, INHERIT FALSE`. The helper uses
`current_setting(..., true)` with `pgs3_server` as its install-safe fallback and
quotes both identifiers. If worker-runtime role creation did not complete, the
credential API fails closed instead of creating an unusable or unsafe mapping.

Install and 0.1.0-to-0.1.1 update SQL resolve the configured role name at
execution time and issue the database/schema/table/function grants to that role;
they do not hard-code those grants to `pgs3_server`. A custom role must already
exist and be `NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
NOREPLICATION NOBYPASSRLS`. No role may be a member of the service role, and its
own memberships may be SET-only—never ADMIN or INHERIT—so credential mappings do
not become ambient rights. The launcher rechecks that shape and the required
runtime grants while reconciling the pool. Checked drift stops existing HTTP
listeners as well as preventing replacement workers from starting.

At-rest encryption with pgcrypto remains an optional later migration because it
adds key-management requirements and a dependency; encryption without a key kept
outside the same database does not protect a database dump. Operations guidance
therefore treats physical/logical backups and server logs as secret-bearing.
Secrets and authorization headers must never appear in normal logs or stats.

## D013 — authorization and isolation

**Status:** Accepted and implemented for the phase-one HTTP/SQL surface.

An access key resolves to an enabled credential record and a PostgreSQL role name.
After signature verification, each request transaction executes `SET LOCAL ROLE`
to that mapped role. Bucket and object access is granted by PostgreSQL privileges
and default-deny RLS; there is no independent IAM, ACL, or bucket-policy engine.

Bucket rows currently carry an owner role name, as does `pgs3.credential`; stable
OID identity remains a migration target. Policies resolve the stored name through
role membership semantics rather than treating arbitrary request text as authority.
Internal helpers that bypass RLS are minimized and SECURITY DEFINER, are owned by
a non-login extension owner, have a fixed safe
`search_path`, validate the effective mapped role, and are not granted to PUBLIC.
The server role can authenticate and enter the semantic API but must not become a
general cross-tenant read path.

Tenant isolation is tested through LIST, HEAD, GET, mutations, copy source, and
presigned URLs by the SQL/HTTP/client/Ceph suites. Returning `NoSuchBucket` or
`NoSuchKey` for invisible resources avoids existence leaks; the fixed Ceph
selection explicitly records the one excluded test that demands a revealing 403.

## D014 — delimiter listing algorithm

**Status:** Core skip-scan/list semantics implemented; token authentication pending.

Keys use deterministic bytewise `COLLATE "C"` ordering and are limited to the S3
maximum of 1,024 UTF-8 bytes (PostgreSQL `text` cannot represent NUL). Listing
without delimiter is an ordinary bounded index range scan.

Listing with a delimiter performs a skip scan:

1. seek the first eligible key at or after the cursor;
2. return it as an object or derive the next common prefix;
3. compute the smallest valid UTF-8 string strictly after every string beginning
   with that common prefix;
4. seek the `(bucket_id, successor)` index position and repeat until `max-keys`.

The successor increments the last Unicode scalar value that can be incremented,
skipping the surrogate range, and truncates the suffix. UTF-8 byte order preserves
scalar order under C collation. It is not implemented as `prefix || high_char`,
which fails when a key contains that character followed by more data. An empty or
maximal prefix has no finite successor and terminates the range.

V1 marker, V2 `start-after`, and continuation tokens all feed this cursor. The
current base64 JSON token binds and validates bucket, prefix, delimiter, and
last-emitted position but is not cryptographically authenticated. Versioned,
tamper-evident tokens remain the accepted target; callers cannot inject raw SQL.

**2026-08-31 zero-page clarification.** `max-keys=0` returns no entries,
`IsTruncated=false`, and no next marker/token for V1, V2, and Versions even when
eligible rows exist.  This matches ceph/s3-tests commit `5522d1c` for V1/V2 and
an independent MinIO `RELEASE.2025-09-07T16-13-09Z` observation for all three
operations.  A zero-size page is therefore not a resumable existence probe.

## D015 — hot-standby behavior

**Status:** Accepted; core SQL/HTTP and fixed malformed-input survival gates pass.

Workers may start on a hot standby and serve operations whose SQL semantic path is
read-only: bucket/list/version metadata, HEAD, GET, and range GET. Any mutating
operation is rejected before reading a request body when recovery state is known.
SQLSTATE `25006` or a recovery transition during execution maps to S3 XML code
`ServiceUnavailable`, HTTP 503, with a clear “read-only standby” message.

Load balancers must route writes to the primary. Standby reads are subject to WAL
replay lag and recovery-conflict cancellation. Presigned requests are still fully
authenticated on a standby. Credential records must have replayed before use.

## D016 — network boundary

**Status:** Accepted.

Only path-style endpoints are supported. pgs3 speaks cleartext HTTP on a trusted
or loopback network; nginx, HAProxy, or an equivalent proxy terminates TLS. The
proxy must preserve the original path, percent encoding, query string, `Host`,
and all `x-amz-*` headers because changing signed material invalidates SigV4.

TLS, virtual-host bucket addressing, bucket ACL/policy, lifecycle/TTL, logical
replication, custom rmgr storage, cross-object HTTP transactions, search, and a
multi-database endpoint remain explicitly out of scope. SQL interfaces should be
extensible, but placeholders are not implementations.

## D017 — garbage collection

**Status:** Accepted; pending-upload leases and blob-reference GC implemented.

The existing `upload_id` is the attempt identity; adding a second token would break
the direct SQL and S3 multipart contracts without improving ownership. Each pending
row has an explicit `lease_expires_at`, initially five minutes after creation. The
common `_upload_for_update` entry point atomically takes the upload-row lock and
extends that deadline by five minutes, so chunk, part reset/finalize, ListParts,
complete, and abort transactions all participate in one locking/renewal protocol.
Complete and abort end the lease by deleting the upload in their transaction.

`updated_at` remains the most recent staging mutation; a heartbeat does not rewrite
it. A streaming HTTP worker makes the target-bound `renew_upload` overload due on a
60-second monotonic schedule and checks it whenever body progress is delivered;
each committed chunk resets that schedule. The body-idle bound is also 60 seconds,
so an event-driven heartbeat normally lands less than two minutes after the prior
touch, comfortably inside the five-minute lease. Every heartbeat rechecks mapped-
role access and `(bucket,key,upload_id,multipart)` just like a chunk transaction.
Lease expiry is GC eligibility, not a new client-visible rejection: an upload
operation that locks an expired row before GC claims it may renew and continue.

`gc_pending_uploads(max_age,limit)` remains operator-only and preserves its existing
signature. A row is eligible only when it is pending, `updated_at` is older than
`max_age`, **and** `lease_expires_at` is not in the future. The bounded candidate
scan takes `FOR UPDATE ... SKIP LOCKED`; therefore a chunk, heartbeat, complete, or
abort transaction already holding the row cannot be waited on or deleted. If GC
locks an already eligible row first, later use correctly resolves as `NoSuchUpload`
after deletion commits. The SQL semantic test covers both eligibility predicates,
and the concurrency test covers renewal against GC.

Blob GC is implemented separately. It locks one zero-ref blob at a time with
`SKIP LOCKED`, deletes it, lets cascade triggers decrement extent sources, and
continues up to the caller's bound. Processing newest eligible composites before
older sources and iterating in the same call allows final → part → physical
collection without an unbounded recursive statement. Source FKs are `RESTRICT` as
a final consistency guard. The SQL regression proves this transitive lifecycle,
including repeated extent references to one deduplicated source blob.

Refcounts are updated only inside the transaction that creates or removes the
corresponding object/extent reference. A reconciliation query and repair procedure
must exist for operators, but routine correctness may not depend on periodic
recounting. Pending retention defaults, lease duration, poll interval, and batch
sizing remain fixed initial values until runtime measurements justify GUCs.

## D018 — stable SQL errors and S3 XML

**Status:** Accepted and implemented for the phase-1 semantic SQL surface.

Semantic functions raise documented SQLSTATEs with machine-readable detail for
expected failures such as missing bucket/key, failed precondition, bad part,
oversize entity, and access denial. HTTP maps this stable contract to an S3 XML
`Error` document containing at least `Code`, `Message`, `Resource`, and `RequestId`.
Internal messages, SQL text, roles, schema details, and secrets are not exposed.

Every one of the 44 `P3xxx` raise sites has a non-sensitive, mandatory `DETAIL`
token of the form `pgs3.error=<Code>`; human `MESSAGE` text is retained only for
server diagnostics.  This is necessary because pgrx 0.19.2 can report an unknown
custom PostgreSQL SQLSTATE as `XX000` at its Rust error boundary while preserving
the PostgreSQL detail field.  The HTTP mapper therefore treats the allow-listed
detail token as the semantic identity and never parses English messages.

`P3K01` uses `NoSuchKey` or `NoSuchVersion`; `P3P01` uses `InvalidPart`,
`InvalidPartOrder`, or `EntityTooSmall`.  The other public tokens are
`NoSuchBucket`, `NoSuchUpload`, `BucketAlreadyExists`, `BucketNotEmpty`,
`PreconditionFailed`, `NotModified`, `BadDigest`, `InvalidRange`, and
`EntityTooLarge`.  Credential administration uses the internal-only
`CredentialError` token for `P3A01`; it is not an S3 response code and must not be
sent to an HTTP client.  SQL regression tests retrieve `PG_EXCEPTION_DETAIL` for
all 15 token identities, including each shared-SQLSTATE branch, and assert that
bucket names, keys, upload IDs, access keys, and secrets are absent.

Malformed HTTP, invalid XML, invalid ranges, body length disagreement, excessive
headers, timeouts, and panics stay inside the request boundary. Limits are checked
before unbounded allocation. Fuzz and malformed-request tests must demonstrate
worker survival; catching one happy-path parser error is not sufficient evidence.

## D019 — statistics shape

**Status:** Accepted; implemented on writable primaries, standby export incomplete.

`pgs3.stats` presents exporter-friendly rows rather than one ever-growing JSON
value. Dimensions include worker identity/state and operation; measures include
requests, errors, bytes in/out, in-flight count, and cumulative latency plus fixed
histogram buckets. Label cardinality is bounded: bucket, key, access key, role,
request ID, and arbitrary error text are not metric labels.

Critical lifecycle, authentication anomaly, GC, standby, and worker failure events
go to PostgreSQL logs with secrets redacted. Stats are operational counters, not a
billing or audit ledger. Writable-primary cumulative counters persist in
`pgs3.worker_metric`; a replacement PID resets the in-flight gauge, while standby
requests are deliberately not flushed to the table.

HTTP workers buffer only fixed operation names and flush at most once per one-second
heartbeat. A newly accepted connection starts in the `InvalidRequest` bucket, moves
to the classified S3 operation after its complete head is parsed, and decrements
that same gauge on success, S3 error, timeout, transport failure, panic containment,
or graceful worker exit. `ServiceUnavailable` is the fixed overload bucket. Gauge
deltas are clamped at zero; a replacement PID resets the old slot's in-flight value,
and the view reports zero for a dead or PID-mismatched worker. Cumulative request,
error, byte, latency, and fixed cumulative histogram counters remain database-local.
The current table-backed flush is intentionally skipped on a hot standby, so D019
does not yet satisfy the shared-memory standby requirement.

## D020 — performance claims require measurements

**Status:** Accepted.

No latency or throughput acceptance target is described as achieved until the
specified 4 KiB–64 MiB sweep and targeted LIST/fork tests run with captured
environment, durability, workload, raw samples, and same-host MinIO. The final
complete sweep ran on Docker Desktop with 16 workers and
`synchronous_commit=on`; power-loss-protected NVMe and hot-buffer residency were
not verified, so `docs/perf.md` discloses those deviations and applies no
normalization. Curve completeness and the 8 MiB PUT gate pass, but small-object
GET/PUT gates fail. The 8 MiB case used one persistent client connection against
a 16-worker listener pool; sequential keep-alive pins the socket to one accepting
worker, although the evidence does not separately record that worker PID. The
measured LIST gates pass; the measured fork timing fails despite a
prior sub-second observation. Estimates and loopback parser benchmarks remain
invalid substitutes for end-to-end evidence.

The final tuned sweep includes sequential keep-alive and the direct GET/PUT fast
paths, including D026 and D027. It completes without request/integrity errors,
passes gates 14/17, and fails gates 12--13; full current results are in
`docs/perf.md`.

## D021 — SQL API execution policy

**Status:** Provisional.

The initial tenant-facing semantic functions retain PostgreSQL's default EXECUTE
grant to PUBLIC, while tables, sequences, underscore helpers, credentials, and GC
entry points are not public. Existing-bucket operations repeat owner-membership
checks and RLS remains the row boundary. Consequently any role allowed to connect
to the database may use the SQL API and create a new bucket owned by itself, but
cannot see another owner's bucket merely because the function is executable.

This is an explicit initial product policy, not an accidental substitute for RLS.
Operators needing a closed service must revoke PUBLIC EXECUTE on tenant entry
points and grant an application role. Dynamic worker control (`start`/`stop`) and
credential administration are always operator-only and must be explicitly revoked
after pgrx emits their functions. Revisit the default before a production release,
because “database CONNECT implies permission to create a bucket” may be broader
than deployments expect.

## D022 — bucket lifecycle serialization

**Status:** Accepted; implemented in the SQL semantic layer.

The `object.bucket_id` and `upload.bucket_id` foreign keys are invariant guards,
not a bucket lifecycle protocol. A plain `delete_bucket` emptiness check followed
by `DELETE` can race a `put` or `begin_upload`: the child may arrive after the
check, leaving either the bucket delete or child insert to surface a raw `23503`
instead of an S3 semantic result.

Every bucket name therefore has one transaction advisory lifecycle identity,
derived from the domain prefix `pgs3.bucket`, a separator, and the exact C-collated
name. Names, rather than numeric bucket IDs, are required because creation, fork
destinations, deletion, and delete/recreate races must coordinate even while no
row for that name is visible.

- `create_bucket`, `delete_bucket`, and a fork destination take the exclusive
  form. `delete_bucket` holds it across both child checks and the bucket-row
  deletion.
- Paths that can create an `object` or `upload` child take the shared form before
  resolving the numeric bucket ID. Internal object-publication helpers reacquire
  it and verify the supplied name/ID pair, so a stale ID becomes `P3B01` /
  `NoSuchBucket`, never an FK or internal error.
- A fork takes source/shared and destination/exclusive. It acquires the two names
  in one bytewise order; source/shared prevents drop while leaving unrelated
  per-key writers concurrent. The single bulk `INSERT ... SELECT` statement
  supplies the source MVCC snapshot.

Shared lifecycle holders are mutually compatible, so this lock adds no bucket-wide
serialization among ordinary PUT, delete-marker, Copy destination, Restore, or
upload-initiation transactions. Per-key locks remain the only writer serialization
for ordinary objects. A lifecycle hash collision may add serialization but cannot
weaken correctness.

The concurrency regression holds `FOR KEY SHARE` on an empty bucket row, lets
`delete_bucket` reach its physical row deletion, then starts real `put`,
`begin_upload`, and source-fork calls in separate sessions. The delete must commit;
each queued child must report `P3B01`, with no `23503`, orphan, or fork destination.
Another gated phase proves two different-key PUTs pass a held shared lifecycle
lock rather than becoming bucket-serialized.

## D023 — DeleteBucket aborts pending uploads in general-purpose buckets

**Status:** Accepted and implemented on 2026-08-31.

The first pinned Ceph s3-tests run left an incomplete multipart upload after an
intentionally malformed `CompleteMultipartUpload`, then its standard teardown
deleted every visible version and called `DeleteBucket`.  Treating the pending
upload as a visible child made that otherwise empty bucket return
`BucketNotEmpty`, and the retained fixture then caused later cases to fail during
setup rather than exercise their own operation.

[AWS documents `DeleteBucket`](https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteBucket.html)
for a general-purpose bucket in terms of deleting all objects, versions, and
delete markers.  Its explicit requirement to abort in-progress multipart uploads
applies to directory buckets.  pgs3 implements a general-purpose, path-style
endpoint, so an unfinished upload is not an object for this emptiness decision.
Under the existing exclusive bucket-name lifecycle lock, `delete_bucket` now:

1. rejects the operation if any object version or delete marker exists;
2. deletes all pending upload rows for that bucket, cascading staged parts and
   releasing their canonical blob references; and
3. deletes the bucket row in the same transaction.

This is an atomic implicit abort, not early publication or silent GC.  Concurrent
upload initiation still takes the shared lifecycle lock and therefore either
commits before the delete transaction acquires exclusivity and is aborted, or
resolves the deleted name afterward as `NoSuchBucket`.  The SQL regression stages
a real multipart part, deletes the otherwise empty bucket, and proves the upload,
part, reference count, and subsequent blob GC all reach zero.

## D024 — multipart additional-checksum negotiation

**Status:** Provisional and implemented on 2026-08-31.

SHA256 multipart uploads use the S3 `COMPOSITE` checksum independently of the
canonical full-content SHA-256 used for deduplication.  Each XML part checksum is
matched against the server-computed stored part digest, the final value is
`base64(SHA256(concat(raw_part_sha256)))-N`, and publication stores that value as
hidden metadata in the same final transaction.  Missing or mismatched part/final
values return `BadDigest`; client values never select a blob identity.

AWS CLI v1.37.13 automatically sends `x-amz-checksum-algorithm: CRC32` for a
multipart transfer even when the user did not request an additional checksum;
newer SDKs may similarly select CRC64NVME.  pgs3 already verifies any supplied
checksum on each UploadPart, but the current schema does not persist each part's
non-SHA digest and therefore cannot honestly publish a final multipart checksum
for those algorithms.  Rejecting this automatic negotiation made the required
100 MiB AWS client path unusable.  For now pgs3 accepts non-SHA selection without
echoing `x-amz-checksum-algorithm` or claiming a stored final checksum; the client
therefore observes that no final additional checksum was negotiated.  The server
still computes the full-content SHA-256 for canonical storage and checks every
supplied part checksum.

Full non-SHA multipart support requires persisting server-computed per-part
digests and implementing each defined full-object/composite combination rule. It
must not be approximated from client declarations or conflated with canonical
SHA-256.

## D025 — global NOTIFY is an opaque wakeup, not a tenant event feed

**Status:** Accepted and implemented on 2026-08-31.

PostgreSQL LISTEN/NOTIFY has no per-channel ACL and no RLS evaluation when a
payload is delivered. Any role able to connect to the database can listen on
channel `pgs3`. The earlier detailed event design therefore leaked bucket, key,
version, ETag, size, actor, and request-correlation identifiers across tenant
boundaries even though object tables themselves were protected by RLS.

The specification requires transactional JSON notification for changes but does
not require identifiers in that JSON. Security takes precedence over convenience:
all mutation paths call the single internal `_notify_change(operation)` helper,
and the only global payload is `{"op":<validated operation class>}`. The helper
is not executable by PUBLIC. Static and installed-catalog SQL regressions enforce
one emitter, the opaque shape, and helper privilege revocation.

The channel is a wakeup only. A tenant consumer queries the semantic/version API
under its own RLS role to discover details it may see. Credential-mapped roles
should be `NOLOGIN`; the server role receives SET-only membership, so an S3 key
does not itself become database-login authority. `NOLOGIN` is operationally
audited rather than frozen by the credential table because role attributes can
change outside extension transactions.

This decision removes identifier disclosure but does not claim tenant-private
activity. A database-connected listener still learns notification timing and the
coarse operation class, and NOTIFY remains lossy/non-replayable. Deployments that
cannot accept that side channel need a separately authorized durable outbox or
database isolation; adding identifiers back to the global channel is forbidden.

## D026 — bounded direct PutObject fast path

**Status:** Accepted, implemented, and runtime-tested on 2026-08-31.

A fixed-length, non-Expect, non-chunked PutObject whose declared body fits within
`min(pgs3.inline_threshold, 64 KiB)` may avoid pending-upload rows. The worker
snapshots that cap into the request session, buffers no more than the snapshotted
amount, computes and verifies SigV4/digests/checksums over every byte, and then
calls `pgs3.put` once. The SQL function remains the sole publication boundary: it
computes the authoritative digest/ETag, takes the same-key lock, evaluates
`If-None-Match: *`/`If-Match` atomically, and publishes no data on failure.

The 64 KiB ceiling is hard even if `inline_threshold` is larger. Reloading the
GUC rebuilds the service for later requests but cannot enlarge or shrink an
already accepted request's cap. Unit tests cover selection at the boundary, the
hard ceiling, and body enforcement against the per-request snapshot.

Requests with unknown or larger length, HTTP `Transfer-Encoding: chunked`, either
required aws-chunked mode, or `Expect: 100-continue` remain staged through
`begin_upload`. In particular, Expect cannot use the direct path: the staged
preflight lets a hot standby reject the write before sending `100 Continue` or
reading body bytes.

This optimization deliberately permits a bounded error-precedence difference.
After access-key authentication, direct PUT consumes and verifies its <=64 KiB
body before the first bucket/RLS/key database access. A bad checksum can therefore
win over missing/inaccessible-target errors. A staged PUT calls `begin_upload`
first, so the target error can win before a later body checksum failure. S3 does
not provide a useful invariant that justifies a preliminary target lookup on the
fast path. The difference changes only which error is observed when multiple
conditions are simultaneously invalid; it never bypasses RLS, atomic write
conditions, digest authority, or object visibility.

## D027 — worker-sealed staged PutObject digests

**Status:** Accepted, implemented, and benchmarked on 2026-08-31.

Profiling an 8 MiB PutObject showed that completion reread every already committed
byte and recomputed SHA-256 plus MD5. The request path also computed six digests
unconditionally, and each chunk crossed avoidable allocation/copy paths. Those
costs are repeated verification, not durability or publication semantics.

After the sealed path removed the completion reread, one-concurrent-request
diagnostic samples measured 119.24 MiB/s with 2 MiB staging chunks and
154.92 MiB/s with 4 MiB chunks, while 8 MiB fell to about 32 MiB/s at a sharp
allocation/storage cliff. These are tuning samples, not the formal benchmark.
The implementation default is therefore 4 MiB. The complete golden-image 4 MiB
acceptance sweep records 167.894 MiB/s and p50 47.399667 ms for the required
one-client 8 MiB PUT, so gate 14 passes. Small-object gates 12--13 remain failed.

For non-multipart HTTP PutObject only, the authenticated worker may therefore
seal digests that it computed over decoded request bytes:

1. each committed chunk carries its worker-computed SHA-256 and returns the
   canonical blob identity and size actually stored by PostgreSQL; earlier
   full chunks retain independent short transactions;
2. the final call carries the server-computed full SHA-256, MD5, decoded size,
   and the exact ordered `(blob_id,size)` manifest returned by those commits;
3. when a final chunk remains buffered, its insert and completion share the
   same short transaction and upload-row lock; completion then proves dense sequence,
   total size, and byte-for-byte manifest equality, rechecks every client and
   SigV4 SHA-256 expectation, then publishes through the unchanged canonical
   commit helper; and
4. staged bodies at or below the inline threshold retain the old bounded
   readback so their canonical representation remains `blob.inline`.

The worker-only functions are revoked from PUBLIC and granted solely to the
configured restricted NOLOGIN service role. They require an unchanged
`session_user`, reject an active `SET ROLE`, validate SET-only membership in the
authenticated tenant, and install only a transaction-local actor marker. The
marker is ignored for every other session identity. A direct SQL caller therefore
cannot inject a claimed digest; the existing public `put_chunk` and
`complete_upload` functions continue to hash/re-read payload bytes themselves.

Manifest equality is mandatory. Dense sequence and total size alone would let a
concurrent same-tenant writer replace a chunk between short transactions and
publish different bytes under the first request's whole-body hash. Every chunk
mutation takes the same upload-row lock, so the final locked comparison closes
that race before `_ensure_staged_blob` creates extents.

SHA-1 and CRC variants are initialized only when a request header or declared
trailer requires them; SHA-256 and ETag MD5 remain unconditional. On AArch64 the
pinned RustCrypto SHA-2 assembly backend is enabled so server authority does not
mean accepting the portable scalar implementation's avoidable CPU cost. These
changes alter neither client checksum precedence nor the digest used as canonical
identity.

Fixed `Content-Length` body slices remain borrowed from the socket input through
the HTTP framing layer instead of being copied into an intermediate decoder
buffer. A staged sink starts with an empty `Vec`, grows only with authenticated
bytes, and after each full-chunk SPI call clears and reuses the allocation for
the next chunk. Chunked HTTP/aws-chunked decoding still owns the buffering needed
to validate its framing/signature before release; the fixed-length optimization
does not weaken those boundaries.

For a fixed-length body ending exactly on a chunk boundary, the worker retains
the last full chunk until the request framing and digests are verified. Storing
that last chunk and publishing the matched manifest in one transaction removes
one redundant durable boundary. A crash before it commits leaves only earlier
independently committed chunks pending; a crash after it commits exposes the
complete object. No transaction is held while waiting for network bytes.

## D028 — real 0.1.0 to 0.1.1 extension transition

**Status:** Accepted, implemented, and runtime-tested on PG17/PG18 on 2026-08-31.

The release version is sourced from Cargo as 0.1.1 and the control file expands
that value for `default_version`. The package ships a current 0.1.1 install SQL
file plus `pgs3--0.1.0--0.1.1.sql`; it does not silently regenerate an old install
file from current source. The upgrade test instead injects a frozen, checksummed
0.1.0 package artifact into a disposable cluster, so the starting catalog cannot
drift with later code.

That fixture contains inline, chunked, multipart, copy, fork, restore,
delete-marker, pending-upload, credential, and cross-tenant state. The harness
records its fingerprint, runs `ALTER EXTENSION pgs3 UPDATE TO '0.1.1'`, verifies
version/data/RLS/refcounts/worker privileges/extension ownership, then runs the
same semantic suite and compares the catalog with a direct 0.1.1 installation.
`pgs3.extension_version()` reads `pg_extension.extversion`, rather than a compiled
constant, so staged-library and catalog-version mismatches remain observable.

The script and harness establish a real transition rather than a no-op migration.
Golden-image runs pass on PG17 and PG18, covering the rich fixture, upgraded and
direct semantic suites, RLS/refcounts/worker privileges, extension membership,
and catalog parity. Future releases still require fresh evidence tied to their
actual package images.

## D029 — fork data path and version-order boundary

**Status:** Accepted, implemented, and measured on 2026-08-31; gate 16 remains
failed on the golden image.

`fork_bucket` inserts the destination's latest-version rows and exposes the
actually inserted blob IDs through one materialized data-modifying CTE. A grouped
set-wise update increments canonical blob refcounts without rescanning the new
100,000-row destination heap/index. `pgs3.blob` uses fillfactor 80 so the hot
refcount column has room for heap updates. Foreign-key/refcount triggers are
suppressed only inside this trusted bulk statement and the caller's exact
`session_replication_role` is restored on success and error.

At the same final workspace digest, a pre-golden image measured
fork/LIST/delimiter at 865.495/1.086/5.238 ms, all PASS. The golden PG17 image
measured 1944.071/2.358/9.487 ms: correctness, refcounts, independent mutations,
result shape, and both LIST gates pass, but fork gate 16 fails. The faster
iteration is optimization and environment-variance evidence, not permission to
cherry-pick a PASS.

Caching `object_version_id_seq` at 1024 was also tested as a fork optimization and
rejected. Different worker backends consumed reserved ranges in an order that
violated version-list ordering; the pinned Ceph suite fell to 194/195 at
`test_versioning_obj_create_overwrite_multipart`. The final schema keeps
`CACHE 1`, and the golden Ceph run returns to 195/195. Fork speed may not trade
away externally visible version semantics.

## Conflict register

| Conflict | Resolution/evidence required |
| --- | --- |
| One DB transaction per request vs independently committed upload chunks | Resolved by D005 in favor of short transactions and atomic final publication. Crash tests must prove no partial visibility. |
| Preload startup vs no current database at postmaster initialization | Resolved by D003 with `pgs3.target_database`. |
| Inline per-version payload vs global dedup and zero-copy Copy/Fork | Resolved by D009 in favor of one canonical all-content blob; current PG17/18 SQL tests prove dedup/refcounts, while the current small-object HTTP path fails its performance targets. |
| Strict `(blob_id, seq, data)` rows vs zero-copy multipart final blob whose SHA is initially unknown | Resolved by D010 with physical chunk blobs plus logical extents; PG17/18 SQL tests prove reads/refcounts/transitive GC. |
| “One index lookup” small GET vs canonical shared payload | Resolved by D009 in favor of canonical sharing and a second lookup; the final tuned current-path benchmark still fails gate 12. |
| Hot-standby reads vs RLS/SigV4 credential freshness | D015 accepts replay-lag semantics; integration tests must cover stale/replayed credential state and recovery conflicts. |
| Small-PUT direct publication vs identical staged error precedence | D026 bounds direct bodies to `min(inline_threshold,64 KiB)` and preserves atomic SQL publication, while documenting that bad-checksum versus missing/inaccessible-target precedence can differ. |

## Decision-change protocol

Change an Accepted decision only by adding a dated amendment that states the
observed PostgreSQL/client behavior, test or benchmark evidence, affected API and
migration impact, and the replacement behavior. Never rewrite a conflict out of
history after choosing a compromise. If implementation differs from this file,
the implementation is incomplete until either it is corrected or this protocol is
followed.
