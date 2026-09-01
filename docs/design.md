# pgs3 design

## Document status

This document describes the required end-state architecture. It is not evidence
that a feature is implemented. The current package must be checked against SQL,
Rust, package, and test artifacts before deployment. Current functional
gates are broadly green, but performance gates 12--13 and 16 fail; gate 14 now
passes on the final 4 MiB-default sweep. Known implementation gaps
are tracked in [known-limitations.md](known-limitations.md), and choices or
conflicts are recorded in [decisions.md](decisions.md).

## Purpose

pgs3 makes one PostgreSQL database an S3-compatible, path-style HTTP endpoint
without a companion daemon. It is optimized for agent workloads with many small
objects, frequent overwrite, prefix listing, permanent version history, and
PostgreSQL-native tenant isolation and transactions. It deliberately does not
optimize for multi-gigabyte streaming bandwidth or implement all of Amazon S3.

The first-phase contract includes:

- PostgreSQL 17 and 18 support, with 16 best effort;
- SQL-callable semantics for every object and upload operation;
- an in-postmaster background-worker HTTP pool;
- SigV4 header and query authentication, including the required streaming modes;
- permanent versions, delete markers, content hashing/deduplication, multipart,
  copy, and bucket fork;
- RLS isolation through mapped PostgreSQL roles;
- the complete API/client/robustness/performance acceptance matrix from the
  project specification.

## Architecture

The useful boundary is intentionally narrow:

```text
S3 client
   │ HTTP + SigV4
   ▼
launcher → N HTTP background-worker processes (SO_REUSEPORT)
                │ authenticate / parse / stream / translate
                │ SPI, only on each worker's main thread
                ▼
       pgs3 SQL semantic functions
                │ locks + RLS + versions + refcounts + NOTIFY
                ▼
 bucket / object / blob / chunk / pending-upload relations
```

There is no external service process, filesystem object store, or second policy
engine. The SQL functions are the asset: they must remain fully usable and
testable from psql with HTTP stopped.

### Extension and process lifecycle

`CREATE EXTENSION pgs3` installs the `pgs3` schema and SQL API in one database.
The current catalog version is 0.1.1. Packaging includes a versioned
`pgs3--0.1.0--0.1.1.sql` update path and a frozen, checksummed 0.1.0 install
fixture used only by the disposable upgrade harness. `pgs3.extension_version()`
reports `pg_extension.extversion`, so it reflects the catalog state even when a
new shared library has been staged before `ALTER EXTENSION`.
There are two target startup modes:

- preload: add `pgs3` to `shared_preload_libraries`, set `pgs3.enabled=on`, and
  configure `pgs3.target_database`; a launcher creates the pool after startup;
- manual: `SELECT pgs3.start()` creates dynamic workers for the caller's current
  database, and `SELECT pgs3.stop()` terminates that pool.

Each HTTP worker is a PostgreSQL background-worker process connected to the target
database as a dedicated, non-superuser server role. Workers bind the same
configured address and port with `SO_REUSEPORT`. An endpoint never multiplexes
databases.

The I/O reactor is nonblocking and single-threaded with respect to PostgreSQL.
Rust async tasks may represent connections, but no task running on another OS
thread may call SPI or any PostgreSQL internal API. PostgreSQL latches integrate
socket readiness, SIGTERM, SIGHUP, and postmaster death. A request panic or parser
failure is contained at the request boundary.

A clean HTTP/1.1 socket may serve sequential successful requests, which keeps one
client connection pinned to one worker. HTTP/1.0, explicit `Connection: close`,
errors, ambiguous/unread framing, or coalesced pipelined bytes close after the
bounded response. Pipelining is not parsed as a second request.

### SQL semantic layer

The SQL layer owns:

