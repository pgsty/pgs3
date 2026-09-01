# Engineering pitfalls

This is the running “things that can quietly go wrong” log. Add observed failures
with PostgreSQL/client versions and a reproducer; do not delete old entries merely
because one code path was fixed.

## Background workers and Rust

- PostgreSQL APIs are process-main-thread APIs. A Tokio/async worker thread must
  never call SPI, touch a PostgreSQL memory context, raise a PostgreSQL error, or
  use a `pg_sys` object borrowed from the main thread.
- PostgreSQL errors may use `longjmp`, bypassing ordinary Rust destructors. Keep
  SPI scopes narrow, use pgrx-supported boundaries, and do not rely on `Drop` to
  release protocol or refcount state after an ERROR.
- Catching Rust panic is necessary but not sufficient. A panic while PostgreSQL
  state is borrowed may leave the current transaction aborted; roll it back and
  close the request safely.
- Dynamic-worker registration and readiness are asynchronous. `start()` must not
  report success merely because registration returned; it needs a bounded ready
  handshake and partial-pool cleanup.
- With `SO_REUSEPORT`, one failed bind can leave a smaller pool serving traffic.
  Pool state must expose desired versus ready workers and stop partial startups.
- A preload launcher has no implicit current database. Never guess installations;
  use `pgs3.target_database` and verify the extension.
- Signal handlers may set flags/latches only. Parsing GUC strings, logging complex
  data, allocation, socket close choreography, and SPI do not belong in a signal
  handler.
- Do not block a worker's event loop on an unbounded body, SPI call, socket write,
  DNS lookup, or shutdown drain. The five-second `pg_ctl stop` test is mandatory.
- PostgreSQL 17.10 under Docker Engine 29.4.1 showed that even direct
  `docker exec --user postgres ... pg_ctl stop -m fast -t 5` can return 137 after
  a clean target exit: terminating container PID 1 destroys its PID namespace and
  kills the still-waiting exec process. Do not confuse that with a harness timeout.
  Use a SIGTERM-based outer timeout (status 124), then require target exit zero,
  elapsed time below five seconds, and new fast-request/clean-shutdown log records.
- A Docker-published host port can complete a TCP handshake and then reset the
  stream after the container listener is gone. Reload tests must inspect the
  container network namespace or require a valid HTTP/S3 response; connect-only
  probes against the published port can report a false failure.
- Authentication reads `pgs3.credential` before any tenant role is trusted. Apply
  the request's transaction-local `statement_timeout` to that server-role lookup
  too: a conflicting credential-table lock must not pin the worker indefinitely.
  Do not set a claimed tenant role until after its SigV4 signature verifies.
- A background worker's direct SPI call has no frontend statement boundary.
  `SET LOCAL statement_timeout` updates the GUC but does not by itself arm the
  core timeout timer. Each pgs3 SPI transaction must explicitly enable PostgreSQL's
  `STATEMENT_TIMEOUT` handler on the worker main thread, disable it after success
  or caught ERROR cleanup, and also set `lock_timeout` as a lock-wait backstop.

## SQL errors across the pgrx boundary

- With pgrx 0.19.2 on PostgreSQL 17, a PostgreSQL function can raise a valid
  private `P3xxx` SQLSTATE yet the Rust SPI error surface may classify it as
  `XX000`.  The PostgreSQL `DETAIL` survives.  Mapping only the Rust-side
  SQLSTATE silently turns expected S3 failures into HTTP 500 responses.
- Every semantic `P3xxx` raise must carry one allow-listed constant token in the
  form `pgs3.error=<Code>`.  Never derive that token from an English message or
  concatenate request data into it.  MESSAGE is diagnostic text, not an API.
- Shared SQLSTATEs need explicit DETAIL subcodes: `P3K01` separates missing keys
  from missing versions, and `P3P01` separates invalid parts, invalid ordering,
  and undersized non-final parts.  Add a `GET STACKED DIAGNOSTICS` regression for
  each new token and include sentinel request values to prove DETAIL redaction.
- `pgs3.error=CredentialError` is for credential-administration internals only.
  It must be logged safely or mapped to a generic authentication failure, never
  exposed as an S3 error code or accompanied by an access key or secret.

## HTTP parsing and request smuggling

- Reject conflicting `Content-Length` values and ambiguous simultaneous length/
  transfer-encoding framing. Do not pass a differently framed request through a
  TLS proxy and parser pair.
