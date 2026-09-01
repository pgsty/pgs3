# pgs3

`pgs3` 0.1.1 is a PostgreSQL extension that turns one database into a path-style,
S3-compatible HTTP endpoint. Object semantics live in SQL; PostgreSQL background
workers authenticate and translate HTTP requests without a sidecar process.

The project targets PostgreSQL 17 and 18 (16 is best effort) and is optimized for
versioned, tenant-isolated agent artifacts from a few KiB to a few MiB. It is not
intended to compete with object stores on very large-object throughput.

> **Development status:** the current package-backed PostgreSQL 17 and 18 images
> install the extension and pass their SQL/HTTP gates. On PostgreSQL 17, the
> complete client
> matrix, 195 selected ceph s3-tests, crash/fast-stop/SIGHUP/standby reliability,
> and the fixed malformed-request corpus all pass. This is still not a
> production-ready S3 endpoint: the complete benchmark ran, but performance gates
> 12--13 fail, and the current 100,000-object fork misses its one-second
> gate. See
> [acceptance evidence](docs/acceptance.md) and
> [known limitations](docs/known-limitations.md).

The reviewed evidence checkpoints are deliberately narrower than a release claim:

- PostgreSQL 17 client matrix:
  [`clients-pg17-72577`](artifacts/acceptance/20260831T064443Z-clients-pg17-72577/manifest.json)
  (`PASS`). This includes both aws CLI surfaces, a 100 MiB/13-part upload with
  exact multipart ETag and SHA-256/rclone verification, rclone, boto3 flexible
  checksums, DuckDB httpfs, and a real opt-in privileged s3fs FUSE mount with
  vim/grep/find. The identical PostgreSQL 18 matrix also passes in
  [`clients-pg18-71442`](artifacts/acceptance/20260831T064421Z-clients-pg18-71442/manifest.json).
- Pinned ceph s3-tests:
  [`ceph-s3-tests-pg17-74469`](artifacts/acceptance/20260831T064550Z-ceph-s3-tests-pg17-74469/manifest.json)
  (`PASS`): 195 selected and passed from a fixed 209-case candidate set, with
  exactly 14 source-audited exclusions and no failure, error, skip, or not-run.
- PostgreSQL 17 reliability, robustness, and deterministic fuzz:
  [`reliability-all-pg17-80047`](artifacts/acceptance/20260831T065006Z-reliability-all-pg17-80047/manifest.json),
  [`http-robustness-pg17-83397`](artifacts/acceptance/20260831T065124Z-http-robustness-pg17-83397/manifest.json),
  and
  [`fuzz-malformed-pg17-84795`](artifacts/acceptance/20260831T065154Z-fuzz-malformed-pg17-84795/manifest.json)
  (all `PASS`; fuzz 24/24 with exact process identity).
- Current PG17/PG18 package/runtime and real catalog transition:
  [`sql-pg17-83057`](artifacts/acceptance/20260831T065107Z-sql-semantic-pg17-83057/manifest.json),
  [`sql-pg18-83550`](artifacts/acceptance/20260831T065126Z-sql-semantic-pg18-83550/manifest.json),
  [`upgrade-pg17-65725`](artifacts/acceptance/20260831T063728Z-extension-upgrade-pg17-65725/manifest.json),
  and [`upgrade-pg18-67508`](artifacts/acceptance/20260831T063921Z-extension-upgrade-pg18-67508/manifest.json)
  (all `PASS`). The client matrices above provide live HTTP coverage on both
  package images.
- Full SQL scale on the current PG17 image:
  [`scale-pg17-90791`](artifacts/acceptance/20260831T065441Z-scale-pg17-90791/manifest.json)
  (`FAIL` overall): LIST 2.358 ms and delimiter LIST 9.487 ms pass, while fork
  1944.071 ms fails. A same-final-source iteration reached 865.495 ms before the
  golden image was built; it is variance/optimization evidence, not the final
  image's gate result.
- Full pgs3/MinIO sweep:
  [`http-benchmark-pg17-91774`](artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/manifest.json)
  completed with verified content and zero request errors. Curve completeness
  and the 8 MiB throughput target pass; fixed small-object gates 12--13 fail.

Every manifest records a dirty-worktree digest and exact image identity. The
manifests above exercise the current extension source in PG17 image
`270f9b60...` and PG18 image `0bc9f5a9...`, at workspace digest `780ea7bb...`;
later documentation and cleanup-harness-only edits do not change those binaries.

## Architecture

- `pgs3.bucket`, `pgs3.object`, `pgs3.blob`, and hash-partitioned `pgs3.chunk`
  keep metadata, versions, deduplicated content, and bounded chunks in ordinary
  PostgreSQL relations.
- SQL functions implement PUT/GET/range/head/delete/copy/list/version/restore,
  fork, staged upload, multipart, and garbage-collection semantics.