- bucket ownership, existence, emptiness, and configuration;
- all object conditions, same-key serialization, and latest-version transitions;
- monotonically increasing version IDs and delete markers;
- server-computed hashes, ETags, blob/chunk references, and deduplication;
- pending upload and multipart state transitions;
- copy, restoration, bucket fork, prefix listing, and version listing;
- authorization-visible data access under `SET LOCAL ROLE` and RLS;
- transactional, deliberately opaque `pg_notify('pgs3', '{"op":...}')` wakeups
  for changes; tenant details remain behind RLS;
- stable expected-error values consumed by the HTTP adapter.

The HTTP adapter must not perform a check-then-write sequence that can race. It
passes preconditions to the semantic function that takes the mutation lock.

## Request lifecycle

### Authentication

1. Enforce header, URI, query, body, and timeout limits before large allocation.
2. Parse path-style routing without normalizing signed bytes.
3. Resolve the access key using the server role; never log the secret.
4. Reconstruct and verify SigV4 canonical request, scope, timestamp, and signature.
5. For a presigned request, also enforce expiry and signed-header requirements.
6. Start the semantic transaction and `SET LOCAL ROLE` to the mapped PG role.
7. Invoke one SQL semantic operation, or the bounded upload transaction sequence.
8. Commit, encode the S3 response, update bounded-cardinality stats, and release
   all request memory.

Supported payload declarations must include exact SHA-256,
`UNSIGNED-PAYLOAD`, `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`, and
`STREAMING-UNSIGNED-PAYLOAD-TRAILER`. Signed streaming verifies every chunk in the
signature chain. Trailer mode validates declared flexible checksums. No checksum
header can select deduplicated content before the full body is read.

### Ordinary metadata and read requests

One request uses one bounded SQL transaction with
`statement_timeout = pgs3.statement_timeout_ms`. The end-state GET path streams
content after the semantic lookup with bounded buffers; the current full GET still
materializes one SQL `bytea`/Rust `Vec`, as recorded in known limitations. Range
and conditional semantics are resolved before response headers are sent. A worker
must handle a client disconnect without leaking a transaction or upload lease.

### PutObject and UploadPart

An eligible fixed-length PutObject at or below
`min(pgs3.inline_threshold, 64 KiB)` may use D026's direct path. The request
snapshots that cap, buffers and verifies no more than it allows, then calls atomic
`pgs3.put` once; it never holds a database transaction while reading the body.
Unknown/larger bodies, `Expect: 100-continue`, HTTP chunking, and aws-chunked stay
on the staged path. Because direct PUT verifies the bounded body before target
database access, its bad-checksum versus missing/inaccessible-target precedence
may differ from staged PUT without changing authorization or visibility.

Large bodies cannot retain a database transaction for their network lifetime.
They use a pending upload and snapshot `pgs3.chunk_size` per accepted request:

1. `begin_upload` creates identity, digest state/declared constraints, owner,
   expiry, and target metadata;
2. bounded full-chunk calls persist data in independent transactions and return
   each canonical `(blob_id,size)` to the worker;
3. the server completes all hashes and validates HTTP/SigV4/checksum framing;
4. for non-multipart HTTP PutObject, a buffered final chunk is stored in the
   same final short transaction whose worker-only completion call locks the
   upload, proves dense sequence/total size and exact ordered manifest equality,
   rechecks the client/SigV4 expectations, and publishes atomically without
   rereading the payload;
5. failures call `abort_upload` when possible; GC reclaims abandoned state.

No pending bytes are visible through object APIs. A postmaster crash can leave
pending rows, never a partially published object.

This seal is a restricted HTTP-worker capability, not a weakening of the SQL
boundary. The worker-only helpers are revoked from PUBLIC and bind the actor only
when `session_user` is the configured restricted service role with SET-only
membership in that tenant. Public `pgs3.put_chunk` and `pgs3.complete_upload`
retain the original server-side hash/readback behavior, so an ordinary SQL caller
cannot supply a trusted digest. Multipart UploadPart/completion also retains its
own authoritative read path.