- Bound request line, header count, individual/total header bytes, XML body, part
  count, and idle/body time. “Read until EOF” is not an acceptable default.
- Handle `Expect: 100-continue` only after header authentication and write routing
  checks. A standby should reject a PUT before inviting its body.
- A premature EOF, excess body, invalid chunk extension, invalid trailer, or client
  disconnect must abort the pending upload and its transaction.
- XML parsers must disable DTD/external entities and enforce depth/size bounds.
- Once response headers/body begin, a later database error cannot be translated
  into a clean S3 XML error. Finish all fallible metadata/condition work first.
- Fixed `Content-Length` framing can hand a borrowed socket-input slice directly
  to the body handler; inserting an owned decoder `Vec` on that path copies every
  byte for no semantic benefit. HTTP chunked and aws-chunked paths still need
  owned verification buffers and must not borrow/release unverified signed data.
- HTTP/1.1 persistence must not become request smuggling. Reuse a socket only
  after the prior response is fully written and the prior request consumed exactly
  its framed bytes. Do not parse a coalesced suffix as a pipelined request; close
  after the response. Errors and ambiguous/unread framing also force close.

## SigV4

- Canonical URI handling is byte-sensitive. Do not decode then re-encode with a
  generic URL library; it may change `%2F`, hex case, duplicate slashes, or spaces.
- Canonical query parameters sort encoded names and values and retain duplicates.
  The signature parameter itself is excluded for presigned requests.
- `Host` (including a non-default port), signed-header whitespace folding, duplicate
  headers, and lowercase canonical names frequently cause proxy-only failures.
- Validate credential scope date, region/service, request timestamp skew, expiry,
  and constant-time signature equality.
- `UNSIGNED-PAYLOAD` still requires reading and enforcing the body. It is not
  permission to trust a checksum or content length.
- Signed aws-chunked uses a signature chain; checking only the final signature is
  wrong. Trailer mode declares trailer names and may carry modern SDK flexible
  checksums. Verify server-computed values.
- Never reserve a signed aws-chunked buffer from its declared chunk size. A peer
  can announce a large chunk and then drip or withhold its body across every
  connection. Signed plaintext cannot be released before verification, so pgs3
  hard-limits one buffered data chunk to 1 MiB and grows that buffer only as bytes
  arrive; clients must split larger payloads into more chunks.
- Never use `x-amz-checksum-*`, ETag, MD5, or a declared SHA to look up and reuse a
  cross-tenant blob before consuming and validating every byte.
- Redact access secrets, authorization headers, signatures, and presigned query
  strings from normal logs. Presigned URLs are bearer credentials.

## Proxies

- TLS proxies must preserve the original path, query string, `Host`, and signed
  headers. URI normalization or changing the authority breaks valid signatures.
- Request buffering hides streaming behavior and can fill proxy disks; disable it
  for object bodies. Response buffering would defeat bounded-memory GET streaming
  after that server path exists; today full GET already materializes one
  SQL/Rust body, so proxy settings cannot be cited as memory-bounded evidence.
- Confirm timeout and body-size limits at both proxy and pgs3. A 413/408 generated
  by the proxy is not necessarily S3 XML and may confuse clients.
- Do not blindly trust forwarded headers. The signature uses the received signed
  authority; client-IP trust requires a separate explicit proxy boundary.

## Transactions and concurrency

- A large HTTP PUT intentionally spans short transactions. Never keep the initial
  transaction open while awaiting network body chunks.
- D026 direct PUT is safe only because it is hard-capped at
  `min(inline_threshold,64 KiB)`, snapshots the cap per request, and performs one
  atomic `pgs3.put` after body verification. Do not add an unlocked target
  pre-read to make its error precedence resemble staged PUT: when checksum and a
  missing/inaccessible target are both invalid, the bounded direct path may report
  the checksum error first.
  Expect and chunked/aws-chunked requests must remain staged so standby and target
  preflight occur before body invitation/consumption.
- D027's no-reread completion applies only to a restricted worker session and a
  non-multipart PutObject. Do not expose a caller-supplied whole-body digest on
  the public SQL API. The worker must compute each chunk digest over the same
  decoded bytes passed to its restricted SQL call and append the returned
  canonical `(blob_id,size)` to the request manifest. The final transaction must
  lock the upload and compare the exact ordered manifest, not just count and
  total size. Otherwise a short-transaction replacement can publish different
  bytes under a stale hash.
