\set ON_ERROR_STOP on

-- The fixture is deliberately set-based.  These INSERTs leave all installed
-- triggers enabled, so object_blob_refs_insert computes the canonical blob
-- refcounts exactly as normal object publication and fork_bucket do.
BEGIN;

SELECT pgs3.create_bucket('scale-fork-source');
SELECT pgs3.create_bucket('scale-list');

CREATE TEMP TABLE scale_fork_payload
ON COMMIT DROP
AS
SELECT payload_id,
       body,
       pgs3.sha256(body) AS sha256,
       md5(body) AS etag
  FROM (
      SELECT g AS payload_id,
             convert_to('pgs3-scale-fork-body-' || g::text, 'UTF8') AS body
        FROM generate_series(1, (:'fork_blobs')::bigint) AS series(g)
  ) AS payload;

CREATE UNIQUE INDEX scale_fork_payload_id_idx
    ON scale_fork_payload (payload_id);
CREATE UNIQUE INDEX scale_fork_payload_sha_idx
    ON scale_fork_payload (sha256);

INSERT INTO pgs3.blob (
    sha256, size, chunk_size, storage_kind, inline
)
SELECT p.sha256,
       octet_length(p.body),
       pgs3._setting_bytes('pgs3.chunk_size', 1048576)::integer,
       'inline',
       p.body
  FROM scale_fork_payload AS p;

INSERT INTO pgs3.object (
    bucket_id, key, is_latest, delete_marker, size, etag, sha256,
    content_type, meta, inline, blob_id, created_by
)
SELECT b.bucket_id,
       'fork/key-' || lpad(g::text, 12, '0'),
       true,
       false,
       octet_length(p.body),
       p.etag,
       p.sha256,
       'application/octet-stream',
       jsonb_build_object('fixture', 'fork', 'ordinal', g),
       NULL,
       p.sha256,
       current_user::name
  FROM generate_series(1, (:'fork_objects')::bigint) AS series(g)
  JOIN scale_fork_payload AS p
    ON p.payload_id = 1 + ((g - 1) % (:'fork_blobs')::bigint)
 CROSS JOIN pgs3.bucket AS b
 WHERE b.name = 'scale-fork-source' COLLATE "C";

CREATE TEMP TABLE scale_list_payload
ON COMMIT DROP
AS
SELECT body,
       pgs3.sha256(body) AS sha256,
       md5(body) AS etag
  FROM (
      SELECT convert_to('pgs3-scale-list-shared-body', 'UTF8') AS body
  ) AS payload;

INSERT INTO pgs3.blob (
    sha256, size, chunk_size, storage_kind, inline
)
SELECT p.sha256,
       octet_length(p.body),
       pgs3._setting_bytes('pgs3.chunk_size', 1048576)::integer,
       'inline',
       p.body
  FROM scale_list_payload AS p;

-- Prefix assignment is round-robin at load time but bytewise-clustered by the
-- production object_latest_live_uniq covering index at read time.  At the
-- acceptance defaults this is exactly 1,000 children below each of 1,000 child
-- prefixes.
INSERT INTO pgs3.object (
    bucket_id, key, is_latest, delete_marker, size, etag, sha256,
    content_type, meta, inline, blob_id, created_by
)
SELECT b.bucket_id,
       'tree/'
           || lpad((1 + ((g - 1) % (:'child_prefixes')::bigint))::text, 6, '0')
           || '/'
           || lpad((1 + ((g - 1) / (:'child_prefixes')::bigint))::text, 12, '0'),
       true,
       false,
       octet_length(p.body),
       p.etag,
       p.sha256,
       'application/octet-stream',
       '{}'::jsonb,
       NULL,
       p.sha256,
       current_user::name
  FROM generate_series(1, (:'list_keys')::bigint) AS series(g)
 CROSS JOIN scale_list_payload AS p
 CROSS JOIN pgs3.bucket AS b
 WHERE b.name = 'scale-list' COLLATE "C";

COMMIT;

-- Plans and transition-trigger updates need representative statistics.  No
-- durability setting is weakened: the runner keeps fsync, full_page_writes,
-- and synchronous_commit enabled throughout setup and measurement.
VACUUM (ANALYZE) pgs3.object;
VACUUM (ANALYZE) pgs3.blob;
CHECKPOINT;

SELECT b.name AS bucket,
       count(*) FILTER (WHERE o.is_latest AND NOT o.delete_marker) AS latest_live,
       count(DISTINCT o.blob_id) AS referenced_blobs
  FROM pgs3.bucket AS b
  LEFT JOIN pgs3.object AS o ON o.bucket_id = b.bucket_id
 WHERE b.name IN ('scale-fork-source', 'scale-list')
 GROUP BY b.name
 ORDER BY b.name COLLATE "C";