- A preload or dynamically started launcher owns a pool of PostgreSQL background
  workers. Each worker performs nonblocking HTTP I/O and calls SPI only on its
  PostgreSQL main thread.
- For staged non-multipart PutObject, the restricted worker seals its
  server-computed whole-body digests only after PostgreSQL returns the exact
  ordered canonical chunk manifest. The final transaction locks and matches that
  manifest before publication; public SQL `put_chunk`/`complete_upload` continue
  to hash the stored bytes themselves.
- Staging defaults to 4 MiB chunks. Fixed-length body slices stay borrowed through
  HTTP framing, staged buffers grow progressively and reuse their allocation, and
  SHA-1/CRC state is created only when requested; SHA-2 assembly is enabled for
  AArch64. The complete 4 MiB sweep records 167.894 MiB/s for the required 8 MiB
  PUT, passing gate 14; the small-object gates remain failed.
- SigV4 credentials map access keys to PostgreSQL roles. `GRANT` plus default-deny
  RLS is the authorization model; there is no parallel IAM implementation. A
  custom `pgs3.server_role` receives only the required runtime grants during
  install/update, and the launcher stops HTTP listeners if its restricted-role
  attributes, memberships, or grants drift.

The normative choices and specification conflicts are recorded in
[decisions.md](docs/decisions.md). Start with [design.md](docs/design.md) and
[schema.md](docs/schema.md) when changing the implementation.

## Development

The Docker/package toolchain pins `cargo-pgrx` 0.19.2. This macOS host currently
has 0.19.1, so a host package-parity claim is blocked until the pinned version and
matching PostgreSQL development headers are installed. After installing them, the
host parity checks are:

```bash
make fmt-check
make check-matrix
make package-matrix
```

The currently reproducible pinned package path is the container matrix:

```bash
make image-matrix
```

Repository image scripts default `DOCKER_BUILDKIT=0` on this host so pinned local
cache builds avoid slow/failing BuildKit frontend metadata resolution. Users may
override the variable explicitly; this changes the builder path, not image pins.

SQL tests build a disposable PostgreSQL image with the extension installed and
run every file under `tests/sql/`:

```bash
make sql-test PG_MAJOR=17
make sql-test PG_MAJOR=18
```

The current catalog version is 0.1.1. The package contains a real
`0.1.0 -> 0.1.1` update script, while the upgrade harness injects the frozen,
checksummed 0.1.0 install fixture only into its disposable test cluster. It then
compares an upgraded rich fixture with a direct 0.1.1 install:

```bash
make upgrade-test PG_MAJOR=17
make upgrade-test PG_MAJOR=18
make upgrade-test-matrix
```

The existence of this path and harness is an implementation fact; each packaged
release still needs a recorded PG17/PG18 upgrade run before release.

The reliability harness exposes an offline check plus isolated Docker runtime
scenarios:

```bash
make reliability-static PG_MAJOR=17
make crash-test PG_MAJOR=17
make fast-stop-test PG_MAJOR=17
make reload-test PG_MAJOR=17
make standby-test PG_MAJOR=17
make lifecycle-test PG_MAJOR=17   # fast-stop plus reload
make reliability-test PG_MAJOR=17 # all four runtime scenarios
make robustness-test PG_MAJOR=17  # fixed seven-case boundary corpus
make fuzz-test PG_MAJOR=17        # 8 core + 16 seeded malformed cases
```

Runtime targets build the current PostgreSQL image by default. Set
`PGS3_SKIP_BUILD=1` only to reuse an image already built from the workspace under
test, for example `make crash-test PG_MAJOR=18 PGS3_SKIP_BUILD=1`. The standby
scenario, and therefore `reliability-test`, is a PostgreSQL 17 gate; the static,
crash, fast-stop, reload, and lifecycle targets also accept PostgreSQL 18. A
static PASS is not runtime evidence. See the
[operations guide](docs/operations.md#executable-reliability-gates) for the
assertions and evidence layout.

`make verify` is the aggregate formatting/build/package/SQL gate; it is not the
release gate. `make acceptance` additionally invokes the mandatory client, ceph,
reliability, scale, robustness, fuzz, and benchmark suites and currently fails on
the measured performance gates.
Container builds
accept `PG_MAJOR=17` or `PG_MAJOR=18` and do not install or start PostgreSQL on
the host.

## Documentation

- [Architecture and lifecycle](docs/design.md)
- [Schema and invariants](docs/schema.md)
- [GUC reference](docs/guc.md)
- [Operations and TLS termination](docs/operations.md)
- [Known limitations](docs/known-limitations.md)
- [Acceptance evidence and release gate](docs/acceptance.md)
- [Implementation pitfalls](docs/pitfalls.md)
- [Performance results and methodology](docs/perf.md)

TLS, virtual-host addressing, ACLs, bucket policies, lifecycle rules, logical
replication, and cross-database endpoint sharing are intentionally out of scope.
