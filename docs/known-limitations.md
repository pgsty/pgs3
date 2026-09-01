# Known limitations and incomplete areas

This file separates deliberate product scope from work that is merely unfinished.
The latter must not be presented as a supported limitation or used to shrink the
acceptance contract.

## Evidence checkpoint (2026-08-31)

The repository is functionally broad but not release-ready because fixed
performance gates still fail. The following package-backed behavior has current
reviewed evidence:

- dynamic `pgs3.start()` launches a current-database HTTP/GC pool and serves live
  traffic;
- header and presigned SigV4, full-hash/unsigned payloads,
  `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`, and
  `STREAMING-UNSIGNED-PAYLOAD-TRAILER` pass, including tamper rejection;
- two non-superuser tenant roles cannot LIST, HEAD, GET, or use a presigned URL
  across the RLS boundary;
- the full PostgreSQL 17 client matrix passes: aws CLI `s3api`/`s3`, rclone,
  boto3, DuckDB httpfs, and a real opt-in privileged s3fs FUSE mount with
  vim/grep/find;
- a 100 MiB aws CLI multipart upload completes as 13 parts with exact S3 ETag,
  SHA-256/download equality, and rclone verification;
- 195 of 195 selected ceph s3-tests pass from a fixed 209-case candidate set,
  with 14 exact source-audited exclusions and no selected failure/error/skip;
- SIGKILL recovery/pending GC, fast stop, live SIGHUP worker/listener/timeout
  reconciliation, PG17 hot-standby GET/LIST plus early write rejection, and the
  fixed seven-case malformed-request survival corpus pass;
- the final PG17 and PG18 package images pass their SQL/HTTP gates.

Evidence paths are recorded in [acceptance.md](acceptance.md). The authoritative
current functional records are
[`clients-pg17-72577`](../artifacts/acceptance/20260831T064443Z-clients-pg17-72577/manifest.json),
[`clients-pg18-71442`](../artifacts/acceptance/20260831T064421Z-clients-pg18-71442/manifest.json),
[`ceph-s3-tests-pg17-74469`](../artifacts/acceptance/20260831T064550Z-ceph-s3-tests-pg17-74469/manifest.json),
[`reliability-all-pg17-80047`](../artifacts/acceptance/20260831T065006Z-reliability-all-pg17-80047/manifest.json),
[`http-robustness-pg17-83397`](../artifacts/acceptance/20260831T065124Z-http-robustness-pg17-83397/manifest.json),
and
[`fuzz-malformed-pg17-84795`](../artifacts/acceptance/20260831T065154Z-fuzz-malformed-pg17-84795/manifest.json).

The following are still incomplete or failing:

- the complete HTTP/MinIO sweep ran without request or integrity errors. Gate 14
  now passes at 167.894 MiB/s, while gates 12--13 fail: small GET max p50
  3.341708 ms and minimum rate 3989.933/s, and small PUT minimum 1555.986/s;
- current golden-image SQL scale passes ordinary and delimiter LIST
  (2.358/9.487 ms) but fails the fork gate at 1944.071 ms. A same-final-source
  pre-golden image reached 865.495 ms; that is variance/optimization evidence,
  not the authoritative final-image result;
- non-SHA multipart algorithm selections such as automatic CRC32 are accepted
  and supplied per-part checksums are verified, but their final composite value
  is not validated or stored. SHA256 `COMPOSITE` is fully implemented (D024);
- the seven-case malformed-request corpus is deliberately bounded. A stronger
  deterministic suite (8 core plus 16 seeded malformed cases, with a signed
  sentinel and exact process identity after every case) also passes; neither
  suite claims exhaustive protocol fuzzing;
- continuation tokens remain forgeable base64 JSON, although decoded request
  fields are bound and checked;
- table-backed standby request metrics remain unavailable;
- the real 0.1.0-to-0.1.1 update SQL and frozen-fixture/direct-install comparison
  pass on both golden PG17 and PG18 images; future release images still need
  fresh transition evidence.

