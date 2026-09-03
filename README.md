# pgs3

[![Release](https://img.shields.io/github/v/release/pgsty/pgs3?display_name=tag&sort=semver)](https://github.com/pgsty/pgs3/releases/latest)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17%20%7C%2018-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**S3-compatible object storage implemented inside PostgreSQL.**

`pgs3` turns one PostgreSQL database into a path-style S3 endpoint. PostgreSQL
background workers authenticate HTTP requests and translate them into SQL-backed
object operations, so metadata, versions, content, authorization, WAL, backup,
and recovery remain inside PostgreSQL.

> [!WARNING]
> `pgs3` is an early alpha. The current implementation has broad functional and
> compatibility coverage, but it is not yet a production-ready general-purpose
> object store. Small-object performance and the 100,000-object Fork target do
> not meet the project gates. Read [Known limitations](docs/known-limitations.md)
> before deployment.

The current GitHub project release is [`v0.1.0`](https://github.com/pgsty/pgs3/releases/tag/v0.1.0).
It contains extension catalog version `0.1.1`, preserving the tested
`0.1.0 -> 0.1.1` PostgreSQL extension upgrade path.

## Why pgs3?

`pgs3` is designed for versioned, tenant-isolated agent artifacts from a few KiB
to a few MiB when PostgreSQL is already the system of record.

- **One data system:** objects and metadata use ordinary PostgreSQL tables,
  indexes, transactions, WAL, backup, and recovery.
- **S3-compatible clients:** AWS CLI, boto3, rclone, DuckDB `httpfs`, and s3fs
  can use the same endpoint in path-style mode.
- **PostgreSQL authorization:** SigV4 access keys map to restricted database
  roles; grants and row-level security isolate tenants.
- **Permanent history:** overwrites create versions, ordinary deletes create
  delete markers, and historical versions remain addressable.
- **Content sharing:** canonical blobs deduplicate identical payloads and are
  shared by Copy, Restore, and Fork operations.
- **No sidecar data service:** PostgreSQL background workers own the HTTP
  listener and invoke the SQL semantic layer through SPI.

## Capability overview

| Area | Current support |
| --- | --- |
| Authentication | SigV4 headers, presigned URLs, full-hash and unsigned payloads, AWS streaming payload forms |
| Buckets | Create, head, list, location, versioning status, and empty-bucket delete |
| Objects | Put, get, head, range, conditional writes, delete, bulk delete, copy, and checksums |
| Listings | ListObjectsV2 with prefix, delimiter, pagination, and version listing |
| Multipart | Create, upload/list parts, complete, abort, multipart ETag, and SHA-256 composite checksum |
| pgs3 extensions | SQL restore of a historical version and metadata-only bucket Fork |
| Tenancy | PostgreSQL role mapping, restricted worker role, grants, and default-deny RLS |
| PostgreSQL | 17 and 18 supported; 16 is best effort |

Deliberate first-phase exclusions include virtual-host bucket URLs, built-in TLS,
IAM or bucket-policy languages, ACLs, lifecycle rules, logical-replication
topologies, and cross-database endpoint routing. TLS must terminate at a reverse
proxy that preserves the signed request path and headers.

## Architecture

```text
S3 client
   |
   | HTTP + SigV4
   v
PostgreSQL background workers
   |
   | SPI in short transactions
   v
SQL semantic layer
   |
   +-- bucket / object versions / delete markers
   +-- canonical blobs and chunk extents
   +-- credentials, RLS, metrics, and worker state
   |
   v
PostgreSQL storage, WAL, backup, and recovery
```

Object behavior is defined in SQL. Rust owns HTTP framing, SigV4, streaming,
worker lifecycle, and the protocol-to-SQL boundary; it does not implement a
second object-semantic engine.

See [Architecture and lifecycle](docs/design.md),
[Schema and invariants](docs/schema.md), and
[API-to-SQL mapping](docs/api-sql-mapping.md) for the detailed contract.

## Quick start

The reproducible development path builds a PostgreSQL image containing the
extension:

```bash
git clone https://github.com/pgsty/pgs3.git
cd pgs3
make image PG_MAJOR=17
```

The complete local walkthrough covers container startup, credential creation,
AWS CLI configuration, object versioning, and cleanup:

- [Quick-start tutorial (Chinese)](docs/getting-started.md)
- [Usage guide (Chinese)](docs/usage.md)

A configured client must use path-style addressing and the explicit endpoint:

```bash
export PGS3_ENDPOINT='https://s3.example.com'
export AWS_ACCESS_KEY_ID='<access-key>'
export AWS_SECRET_ACCESS_KEY='<secret-key>'
export AWS_DEFAULT_REGION='us-east-1'

aws --endpoint-url "$PGS3_ENDPOINT" s3api list-buckets
```

Do not expose the cleartext worker port directly to the Internet, and do not
allow a client to fall back silently to AWS when `PGS3_ENDPOINT` is missing.

## Build and install

The source release requires:

- Rust with the 2024 edition;
- `cargo-pgrx 0.19.2`;
- PostgreSQL 17 or 18 server development files;
- Docker for the pinned package and integration-test path.

Common targets:

```bash
make fmt-check
make check PG_MAJOR=17
make package PG_MAJOR=17
make image-matrix
```

The host checks require a matching `pg_config`. Container builds are the
portable path when both PostgreSQL development versions are not installed on the
host.

After installing the package, preload the library and configure its endpoint:

```conf
shared_preload_libraries = 'pgs3'
pgs3.enabled = on
pgs3.target_database = 'artifacts'
pgs3.listen_addr = '127.0.0.1'
pgs3.port = 9000
pgs3.workers = 4
```

Install `CREATE EXTENSION pgs3` in the target database before enabling traffic.
Review the full [GUC reference](docs/guc.md) and
[operations guide](docs/operations.md) before using automatic startup, changing
the worker role, or exposing an endpoint.

## Security model

An access key resolves to a PostgreSQL role after SigV4 verification. Each object
transaction runs through a restricted service role and transaction-local tenant
role; RLS is the final data-isolation boundary.

- Application roles should be `NOLOGIN`, `NOINHERIT`, and
  `NOBYPASSRLS`.
- The pgs3 service role must not be used as a tenant or application identity.
- Secrets are stored reversibly because SigV4 verification requires them; treat
  database backups as credential-bearing material.
- Bucket names, object keys, credentials, SQL text, and tenant identifiers must
  not appear in ordinary metrics labels or cross-tenant errors.
- Production endpoints require external TLS termination and restricted
  PostgreSQL administration access.

## Validation status

The reviewed package-backed baseline records:

| Gate | Result |
| --- | --- |
| PostgreSQL 17 and 18 SQL semantics and package runtime | Pass |
| PostgreSQL 17 and 18 client matrices | Pass |
| Selected Ceph S3 compatibility suite | 195/195 pass |
| Real `0.1.0 -> 0.1.1` upgrade on PostgreSQL 17 and 18 | Pass |
| Crash recovery, fast stop, SIGHUP, and standby reads | Pass |
| Fixed malformed-request and deterministic fuzz suites | Pass |
| 8 MiB PUT throughput and LIST targets | Pass |
| Small-object GET/PUT targets | Fail |
| 100,000-object Fork under one second | Fail |

See [Acceptance evidence](docs/acceptance.md) and
[Performance results](docs/perf.md) for exact scope and measurements. Test runs
write redacted evidence under `artifacts/acceptance/`; generated evidence is
not committed to the source repository.

The aggregate commands are:

```bash
make integration-lint
make unit
make verify
make acceptance
```

`make acceptance` is intentionally strict and currently returns non-zero for
the documented performance failures. It does not convert missing tools or
blocked capabilities into passes.

Use `make clean` to remove the consolidated Cargo build directory and scattered
interpreter/test caches.

## Documentation

| Document | Purpose |
| --- | --- |
| [Quick start](docs/getting-started.md) | Local PostgreSQL 17 container and first S3 workflow (Chinese) |
| [Usage guide](docs/usage.md) | AWS CLI, boto3, rclone, s3fs, DuckDB, and SQL usage (Chinese) |
| [Design](docs/design.md) | Architecture, ownership, transaction, and worker lifecycle |
| [Schema](docs/schema.md) | Tables, indexes, invariants, RLS, and upgrade rules |
| [Configuration](docs/guc.md) | GUC defaults, ranges, reload, and restart behavior |
| [Operations](docs/operations.md) | TLS, HA, backup, recovery, observability, and upgrades |
| [API mapping](docs/api-sql-mapping.md) | S3 routes and their SQL semantic functions |
| [Acceptance](docs/acceptance.md) | Release gates, evidence boundaries, and current results |
| [Known limitations](docs/known-limitations.md) | Unsupported and incomplete behavior |
| [Implementation pitfalls](docs/pitfalls.md) | Compatibility, safety, and correctness traps |
| [Agent skill](SKILL.md) | Guardrails for agents using a deployed pgs3 endpoint |

## Repository layout

```text
src/       Rust extension, protocol, S3 adapter, and background workers
sql/       Install and versioned extension-update SQL
tests/     Unit, SQL, client, compatibility, reliability, and performance suites
scripts/   Build and acceptance orchestration
docker/    Reproducible PostgreSQL and client images
docs/      Design, operations, usage, and validation documentation
```

## Contributing

Bug reports and focused pull requests are welcome through
[GitHub Issues](https://github.com/pgsty/pgs3/issues). Preserve the SQL semantic
boundary, tenant non-disclosure, and fail-closed acceptance behavior. Run the
smallest relevant test first, then the applicable matrix before submitting a
change.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