- Check-then-write outside the per-key lock makes `If-None-Match: *` and `If-Match`
  race. Conditions must be evaluated after serialization.
- Allocate the sequence-backed version ID after acquiring the same-key lock, or
  concurrent commit/latest order can look inverted.
- Advisory-lock hashes can collide; that is safe only when collisions cause extra
  serialization. Do not treat the hash as object identity.
- A foreign key does not serialize `delete_bucket`'s emptiness check with later
  object/upload insertion. Without a name-scoped lifecycle lock, the loser leaks
  `23503` instead of `BucketNotEmpty` or `NoSuchBucket`. Exclusive create/delete/
  fork-destination holders must conflict with shared child creators.
- Take the shared lifecycle lock before resolving a child insert's numeric bucket
  ID, or revalidate the name/ID pair while holding it. Locking a stale ID after a
  delete/recreate still permits an FK failure. Multi-name fork locks must be taken
  in one C-collated order, while source and ordinary writers use shared mode so
  unrelated keys remain concurrent.
- Multi-key delete/copy/fork must acquire locks in one stable order. Caller/XML
  order is attacker-controlled and can produce deadlocks. Copy must acquire both
  per-key advisory locks before taking `FOR KEY SHARE` on its source row; taking
  the source row lock first lets reciprocal A-to-B and B-to-A copies deadlock on
  their destination `FOR UPDATE` locks even if each destination is serialized.
- A partial unique index excluding delete markers does not prevent two latest
  delete markers. Enforce exactly one latest history row separately.
- `ON CONFLICT` around blob insertion does not by itself make refcount correct.
  The reference increment and object publication must share a transaction and the
  conflict path must lock/re-read the canonical blob.
- NOTIFY is delivered on commit. Sending outside the object transaction can emit
  rolled-back events. More importantly, PostgreSQL channels have no ACL/RLS
  boundary: a detailed bucket/key/version/actor payload is a cross-tenant leak to
  any connected listener. Keep the one global emitter to `{"op":...}`, revoke
  PUBLIC from its helper, and make tenant consumers fetch details through RLS.
  Operation timing remains observable and the signal is not durable.

## Uploads, multipart, and hashing

- A Rust panic boundary does not catch `SIGSEGV`. Historical PG17 manifest
  [`clients-pg17-79386`](../artifacts/acceptance/20260831T004926Z-clients-pg17-79386/manifest.json)
  records a real signal-11 failure on the eighth UploadPart of a 100 MiB aws CLI
  transfer and the resulting postmaster recovery. A successful small streaming
  smoke or several successful parts was not evidence that the path was safe. The
  current 13-part ETag/download/rclone run passes in
  [`clients-pg17-72577`](../artifacts/acceptance/20260831T064443Z-clients-pg17-72577/manifest.json),
  but retain the original failure as a regression target.
- The fixed malformed-request corpus can pass while a valid high-volume request
  still crashes a worker. Its current
  [`http-robustness-pg17-83397`](../artifacts/acceptance/20260831T065124Z-http-robustness-pg17-83397/manifest.json)
  PASS proves seven bounded rejection paths and process identity after each
  batch; it does not waive independent valid-request/client coverage.
- Persisting pending chunks before complete is safe only when no object API can
  reach them and GC cannot race an active lease.
- A staged buffer should begin empty so a slow authenticated peer cannot reserve
  4 MiB by sending only a request head. Grow it with received bytes; after a full
  chunk is committed, clear and reuse that allocation instead of allocating and
  copying a replacement `Vec` for every chunk.
- Digest initialization is also an allocation/CPU boundary. SHA-256 and ETag MD5
  are mandatory, but SHA-1/CRC32/CRC32C/CRC64NVME state should exist only when a
  supplied header or declared trailer needs that algorithm. Keep the pinned
  SHA-2 assembly feature enabled for AArch64 builds.
- Chunk-size tuning has a nonlinear cliff. Single-request diagnostic samples were
  119.24 MiB/s at 2 MiB, 154.92 MiB/s at 4 MiB, and about 32 MiB/s at 8 MiB; the
  4 MiB default follows those samples. Do not call the throughput gate passed
  until the complete fixed benchmark has run with that default.
- A server-computed whole SHA-256 is not derivable from per-part SHA-256 values.
  Multipart completion must read all ordered content unless hashing state was
  constructed with a proven composable scheme (ordinary SHA-256 is not one).