SHA-256 and ETag MD5 are always computed. SHA-1, CRC32, CRC32C, and CRC64NVME
state is created only when a request header or declared trailer requires that
algorithm. The pinned SHA-2 crate enables its assembly backend on AArch64. At the
buffer boundary, fixed `Content-Length` bytes are borrowed from socket input;
staged storage starts with an empty `Vec`, grows only with received bytes, and
clears/reuses each full chunk allocation after SPI returns.

### Multipart completion

Create returns an opaque upload ID. Parts are independently replaceable and have
their own binary MD5 and size. Completion validates that every requested part
exists, the list is strictly ordered, non-final parts meet S3 size constraints,
and the requested ETags match. The final multipart ETag uses binary part MD5
values, not their hexadecimal text.

The implemented zero-copy design builds immutable `blob_extent` manifests over
already stored canonical source blobs, while reading ordered content to derive the
authoritative whole-object SHA-256. Completion publishes only metadata/refcounts;
it does not reassign or rewrite source chunk/TOAST payload rows. See D010 in
decisions.md.

## Storage paths

### Object metadata and versions

Buckets have an immutable internal ID, S3 name, owning role, creation time, and
JSON configuration. Object history is keyed by `(bucket_id, key, version_id)`.
Keys use `COLLATE "C"`, are valid database-encoding text, and are limited to the
S3 1,024-byte maximum.

Every successful mutation of a key is serialized. A data PUT creates a version;
ordinary DELETE creates a delete marker; restore creates another version that
references old content. Exactly one row in a key history is latest. Ordinary
GET/HEAD/LIST ignore a latest delete marker, while version listing exposes it.

### Inline and blob data

The default threshold is 64 KiB. D009 resolves the original one-row-inline versus
global-dedup conflict: every content-bearing object references a canonical shared
blob. A small physical blob keeps its one copy in `blob.inline`; a larger physical
blob uses partitioned chunks. `object.inline` remains catalog compatibility only
and is constrained NULL.

Large physical content uses default 4 MiB chunks. Chunk data is `STORAGE EXTERNAL`
to avoid compression/detoast surprises and the physical chunk table is hash
partitioned by blob ID. The partition count is an installation/schema decision,
not a per-request parameter.

Blob refcount transitions occur in the same transaction as references. Copy,
restore, and large-object bucket fork increment references without copying bytes.
Refcount zero makes a blob eligible, not immediately safe, for GC.

## Concurrency model

Mutation of a key takes a transaction advisory lock derived from immutable bucket
ID and full key. After acquiring it, the function reads the latest row, evaluates
`If-None-Match: *` or `If-Match`, allocates a sequence-backed version ID, changes
the former latest row, inserts the new row, adjusts references, and sends NOTIFY.
The transaction then commits as one visibility boundary.

Required unique indexes enforce at most one latest history row and at most one
latest non-delete object. They are invariant backstops, not a substitute for lock
and condition ordering. Multi-key calls sort lock acquisition bytewise. Hash
collisions can reduce concurrency but cannot create incorrect success.

## Listing

The `(bucket_id, key COLLATE "C")` latest-object index drives all ordinary lists.
`prefix` becomes a lower/upper index range. A delimiter query performs repeated
index seeks: emit an object or common prefix, compute the proper Unicode lexical
successor of that common prefix, and seek again. It must never scan all matching
keys and apply `DISTINCT`.

V1 marker and V2 continuation state preserve bytewise order. V2 tokens are opaque,
versioned, tamper-evident, and bound to the bucket and list parameters. Objects and
common prefixes both count against `max-keys`. SQL tests must use a million-key
shape to distinguish a real skip scan from a superficially correct full scan.

## RLS and role model

`pgs3.credential` maps an access key to a reversible secret and PG role. Only the
server role can read secrets. After signature verification, the transaction uses
`SET LOCAL ROLE`. Tables revoke PUBLIC privileges and use default-deny RLS based
on bucket owner/member authorization and explicit grants.