The recorded packaged PG17 and PG18 SQL suites cover catalog/semantics, the 20 x 50
conditional race, canonical small/large dedup, and GC. PostgreSQL 16 remains
best-effort regression history. Every manifest identifies its workspace digest;
source changes require a new run.

## Resolved storage conflicts and remaining memory gap

### Inline content

PostgreSQL cannot share an inline heap/TOAST value across arbitrary object rows.
D009 now resolves that conflict: every live object references `pgs3.blob`, small
physical bytes occur once in `blob.inline`, and `object.inline` is constrained
NULL. Copy, Restore, and Fork copy only metadata/blob IDs. The SQL regression
proves 100 identical small and large uploads collapse to one canonical blob each,
including Copy/Fork refcounts and GC to zero. The tradeoff is one extra indexed
lookup for a small GET; the final tuned current-path Docker Desktop benchmark
still fails the fixed small-object latency/throughput target.

### Multipart content

`put_chunk` now canonicalizes each independently committed input chunk and stores
only its blob reference in pending state. Part completion, multipart completion,
and large ordinary streamed completion publish `blob_extent` metadata rather than
copying final payload/chunk rows. Extents own their sources; iterative GC walks
final → part → physical blobs. Exact ETag/SHA, boundary reads, lack of final chunk
copies, and transitive GC passed the PG17/18 SQL suite.

Stock PostgreSQL has no incremental SHA-256/MD5 cursor aggregate. The packaged
extension now supplies `hash_upload_part(uuid,integer)` and
`hash_blob_sequence(bytea[])`, so its intended completion path hashes ordered
content without a final persistent payload copy. A SQL-only fallback still
assembles at most `pgs3.sql_hash_fallback_limit` (default 128 MiB) and fails with
`0A000` above it. The required 100 MiB HTTP multipart flow now passes end to end
with exact ETag and download/rclone integrity. The run proves completion and
correctness, not a formal peak-memory bound under arbitrary object size.

Ordinary non-multipart HTTP PutObject no longer needs that completion reread:
D027 lets only the restricted worker seal its SHA-256/MD5 after every committed
chunk's server-computed `(blob_id,size)` has been recorded. The final locked
transaction requires exact ordered manifest equality, dense sequence, and total
size before publication. Public SQL `put_chunk`/`complete_upload`, UploadPart,
and multipart completion retain their authoritative hash/readback paths. This is
an implemented optimization; its complete post-change run passes gate 14 but
does not repair the failed small-object gates.

## Deliberate first-phase limitations

- Path-style addressing only; virtual-host bucket addressing is unsupported.
- Cleartext HTTP only. TLS must terminate in nginx, HAProxy, or an equivalent
  proxy that preserves signed request bytes.
- One endpoint serves one configured database. There is no multi-database router.
- No bucket policy, IAM policy language, or ACL. PostgreSQL GRANT, role membership,
  and RLS are the authorization mechanism.
- No lifecycle/TTL service, object-expiry rules, or S3 lifecycle XML API.
- No supported logical-replication topology for object state.
- No custom rmgr or filesystem/direct-disk content path; data is ordinary WAL-
  logged PostgreSQL table data.
- No cross-object HTTP transaction API.
- No full-text or vector search API.
- S3 keys are PostgreSQL text in the database encoding, ordered with C collation.
  They cannot contain NUL and are limited to 1,024 encoded bytes.
- pgs3 targets many small files and moderate multipart objects, not maximum S3
  object-size bandwidth. A supported maximum must be documented only after the
  implementation enforces and tests one.
- Full-object GET currently materializes the response through one SQL `bytea` and
  Rust `Vec` before writing it to the socket. Range GET bounds the selected slice,
  but the general response path is not a bounded database/network cursor. The
  advertised 5 GiB HTTP ceiling is therefore a parser limit, not a safe memory
  sizing promise; production deployments should impose a much smaller tested
  object limit until response streaming is implemented.
