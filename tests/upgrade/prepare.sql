\set ON_ERROR_STOP on

DO $version$
BEGIN
    ASSERT (
        SELECT extversion = '0.1.0'
          FROM pg_catalog.pg_extension
         WHERE extname = 'pgs3'
    ), 'upgrade fixture must start at pgs3 0.1.0';
    ASSERT to_regprocedure('pgs3.extension_version()') IS NULL;
    ASSERT to_regprocedure('pgs3._worker_set_actor(name)') IS NULL;
    ASSERT to_regprocedure(
        'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)'
    ) IS NULL;
    ASSERT to_regprocedure(
        'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])'
    ) IS NULL;
END
$version$;

CREATE ROLE pgs3_upgrade_tenant_a
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
CREATE ROLE pgs3_upgrade_tenant_b
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;

SELECT pgs3.create_credential(
    'UPGRADEACCESSA', 'upgrade-secret-a', 'pgs3_upgrade_tenant_a', true
);
SELECT pgs3.create_credential(
    'UPGRADEACCESSB', 'upgrade-secret-b', 'pgs3_upgrade_tenant_b', true
);

SET ROLE pgs3_upgrade_tenant_a;

DO $tenant_a_fixture$
DECLARE
    v_first pgs3.object_info;
    v_part pgs3.part_info;
    v_upload uuid;
BEGIN
    PERFORM pgs3.create_bucket('upgrade-a');
    PERFORM pgs3.put(
        'upgrade-a', 'inline.txt', convert_to('tiny', 'UTF8'), 'text/plain'
    );
    PERFORM pgs3.put(
        'upgrade-a', 'chunked.bin',
        convert_to('chunked-payload-before-upgrade', 'UTF8')
    );
    PERFORM pgs3.copy(
        'upgrade-a', 'chunked.bin', 'upgrade-a', 'copied.bin'
    );

    v_first := pgs3.put(
        'upgrade-a', 'restored.txt', convert_to('first', 'UTF8')
    );
    PERFORM pgs3.put(
        'upgrade-a', 'restored.txt', convert_to('second', 'UTF8')
    );
    PERFORM pgs3.delete('upgrade-a', 'restored.txt');
    PERFORM pgs3.restore(
        'upgrade-a', 'restored.txt', v_first.version_id
    );

    PERFORM pgs3.put(
        'upgrade-a', 'marker.txt', convert_to('deleted', 'UTF8')
    );
    PERFORM pgs3.delete('upgrade-a', 'marker.txt');

    v_upload := pgs3.begin_upload(
        'upgrade-a', 'multipart.bin', p_multipart => true
    );
    v_part := pgs3.put_part(
        v_upload, 1, convert_to('multipart-body', 'UTF8')
    );
    PERFORM pgs3.complete_multipart_upload(
        v_upload, ARRAY[1], ARRAY[v_part.etag]
    );

    ASSERT pgs3.fork_bucket('upgrade-a', 'upgrade-a-fork') = 6,
           'fixture fork must copy six latest rows, including the marker';

    v_upload := pgs3.begin_upload('upgrade-a', 'pending.bin');
    PERFORM pgs3.put_chunk(
        v_upload, 0, convert_to('pending-body', 'UTF8')
    );
END
$tenant_a_fixture$;

RESET ROLE;
SET ROLE pgs3_upgrade_tenant_b;

SELECT pgs3.create_bucket('upgrade-b');
SELECT pgs3.put(
    'upgrade-b', 'private.txt', convert_to('tenant-b-only', 'UTF8')
);

RESET ROLE;

CREATE FUNCTION public.pgs3_upgrade_fingerprint()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pgs3
AS $fingerprint$
    SELECT md5(jsonb_build_object(
        'bucket', (
            SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.bucket_id), '[]')
              FROM pgs3.bucket AS x
        ),
        'blob', (
            SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.sha256), '[]')
              FROM pgs3.blob AS x
        ),
        'object', (
            SELECT coalesce(jsonb_agg(
                       to_jsonb(x) ORDER BY x.bucket_id, x.key, x.version_id
                   ), '[]')
              FROM pgs3.object AS x
        ),
        'chunk', (
            SELECT coalesce(jsonb_agg(
                       to_jsonb(x) ORDER BY x.blob_id, x.seq
                   ), '[]')
              FROM pgs3.chunk AS x
        ),
        'blob_extent', (
            SELECT coalesce(jsonb_agg(
                       to_jsonb(x) ORDER BY x.final_blob_id, x.seq
                   ), '[]')
              FROM pgs3.blob_extent AS x
        ),
        'upload', (
            SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.upload_id), '[]')
              FROM pgs3.upload AS x
        ),
        'upload_chunk', (
            SELECT coalesce(jsonb_agg(
                       to_jsonb(x) ORDER BY x.upload_id, x.part_number, x.seq
                   ), '[]')
              FROM pgs3.upload_chunk AS x
        ),
        'upload_part', (
            SELECT coalesce(jsonb_agg(
                       to_jsonb(x) ORDER BY x.upload_id, x.part_number
                   ), '[]')
              FROM pgs3.upload_part AS x
        ),
        'credential', (
            SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.access_key), '[]')
              FROM pgs3.credential AS x
        )
    )::text)
