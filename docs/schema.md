# Storage schema

## Status and authority

This document describes the current SQL schema in `sql/bootstrap.sql` and names
the remaining runtime/streaming gaps separately. The installed catalog is the
authority for a particular extension build. The current direct-install catalog
is 0.1.1, with a versioned 0.1.0-to-0.1.1 update script. The storage semantics
described here
were exercised by `tests/sql/semantic.sql` against live PostgreSQL 17 and 18 on
2026-08-31; packaged-extension and HTTP evidence remain separate gates.

The current physical shape is:

```text
bucket ──< object >── blob ──< chunk (16 hash partitions)
   │                      └──< blob_extent >── source blob
   └──< upload ──< upload_chunk >──────────────┘
             └──< upload_part >────────────────┘

credential ── maps access_key to a PostgreSQL role name (no payload FK)
```

Every non-delete object references one canonical blob. Physical small blobs keep
their single payload copy in `blob.inline`; physical large blobs use `chunk`;
logical streamed/multipart blobs use ordered extents over already canonical
source blobs. `object.inline` remains present only for catalog compatibility and
is constrained to NULL.

## Schema-wide conventions

- Extension objects live in schema `pgs3`.
- Key and bucket-name ordering is explicit `COLLATE "C"`.
- Timestamps are `timestamptz` and default to `clock_timestamp()`.
- SHA-256 values are 32-byte `bytea`, not hexadecimal text.
- Stored ETags omit HTTP quotes and are lowercase hex, optionally with multipart
  `-N` suffix.
- Size/refcount values are signed `bigint` with nonnegative checks.
- JSON metadata/config must be a JSON object.
- `version_id` is sequence-backed `bigint`; gaps are valid.
- Initial owner/actor/credential role identities use PostgreSQL `name`. Role
  rename/drop can stale these values and is a known gap; the stronger target is
  stable OID identity plus readable-name presentation.

## Relations

### `pgs3.bucket`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `bucket_id` | `bigint` identity | primary key | Immutable internal join/lock identity. |
| `name` | `text COLLATE "C"` | not null, unique | Path-style S3 bucket name. Semantic validation enforces the supported 3–63 byte DNS-like form. |
| `owner` | `name` | not null | Initial PostgreSQL role-name owner/membership boundary. |
| `created_at` | `timestamptz` | current clock | Creation timestamp. |
| `config` | `jsonb` | `{}` | Extensible bucket configuration; constrained to an object. |

Bucket ownership is tested with `pg_has_role(actor, owner, 'USAGE')`. The initial
table does not use an OID foreign key to `pg_authid`, so role rename/drop behavior
must be handled operationally until migrated.

### `pgs3.object`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `bucket_id` | `bigint` | FK bucket, not null | Owning bucket. |
| `key` | `text COLLATE "C"` | not null | 1–1,024 encoded-byte object key in the initial schema. |
| `version_id` | `bigint` | next sequence value | Opaque version ID; part of primary key. |
| `is_latest` | `boolean` | `true` | Exactly one history row per key should be latest. |
| `delete_marker` | `boolean` | `false` | A version that hides the current key without payload. |
| `size` | `bigint` | not null | Logical payload bytes; zero for marker. |
| `etag` | `text` | nullable | MD5/multipart ETag without quotes; null for marker. |
| `sha256` | `bytea` | nullable | Server-authoritative content digest; null for marker. |
| `content_type` | `text` | nullable | HTTP media type. |
| `meta` | `jsonb` | `{}` | User/system metadata object. |
| `inline` | `bytea` | always null | Compatibility column retained from the requested catalog shape; never canonical payload. |
| `blob_id` | `bytea` | FK blob SHA-256 | Required canonical content reference for every non-marker version. |
| `created_at` | `timestamptz` | current clock | Version creation time. |
| `created_by` | `name` | not null | Initial actor role name. |

Primary key: `(bucket_id, key, version_id)`.

The payload-shape check requires a marker to have no hash/ETag/body/blob and a
live version to have hash/ETag, `inline IS NULL`, and a non-null blob reference
equal to `object.sha256`. This catalog constraint prevents a later writer from
silently reintroducing per-version payload duplication.

