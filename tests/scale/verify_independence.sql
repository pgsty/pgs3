\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.scale_assert(p_ok boolean, p_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT coalesce(p_ok, false) THEN
        RAISE EXCEPTION 'scale assertion failed: %', p_message;
    END IF;
END
$$;

SELECT pg_temp.scale_assert(
    (pgs3.get('scale-fork-destination', 'fork/key-000000000001')).body
        = convert_to('pgs3-scale-fork-body-1', 'UTF8'),
    'fork destination did not retain the source body'
);

SELECT pgs3.put(
    'scale-fork-source',
    'fork/key-000000000001',
    convert_to('source-mutated-after-fork', 'UTF8')
);
SELECT pg_temp.scale_assert(
    (pgs3.get('scale-fork-destination', 'fork/key-000000000001')).body
        = convert_to('pgs3-scale-fork-body-1', 'UTF8'),
    'source overwrite changed the destination'
);

SELECT pgs3.put(
    'scale-fork-destination',
    'fork/key-000000000001',
    convert_to('destination-mutated-after-fork', 'UTF8')
);
SELECT pg_temp.scale_assert(
    (pgs3.get('scale-fork-source', 'fork/key-000000000001')).body
        = convert_to('source-mutated-after-fork', 'UTF8'),
    'destination overwrite changed the source'
);

SELECT pgs3.put(
    'scale-fork-source',
    'fork/source-only',
    convert_to('source-only-body', 'UTF8')
);
SELECT pgs3.put(
    'scale-fork-destination',
    'fork/destination-only',
    convert_to('destination-only-body', 'UTF8')
);
SELECT pg_temp.scale_assert(
    NOT EXISTS (
        SELECT 1
          FROM pgs3.list_objects_v2(
              'scale-fork-destination', 'fork/source-only', NULL,
              NULL, NULL, 1000
          )
         WHERE key = 'fork/source-only'
    ),
    'source-only key leaked into the destination'
);
SELECT pg_temp.scale_assert(
    NOT EXISTS (
        SELECT 1
          FROM pgs3.list_objects_v2(
              'scale-fork-source', 'fork/destination-only', NULL,
              NULL, NULL, 1000
          )
         WHERE key = 'fork/destination-only'
    ),
    'destination-only key leaked into the source'
);

SELECT pgs3.delete('scale-fork-source', 'fork/key-000000000002');
SELECT pg_temp.scale_assert(
    (pgs3.get('scale-fork-destination', 'fork/key-000000000002')).body
        = convert_to(
            'pgs3-scale-fork-body-'
                || (1 + ((2 - 1) % (:'fork_blobs')::bigint))::text,
            'UTF8'
          ),
    'source delete changed the destination'
);

-- Refcount is reconciled against every owning object version, including the
-- old versions retained by the two overwrites and the new delete marker.
SELECT pg_temp.scale_assert(
    NOT EXISTS (
        SELECT 1
          FROM pgs3.blob AS b
          LEFT JOIN (
              SELECT o.blob_id, count(*)::bigint AS owners
                FROM pgs3.object AS o
               WHERE o.blob_id IS NOT NULL
               GROUP BY o.blob_id
          ) AS refs ON refs.blob_id = b.sha256
         WHERE b.refcount <> coalesce(refs.owners, 0)
    ),
    'blob refcount diverged from object-version ownership'
);

SELECT 'fork independence and refcount reconciliation passed' AS result;
