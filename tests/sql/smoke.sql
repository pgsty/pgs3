\set ON_ERROR_STOP on

-- Catalog-level installation smoke test.  Unlike semantic.sql, this checks the
-- packaged extension (including Rust functions), not a standalone bootstrap.
DO $smoke$
DECLARE
    v_predicate text;
    v_index_definition text;
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pgs3'
    ), 'pgs3 extension is not installed';
    ASSERT pgs3.extension_version() = '0.1.1',
           'pgs3 extension catalog version is not 0.1.1';
    ASSERT to_regnamespace('pgs3') IS NOT NULL;

    ASSERT to_regclass('pgs3.bucket') IS NOT NULL;
    ASSERT to_regclass('pgs3.object') IS NOT NULL;
    ASSERT to_regclass('pgs3.blob') IS NOT NULL;
    ASSERT to_regclass('pgs3.chunk') IS NOT NULL;
    ASSERT to_regclass('pgs3.blob_extent') IS NOT NULL;
    ASSERT to_regclass('pgs3.upload') IS NOT NULL;
    ASSERT to_regclass('pgs3.upload_chunk') IS NOT NULL;
    ASSERT to_regclass('pgs3.upload_part') IS NOT NULL;
    ASSERT to_regclass('pgs3.credential') IS NOT NULL;

    ASSERT (
        SELECT count(*) = 16
          FROM pg_inherits AS i
         WHERE i.inhparent = 'pgs3.chunk'::regclass
    ), 'chunk must have sixteen hash partitions';
    ASSERT (
        SELECT a.attstorage = 'e'
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.chunk'::regclass
           AND a.attname = 'data'
           AND NOT a.attisdropped
    ), 'chunk.data must use EXTERNAL storage';
    ASSERT EXISTS (
        SELECT 1
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.object'::regclass
           AND a.attname = 'inline'
           AND a.atttypid = 'bytea'::regtype
    ), 'object.inline bytea is missing';
    ASSERT EXISTS (
        SELECT 1
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.blob'::regclass
           AND a.attname = 'inline'
           AND a.atttypid = 'bytea'::regtype
           AND a.attstorage = 'e'
    ), 'canonical blob.inline bytea must use EXTERNAL storage';
    ASSERT EXISTS (
        SELECT 1
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.upload_chunk'::regclass
           AND a.attname = 'blob_id'
           AND a.atttypid = 'bytea'::regtype
           AND NOT a.attisdropped
    ) AND NOT EXISTS (
        SELECT 1
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.upload_chunk'::regclass
           AND a.attname = 'data'
           AND NOT a.attisdropped
    ), 'pending chunks must reference canonical blobs, not duplicate payloads';
    ASSERT EXISTS (
        SELECT 1
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.upload_part'::regclass
           AND a.attname = 'blob_id'
           AND a.atttypid = 'bytea'::regtype
    ), 'multipart parts must own canonical blobs';
    ASSERT EXISTS (
        SELECT 1
          FROM pg_attribute AS a
         WHERE a.attrelid = 'pgs3.upload'::regclass
           AND a.attname = 'lease_expires_at'
           AND a.atttypid = 'timestamptz'::regtype
           AND a.attnotnull
           AND NOT a.attisdropped
    ), 'pending uploads must have a non-null lease deadline';

    SELECT pg_get_expr(i.indpred, i.indrelid),
           pg_get_indexdef(i.indexrelid)
      INTO STRICT v_predicate, v_index_definition
      FROM pg_index AS i
     WHERE i.indexrelid = 'pgs3.object_latest_live_uniq'::regclass;
    ASSERT v_predicate LIKE '%is_latest%NOT delete_marker%',
           'latest-live partial unique index has the wrong predicate';
    ASSERT v_index_definition LIKE
               '%INCLUDE (version_id, size, etag, content_type, created_at)%',
           'latest-live index must cover the bounded LIST projection';
    ASSERT to_regclass('pgs3.object_list_idx') IS NULL,
           'LIST must not duplicate the latest-live partial B-tree';

    ASSERT (
        SELECT bool_and(c.relrowsecurity)
          FROM pg_class AS c
         WHERE c.oid = ANY (ARRAY[
             'pgs3.bucket'::regclass,
             'pgs3.object'::regclass,
             'pgs3.blob'::regclass,
             'pgs3.chunk'::regclass,
             'pgs3.blob_extent'::regclass,
             'pgs3.upload'::regclass
         ])
    ), 'tenant-facing tables must have RLS enabled';

    ASSERT to_regprocedure('pgs3.sha256(bytea)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.start()') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.stop()') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.put(text,text,bytea,text,jsonb,text,text,bytea)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.get(text,text,bigint,text,text)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.list(text,text,text,text,text,integer)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.complete_upload(uuid,integer[],text[],bytea)') IS NOT NULL;
    ASSERT to_regprocedure(
        'pgs3.complete_multipart_upload(text,text,uuid,integer[],text[],bytea,bytea[],text)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'pgs3.multipart_checksum_algorithm(text,text,uuid)'
    ) IS NOT NULL;
    ASSERT to_regprocedure('pgs3.renew_upload(uuid)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.renew_upload(text,text,uuid,boolean)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.begin_part(uuid,integer)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.abort_part(uuid,integer)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.fork_bucket(text,text,jsonb)') IS NOT NULL;
    ASSERT to_regprocedure('pgs3.set_credential_role(text,name)') IS NOT NULL;