- Multipart ETag hashes concatenated **binary** 16-byte part MD5 values, then adds
  `-N`. Hashing hex strings produces the wrong ETag and breaks rclone.
- Multipart SHA256 `COMPOSITE` is not the canonical full-content SHA-256: it is
  `base64(SHA256(concat(raw_part_sha256)))-N`. Conversely, accepting an automatic
  CRC32/CRC64-family algorithm selection does not justify inventing a final value
  from client declarations. D024 accepts those selections without claiming a
  stored final non-SHA checksum until per-part server digests and composition
  rules exist.
- Uploading the same part number replaces the prior part. Refcounts and pending
  bytes must be released exactly once.
- An `uploadId` is not a bearer capability detached from its URL. Recheck its
  bucket, key, and multipart kind in every independently committed UploadPart,
  ListParts, Complete, and Abort transaction; checking only when the body starts
  leaves later chunk transactions vulnerable to cross-target reuse.
- Validate strict ascending part order, duplicate part numbers, requested ETag,
  missing part, maximum part count, and minimum non-final part size.
- Final publication may reuse an existing SHA blob only after all bytes were read
  and verified. Abandoned duplicate pending chunks still need GC.
- Crash tests must kill the postmaster at several points: during chunk commit,
  after final hash, during object publication, and during cleanup.

## Extension upgrades and service-role drift

- A new install SQL file is not an upgrade path. Keep the frozen 0.1.0 fixture
  checksummed, ship `pgs3--0.1.0--0.1.1.sql`, and test both `ALTER EXTENSION` and
  direct 0.1.1 install catalogs. Do not ship the test-only old install fixture as
  if the current package supported an unreviewed fresh 0.1.0 installation.
- Runtime grants must target the configured `pgs3.server_role`, not a hard-coded
  `pgs3_server`. A custom role must be NOLOGIN/NOINHERIT and unprivileged, have no
  inbound members, and hold only SET-only tenant memberships. The launcher must
  stop already-running HTTP listeners when attributes, memberships, or required
  ACLs drift; merely refusing to spawn the next worker leaves an unsafe old pool
  reachable.

## PostgreSQL storage

- `SET STORAGE EXTERNAL` is a column setting, not proof that each value is out of
  line or slice-readable without detoasting. Measure actual tuple/TOAST behavior.
- Updating a partition key is a delete/insert and can copy/retoast a bytea. That is
  why reassigning staged chunk rows is not a zero-copy multipart design.
- Hash partition count cannot be tuned freely after data arrives. Repartitioning
  is an online-migration project and must be documented.
- PostgreSQL `bytea` and varlena APIs have size limits even when the logical object
  uses chunks. Never assemble a large object into one backend allocation.
- `text` rejects NUL and invalid database-encoding bytes. Validate the 1,024-byte
  S3 key limit on encoded bytes, not Unicode character count.
- JSON metadata needs explicit size and type limits. Arbitrary deep/large JSON can
  create TOAST, parser, index, and response amplification problems.
- Refcount zero is only eligibility. Check pending manifests/extents and serialize
  with reference creation before deleting physical data.

## LIST and versions

- Reduced smoke dimensions can pass while the required scale fails. The golden
  PG17 full 100k/1M run passes ordinary/delimiter LIST at 2.358/9.487 ms but
  fails fork at 1944.071 ms. A same-final-source iteration reached 865.495 ms
  with almost identical logical work; that demonstrates host variance, not a
  stable golden-image pass. Never
  promote a 2k/10k smoke or cherry-pick the fastest observation.
- `SELECT DISTINCT substring(...)` over an entire prefix is correct-looking but
  violates the required skip-scan complexity. Use repeated index seeks and prove
  it with EXPLAIN/scale tests.
- `prefix || U+10FFFF` is not a universal upper bound; a valid key can append data.
  Compute a real lexical successor by incrementing a Unicode scalar and truncating.
- Under C collation, keep every comparison/operator on the indexed collation. An
  implicit database-default collation can disable or alter the index range.
- Objects and common prefixes both consume `max-keys`. V1 marker and V2
  continuation/start-after have different response fields and edge cases.
- Do not infer truncation from “eligible data exists” when `max-keys=0`.
  ceph/s3-tests and MinIO return an empty non-truncated page with no continuation
  fields for this explicit zero-page request.
