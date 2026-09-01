---
name: pgs3-artifacts
description: Store, retrieve, version, restore, and fork agent artifacts in a pgs3 bucket through its path-style S3 endpoint or SQL semantic API. Use when a task names pgs3 or provides a pgs3 endpoint; do not treat this as generic AWS infrastructure guidance.
---

# Use pgs3 for agent artifacts

Use the S3 endpoint for ordinary artifact I/O. Use the SQL API only for pgs3-only
operations such as restoring a version or forking a bucket.

## Preconditions

Expect these values from the environment or user:

- `PGS3_ENDPOINT`, including `http://` or the TLS-terminating proxy URL;
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for the mapped PostgreSQL role;
- `AWS_DEFAULT_REGION` (normally the deployment's configured region);
- `PGS3_DSN` only when restore/fork SQL is needed.

Never print, embed in commands, commit, or copy the secret into object metadata.
Do not silently fall back to AWS when `PGS3_ENDPOINT` is absent. pgs3 supports
path-style addressing, so configure SDKs with path-style mode when they default to
virtual-host addressing.

Before a workflow that writes material data, check the intended bucket:

```bash
aws --endpoint-url "${PGS3_ENDPOINT}" s3api head-bucket --bucket "${bucket}"
```

Treat authentication, authorization, and missing-bucket failures as distinct from
transient endpoint failures. Do not start, reconfigure, or grant access to the
database unless the task authorizes administration.

## Store and retrieve

Choose stable keys that include the project/run identity. Upload the actual bytes;
client checksum headers are validation inputs and never a way to refer to content
that the server has not read.

```bash
aws --endpoint-url "${PGS3_ENDPOINT}" s3api put-object \
  --bucket "${bucket}" --key "${key}" --body "${artifact}"

aws --endpoint-url "${PGS3_ENDPOINT}" s3api get-object \
  --bucket "${bucket}" --key "${key}" "${destination}"
```

Every overwrite creates a version. Capture the returned `VersionId` when a later
step must refer to the exact artifact. For large artifacts, let the AWS CLI or SDK
use multipart upload; do not concatenate parts locally to simulate completion.

List by prefix rather than downloading a manifest:

```bash
aws --endpoint-url "${PGS3_ENDPOINT}" s3api list-objects-v2 \
  --bucket "${bucket}" --prefix "${prefix}" --delimiter / --max-keys 1000
```

Follow `NextContinuationToken` until `IsTruncated` is false. Never manufacture or
edit continuation tokens.

## Inspect versions

```bash
aws --endpoint-url "${PGS3_ENDPOINT}" s3api list-object-versions \
  --bucket "${bucket}" --prefix "${key}"

aws --endpoint-url "${PGS3_ENDPOINT}" s3api get-object \
  --bucket "${bucket}" --key "${key}" --version-id "${version_id}" \
  "${destination}"
```

A normal delete creates a delete marker; older content remains addressable by
version ID. An explicit version delete permanently removes that version once no
other metadata references its content, so use it only when the task asks for
permanent removal.

## Restore a version

Restore is intentionally a pgs3 SQL operation. It creates a new latest version
that references the selected historical content; it does not rewrite history.

```bash
psql "${PGS3_DSN}" -X --set ON_ERROR_STOP=1 \
  --set bucket="${bucket}" --set key="${key}" --set version="${version_id}" <<'SQL'
SELECT pgs3.restore(:'bucket', :'key', :'version'::bigint);
SQL
```

Record the new version ID returned by `restore`. The connected PostgreSQL role
must be the same tenant role, or a role allowed to assume it.

## Fork a bucket

Fork copies the source bucket's latest metadata into a new bucket. Subsequent
writes are independent; referenced large-object content is shared until GC can
prove it is unreferenced.

```bash
psql "${PGS3_DSN}" -X --set ON_ERROR_STOP=1 \
  --set source="${source_bucket}" --set destination="${destination_bucket}" <<'SQL'
SELECT pgs3.fork_bucket(:'source', :'destination');
SQL
```

The destination must not already exist. Use a fork for a cheap experiment or
checkpoint, then write only to the destination. Verify the returned object count
and list the destination before relying on it.

## Operational boundaries

- Do not send virtual-host-style bucket URLs or expect pgs3 to terminate TLS.
- Prefer bounded prefix listings and ranged reads; do not scan a whole bucket to
  find one prefix.
- ETags are MD5-shaped compatibility identifiers (multipart ETags end in `-N`),
  not authorization tokens or general SHA-256 checksums.
- A standby may serve GET/LIST but must reject writes; retry writes against the
  primary endpoint rather than looping on the standby.
- Consult [the API mapping](docs/api-sql-mapping.md) for exact SQL semantics and
  [operations](docs/operations.md) before administrative or recovery work.

