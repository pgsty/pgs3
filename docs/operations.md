# Operations guide

## Readiness warning

Current package-backed PostgreSQL 17/18 SQL, HTTP, and client gates pass. On PG17,
195 selected Ceph cases, crash/GC, fast-stop, SIGHUP, hot standby, robustness, and
24-case deterministic fuzz have PASS evidence. It is still unsafe
to deploy as a production endpoint: measured performance gates 12--14 fail and
to deploy as a production endpoint: measured performance gates 12--13 fail,
although gate 14 passes, and the current 100,000-object fork misses one second.
Non-SHA multipart final
checksum composition also remains provisional under D024. Exact status and
manifests are in [acceptance.md](acceptance.md).

## Deployment shape

Use one pgs3 endpoint per PostgreSQL database:

```text
clients ── HTTPS ── nginx/HAProxy ── cleartext loopback/private HTTP ── pgs3 workers
                                                                  └── one PG database
```

pgrx code and SQL extension versions must match. PostgreSQL 17 and 18 are required
package targets; PostgreSQL 16 is best effort. Keep the proxy and database on the
same host or a tightly controlled private network because the backend has no TLS.

## Preflight

Before installation, record:

- exact PostgreSQL/pgrx/pgs3 build and package versions;
- sufficient `max_worker_processes` capacity for the launcher, HTTP workers, GC,
  and other extensions;
- TCP port availability and Linux `SO_REUSEPORT` support;
- a dedicated non-superuser/no-BYPASSRLS worker role design;
- backup encryption/access control for reversible SigV4 secrets;
- proxy body/header/time limits compatible with the largest supported upload;
- WAL, disk, connection, memory, and autovacuum capacity for object/chunk tables.

The extension must install in the configured target database. Never point a
launcher at a maintenance database merely because it is the default.

## Installation and startup

### Automatic preload mode

Append (do not replace other entries) in `postgresql.conf`:

```conf
shared_preload_libraries = 'pgs3'
pgs3.enabled = on
pgs3.target_database = 'artifacts'
pgs3.listen_addr = '127.0.0.1'
pgs3.port = 9000
pgs3.workers = 4
pgs3.chunk_size = 4194304
pgs3.server_role = 'pgs3_server'
```

Restart PostgreSQL, connect to the target database, and install the extension in
the release-defined order. A production packaging/migration process may require
installing the SQL extension before enabling the launcher; if so, perform one
restart with `pgs3.enabled=off`, install, then enable and restart. Do not accept
traffic until the implemented worker-status source shows every desired worker
ready on the same configuration generation.

### Manual mode

The target development/operator flow is:

```sql
CREATE EXTENSION IF NOT EXISTS pgs3;
SELECT pgs3.start();
-- later
SELECT pgs3.stop();
```

Manual start targets the caller's current database and does not survive a
postmaster restart. `stop()` discovers the current-database launcher/children, so
it is no longer tied to the backend that called `start()`. The PG17 HTTP smoke
exercises dynamic start; retain a dedicated cross-session stop test in release
validation. Never run manual and preload pools on the same address/port.

### Worker role and tenant roles

The default installation creates/validates a dedicated `pgs3_server` role. A
custom role named by `pgs3.server_role` must exist before install/update and be:

```sql
CREATE ROLE pgs3_service_custom
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
```

Install and 0.1.0-to-0.1.1 update SQL use the configured name in dynamic,
identifier-quoted grants: database CONNECT, schema USAGE, credential SELECT, and
only the worker state/metric/actor/sealed-upload helper EXECUTEs. They do not grant
tenant-table mutation privileges. Credential administration gives the service
role SET-only, non-INHERIT membership in mapped tenant roles. No role may be a
member of the service role, and it must not have ADMIN/INHERIT membership in
another role. The PG17 two-tenant smoke runs requests through the default role and
verifies cross-tenant invisibility. Do not replace it with the bootstrap
superuser or extension owner to “get RLS working.”