- D026's direct PutObject path is hard-bounded to
  `min(pgs3.inline_threshold, 64 KiB)` and snapshots that cap per request. It
  verifies the bounded body before its first bucket/RLS/key lookup, while larger
  staged PUT preflights the target through `begin_upload`. If both checksum and a
  missing/inaccessible target are invalid, the observed error can therefore differ
  by size.
  Conditions and publication still occur atomically in SQL; this is error
  precedence, not an authorization or partial-visibility bypass.
- One aws-chunked data chunk is limited to 1 MiB so a signed chunk can remain
  private until verification without letting 256 slow connections reserve
  attacker-declared buffers. Total object size is unaffected; clients split a
  larger payload across additional chunks.
- Runtime `SO_REUSEPORT` support currently targets Linux. Other operating systems
  need their own bind, shutdown, and package verification.
- HTTP/1.1 keep-alive is sequential only. pgs3 does not support pipelining: a
  coalesced next request, unread body bytes, HTTP error, HTTP/1.0 request, or
  explicit close/upgrade token terminates the socket after its bounded response.
  Idle reusable sockets use the request-head timeout rather than an unbounded
  connection lifetime.
- Tenant SQL semantic functions initially retain EXECUTE PUBLIC. Any role with
  database CONNECT can create a bucket it owns; deployments requiring an allowlist
  must revoke/grant the API explicitly. Worker control and credentials are not
  covered by this tenant policy and must be operator-only.
- Credential target roles are required to be unprivileged but `NOLOGIN` is
  currently an operator convention rather than an enforced invariant. Use
  `NOLOGIN`; monitor role-attribute drift and do not let an S3 access key imply a
  separate database-login path.

These limits do not waive any API explicitly listed for phase one.

## Compatibility is test-defined

“S3-compatible” means the required clients and in-scope ceph s3-tests pass. It
does not mean every Amazon S3 extension, header, region behavior, storage class,
ACL, policy, lifecycle call, or undocumented client quirk works. The current
selection has no selected skip or failure; all 14 exclusions have pinned-source
anchors and explicit contract reasons. An in-scope core case cannot be relabeled
out of scope to improve the count.

## Operational caveats

- Credentials require reversible secrets for SigV4. Dumps and replicas therefore
  contain secrets and must be encrypted and access-controlled.
- Install/update SQL can target a custom restricted `pgs3.server_role` and grants
  its required runtime ACL dynamically. The launcher stops active HTTP listeners
  when checked attributes, memberships, or required grants drift. This protects
  the service-role boundary; it does not make credential target-role `NOLOGIN`
  immutable or turn the documented service-role SIGHUP path into acceptance
  evidence.
- Standby reads can be stale and can be canceled by recovery conflicts. Writes
  must be routed to the primary.
- LIST pagination is snapshotless like S3: concurrent writes may affect subsequent
  pages. Tokens preserve position and parameters, not a database snapshot.
- PostgreSQL NOTIFY is best-effort transactional signaling, not a durable or
  tenant-private event queue. The global `pgs3` channel deliberately reveals only
  operation class, never bucket/key/version/actor details; consumers fetch visible
  details through RLS SQL APIs. PostgreSQL has no channel ACL, so every
  database-connected role can still observe aggregate change timing and operation
  class. Consumers needing replay must add a properly authorized durable table
  downstream.
- Background workers share the database instance's CPU, memory, WAL, I/O, and
  connection budget. Resource exhaustion can affect both SQL and S3 workloads.
- Upload lease duration (five minutes), HTTP body-idle/heartbeat due interval (60
  seconds, checked on body progress), pending retention (24 hours), GC poll (one
  minute), and batch (1,000)
  are fixed initial constants rather than reloadable GUCs. SQL lease eligibility
  and the renewal/GC row-lock race are regression-tested; PG17 crash/GC acceptance
  passes, while production timing under sustained overload remains unbenchmarked.
- Logical dump/restore is not supported until extension configuration tables and
  restore ordering are explicitly tested; use physical backups meanwhile.

## How to retire a limitation

Add the implementation, a regression/integration test at the relevant scale, and
an operator-visible verification command. Update decisions.md if the solution
changes an accepted choice, then remove or narrow the entry here. A code path
without acceptance evidence is not enough.
