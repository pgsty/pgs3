# pgs3 configuration (GUCs)

## Status

The current implementation registers the variables in this table and exercises
dynamic startup plus a live SIGHUP generation on PostgreSQL 17. That gate proves
worker-count reconciliation, address/port rebinding, and a new per-transaction
statement timeout. Registration alone is still not evidence for settings not
named by that gate.

All current variables use PostgreSQL context `PGC_SIGHUP`: they are set in server
configuration (or with `ALTER SYSTEM`) and their process-local values can change
after configuration reload. Several resources cannot actually be changed in place;
the **effective change** column is the operational contract to implement.

| GUC | Type / units | Default | Accepted range | Effective change and meaning |
| --- | --- | ---: | ---: | --- |
| `pgs3.enabled` | boolean | `off` | boolean | Desired state for a launcher registered by `shared_preload_libraries`. The static launcher reacts to SIGHUP and starts/stops its children. Reload cannot create a launcher when the library was not preloaded; adding/removing the preload entry requires restart. Dynamic launchers ignore this flag. The on/off reload path is implemented but is not part of the current runtime acceptance scenario. |
| `pgs3.workers` | integer workers | `4` | `1..64` | Desired HTTP worker count. The launcher reconciles the pool after SIGHUP; the PG17 gate proves four workers converging to two and retiring the excess PIDs. |
| `pgs3.listen_addr` | string address | `127.0.0.1` | valid IPv4/IPv6 address | Every worker binds with `SO_REUSEPORT`. On SIGHUP a worker binds the new socket before replacing its listener; a failed bind retains the old listener and records error state. The PG17 gate proves a successful address move and old-listener retirement. |
| `pgs3.port` | integer TCP port | `9000` | `1..65535` | Reloadable with the address. The PG17 gate proves port 9000 to 9001, authenticated traffic on the new endpoint, and no listener in the old container namespace. |
| `pgs3.inline_threshold` | integer bytes | `65536` | `0..1073741824` | New canonical physical blobs at or below the current value store their one copy in `blob.inline`; existing blobs/versions are never rewritten. It also sets D026's direct-PUT cap, hard-limited to 64 KiB. Each accepted direct request snapshots its cap, so SIGHUP affects only later requests. |
| `pgs3.chunk_size` | integer bytes | `4194304` | `65536..16777216` | HTTP staged PUT snapshots this value into each accepted request and uses it for network-to-SQL chunk commits; SIGHUP affects only later requests. Each physical blob also records its layout, so reads never reinterpret old content. The 4 MiB default follows one-concurrent-request diagnostic samples of 119.24 MiB/s at 2 MiB, 154.92 MiB/s at 4 MiB, and about 32 MiB/s at an 8 MiB cliff. The complete golden-image sweep measures 167.894 MiB/s for the required 8 MiB PUT and passes gate 14. |
| `pgs3.statement_timeout_ms` | integer milliseconds | `30000` | `1..3600000` | Per-transaction semantic SPI timeout. The worker arms PostgreSQL's core statement timer explicitly and sets transaction-local `statement_timeout` plus `lock_timeout`; it is not an HTTP header/body idle timeout. New transactions use the reloaded value. |
| `pgs3.target_database` | string database name | `postgres` | valid existing database | Database a static preload launcher attaches to. It must contain the extension. Manual `pgs3.start()` uses the caller's current database. A connected launcher cannot change database; changing this value requires a PostgreSQL restart. |
| `pgs3.server_role` | string role name | `pgs3_server` | default or valid existing custom role | Restricted `NOLOGIN NOINHERIT` role used when HTTP workers connect. Install/update creates the missing default role, while a custom role must already exist; SQL dynamically grants the selected role only CONNECT, schema USAGE, credential SELECT, and the worker helper EXECUTEs. It must have no inbound members; its own memberships may be SET-only, never ADMIN/INHERIT. On SIGHUP the launcher stops old-identity listeners, validates attributes/memberships/grants, and starts replacements only when the new role is ready. This reload path is implemented but not acceptance-proven. |

## Preload configuration example

The target automatic-start configuration is:

```conf
shared_preload_libraries = 'pgs3'       # append to an existing list
pgs3.enabled = on
pgs3.target_database = 'artifacts'
pgs3.workers = 4
pgs3.listen_addr = '127.0.0.1'
pgs3.port = 9000
pgs3.inline_threshold = 65536
pgs3.chunk_size = 4194304
pgs3.statement_timeout_ms = 30000
pgs3.server_role = 'pgs3_server'
```