- Continuation tokens are client-controlled. Authenticate/bind them to list
  parameters, version their encoding, and reject tampering without embedding SQL.
- LIST is not a held snapshot across pages. Avoid duplicates caused by a broken
  cursor, but document normal concurrent-mutation behavior.
- Ordinary list hides histories and delete-marked latest keys; version list orders
  key and versions exactly as its S3 XML contract requires.

## HTTP object semantics

- Conditional GET precedence and wildcard/list ETag parsing differ from write
  preconditions. Do not reuse a simplistic equality helper.
- Byte ranges are inclusive; suffix ranges, open-ended ranges, empty objects,
  unsatisfiable ranges, and invalid multi-range requests need explicit behavior.
- HEAD returns GET metadata/status without a body, including on errors where S3
  clients may rely on status rather than XML.
- User metadata header names are case-insensitive in HTTP but must round-trip
  predictably. Filter hop-by-hop/reserved headers.
- Copy source is URL-encoded independently of destination routing and has its own
  conditions/version selection. Never allow an RLS-invisible source to become a
  cross-tenant oracle.
- Delete of a missing current key still creates a versioned delete marker under
  versioning semantics; deleting a specific version is different.
- Versioned DeleteObjects is ordered and idempotent per XML entry. Validate the
  whole key/version array first, acquire the distinct key locks once in C order,
  then execute in request order. Do not collapse duplicate VersionIds: the first
  may report a deleted marker while a repeat is still a successful `<Deleted>`
  entry without claiming that it deleted a marker.

## RLS and secrets

- Table ownership and superuser/BYPASSRLS bypass policies. Use a dedicated
  non-superuser request role and test `row_security=on`; consider FORCE RLS where
  owner access is not intended.
- `SET ROLE` persists beyond a transaction; request handling requires
  `SET LOCAL ROLE` plus guaranteed transaction cleanup before connection reuse.
- A SECURITY DEFINER function with caller-controlled `search_path` is an escalation
  path. Pin it to `pg_catalog, pgs3` and schema-qualify objects.
- Role OIDs, not names stored in JSON, should be authorization identities. Rename,
  membership, dropped-role, and credential-disable behavior need tests.
- SigV4 secrets are reversible. `pg_dump`, base backups, replicas, core dumps, and
  diagnostic queries can expose them; operational encryption and access controls
  are mandatory.
- Existence error choices can leak tenant data. LIST, HEAD, copy source, version ID,
  and presigned requests need consistent invisible-as-missing behavior.

## Standby and observability

- A read path that updates a SQL stats row, upload lease, last-access time, or
  audit table will fail on a standby. Keep read stats in shared memory/logs.
- Recovery can start between the initial check and mutation. Translate SQLSTATE
  `25006` as the explicit read-only S3 error too.
- WAL replay may cancel long reads. Catch cancellation, abort cleanly, and return a
  retryable response without killing the worker.
- Metric labels containing bucket/key/role/access key create unbounded cardinality
  and can leak tenant names. Use operation/status dimensions only.
- Latency histograms need fixed buckets and cumulative semantics compatible with
  the chosen exporter. An average alone cannot prove p50 targets.
- An in-flight metric is a gauge lifecycle, not a completion counter. Increment
  on accept, move the gauge when the request is classified, and decrement on every
  completion, timeout, panic, transport error, disconnect, and graceful shutdown.
  Reset a stable worker slot when its PID changes and hide stale gauges for dead
  PIDs; otherwise one crash leaves a permanent false backlog.

## Documentation discipline

- Never copy a planned behavior into operations.md as if it were available.
- Never put placeholder zeroes in perf.md; use `NOT RUN` so absence cannot look
  like a measured result.
- A manifest applies only to its recorded workspace digest. Do not carry a PASS
  across later source changes or use an older PG18 package as final-tree proof.
- Preserve superseded failures without laundering them: the historical multipart
  `SIGSEGV`, missing `vim`, and FUSE preflight failure remain useful evidence for
  their old digest, while the current independent full matrix is the status
  authority. On Docker Desktop, s3fs may use a privileged disposable container
  only with explicit `PGS3_ALLOW_PRIVILEGED_FUSE=1`; absence of FUSE is BLOCKED,
  not a skip or synthetic PASS.
- Record client/version-specific discoveries in decisions.md before changing the
  contract. The Ceph candidate set is fixed before repair; every exclusion needs
  pinned-source evidence, and no selected failure/skip can be silently relabeled.