Current indexes:

- `object_latest_live_uniq (bucket_id, key) INCLUDE (version_id, size, etag,
  content_type, created_at) WHERE is_latest AND NOT delete_marker` — explicitly
  required live uniqueness and the covering ordinary-list path;
- `object_latest_any_uniq (bucket_id, key) WHERE is_latest` — stronger exactly-one-
  latest invariant including delete markers;
- `object_versions_idx (bucket_id, key, version_id DESC)` — history path;
- `object_blob_idx (blob_id) WHERE blob_id IS NOT NULL` — reference/GC lookup.

The sequence default alone does not guarantee same-key commit ordering. Semantic
mutations must take `_lock_key` before allocation/publication as D006 requires.

### `pgs3.blob`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `sha256` | `bytea` | primary key | Server-computed content address. |
| `size` | `bigint` | not null | Whole logical payload size. |
| `chunk_size` | `integer` | not null | Size selected when this blob was written; the current default is 4 MiB. |
| `storage_kind` | `text` | not null | `inline`, `chunked`, or `composite`. |
| `inline` | `bytea`, EXTERNAL | nullable | The one canonical payload copy for a physical small blob. |
| `refcount` | `bigint` | `0` | Owning object, pending-chunk/part, and source-extent references. |
| `created_at` | `timestamptz` | current clock | Canonical blob creation time. |

Checks enforce a 32-byte key, nonnegative size/refcount, a known storage kind, and
the representation shape. `inline` requires a non-null bytea whose length equals
`size`; `chunked` and `composite` require NULL inline data. Statement-level
transition-table triggers on object INSERT/DELETE/UPDATE aggregate by `blob_id`,
so a bulk fork adjusts each blob once per statement. Row triggers account for
pending chunk/part owners and extent sources. Refcount zero means GC eligibility,
not permission to bypass the row lock/FK checks.

### `pgs3.chunk`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `blob_id` | `bytea` | FK blob, not null | Physical blob identity; delete cascades. |
| `seq` | `integer` | not null, >= 0 | Zero-based chunk sequence. |
| `data` | `bytea` | not null, `STORAGE EXTERNAL` | Bounded payload bytes. |

Primary key: `(blob_id, seq)`. The parent is hash partitioned on `blob_id` with
fixed modulus 16 and partitions `chunk_p00` through `chunk_p15`. A blob row records
the chunk size used; reads must not use the current GUC to infer old boundaries.

Only physical `storage_kind='chunked'` blobs own rows here. Current checks do not
enforce per-chunk length, contiguous sequence numbers, or
`sum(octet_length(data)) = blob.size`; writers and integrity tests must prove
those properties. Composite final identities deliberately have no final chunk
rows—their physical source blobs still use this required partitioned relation
when larger than the inline threshold.

### `pgs3.blob_extent`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `final_blob_id` | `bytea` | FK blob, delete cascade | Logical composite that owns the manifest. |
| `seq` | `integer` | PK component, >= 0 | Ordered extent number. |
| `logical_offset` | `bigint` | >= 0 | Zero-based offset in the final logical blob. |
| `source_blob_id` | `bytea` | FK blob, delete restrict | Already canonical source blob kept alive by this row. |
| `source_offset` | `bigint` | `0`, >= 0 | First source byte used by the extent. |
| `length` | `bigint` | >= 0 | Number of logical bytes contributed. |

Primary key `(final_blob_id, seq)` and index `(source_blob_id)` support ordered
reads and lifecycle checks. Self-reference is forbidden. Publication constructs
contiguous offsets and verifies total size/SHA before inserting the object; range
reads recursively intersect only overlapping extents, with a depth guard. An
extent increments its source's refcount. Deleting a composite cascades its extent
rows and releases those source references; the source FK remains `RESTRICT` as a
last defense against refcount drift.