END
$smoke$;

-- The live worker owns in-flight as a gauge, not a cumulative counter.  A new
-- PID for the same stable slot must discard a crashed predecessor's gauge, and
-- a late/duplicate decrement must clamp rather than make the exported value
-- negative.  Operation labels are an allow-list so request data cannot create
-- exporter cardinality.
DO $metric_smoke$
DECLARE
    v_metric pgs3.worker_metric%ROWTYPE;
    v_rejected_dynamic_label boolean := false;
BEGIN
    INSERT INTO pgs3.worker_metric (
        worker_kind, worker_slot, pid, operation, requests, errors,
        bytes_in, bytes_out, in_flight, latency_us
    ) VALUES (
        'http', 2147483647, -1, 'InvalidRequest', 10, 2,
        100, 200, 7, 300
    );

    PERFORM pgs3._worker_add_metric(
        'http', 2147483647, 'InvalidRequest',
        1, 1, 11, 13, 1, 17,
        1, 1, 1, 1, 1, 1, 1
    );
    SELECT * INTO STRICT v_metric
      FROM pgs3.worker_metric
     WHERE worker_kind = 'http'
       AND worker_slot = 2147483647
       AND operation = 'InvalidRequest';
    ASSERT v_metric.pid = pg_backend_pid();
    ASSERT v_metric.requests = 11 AND v_metric.errors = 3;
    ASSERT v_metric.bytes_in = 111 AND v_metric.bytes_out = 213;
    ASSERT v_metric.in_flight = 1,
           'replacement PID must reset the predecessor in-flight gauge';

    PERFORM pgs3._worker_add_metric(
        'http', 2147483647, 'InvalidRequest',
        0, 0, 0, 0, -2, 0,
        0, 0, 0, 0, 0, 0, 0
    );
    SELECT * INTO STRICT v_metric
      FROM pgs3.worker_metric
     WHERE worker_kind = 'http'
       AND worker_slot = 2147483647
       AND operation = 'InvalidRequest';
    ASSERT v_metric.in_flight = 0,
           'in-flight gauge must clamp at zero after a late decrement';

    BEGIN
        INSERT INTO pgs3.worker_metric (
            worker_kind, worker_slot, pid, operation
        ) VALUES (
            'http', 2147483646, pg_backend_pid(), 'bucket-controlled-label'
        );
    EXCEPTION WHEN check_violation THEN
        v_rejected_dynamic_label := true;
    END;
    ASSERT v_rejected_dynamic_label,
           'worker_metric must reject non-allow-listed operation labels';

    DELETE FROM pgs3.worker_metric
     WHERE worker_kind = 'http'
       AND worker_slot IN (2147483646, 2147483647);
END
$metric_smoke$;

SELECT 'pgs3 install smoke: ok' AS result;