Tenant roles receive bucket/object semantic privileges and RLS visibility through
documented grants. Credential management functions must return redacted records;
never query or paste raw secrets into ordinary operational logs/tickets. Create
credential-mapped tenant roles as `NOLOGIN`: the restricted worker needs SET-only
membership, not a second database authentication path. Audit role attributes for
drift because the extension cannot make `NOLOGIN` immutable. The launcher audits
service-role attributes, memberships, and required runtime grants during
reconciliation; if any checked field drifts, it stops active HTTP listeners and
records an error instead of continuing with the old pool. Changing
`pgs3.server_role` requires provisioning
the new role/grants first; after SIGHUP the launcher replaces the old-identity
workers only if the audit passes. That reload path is implemented but not yet an
acceptance-proven operation.

## nginx TLS termination

This starting point keeps pgs3 on loopback and disables proxy buffering so the
proxy does not add another buffering layer to signed uploads or object responses.
The current full GET path still materializes one SQL `bytea`/Rust `Vec`; proxy
settings do not turn it into bounded server-side streaming:

```nginx
upstream pgs3_backend {
    server 127.0.0.1:9000;
    keepalive 64;
}

server {
    listen 443 ssl;
    server_name s3.example.internal;

    ssl_certificate     /etc/nginx/tls/s3.crt;
    ssl_certificate_key /etc/nginx/tls/s3.key;

    client_max_body_size 0;
    client_body_timeout 300s;

    location / {
        # No URI component on proxy_pass: retain the original request URI.
        proxy_pass http://pgs3_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header Connection "";
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

Validate this exact proxy/version with SigV4 conformance tests. The proxy must not
rewrite or normalize the path, query string, percent escapes, `Host`, or any
signed/`x-amz-*` header. `client_max_body_size 0` delegates object limits to pgs3;
operators may set a finite larger-than-supported limit but should expect nginx's
native 413 rather than S3 XML when it fires. Secure certificate keys and restrict
the cleartext backend port.

If nginx cannot preserve the raw URI behavior needed by a client, fix or replace
the proxy rather than weakening signature verification.

pgs3 supports sequential HTTP/1.1 keep-alive on a clean connection, so the nginx
upstream pool can reuse successful backend sockets. It deliberately closes after
HTTP/1.0, an explicit close/upgrade token, any error response, unread or ambiguous
body framing, and coalesced/pipelined next-request bytes. The last rule prevents a
suffix from being reinterpreted as a smuggled request; clients must wait for one
response before sending the next request. An idle keep-alive peer is closed after
the request-head idle timeout. Monitor connection reuse, but do not weaken these
close conditions merely to improve benchmark numbers.

## Primary/standby routing

The PG17 standby worker serves authenticated GET/LIST from replayed state and
rejects mutation headers before body consumption as HTTP 503 S3
`ServiceUnavailable` with a read-only-standby message. The current gate also
proves no rejected object appears and the launcher, children, and postmaster
survive. See
[`reliability-all-pg17-80047`](../artifacts/acceptance/20260831T065006Z-reliability-all-pg17-80047/manifest.json).
Other read routes still require explicit standby coverage, and replay lag/conflict
behavior remains an operator concern.

Recommended routing policy:

- send all PUT/POST/DELETE requests to the primary;
- GET/HEAD may go to a standby only when replay lag is within the application's
  tolerance and the route does not require read-your-write;
- keep a retry path to primary for recovery conflicts or lag-sensitive reads;
- health checks verify PostgreSQL recovery role, replay delay, pgs3 worker
  readiness, and authenticated semantic access—not only an open TCP socket.

Method routing is conservative but not a full authorization parser. Preserve the
request unchanged when retrying: a presigned request may expire, and a streaming
request generally cannot be replayed after its body is consumed. Never send a
write body to a standby first. Avoid automatic retry of non-idempotent requests
unless the client/protocol semantics make it safe.

On promotion, restart/reconcile the pool and route writes only after recovery ends
and the database is writable. On failback, prevent both primaries from accepting
writes; pgs3 does not solve split brain.

## Backups and recovery

### Recommended baseline: physical backup plus WAL

Use a tested PostgreSQL physical base-backup/PITR system that includes every
tablespace and WAL needed for `pgs3` relations. Object data is ordinary database
data; there is no external blob directory to back up separately. Protect backup
repositories because `pgs3.credential` contains reversible SigV4 secrets.

A physical backup's database snapshot preserves object rows, chunks, pending
uploads, and transactional refcounts. After recovery:

1. keep client traffic disabled;
2. verify the extension library/SQL version matches the recovered catalog;
3. run catalog/refcount/pending-upload integrity checks supplied by the release;
4. allow GC to reclaim truly expired pending uploads in bounded batches;
5. sample inline and chunked objects and compare stored/server-computed SHA-256;
6. verify tenant/RLS and credential-disable behavior;
7. start workers and enable proxy health/routing.

Pending uploads present at backup time are not visible objects and may expire
after restore. Do not “repair” them into object rows.

### Logical dump caveat

Logical dump/restore is unsupported until every extension-owned data table is
registered appropriately for extension configuration dumping, sequence state and
partition data restore correctly, credentials remain protected, and a full
restore/client test passes. `pg_dump` succeeding is not enough. Until then, use
physical backups for recoverability.

### Point-in-time recovery semantics

PITR returns the entire database—including objects, versions, credentials, and
application state—to one WAL position, which is the main transactional advantage
of pgs3. Events already consumed from NOTIFY are not replayable; NOTIFY is not a
durable change log. Rotate/disable credentials if a restored database could make
old access keys valid again.

### Change notifications

`LISTEN pgs3` is a transactional wakeup, not an object change feed. Payloads
contain only an operation class such as `{"op":"put"}`. PostgreSQL channels have
no ACL, so do not add bucket, key, version, ETag, size, actor, access key, or
request identifiers: any role that can connect to the database can listen. A
tenant consumer responds to a wakeup by querying the RLS-protected semantic or
version-list API under its own role. It must tolerate coalescing, disconnect loss,
and unrelated tenant wakeups.

The opaque payload prevents identifier disclosure but cannot hide aggregate
activity timing or operation class from another connected role. If that side
channel or reliable replay is unacceptable, use a separately designed durable
outbox with tenant-scoped authorization; do not broaden the global notification.

## Routine monitoring

`pgs3.stats` exposes one row per worker slot and fixed operation. HTTP deltas are
flushed on a one-second heartbeat, so a smoke check must poll rather than sampling
immediately after the final response. A quiescent healthy endpoint has nonzero
request/byte/latency counters after traffic and `in_flight = 0`; histogram columns
are cumulative (`le_1ms <= le_5ms <= ... <= le_1s <= requests`). The integration
HTTP smoke performs this bounded wait and fails on an all-zero or leaked gauge.

Alert on:

- desired versus ready workers and restart loops;
- request error rate by operation/S3 code;
- p50/p95/p99 or histogram latency, in-flight requests, and timeout/cancel count;
- bytes in/out and upload abort/checksum/signature failures;
- pending upload age/count/bytes, GC backlog/failures, zero-ref blobs;
- pending lease expiry, renewal failures, and uploads old by age but still leased;
- chunk/object/blob table and index growth, dead tuples, TOAST size;
- WAL rate, checkpoint pressure, disk capacity, replication lag/conflicts;
- shutdown/reload generation and standby/primary role.

Do not create bucket/key/access-key metric labels. Review PostgreSQL logs for
worker lifecycle, GC, auth anomalies, and internal errors while preserving secret
redaction. The current writable-primary implementation persists cumulative counters
in `pgs3.worker_metric`; replacement worker PIDs reset only the in-flight gauge.
Table-backed metric updates are skipped during recovery, so standby request metrics
are not yet exported and must not be represented as zero-traffic proof.

Useful PostgreSQL infrastructure checks include `pg_stat_activity`,
`pg_stat_database`, `pg_stat_wal`, `pg_stat_bgwriter`, `pg_stat_replication`,
`pg_stat_database_conflicts`, relation sizes, and autovacuum progress. Queries for
extension relations should be shipped/tested with the finalized schema rather
than copied from a stale document.

## Autovacuum, analyze, and bloat

Frequent overwrite creates new versions rather than updating payload history, but
latest-flag transitions, refcounts, upload state, GC, and chunk cleanup still
create dead tuples. Monitor each partition and TOAST relation. Tune autovacuum per
relation only from measurements; disabling it is unsafe. Analyze after large bulk
loads/forks so LIST and refcount plans see representative distributions.

Deleting visible versions does not necessarily release disk immediately: GC must
remove unreferenced blobs/chunks and VACUUM must make space reusable. `VACUUM FULL`
and table rewrites require disruptive locks and are not routine reclamation.

## Configuration changes and shutdown

See guc.md for the declared variables. A PG17 runtime gate now proves live worker
count reduction, address/port rebinding, old-listener retirement, new-endpoint
traffic, and a new per-request statement timeout after SIGHUP. Target database,
`shared_preload_libraries`, and launcher registration still require the documented
restart boundary. Inline threshold/chunk size affect only newly created canonical
physical blobs and are read at each blob's creation. Every blob records its own
storage kind and chunk size, so reads never reinterpret old rows after a reload;
the pending-upload row does not contain configuration snapshot columns. HTTP
staged requests snapshot `chunk_size` in request memory, so SIGHUP changes only
later requests. The default is 4 MiB, selected from isolated 2/4/8 MiB diagnostic
samples; a complete 4 MiB benchmark remains required. Staged buffers start empty,
samples. The complete golden-image 4 MiB sweep passes gate 14 at 167.894 MiB/s.
Staged buffers start empty,
grow with received bytes, and reuse their allocation after a full chunk commit so
an idle/slow request does not reserve the entire chunk at head parse time. The
inline threshold also bounds D026 direct PUT, with a hard 64 KiB ceiling; that cap
is copied into each accepted request session, so a SIGHUP cannot resize a body
already being read.

Fixed-length HTTP framing lends received slices directly to the body handler.
SHA-256/MD5 remain unconditional, while SHA-1/CRC state is allocated only for
requested headers/trailers; AArch64 builds use the pinned SHA-2 assembly feature.
These are implementation properties, not knobs. HTTP chunked/aws-chunked still
owns the buffers required to validate framing and signature chains before bytes
are accepted.

Test every release with:

```sh
pg_ctl stop -D "$PGDATA" -m fast -t 5
```

Use the actual instance-specific data directory; do not copy the placeholder
blindly. The acceptance result requires completion within five seconds with no
unclean worker or postmaster restart. SIGHUP tests must show a new request using
the new live value, not just a changed `pg_settings` row.

## Executable reliability gates

The aggregate release entry point is:

```sh
make acceptance
```

It delegates to `scripts/acceptance-all.sh`, runs every independent PG17/PG18,
static, client, Ceph, reliability, fixed-robustness, deterministic-fuzz, scale,
and benchmark gate, and
reports an aggregate failure only after later suites have had a chance to record
their evidence. One failure therefore does not erase the status of subsequent
independent gates.

Host Rust/package checks still need version-specific PostgreSQL development
toolchains. The Makefile resolves `PG_CONFIG_17` and `PG_CONFIG_18` across Debian
and Homebrew layouts or accepts explicit paths. On the current macOS evidence
host, PG18 is available through Homebrew but PG17 `pg_config` is genuinely absent;
a host PG17 build/package rerun is `BLOCKED` until that toolchain is installed or
`PG_CONFIG_17` names a valid binary. The host also has `cargo-pgrx` 0.19.1 while
the Docker/release toolchain pins 0.19.2, so host package parity is separately
blocked until the pinned cargo tool is installed. Do not convert either preflight
condition into a skip or confuse it with completed Docker package/runtime gates.

The s3fs case requires a real FUSE mount. On Docker Desktop, where `/dev/fuse` is
not exposed normally, the harness permits a disposable privileged-container
fallback only with the explicit `PGS3_ALLOW_PRIVILEGED_FUSE=1` opt-in. It creates
the device only inside that run-labeled container. Without either ordinary FUSE
access or this explicit opt-in, the client gate is `BLOCKED`, never a synthetic
PASS.

The repository has a destructive, disposable-cluster reliability harness. It
creates run-labeled Docker networks, containers, and named volumes, verifies the
label again before removal, and installs an EXIT/INT/TERM cleanup trap. It never
uses global Docker prune commands. Run its offline checks first:

```sh
make reliability-static PG_MAJOR=17
```

A PASS from this command proves only Bash/Python syntax, offline unit tests,
cleanup guards, and evidence-manifest construction. It does **not** prove any
PostgreSQL runtime behavior. Runtime gates build the current workspace by
default; `PGS3_SKIP_BUILD=1` is valid only when the named image was already built
from the workspace being assessed:

```sh
make crash-test PG_MAJOR=17
make fast-stop-test PG_MAJOR=17
make reload-test PG_MAJOR=17
make standby-test PG_MAJOR=17
# both lifecycle scenarios
make lifecycle-test PG_MAJOR=17
# all four, each on a fresh disposable cluster
make reliability-test PG_MAJOR=17
# reuse a workspace-matching image instead of rebuilding it
make crash-test PG_MAJOR=18 PGS3_SKIP_BUILD=1
```

The static, crash, fast-stop, reload, and lifecycle targets accept
`PG_MAJOR=17` or `PG_MAJOR=18`. Physical-standby coverage is intentionally a
PostgreSQL 17 gate, so `standby-test` and the all-scenarios `reliability-test`
require `PG_MAJOR=17`. The Make targets pass both `PG_MAJOR` and
`PGS3_SKIP_BUILD` into the harness; an unavailable reused image is BLOCKED, not a
successful skip.

Every invocation writes a redacted
`artifacts/acceptance/<run-id>/manifest.json` with the workspace digest, commands,
exit statuses, and per-step logs. Runtime preflight failure is nonzero and is
recorded as BLOCKED or FAIL, never PASS. The test credential secret is generated
for the run by default, passed by environment-variable name, and registered with
the evidence redactor; request authorization and signatures are never printed.
After container logs and cleanup steps are collected, a final raw-byte audit
forces FAIL if either test credential remains anywhere in the evidence directory.

### Crash and GC gate

The crash case first commits a chunked object and verifies its SHA-256, then sends
a different 64 MiB PutObject slowly. It waits until at least two 1 MiB upload
chunks are durable before sending SIGKILL to the container's PID-1 postmaster.
After crash recovery it requires all of the following:

- the committed object still has the exact byte count and SHA-256;
- GET and ListObjectsV2 cannot see the partially uploaded key;
- exactly one pending upload and its upload chunks survived for GC;
- bounded pending/blob GC restores the pre-crash row counts in `upload`,
  `upload_chunk`, `upload_part`, `blob`, `chunk`, and `blob_extent`;
- the committed object remains byte-for-byte valid after GC.

The production pending-upload age is currently 24 hours, its lease duration is five
minutes, and the worker polls once per minute. An acceptance run cannot wait 24
hours, so the harness first proves the crash row is pending, moves only that
identified row's `updated_at` back by 25 hours and its `lease_expires_at` into the
past, invokes the privileged semantic GC functions, and then checks exact table
counts. This explicitly accelerates both independent eligibility predicates; it is
not evidence that natural retention elapsed. Do not shorten production retention
or lease safety margin merely to make this test faster.

### Fast shutdown and SIGHUP gates

The fast-stop case keeps a chunked PutObject in flight while running the exact
command below through `docker exec` in the disposable container. It measures host
time through the target-container exit and requires less than 5,000 ms, target
container/postmaster exit status zero, one new fast-shutdown request log, one new
clean-shutdown log, and an interrupted client:

```sh
pg_ctl stop -D /var/lib/postgresql/data -m fast -t 5
```

Docker destroys the container PID namespace when its PID 1 postmaster exits. On
Docker Engine 29.4.1, that can kill the still-waiting `docker exec` process and
surface status 137 even though PostgreSQL completed a clean fast shutdown. The
harness accepts that namespace-teardown status only after the target container is
`exited|0|false`, the elapsed bound passes, and both new log records are present;
status 0 is also valid. The outer guard uses SIGTERM so its own seven-second
timeout is unambiguously status 124 and always fails the gate.

The reload case changes worker count from four to two, moves both address and port,
and changes `pgs3.statement_timeout_ms` from 5,000 ms to 250 ms. Passing requires
the two excess worker PIDs to disappear, every desired worker to advertise the new
bind, the old port's listener to remain absent in the container network namespace,
and a signed GET to succeed on the new port. The listener assertion deliberately
does not use a host-side TCP handshake: Docker's published-port forwarding can
accept a connection and then reset it after the target listener has disappeared.
The case then holds an `ACCESS EXCLUSIVE` lock on the bucket table: a new signed
LIST must return S3 `SlowDown`/HTTP 503 in under two seconds. This final request
distinguishes an effective timeout reload from a changed `pg_settings` row.
The lock holder uses a 30-second safety ceiling and is explicitly cancelled only
after the request assertion, so evidence-recording latency cannot let the lock
expire before the probe reaches the server.

Earlier reload runs correctly exposed two defects: the request service retained
its old database timeout, and a changed `pg_settings` row did not affect the
lock-conflicting LIST. The recorded PG17 all-scenarios run returns HTTP 503/S3
`SlowDown` after 0.258 seconds while also proving pool/listener convergence and a
valid GET on the new endpoint. The accepted evidence is
[`reliability-all-pg17-78975`](../artifacts/acceptance/20260831T040332Z-reliability-all-pg17-78975/manifest.json).
Keep the lock-based assertion; a future regression must remain a product failure.

### PostgreSQL 17 hot-standby gate

The standby scenario builds a physical replica with `pg_basebackup -R` on an
isolated Docker network. The primary uses a short-lived trust rule limited to the
disposable network and a dedicated replication role. Passing requires streaming
WAL, `pg_is_in_recovery()`, one preloaded launcher and two dynamically registered
HTTP child workers on the replica, exact-SHA GET, ListObjectsV2, and an attempted
PutObject returning HTTP 503/S3 `ServiceUnavailable` with a read-only-standby
message. The rejected key must remain invisible and all worker/postmaster
processes must survive. This gate is intentionally fixed to PostgreSQL 17; PG18
packaging is covered separately and must not be substituted for the required PG17
replication result.

## Incident playbooks

### Endpoint accepts TCP but requests fail

Compare desired/ready worker state, target database, extension version, PostgreSQL
recovery state, RLS role, proxy Host/URI preservation, and recent worker restarts.
Do not disable SigV4 or RLS as a diagnostic shortcut. Reproduce directly on the
loopback endpoint with a short-lived test credential and redact the request.

### Multipart upload crashes a worker

This playbook comes from a resolved but important failure. In historical manifest
[`clients-pg17-79386`](../artifacts/acceptance/20260831T004926Z-clients-pg17-79386/manifest.json),
the eighth UploadPart of a 100 MiB aws CLI transfer terminated a worker with
signal 11 and caused postmaster crash recovery. The current image
supersedes that status:
[`clients-pg17-72577`](../artifacts/acceptance/20260831T064443Z-clients-pg17-72577/manifest.json)
completes all 13 parts, validates the exact multipart ETag and download SHA-256,
and passes rclone; the current crash/GC suite also passes.

If the symptom returns, preserve the manifest, postmaster log, upload ID, part
count, and exact package/image identity; verify no partial object became visible
and let only the locked semantic GC reclaim pending state. Treat it as a product
failure and rerun both 100 MiB client and crash/GC gates after repair.

### Growing pending uploads

Check active leases, client disconnect/timeouts, checksum/signature failure rate,
GC readiness, transaction errors, and disk/WAL headroom. Do not manually delete
chunks without the release's locked semantic cleanup; doing so can race complete
or remove content referenced by a manifest.

`upload_id` is the attempt identity. A new upload starts with a five-minute
`lease_expires_at`; chunk/part/list locks renew it, while complete and abort lock
then delete the attempt. For an in-progress HTTP body, a target-bound heartbeat
becomes due after 60 monotonic seconds and runs on the next body-progress callback;
a committed chunk resets the schedule. The application body-idle timeout is 60
seconds and the lease is five minutes, leaving margin for this event-driven cadence.
Inspect `created_at`, `updated_at`, and `lease_expires_at` separately: a row can
intentionally be old by staging age while a live request keeps its lease current.
Operator cleanup must use `pgs3.gc_pending_uploads`, which additionally takes `FOR
UPDATE SKIP LOCKED`; never replace it with an age-only `DELETE`.

### Suspected refcount mismatch

Stop mutations or isolate the affected bucket, take a physical backup, and run the
release-supplied read-only reconciliation query. A zero refcount is not alone safe
evidence for deletion. Repair must lock against new references and leave an audit
record. The current release does not yet supply a proven repair procedure.

### Signature failures after enabling TLS proxy

Compare the exact raw client path/query/Host/signed headers with what pgs3 receives.
Look for URI normalization, decoded `%2F`, changed port/Host, stripped duplicate
query values, request buffering/trailers, or clock skew. Never log the secret or
full presigned URL.

### Standby unexpectedly receives a write

The worker must reject it before `100 Continue`/body consumption. Correct proxy
routing and verify database recovery role. If a standby mutates or hangs, remove
it from service and treat that as a failed reliability gate.

## Upgrade and rollback

The current release version is 0.1.1 and ships a real
`pgs3--0.1.0--0.1.1.sql` transition. The package does not advertise the frozen
0.1.0 install fixture as a current fresh-install choice; the upgrade harness
copies that checksummed fixture only into a disposable test image. It then:

1. installs 0.1.0 and creates inline, chunked, multipart, copied, forked,
   restored, delete-marker, pending-upload, credential, and cross-tenant state;
2. records a data/refcount/catalog fingerprint;
3. runs `ALTER EXTENSION pgs3 UPDATE TO '0.1.1'`;
4. verifies `pgs3.extension_version()`, preserved data/RLS/refcounts, worker-only
   grants, and extension membership; and
5. compares the upgraded catalog and full semantic suite with a direct 0.1.1
   installation.

Run both majors before release:

```sh
make upgrade-test PG_MAJOR=17
make upgrade-test PG_MAJOR=18
# or
make upgrade-test-matrix
```

The update SQL and harness are implemented; their existence is not itself a PASS
record. Every later release that changes tables/functions must keep shipping and
running a versioned path over similarly rich state. Take a recoverable physical
backup first. Do not assume a shared-library downgrade is catalog-compatible. A
rollback plan must name the last compatible SQL version or restore point.

Rolling worker replacement on one port is not safe until configuration generation,
protocol compatibility, and mixed-version tests exist. Prefer a controlled outage
or a second endpoint/port during early releases.

## Production verification gates

Do not call an installation production-ready until all are reproducible:

- `cargo pgrx package` for PostgreSQL 17 and 18 and an upgrade/install smoke test;
- SQL semantic suite including 50-way conditional races repeated 20 times;
- aws CLI, rclone, boto3, s3fs, and DuckDB client matrix;
- 100 MiB multipart with correct ETag and rclone check;
- documented ceph s3-tests matrix of at least 150 cases;
- 100-upload dedup/delete/GC, kill-9 recovery, and 100k fork independence;
- two-tenant including LIST/HEAD/presigned isolation and tampered-body rejection;
- malformed-request fuzz with worker/postmaster survival;
- hot-standby reads/write rejection, five-second shutdown, and live SIGHUP tests;
- measured perf.md sweep and acceptance-target results against same-host MinIO.