$fingerprint$;

CREATE FUNCTION public.pgs3_assert_upgrade_fixture()
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pgs3
AS $assert_fixture$
BEGIN
    ASSERT (pgs3.get('upgrade-a', 'inline.txt')).body
           = convert_to('tiny', 'UTF8');
    ASSERT (pgs3.get('upgrade-a', 'chunked.bin')).body
           = convert_to('chunked-payload-before-upgrade', 'UTF8');
    ASSERT (pgs3.get('upgrade-a', 'copied.bin')).body
           = convert_to('chunked-payload-before-upgrade', 'UTF8');
    ASSERT (pgs3.get('upgrade-a', 'restored.txt')).body
           = convert_to('first', 'UTF8');
    ASSERT (pgs3.get('upgrade-a', 'multipart.bin')).body
           = convert_to('multipart-body', 'UTF8');
    ASSERT (pgs3.get('upgrade-a-fork', 'chunked.bin')).body
           = convert_to('chunked-payload-before-upgrade', 'UTF8');
    ASSERT (pgs3.get('upgrade-b', 'private.txt')).body
           = convert_to('tenant-b-only', 'UTF8');

    ASSERT EXISTS (
        SELECT 1
          FROM pgs3.blob
         WHERE storage_kind = 'inline'
           AND inline = convert_to('tiny', 'UTF8')
    ), 'inline fixture is missing';
    ASSERT EXISTS (
        SELECT 1
          FROM pgs3.object AS o
          JOIN pgs3.bucket AS b USING (bucket_id)
         WHERE b.name = 'upgrade-a'
           AND o.key = 'chunked.bin'
           AND o.is_latest
           AND EXISTS (
               SELECT 1 FROM pgs3.chunk AS c WHERE c.blob_id = o.blob_id
           )
    ), 'chunked fixture is missing';
    ASSERT EXISTS (
        SELECT 1
          FROM pgs3.object AS o
          JOIN pgs3.bucket AS b USING (bucket_id)
         WHERE b.name = 'upgrade-a'
           AND o.key = 'marker.txt'
           AND o.is_latest
           AND o.delete_marker
    ), 'delete marker fixture is missing';
    ASSERT EXISTS (
        SELECT 1
          FROM pgs3.object AS o
          JOIN pgs3.bucket AS b USING (bucket_id)
         WHERE b.name = 'upgrade-a'
           AND o.key = 'multipart.bin'
           AND o.is_latest
           AND o.etag LIKE '%-1'
    ), 'multipart fixture is missing';
    ASSERT EXISTS (
        SELECT 1
          FROM pgs3.upload AS u
          JOIN pgs3.bucket AS b USING (bucket_id)
         WHERE b.name = 'upgrade-a'
           AND u.key = 'pending.bin'
           AND u.state = 'pending'
           AND EXISTS (
               SELECT 1
                 FROM pgs3.upload_chunk AS c
                WHERE c.upload_id = u.upload_id
           )
    ), 'pending upload fixture is missing';
END
$assert_fixture$;

SELECT public.pgs3_assert_upgrade_fixture();

CREATE TABLE public.pgs3_upgrade_expected (
    name text PRIMARY KEY,
    value text NOT NULL
);
INSERT INTO public.pgs3_upgrade_expected(name, value)
VALUES ('data_fingerprint', public.pgs3_upgrade_fingerprint());

SET ROLE pgs3_upgrade_tenant_a;
DO $tenant_a_isolation$
BEGIN
    ASSERT (SELECT count(*) FROM pgs3.list_buckets()) = 2;
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.list_buckets() WHERE name = 'upgrade-b'
    );
END
$tenant_a_isolation$;
RESET ROLE;

SET ROLE pgs3_upgrade_tenant_b;
DO $tenant_b_isolation$
BEGIN
    ASSERT (SELECT count(*) FROM pgs3.list_buckets()) = 1;
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.list_buckets() WHERE name = 'upgrade-a'
    );
END
$tenant_b_isolation$;
RESET ROLE;

SELECT 'pgs3 0.1.0 upgrade fixture: ok' AS result;