### `pgs3.upload`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `upload_id` | `uuid` | `gen_random_uuid()`, PK | Opaque pending/multipart attempt identity; also the lease identity. |
| `bucket_id`, `key` | bigint/text C | not null | Destination. Key check matches object. |
| `multipart` | boolean | `false` | Multipart lifecycle discriminator. |
| `content_type`, `meta` | text/jsonb | null / `{}` | Publication metadata. |
| `if_none_match`, `if_match` | text | nullable | Write conditions retained until atomic publication. |
| `expected_sha256` | `bytea` | nullable, 32 bytes | Client-declared comparison only; never dedup authority. |
| `initiated_by` | `name` | not null | Initial actor role name. |
| `state` | `text` | `pending` | Currently constrained to `pending` or `completing`. |
| `created_at`, `updated_at` | timestamptz | current clock | Creation and most recent staging-mutation timestamps. Heartbeats do not falsify staging age. |
| `lease_expires_at` | `timestamptz` | current clock + 5 minutes | Explicit liveness deadline, renewed while the upload row is locked. |

Index `upload_pending_gc_idx(lease_expires_at,updated_at,upload_id) WHERE
state='pending'` supports bounded cleanup scans. `upload_id` itself identifies the
attempt; no separate lease owner/token is needed. `_upload_for_update` renews the
deadline while taking the row lock, and explicit `renew_upload` is the short body
heartbeat. GC requires both an old `updated_at` and expired deadline, then claims
with `FOR UPDATE SKIP LOCKED`. There are still no abort/error or configuration-
snapshot columns.

### `pgs3.upload_chunk`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `upload_id` | `uuid` | FK upload, delete cascade | Pending owner. |
| `part_number` | `integer` | `0`, >= 0 | `0` for ordinary PUT; positive for multipart. |
| `seq` | `integer` | not null, >= 0 | Per-part sequence. |
| `blob_id` | `bytea` | FK blob, not null | Canonical physical blob for this independently committed input chunk. |
| `size` | `bigint` | nonnegative | Logical bytes in the referenced input chunk. |
| `created_at` | `timestamptz` | current clock | Staging time. |

Primary key: `(upload_id, part_number, seq)`; `(blob_id)` is indexed. `put_chunk`
reads and server-hashes its supplied bytea, creates/reuses the physical canonical
blob, then commits only this owner reference. There is no second payload copy in
the upload table. `begin_part`/`abort_part` lock the upload and remove every old
row for a retried part, preventing stale high sequence numbers. Cascading upload
deletion releases these owner references, but complete/abort/GC must still
serialize on the upload row.

For non-multipart HTTP PutObject, the restricted `_worker_put_chunk` receives the
worker-sealed per-chunk SHA-256 beside the exact `bytea`, installs/reuses that
canonical blob, and returns the `(blob_id,size)` committed in this row. The worker
records those values in exact sequence order. `_worker_complete_upload` locks the
upload and requires its ordered `upload_chunk` blob IDs/sizes, dense sequence, and
total size to match before using the worker's whole-body SHA-256/MD5. Public
`put_chunk` and `complete_upload`, plus UploadPart/multipart completion, retain
server-side hash/readback; the catalog does not treat arbitrary SQL digest
arguments as authority.

### `pgs3.upload_part`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `upload_id` | `uuid` | FK upload, delete cascade | Multipart upload. |
| `part_number` | `integer` | positive, PK component | S3 part number. |
| `size` | `bigint` | nonnegative | Part bytes. |
| `etag` | `text` | 32 lowercase hex | Per-part MD5 without quotes. |
| `sha256` | `bytea` | exactly 32 bytes | Server-computed part digest. |
| `blob_id` | `bytea` | FK blob, equals SHA-256 | Canonical physical/logical part blob owned until final completion or abort. |
| `completed_at` | `timestamptz` | current clock | Latest replacement completion time. |

Primary key: `(upload_id, part_number)`, so uploading a part number again replaces
its logical part. Part completion validates contiguous staged sequence numbers,
hashes all ordered bytes, creates/reuses an extent blob over them, inserts this
owner, and deletes the staging references in one transaction. The part blob's
extents retain its physical sources. `begin_part` is the explicit generation
boundary used before accepting a replacement body.

### `pgs3.credential`