Install/update SQL resolves a custom `pgs3.server_role` dynamically and grants
only its required CONNECT/schema/table/helper privileges. The role is NOLOGIN,
NOINHERIT, unprivileged, has no inbound members, and may hold only SET-only tenant
memberships. The launcher re-audits attributes, memberships, and those grants
while reconciling; any drift stops active HTTP listeners and blocks replacement
workers rather than leaving a weaker pool serving traffic.

Security-definer helpers, where unavoidable, have a fixed safe search path and
cannot be called by PUBLIC. They must not turn the server role into a tenant-data
bypass. PostgreSQL role membership and grants are the only policy model.

The initial tenant semantic functions intentionally retain EXECUTE PUBLIC, so a
role with database CONNECT can create a bucket it owns; tables/helpers/GC and
worker control do not. Deployments that require an allowlist revoke tenant API
EXECUTE from PUBLIC and grant a chosen application role (D021).

## Events and observability

Successful mutations call the internal `_notify_change` helper. Delivery on
commit makes the notification align with visibility; rollback emits nothing. The
global `pgs3` channel carries only `{"op":"put"}`-shaped operation-class JSON.
It never carries bucket, key, version, ETag, size, actor, access key, or request
identity because PostgreSQL LISTEN/NOTIFY channels have no ACL or RLS boundary.

The notification is only a wakeup. A tenant consumer fetches visible details from
the SQL semantic/list-version API under its own RLS role. Credential-mapped roles
should be NOLOGIN so an S3 credential does not independently grant a database
session. Any role that can connect to the database can still observe aggregate
notification timing; phase one documents that side channel rather than pretending
the channel is tenant-private or durable.

`pgs3.stats` is intended for pg_exporter and exposes per-operation request/error
counts, latency histogram buckets, bytes, in-flight work, and worker state. It
must not use bucket/key/access-key labels. Critical worker, GC, auth anomaly, and
standby events go to PostgreSQL logs with redaction.

## Standby behavior

On a hot standby the worker accepts authenticated read APIs and runs only read-only
SQL paths. Mutations are rejected with an S3 XML `ServiceUnavailable` response
that explicitly identifies the endpoint as read-only. Stats on standby must use
shared memory or logs rather than table writes. Reads may be stale by WAL replay
lag or canceled by recovery conflict; clients/load balancers must retry safely.

## Failure boundaries

- A malformed request can fail only its connection/request, not its worker.
- A worker crash must not request a postmaster restart; launcher policy restarts a
  worker with backoff while logging the event.
- Postmaster death is detected immediately through the parent-death signal/latch.
- SIGTERM completes within the five-second acceptance window.
- Pending upload writes are WAL-logged and recoverable/reclaimable.
- Object publication is the only visibility boundary; GC is repeatable.
- Database errors are translated to stable S3 XML without leaking SQL internals.

## Explicit non-goals

Bucket policies and ACLs, lifecycle/TTL rules, logical replication as a supported
transport, TLS, virtual-host addressing, custom rmgr/direct-disk storage,
cross-object HTTP transactions, full-text/vector search, and one endpoint spanning
multiple databases are not implemented in the first phase.

## Evidence required before “complete”

The design is complete only when current artifacts prove all of the following:

- SQL tests cover every mapped semantic function and all race/refcount invariants;
- aws CLI (`s3` and `s3api`), rclone, boto3, s3fs, and DuckDB httpfs pass;
- 100 MiB multipart and S3 ETag/rclone verification pass;
- at least 150 ceph s3-tests cases have a published pass/fail/skip matrix with a
  reason for every failure or skip and core in-scope APIs passing;
- concurrency, dedup/GC, crash, fork, tenant, fuzz, standby, shutdown, and SIGHUP
  acceptance tests pass at their specified repetition/scale;
- packages build for PostgreSQL 17 and 18;
- the complete benchmark matrix in perf.md contains measured p50/throughput/list/
  fork results and same-host MinIO comparisons, and every fixed threshold passes.

The functional/client/Ceph/reliability evidence exists, and the complete benchmark
is published, but fixed performance thresholds do not all pass. This therefore
remains a design and traceability document—not a release claim.