`shared_preload_libraries` and the initial static launcher require a PostgreSQL
restart, not only `pg_reload_conf()`. Install `CREATE EXTENSION pgs3` in the target
database before enabling traffic. Current startup readiness must be verified from
`pgs3.worker_state` and logs; do not use only an open TCP socket.

## Manual-start configuration

Manual mode is:

```sql
CREATE EXTENSION IF NOT EXISTS pgs3;
SELECT pgs3.start();
```

The dynamic launcher uses the current database, waits for bounded readiness, and
records ownership in shared SQL state so a later operator session can stop it. A
manually started pool disappears when PostgreSQL stops and must not race a preload
pool on the same socket.

## Inspecting values

After the library is loaded, inspect exact live settings and sources with:

```sql
SELECT name, setting, unit, context, source, pending_restart
FROM pg_settings
WHERE name LIKE 'pgs3.%'
ORDER BY name;
```

This query proves registration/current values, not that workers applied a change.
Operational status must expose desired and actual worker address, port, database,
configuration generation, and readiness.

## Reload versus restart matrix

| Change | PostgreSQL reload | pgs3 pool restart | PostgreSQL restart |
| --- | --- | --- | --- |
| Request statement timeout | yes; PG17 gate proven | no | no |
| Inline threshold / chunk size for new physical blobs | yes; existing blobs retain recorded layout | no | no |
| Worker count | yes; PG17 scale-down gate proven | no | no |
| Listen address / port | yes; PG17 rebind gate proven | no on success; inspect error/old listener on failure | no |
| Server role | launcher stops the old-identity HTTP pool and starts replacements only after the new role passes its restricted-shape/runtime-grant audit; not acceptance-proven | automatic reconciliation, or controlled operator restart if preload reconciliation is unavailable | no |
| Target database | value only for a running launcher | insufficient | yes |
| `enabled: on → off` | implemented for a preloaded launcher; not acceptance-proven | no | no |
| `enabled: off → on` without registered launcher | insufficient | insufficient | yes |
| Add/remove `shared_preload_libraries` entry | insufficient | insufficient | yes |

SIGHUP acceptance requires proving that settings advertised as live affect new
requests. Merely observing a changed row in `pg_settings` does not pass.

## Validation and safety rules

- Reject empty/invalid listen addresses and database names with clear logs; never
  silently fall back to a public wildcard or another database.
- Treat wildcard binds (`0.0.0.0`, `::`) as an explicit security decision. pgs3
  does not provide TLS.
- Ensure `inline_threshold <= chunk_size` is not assumed: the registered ranges
  allow otherwise, so storage code must handle any valid pair or add a documented
  cross-setting validation.
- Persist the chosen upload/chunk representation in rows. Reads and GC cannot
  depend on the current threshold/chunk-size value.
- Convert `statement_timeout_ms` without integer overflow and apply it with
  `SET LOCAL`, not a session setting that leaks to the next request.
- Do not include secrets, access keys, or TLS private keys in pgs3 GUCs.
- Provision a custom `server_role` before install/update with `NOLOGIN NOINHERIT
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`. Do not grant
  membership in the service role to any other role, and do not give it
  ADMIN/INHERIT membership in tenant roles. Install/update SQL grants its narrow
  runtime ACL dynamically; the launcher treats later attribute, membership, or
  ACL drift as fail-closed and removes active HTTP listeners.

## Settings not yet defined

GC interval/batch, HTTP size/header limits, SigV4 clock skew,
credential encryption key source, metrics buckets, region, and chunk partition
count need explicit decisions before becoming user-visible
GUCs. Code must not hide material operational knobs as undocumented environment
variables. Add a setting only when its context, range, reload behavior, migration
impact, and test are documented here.

## Fixed safety constants (not GUCs)

The upload lease protocol currently uses a five-minute duration in SQL. The HTTP
body-idle timeout is 60 seconds; a heartbeat becomes due after 60 monotonic seconds
and runs on the next body-progress callback, while a committed chunk resets its
schedule. Chunk/part/list operations also renew while holding the upload row. These
are documented implementation constants, not reloadable GUCs: changing only one
copy would invalidate the safety margin, and SIGHUP does not alter existing
deadlines. GC pending retention remains 24 hours with a one-minute worker poll and a
1,000-row batch. A future configurable form must define one authoritative duration,
ranges, reload behavior for existing uploads, and concurrency tests before
registration.