| Column | Type | Null/default | Meaning |
| --- | --- | --- | --- |
| `access_key` | `text` | primary key, nonempty | SigV4 access-key lookup. |
| `secret` | `text` | nonempty | Reversible signing secret. |
| `role_name` | `name` | not null | PG role selected after authentication. |
| `enabled` | `boolean` | `true` | Credential revocation switch. |
| `created_at` | `timestamptz` | current clock | Creation time. |

All PUBLIC table privileges are explicitly revoked. The table intentionally has
no tenant RLS policy because authentication occurs before tenant role selection;
grant SELECT only to the dedicated server role. Secret values must never be
returned by tenant APIs, stats, errors, or logs. Role rename/drop staleness remains
an initial limitation. Credential create/role-change functions reject privileged
target roles and grant the configured restricted server role membership with
`SET TRUE, INHERIT FALSE`; identifiers are formatted with `%I`, and a missing or
privileged server role fails closed.

Credential target roles should be `NOLOGIN`. The access key authenticates at the
S3 boundary and the worker uses narrowly granted `SET ROLE`; making the mapped
role independently login-capable widens the database attack surface and lets that
identity open a session outside the S3 protocol. This is deployment guidance, not
currently a catalog CHECK: PostgreSQL role attributes are outside the extension
table and can be changed later.

## Composite API types

The source currently defines:

- `bucket_info`: name, owner, creation, config;
- `object_info`: bucket/key/version/latest/marker/size/ETag/SHA/content type/meta/
  creation/actor;
- `object_data`: `object_info` plus one `bytea` body;
- `delete_result`: key/version/marker/deleted;
- `list_entry`: object or common-prefix fields plus continuation token;
- `version_entry`: version/delete-marker fields and next markers;
- `part_info`: part number, size, ETag, SHA-256, completion time.

`object_data.body bytea` is convenient for SQL tests but cannot be the HTTP path
for arbitrarily large objects because it assembles one varlena value. The worker
needs a bounded chunk cursor/streaming SQL interface in addition to the convenient
SQL function while preserving identical semantics.

## RLS and privilege shape

The source enables (not FORCE-enables) RLS on bucket, object, blob, chunk,
blob_extent, upload, upload_chunk, and upload_part. Policies use bucket role
membership:

- bucket/object/upload and pending descendants have tenant USING/WITH CHECK;
- blob/chunk expose SELECT when an accessible object references them directly or
  through one extent level; semantic reads are security-definer and support
  nested extent chains;
- blob_extent exposes SELECT when an accessible object references its final blob;
- credential has no RLS and relies on explicit privilege revocation/grant.

Table owners and SECURITY DEFINER functions bypass ordinary RLS. The intended
invariant-preserving API is extension-owner-owned, pins `search_path`, derives the
actor from `SET LOCAL ROLE`/session state, and repeats membership checks. PUBLIC
has schema USAGE so selected APIs can be callable; helper/table privileges must
remain revoked. This design is default-deny for nonowners only if grants are kept
minimal and every SECURITY DEFINER entry point performs the same check. The final
grant/revoke catalog and two-tenant tests are required evidence. Tenant semantic
functions initially retain EXECUTE PUBLIC, which permits any database-connected
role to create a bucket it owns; finalize SQL separately revokes PUBLIC from
`pgs3.start()`/`stop()`.

The service-role exception is narrow. Install/update SQL dynamically grants the
configured `pgs3.server_role` CONNECT, schema USAGE, credential SELECT, and the
worker state/metric/actor/sealed-upload helper EXECUTEs. The role must be
NOLOGIN/NOINHERIT/unprivileged, have no inbound members, and hold only SET-only
tenant memberships. Launcher reconciliation checks that shape and the required
ACLs; checked drift stops active HTTP listeners before replacements are allowed.

## Invariants and who enforces them

| Invariant | Catalog enforcement | Semantic/test enforcement still needed |
| --- | --- | --- |
| One latest version including marker | partial unique index | locked latest transition and rollback/race tests |
| One latest live object | required partial unique index | same |
| Version ID unique for key | primary key/global sequence | lock before allocation for monotonic commit order |
| Marker has no payload | CHECK | S3 delete/version response semantics |
| Every live row is canonical-blob-backed; object.inline is NULL | CHECK + FK | server-computed SHA/ETag and dedup races |
| Physical small/chunked vs logical composite shape | blob CHECK | chunk/extent integrity and threshold tests |
| Hash is 32 bytes and object/part blob ID equals SHA | CHECK | server must compute it from every supplied byte |
| ETag text shape | CHECK | exact MD5/multipart algorithm |
| Blob refcount nonnegative | CHECK + object/pending/extent triggers | reconciliation and concurrent GC stress |
| Chunk ordering/total size | primary key only | contiguity and total/hash validation |
| Worker-sealed ordinary PUT manifest | restricted service identity + upload row lock + upload-chunk primary key | exact ordered blob-ID/size arrays, dense sequence, total size, and whole-body/client digest checks |
| Extent order/total size | primary key + nonnegative checks | publication/read/hash validation |
| Pending invisibility | no FK from object to upload | semantic function and crash tests |
| Tenant isolation | ENABLE RLS/policies + privileges | SECURITY DEFINER audit and HTTP two-tenant tests |

## Remaining storage/runtime work

### Streaming digest helpers

Extent publication is storage-zero-copy, but stock PostgreSQL has no incremental
SHA-256/MD5 aggregate for a cursor. SQL therefore uses a bounded transient-body
fallback controlled by `pgs3.sql_hash_fallback_limit` (default 128 MiB) and rejects
larger completion with SQLSTATE `0A000`. The packaged Rust implementation supplies
`hash_upload_part(uuid,integer)` and `hash_blob_sequence(bytea[])` as described in
D010. They use bounded cursors, support nested extents, return exactly one result
row, and read every byte. D027 separately removes the completion reread only for a
restricted non-multipart HTTP worker whose exact committed manifest matches. The
convenience `get()`/`object_data` path has the analogous full-varlena limitation;
HTTP needs a range/chunk cursor rather than one assembled `bytea`.

### Physical integrity/reconciliation

Publication validates sequence contiguity, logical sizes, and final hashes, and
the PG17/18 semantic test covers representative inline/chunk/extent paths. A
production operator still needs a bounded reconciliation report/repair API for
refcount drift, malformed direct-SQL chunks/extents, and hash mismatches. Routine
correctness must not depend on that repair task.

### Stable roles and recorded blob layout

A migration should replace or supplement role names with OIDs while defining
dump/restore and dropped-role behavior. Upload lease/heartbeat/attempt identity is
now explicit and safe against concurrent GC, but the five-minute duration remains
a fixed SQL protocol constant rather than a GUC. Physical blobs record their own
chunk size and kind, so later setting reloads do not reinterpret stored bytes;
`begin_part` is the current explicit retry-generation boundary.

### Durable event/audit state

The required `pg_notify` event is transactional but not durable/replayable.
PostgreSQL channels have no per-channel ACL or RLS policy, so the one internal
emitter sends only `{"op":<operation>}` on channel `pgs3`. Bucket, key, version,
ETag, size, actor, access key, and request identifiers are forbidden. The helper
is not executable by PUBLIC, and static/SQL privilege regressions enforce the
single opaque-emitter shape.

Tenant consumers treat the signal as a wakeup and fetch details through the
RLS-protected SQL API under their mapped role. Any database-connected role can
still observe the timing and operation class, and notifications can coalesce or
be lost across disconnects. No durable outbox is required in phase one. If later
added, it must not turn every read into a standby write or silently redefine the
NOTIFY contract.

## Migration rules

- Version 0.1.1 ships `pgs3--0.1.0--0.1.1.sql` and
  `pgs3.extension_version()`. The update path is compared with a direct 0.1.1
  install using a frozen, checksummed 0.1.0 fixture; the fixture is test input,
  not a current-package fresh-install version.
- Use versioned extension update scripts; never edit an installed catalog by hand.
- Add constraints as `NOT VALID`, validate after a consistency audit, then make
  writers rely on them.
- Repartitioning chunks or changing canonical inline layout requires an online/
  offline data migration with hash verification and rollback plan.
- Preserve version IDs and content hashes across upgrades.
- Test upgrades with inline, chunked, multipart, copied, forked, restored, marker,
  pending, and cross-tenant fixtures before packaging.
