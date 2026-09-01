\set ON_ERROR_STOP on

-- Plain-SQL regression suite.  Run after CREATE EXTENSION pgs3 as a
-- superuser; every failure is an ASSERT or an uncaught exception.
BEGIN;

SET LOCAL client_min_messages = warning;

-- Packaged pgrx GUCs are SIGHUP settings and must be supplied when the test
-- postmaster starts.  A standalone bootstrap.sql run has no registered GUCs,
-- so define equivalent custom settings locally for that development path.
DO $test_storage_settings$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_settings
         WHERE name = 'pgs3.inline_threshold'
    ) THEN
        PERFORM pg_catalog.set_config('pgs3.inline_threshold', '8B', true);
        PERFORM pg_catalog.set_config('pgs3.chunk_size', '1MB', true);
    END IF;
    ASSERT pg_catalog.current_setting('pgs3.inline_threshold') = '8B',
           'semantic test requires pgs3.inline_threshold=8B at postmaster start';
    ASSERT pg_catalog.current_setting('pgs3.chunk_size') = '1MB',
           'semantic test requires pgs3.chunk_size=1MB at postmaster start';
END
$test_storage_settings$;

CREATE ROLE pgs3_sql_tenant_a NOLOGIN;
CREATE ROLE pgs3_sql_tenant_b NOLOGIN;

SET LOCAL ROLE pgs3_sql_tenant_a;

DO $test_bucket_object$
DECLARE
    v_first pgs3.object_info;
    v_second pgs3.object_info;
    v_current pgs3.object_info;
    v_data pgs3.object_data;
    v_deleted pgs3.delete_result;
    v_original pgs3.bucket_info;
    v_reopened pgs3.bucket_info;
    v_object_count bigint;
BEGIN
    PERFORM pgs3.create_bucket(
        'sql-tenant-a',
        '{"region":"us-east-1","retained":"original"}'::jsonb
    );
    ASSERT (SELECT count(*) FROM pgs3.list_buckets()) = 1,
           'tenant A should see its bucket';
    ASSERT pgs3.get_bucket_location('sql-tenant-a') = 'us-east-1';
    ASSERT pgs3.get_bucket_versioning('sql-tenant-a') = 'Enabled';

    v_first := pgs3.put(
        'sql-tenant-a', 'small.txt', convert_to('one', 'UTF8'), 'text/plain'
    );
    ASSERT v_first.version_id IS NOT NULL;
    ASSERT v_first.etag = md5(convert_to('one', 'UTF8'));
    ASSERT v_first.size = 3;

    v_original := pgs3.head_bucket('sql-tenant-a');
    SELECT count(*)
      INTO v_object_count
      FROM pgs3.list_versions('sql-tenant-a');

    v_reopened := pgs3.create_bucket(
        'sql-tenant-a',
        '{"region":"us-east-1","retained":"replacement"}'::jsonb
    );
    ASSERT v_reopened = v_original,
           'same-owner us-east-1 bucket reopen must retain the canonical row';
    ASSERT pgs3.head_bucket('sql-tenant-a') = v_original;
    ASSERT (
        SELECT count(*)
          FROM pgs3.list_versions('sql-tenant-a')
    ) = v_object_count,
    'same-owner us-east-1 bucket reopen must retain child objects';
    ASSERT (pgs3.get('sql-tenant-a', 'small.txt')).body = convert_to('one', 'UTF8');

    v_data := pgs3.get('sql-tenant-a', 'small.txt');
    ASSERT v_data.body = convert_to('one', 'UTF8');
    ASSERT (v_data.info).version_id = v_first.version_id;

    BEGIN
        PERFORM pgs3.put(
            'sql-tenant-a', 'small.txt', convert_to('blocked', 'UTF8'),
            p_if_none_match => '*'
        );
        ASSERT false, 'If-None-Match:* should fail for a live key';
    EXCEPTION WHEN SQLSTATE 'P3C01' THEN
        NULL;
    END;

    BEGIN
        PERFORM pgs3.put(
            'sql-tenant-a', 'small.txt', convert_to('blocked', 'UTF8'),
            p_if_match => '00000000000000000000000000000000'
        );
        ASSERT false, 'wrong If-Match should fail';
    EXCEPTION WHEN SQLSTATE 'P3C01' THEN
        NULL;
    END;

    v_second := pgs3.put(
        'sql-tenant-a', 'small.txt', convert_to('two', 'UTF8'),
        p_if_match => v_first.etag
    );
    ASSERT v_second.version_id > v_first.version_id,
           'versions must increase monotonically';
    ASSERT (pgs3.get('sql-tenant-a', 'small.txt')).body = convert_to('two', 'UTF8');

    v_deleted := pgs3.delete('sql-tenant-a', 'small.txt');
    ASSERT v_deleted.delete_marker AND v_deleted.deleted;
    BEGIN
        PERFORM pgs3.get('sql-tenant-a', 'small.txt');
        ASSERT false, 'a latest delete marker should hide older versions';
    EXCEPTION WHEN SQLSTATE 'P3K01' THEN
        NULL;
    END;

    v_current := pgs3.restore('sql-tenant-a', 'small.txt', v_first.version_id);
    ASSERT v_current.version_id > v_deleted.version_id;
    ASSERT (pgs3.get('sql-tenant-a', 'small.txt')).body = convert_to('one', 'UTF8');
    ASSERT pgs3.get_range('sql-tenant-a', 'small.txt', 1, 2) = convert_to('ne', 'UTF8');
END
$test_bucket_object$;

-- Stable DETAIL tokens are the request-boundary contract.  pgrx may surface a
-- custom P3xxx SQLSTATE as XX000, so no caller may infer the S3 code from the
-- human MESSAGE.  Every representative below also uses a sentinel in its
-- request input and proves that DETAIL does not echo it.
DO $test_semantic_error_details$
DECLARE
    v_detail text;
    v_message text;
    v_current pgs3.object_info;
    v_upload uuid;
    v_part_one pgs3.part_info;
    v_part_two pgs3.part_info;
BEGIN
    BEGIN
        PERFORM pgs3.head_bucket('detail-leak-sentinel-bucket');
        ASSERT false, 'missing bucket must fail';
    EXCEPTION WHEN SQLSTATE 'P3B01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NoSuchBucket';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.create_bucket('_detail-leak-sentinel-invalid-bucket');
        ASSERT false, 'invalid bucket name must fail';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        GET STACKED DIAGNOSTICS
            v_detail = PG_EXCEPTION_DETAIL,
            v_message = MESSAGE_TEXT;
        ASSERT v_detail = 'pgs3.error=InvalidBucketName';
        ASSERT v_message = 'InvalidBucketName';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
        ASSERT position('detail-leak-sentinel' IN v_message) = 0;
    END;

    BEGIN
        PERFORM pgs3.delete_bucket('sql-tenant-a');
        ASSERT false, 'nonempty bucket deletion must fail';
    EXCEPTION WHEN SQLSTATE 'P3F01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=BucketNotEmpty';
        ASSERT position('sql-tenant-a' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.get('sql-tenant-a', 'detail-leak-sentinel-key');
        ASSERT false, 'missing current key must fail';
    EXCEPTION WHEN SQLSTATE 'P3K01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NoSuchKey';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.head(
            'sql-tenant-a', 'small.txt', 9223372036854775807
        );
        ASSERT false, 'missing explicit version must fail';
    EXCEPTION WHEN SQLSTATE 'P3K01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NoSuchVersion';
        ASSERT position('small.txt' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.copy(
            'sql-tenant-a', 'small.txt',
            'sql-tenant-a', 'detail-leak-sentinel-copy',
            p_source_version_id => 9223372036854775807
        );
        ASSERT false, 'missing explicit copy-source version must fail';
    EXCEPTION WHEN SQLSTATE 'P3K01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NoSuchVersion';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
        ASSERT position('small.txt' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.begin_part(
            '00000000-0000-0000-0000-000000000001'::uuid, 1
        );
        ASSERT false, 'missing upload must fail';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NoSuchUpload';
        ASSERT position('00000000' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.head(
            'sql-tenant-a', 'small.txt',
            p_if_match => 'detail-leak-sentinel-etag'
        );
        ASSERT false, 'wrong If-Match must fail';
    EXCEPTION WHEN SQLSTATE 'P3C01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=PreconditionFailed';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;

    v_current := pgs3.head('sql-tenant-a', 'small.txt');
    BEGIN
        PERFORM pgs3.head(
            'sql-tenant-a', 'small.txt',
            p_if_none_match => v_current.etag
        );
        ASSERT false, 'matching If-None-Match must fail';
    EXCEPTION WHEN SQLSTATE 'P3N01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NotModified';
        ASSERT position(v_current.etag IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.put(
            'sql-tenant-a', 'detail-leak-sentinel-digest',
            convert_to('checksum-input', 'UTF8'),
            p_checksum_sha256 => decode(repeat('00', 32), 'hex')
        );
        ASSERT false, 'wrong checksum must fail';
    EXCEPTION WHEN SQLSTATE 'P3H01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=BadDigest';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.get_range('sql-tenant-a', 'small.txt', 999, 1000);
        ASSERT false, 'unsatisfiable range must fail';
    EXCEPTION WHEN SQLSTATE 'P3R01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=InvalidRange';
        ASSERT position('small.txt' IN v_detail) = 0;
    END;

    -- The size guard runs before upload lookup.  This intentionally allocates
    -- one byte over the 64 MiB request-chunk ceiling to execute the real branch.
    BEGIN
        PERFORM pgs3.put_chunk(
            '00000000-0000-0000-0000-000000000002'::uuid,
            0, decode(repeat('00', 67108865), 'hex'), 0
        );
        ASSERT false, 'oversize upload chunk must fail';
    EXCEPTION WHEN SQLSTATE 'P3S01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=EntityTooLarge';
        ASSERT position('00000000' IN v_detail) = 0;
    END;

    v_upload := pgs3.begin_upload(
        'sql-tenant-a', 'detail-leak-sentinel-multipart',
        p_multipart => true
    );
    BEGIN
        PERFORM pgs3.begin_part(v_upload, 0);
        ASSERT false, 'part zero must fail';
    EXCEPTION WHEN SQLSTATE 'P3P01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=InvalidPart';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;

    BEGIN
        PERFORM pgs3.complete_upload(v_upload, ARRAY[2, 1]);
        ASSERT false, 'descending part order must fail';
    EXCEPTION WHEN SQLSTATE 'P3P01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=InvalidPartOrder';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;

    v_part_one := pgs3.put_part(
        v_upload, 1, convert_to('short-first-part', 'UTF8')
    );
    v_part_two := pgs3.put_part(
        v_upload, 2, convert_to('last-part', 'UTF8')
    );
    BEGIN
        PERFORM pgs3.complete_upload(
            v_upload,
            ARRAY[v_part_one.part_number, v_part_two.part_number],
            ARRAY[v_part_one.etag, v_part_two.etag]
        );
        ASSERT false, 'non-final short multipart part must fail';
    EXCEPTION WHEN SQLSTATE 'P3P01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=EntityTooSmall';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;
    ASSERT pgs3.abort_upload(v_upload);
END
$test_semantic_error_details$;

DO $test_blob_copy_fork_list$
DECLARE
    v_large pgs3.object_info;
    v_copy pgs3.object_info;
    v_forked bigint;
    v_first_page pgs3.list_entry;
    v_replication_role text := current_setting('session_replication_role');
BEGIN
    v_large := pgs3.put(
        'sql-tenant-a', 'large-a.bin', convert_to('abcdefghijklmnop', 'UTF8')
    );
    PERFORM pgs3.put(
        'sql-tenant-a', 'large-b.bin', convert_to('abcdefghijklmnop', 'UTF8')
    );
    v_copy := pgs3.copy(
        'sql-tenant-a', 'large-a.bin', 'sql-tenant-a', 'large-copy.bin'
    );
    ASSERT v_copy.sha256 = v_large.sha256;
    ASSERT v_copy.etag = v_large.etag;
    ASSERT pgs3.get_range('sql-tenant-a', 'large-copy.bin', 3, 10)
           = convert_to('defghijk', 'UTF8');

    PERFORM pgs3.put('sql-tenant-a', 'dir/a', convert_to('a', 'UTF8'));
    PERFORM pgs3.put('sql-tenant-a', 'dir/b', convert_to('b', 'UTF8'));
    PERFORM pgs3.put('sql-tenant-a', 'dir/nested/c', convert_to('c', 'UTF8'));
    PERFORM pgs3.put('sql-tenant-a', 'root', convert_to('r', 'UTF8'));

    ASSERT (SELECT count(*) FROM pgs3.list_objects_v1(
        'sql-tenant-a', '', NULL, NULL, 0
    )) = 0, 'ListObjects V1 max-keys=0 must be an empty, non-resumable page';
    ASSERT (SELECT count(*) FROM pgs3.list_objects_v2(
        'sql-tenant-a', '', NULL, NULL, NULL, 0
    )) = 0, 'ListObjects V2 max-keys=0 must be an empty, non-resumable page';
    ASSERT (SELECT count(*) FROM pgs3.list_versions(
        'sql-tenant-a', '', NULL, NULL, NULL, 0
    )) = 0, 'ListVersions max-keys=0 must be an empty, non-resumable page';

    ASSERT (
        SELECT count(*) FROM pgs3.list('sql-tenant-a', '', '/', NULL, NULL, 1000)
         WHERE common_prefix = 'dir/'
    ) = 1, 'delimiter list should emit one jumped common prefix';
    ASSERT (
        SELECT count(*) FROM pgs3.list('sql-tenant-a', 'dir/', '/', NULL, NULL, 1000)
         WHERE key IN ('dir/a', 'dir/b')
    ) = 2, 'delimiter list should include direct children';
    ASSERT (
        SELECT count(*) FROM pgs3.list('sql-tenant-a', 'dir/', '/', NULL, NULL, 1000)
         WHERE common_prefix = 'dir/nested/'
    ) = 1, 'nested prefix should be emitted once';

    SELECT page.* INTO STRICT v_first_page
      FROM pgs3.list('sql-tenant-a', 'dir/', NULL, NULL, NULL, 1) AS page;
    ASSERT (
        SELECT count(*)
          FROM pgs3.list(
              'sql-tenant-a', 'dir/', NULL, NULL,
              v_first_page.continuation_token, 1000
          ) AS next_page
         WHERE next_page.key > v_first_page.key COLLATE "C"
    ) >= 1, 'continuation token must resume strictly after the prior key';

    v_forked := pgs3.fork_bucket('sql-tenant-a', 'sql-tenant-a-fork');
    ASSERT current_setting('session_replication_role') = v_replication_role,
           'fork must restore the caller trigger mode';
    ASSERT v_forked = (
        SELECT count(*) FROM pgs3.list_versions('sql-tenant-a-fork') WHERE is_latest
    );
    ASSERT (pgs3.get('sql-tenant-a-fork', 'large-a.bin')).body
           = convert_to('abcdefghijklmnop', 'UTF8');
    PERFORM pgs3.put('sql-tenant-a-fork', 'fork-only', convert_to('x', 'UTF8'));
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.list('sql-tenant-a') WHERE key = 'fork-only'
    ), 'fork writes must not affect the source bucket';
END
$test_blob_copy_fork_list$;

DO $test_uploads$
DECLARE
    v_upload uuid;
    v_multipart uuid;
    v_info pgs3.object_info;
    v_part_one pgs3.part_info;
    v_part_two pgs3.part_info;
    v_part_one_body bytea;
    v_part_two_body bytea;
    v_expected_etag text;
    v_composite_checksum_sha256 text;
BEGIN
    v_upload := pgs3.begin_upload('sql-tenant-a', 'streamed.bin');
    PERFORM pgs3.put_chunk(v_upload, 0, convert_to('abcd', 'UTF8'));
    PERFORM pgs3.put_chunk(v_upload, 1, convert_to('efgh', 'UTF8'));
    v_info := pgs3.complete_upload(v_upload);
    ASSERT v_info.etag = md5(convert_to('abcdefgh', 'UTF8'));
    ASSERT (pgs3.get('sql-tenant-a', 'streamed.bin')).body
           = convert_to('abcdefgh', 'UTF8');

    v_upload := pgs3.begin_upload('sql-tenant-a', 'streamed-large.bin');
    PERFORM pgs3.put_chunk(v_upload, 0, convert_to('stream-A', 'UTF8'));
    PERFORM pgs3.put_chunk(v_upload, 1, convert_to('stream-B', 'UTF8'));
    v_info := pgs3.complete_upload(v_upload);
    ASSERT v_info.etag = md5(convert_to('stream-Astream-B', 'UTF8'));
    ASSERT (pgs3.get('sql-tenant-a', 'streamed-large.bin')).body
           = convert_to('stream-Astream-B', 'UTF8');

    v_multipart := pgs3.begin_upload(
        'sql-tenant-a', 'multipart.bin',
        p_meta => jsonb_build_object(
            '@pgs3:checksum-algorithm', 'SHA256'
        ),
        p_multipart => true
    );
    ASSERT pgs3.multipart_checksum_algorithm(
               'sql-tenant-a', 'multipart.bin', v_multipart
           ) = 'SHA256',
           'CreateMultipartUpload must retain its selected checksum algorithm';
    -- Multipart's first part must be at least 5 MiB.  Use a practical physical
    -- The test postmaster uses the production-default 1 MiB chunk size, which
    -- avoids creating an artificial number of rows for this 5 MiB part.
    v_part_one_body := convert_to(repeat('a', 5242880), 'UTF8');
    v_part_two_body := convert_to('-tail', 'UTF8');
    ASSERT pgs3.begin_part(v_multipart, 1);
    v_part_one := pgs3.put_part(
        v_multipart, 1, v_part_one_body
    );
    ASSERT pgs3.begin_part(v_multipart, 2);
    v_part_two := pgs3.put_part(
        v_multipart, 2, v_part_two_body
    );
    ASSERT (SELECT count(*) FROM pgs3.list_parts(v_multipart)) = 2;
    v_expected_etag := md5(
        decode(v_part_one.etag, 'hex') || decode(v_part_two.etag, 'hex')
    ) || '-2';
    v_composite_checksum_sha256 := encode(
        pgs3.sha256(v_part_one.sha256 || v_part_two.sha256), 'base64'
    ) || '-2';

    BEGIN
        PERFORM pgs3.complete_multipart_upload(
            'sql-tenant-a', 'multipart.bin', v_multipart,
            ARRAY[1, 2], ARRAY[v_part_one.etag, v_part_two.etag], NULL,
            ARRAY[v_part_one.sha256, v_part_two.sha256],
            encode(decode(repeat('00', 32), 'hex'), 'base64') || '-2'
        );
        ASSERT false, 'wrong multipart composite SHA-256 must fail';
    EXCEPTION WHEN SQLSTATE 'P3H01' THEN
        NULL;
    END;
    ASSERT pgs3.multipart_checksum_algorithm(
               'sql-tenant-a', 'multipart.bin', v_multipart
           ) = 'SHA256'
       AND (SELECT count(*) FROM pgs3.list_parts(v_multipart)) = 2,
           'failed composite validation must atomically retain the pending upload';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.list('sql-tenant-a') WHERE key = 'multipart.bin'
    ), 'failed composite validation must not publish an object';

    v_info := pgs3.complete_multipart_upload(
        'sql-tenant-a', 'multipart.bin', v_multipart,
        ARRAY[1, 2], ARRAY[v_part_one.etag, v_part_two.etag], NULL,
        ARRAY[v_part_one.sha256, v_part_two.sha256],
        v_composite_checksum_sha256
    );
    ASSERT v_info.etag = v_expected_etag,
           'multipart ETag must be md5(concatenated part MD5s)-N';
    ASSERT v_info.sha256 = pgs3.sha256(v_part_one_body || v_part_two_body),
           'multipart SHA-256 must cover all ordered source bytes';
    ASSERT v_info.meta ->> '@pgs3:checksum-sha256'
               = v_composite_checksum_sha256
       AND v_info.meta ->> '@pgs3:checksum-type' = 'COMPOSITE',
           'multipart publication must atomically persist its hidden composite checksum';
    ASSERT v_composite_checksum_sha256 <>
               encode(v_info.sha256, 'base64') || '-2',
           'composite checksum must not replace the canonical full-content SHA-256';
    ASSERT pgs3.get_range(
               'sql-tenant-a', 'multipart.bin', 5242878, 5242884
           ) = convert_to('aa-tail', 'UTF8'),
           'range reads must cross extent boundaries';

    v_upload := pgs3.begin_upload('sql-tenant-a', 'aborted.bin');
    PERFORM pgs3.put_chunk(v_upload, 0, convert_to('never visible', 'UTF8'));
    ASSERT pgs3.abort_upload(v_upload);
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.list('sql-tenant-a') WHERE key = 'aborted.bin'
    );
END
$test_uploads$;

DO $test_versioned_delete_objects$
DECLARE
    v_first pgs3.object_info;
    v_second pgs3.object_info;
    v_marker pgs3.delete_result;
    v_guard pgs3.object_info;
    v_result pgs3.delete_result;
    v_index integer := 0;
    v_missing constant bigint := 9223372036854775000;
BEGIN
    v_first := pgs3.put(
        'sql-tenant-a', 'bulk-versioned', convert_to('first', 'UTF8')
    );
    v_second := pgs3.put(
        'sql-tenant-a', 'bulk-versioned', convert_to('second', 'UTF8')
    );
    v_marker := pgs3.delete('sql-tenant-a', 'bulk-versioned');

    FOR v_result IN
        SELECT d.*
          FROM pgs3.delete_many(
              'sql-tenant-a',
              ARRAY[
                  'bulk-versioned', 'bulk-versioned',
                  'bulk-versioned', 'bulk-versioned'
              ],
              ARRAY[
                  v_second.version_id, v_second.version_id,
                  v_marker.version_id, v_missing
              ]
          ) AS d
    LOOP
        v_index := v_index + 1;
        ASSERT v_result.key = 'bulk-versioned';
        CASE v_index
            WHEN 1 THEN
                ASSERT v_result.version_id = v_second.version_id
                       AND v_result.deleted AND NOT v_result.delete_marker,
                       'first duplicate must delete the requested data version';
            WHEN 2 THEN
                ASSERT v_result.version_id = v_second.version_id
                       AND NOT v_result.deleted AND NOT v_result.delete_marker,
                       'repeated missing version must remain an idempotent success row';
            WHEN 3 THEN
                ASSERT v_result.version_id = v_marker.version_id
                       AND v_result.deleted AND v_result.delete_marker,
                       'delete-marker deletion must preserve marker metadata';
            WHEN 4 THEN
                ASSERT v_result.version_id = v_missing
                       AND NOT v_result.deleted AND NOT v_result.delete_marker,
                       'an unknown version must remain an idempotent success row';
            ELSE
                ASSERT false, 'delete_many emitted too many rows';
        END CASE;
    END LOOP;
    ASSERT v_index = 4, 'delete_many must emit exactly one row per request entry';
    ASSERT (pgs3.head('sql-tenant-a', 'bulk-versioned')).version_id
           = v_first.version_id,
           'deleting the latest marker and data version must repair is_latest';

    -- The original two-argument API remains source compatible and creates
    -- ordinary delete markers in request order.
    v_index := 0;
    FOR v_result IN
        SELECT d.*
          FROM pgs3.delete_many(
              'sql-tenant-a', ARRAY['legacy-delete-a', 'legacy-delete-b']
          ) AS d
    LOOP
        v_index := v_index + 1;
        ASSERT v_result.deleted AND v_result.delete_marker;
    END LOOP;
    ASSERT v_index = 2;

    -- Array validation completes before any requested object changes.
    v_guard := pgs3.put(
        'sql-tenant-a', 'bulk-validation-guard', convert_to('guard', 'UTF8')
    );
    BEGIN
        PERFORM d
          FROM pgs3.delete_many(
              'sql-tenant-a',
              ARRAY['bulk-validation-guard', NULL],
              ARRAY[NULL::bigint, NULL::bigint]
          ) AS d;
        ASSERT false, 'NULL key must reject the whole bulk request';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
    ASSERT (pgs3.head('sql-tenant-a', 'bulk-validation-guard')).version_id
           = v_guard.version_id,
           'a later invalid target must not delete an earlier valid target';

    BEGIN
        PERFORM d
          FROM pgs3.delete_many(
              'sql-tenant-a', ARRAY['bulk-validation-guard'], ARRAY[]::bigint[]
          ) AS d;
        ASSERT false, 'mismatched bulk arrays must be rejected';
    EXCEPTION WHEN invalid_parameter_value THEN
        NULL;
    END;
END
$test_versioned_delete_objects$;

DO $test_http_upload_target_binding$
DECLARE
    v_upload uuid;
    v_abort uuid;
    v_part pgs3.part_info;
    v_info pgs3.object_info;
    v_detail text;
BEGIN
    v_upload := pgs3.begin_upload(
        'sql-tenant-a', 'bound-multipart', p_multipart => true
    );

    BEGIN
        PERFORM pgs3.begin_part(
            'sql-tenant-a', 'wrong-key', v_upload, 1
        );
        ASSERT false, 'UploadPart must bind uploadId to the URL key';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=NoSuchUpload';
    END;

    BEGIN
        PERFORM pgs3.renew_upload(
            'sql-tenant-a', 'wrong-key', v_upload, true
        );
        ASSERT false, 'upload heartbeat must bind uploadId to the URL key';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;
    ASSERT pgs3.renew_upload(
        'sql-tenant-a', 'bound-multipart', v_upload, true
    ) > clock_timestamp() + interval '4 minutes',
      'target-bound heartbeat must renew the upload lease';

    ASSERT pgs3.begin_part('sql-tenant-a', 'bound-multipart', v_upload, 1);
    BEGIN
        PERFORM pgs3.put_chunk(
            'sql-tenant-a', 'wrong-key', v_upload, 0,
            convert_to('only-part', 'UTF8'), 1
        );
        ASSERT false, 'each staged UploadPart transaction must recheck URL binding';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;
    PERFORM pgs3.put_chunk(
        'sql-tenant-a', 'bound-multipart', v_upload, 0,
        convert_to('only-part', 'UTF8'), 1
    );
    BEGIN
        PERFORM pgs3.complete_part(
            'sql-tenant-a', 'wrong-key', v_upload, 1
        );
        ASSERT false, 'UploadPart completion must recheck URL binding';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;
    v_part := pgs3.complete_part(
        'sql-tenant-a', 'bound-multipart', v_upload, 1
    );

    BEGIN
        PERFORM p
          FROM pgs3.list_parts('sql-tenant-a', 'wrong-key', v_upload) AS p;
        ASSERT false, 'ListParts must bind uploadId to the URL key';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;
    ASSERT (
        SELECT count(*)
          FROM pgs3.list_parts(
              'sql-tenant-a', 'bound-multipart', v_upload
          )
    ) = 1;

    BEGIN
        PERFORM pgs3.complete_multipart_upload(
            'sql-tenant-a', 'wrong-key', v_upload,
            ARRAY[1], ARRAY[v_part.etag]
        );
        ASSERT false, 'CompleteMultipartUpload must bind uploadId to the URL key';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;
    BEGIN
        PERFORM pgs3.abort_upload(
            'sql-tenant-a', 'wrong-key', v_upload, true
        );
        ASSERT false, 'AbortMultipartUpload must bind uploadId to the URL key';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;

    v_info := pgs3.complete_multipart_upload(
        'sql-tenant-a', 'bound-multipart', v_upload,
        ARRAY[1], ARRAY[v_part.etag]
    );
    ASSERT (pgs3.get('sql-tenant-a', 'bound-multipart')).body
           = convert_to('only-part', 'UTF8');
    ASSERT v_info.etag = md5(decode(v_part.etag, 'hex')) || '-1';

    v_abort := pgs3.begin_upload(
        'sql-tenant-a', 'bound-abort', p_multipart => true
    );
    ASSERT pgs3.abort_upload(
        'sql-tenant-a', 'bound-abort', v_abort, true
    );
    BEGIN
        PERFORM pgs3.list_parts(
            'sql-tenant-a', 'bound-abort', v_abort
        );
        ASSERT false, 'correctly targeted abort must remove the upload';
    EXCEPTION WHEN SQLSTATE 'P3U01' THEN
        NULL;
    END;
END
$test_http_upload_target_binding$;

RESET ROLE;

DO $test_upload_leases$
DECLARE
    v_live uuid;
    v_expired uuid;
    v_not_old uuid;
    v_abort uuid;
    v_deadline timestamptz;
    v_part pgs3.part_info;
    v_info pgs3.object_info;
BEGIN
    SET LOCAL ROLE pgs3_sql_tenant_a;
    v_live := pgs3.begin_upload('sql-tenant-a', 'lease-live');
    v_expired := pgs3.begin_upload('sql-tenant-a', 'lease-expired');
    PERFORM pgs3.put_chunk(
        v_expired, 0, convert_to('expired-staging', 'UTF8')
    );
    v_not_old := pgs3.begin_upload(
        'sql-tenant-a', 'lease-not-old', p_multipart => true
    );
    v_abort := pgs3.begin_upload('sql-tenant-a', 'lease-abort');
    RESET ROLE;

    ASSERT (
        SELECT u.lease_expires_at > clock_timestamp() + interval '4 minutes'
          FROM pgs3.upload AS u
         WHERE u.upload_id = v_live
    ), 'begin_upload must create a five-minute lease';

    -- Age and lease expiry are independent eligibility conditions.  The first
    -- row is old but actively leased; the third has an expired lease but is
    -- not yet old enough for the operator retention threshold.
    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp() - interval '48 hours',
           lease_expires_at = clock_timestamp() + interval '1 hour'
     WHERE u.upload_id = v_live;
    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp() - interval '48 hours',
           lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_expired;
    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp(),
           lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_not_old;

    ASSERT pgs3.gc_pending_uploads(interval '24 hours', 100) = 1,
           'pending GC must require both max age and lease expiry';
    ASSERT EXISTS (
        SELECT 1 FROM pgs3.upload AS u WHERE u.upload_id = v_live
    ), 'an aged upload with a valid lease must survive GC';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload AS u WHERE u.upload_id = v_expired
    ), 'an aged upload with an expired lease must be collected';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload_chunk AS c
         WHERE c.upload_id = v_expired
    ), 'pending GC must cascade staged chunks for the claimed upload';
    ASSERT EXISTS (
        SELECT 1 FROM pgs3.upload AS u WHERE u.upload_id = v_not_old
    ), 'lease expiry alone must not bypass max-age retention';

    -- A direct heartbeat is a short SQL transaction used while an HTTP worker
    -- is still reading a body.  It renews liveness without changing staging age.
    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_live;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    v_deadline := pgs3.renew_upload(v_live);
    RESET ROLE;
    ASSERT v_deadline > clock_timestamp() + interval '4 minutes';
    ASSERT (
        SELECT u.updated_at < clock_timestamp() - interval '24 hours'
               AND u.lease_expires_at = v_deadline
          FROM pgs3.upload AS u
         WHERE u.upload_id = v_live
    ), 'heartbeat must extend only the lease, not falsify staging age';
    ASSERT pgs3.gc_pending_uploads(interval '24 hours', 100) = 0,
           'a renewed aged upload must not be collected';

    -- Every chunk/part/list operation shares the same locked renewal helper.
    -- Exercise both ordinary and multipart entry paths after forcing expiry.
    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_live;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    PERFORM pgs3.put_chunk(v_live, 0, convert_to('live', 'UTF8'));
    RESET ROLE;
    ASSERT (
        SELECT u.lease_expires_at > clock_timestamp() + interval '4 minutes'
          FROM pgs3.upload AS u
         WHERE u.upload_id = v_live
    ), 'put_chunk must renew while holding the upload row';

    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_not_old;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    ASSERT pgs3.begin_part(v_not_old, 1);
    RESET ROLE;
    ASSERT (
        SELECT u.lease_expires_at > clock_timestamp() + interval '4 minutes'
          FROM pgs3.upload AS u
         WHERE u.upload_id = v_not_old
    ), 'begin_part must renew while resetting the part';

    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_not_old;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    PERFORM pgs3.put_chunk(
        v_not_old, 0, convert_to('only-part', 'UTF8'), 1
    );
    RESET ROLE;
    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_not_old;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    v_part := pgs3.complete_part(v_not_old, 1);
    RESET ROLE;
    ASSERT (
        SELECT u.lease_expires_at > clock_timestamp() + interval '4 minutes'
          FROM pgs3.upload AS u
         WHERE u.upload_id = v_not_old
    ), 'complete_part must renew while finalizing the part';

    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_not_old;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    ASSERT (SELECT count(*) FROM pgs3.list_parts(v_not_old)) = 1;
    RESET ROLE;
    ASSERT (
        SELECT u.lease_expires_at > clock_timestamp() + interval '4 minutes'
          FROM pgs3.upload AS u
         WHERE u.upload_id = v_not_old
    ), 'list_parts must renew while locking the upload';

    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() - interval '1 hour'
     WHERE u.upload_id = v_not_old;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    v_info := pgs3.complete_multipart_upload(
        v_not_old, ARRAY[1], ARRAY[v_part.etag]
    );
    RESET ROLE;
    ASSERT v_info.etag = md5(decode(v_part.etag, 'hex')) || '-1';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload AS u WHERE u.upload_id = v_not_old
    ), 'complete must end the lease by deleting the pending attempt';

    SET LOCAL ROLE pgs3_sql_tenant_a;
    ASSERT pgs3.abort_upload(v_live);
    ASSERT pgs3.abort_upload(v_abort);
    RESET ROLE;
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload AS u
         WHERE u.upload_id IN (v_live, v_abort)
    ), 'abort must end the lease by deleting the pending attempt';
END
$test_upload_leases$;

DO $test_delete_bucket_aborts_pending_uploads$
DECLARE
    v_upload uuid;
    v_part pgs3.part_info;
    v_blob_id bytea;
BEGIN
    SET LOCAL ROLE pgs3_sql_tenant_a;
    PERFORM pgs3.create_bucket('sql-pending-delete');
    v_upload := pgs3.begin_upload(
        'sql-pending-delete', 'unfinished', p_multipart => true
    );
    PERFORM pgs3.put_chunk(
        v_upload, 0, convert_to('pending-delete-body', 'UTF8'), 1
    );
    v_part := pgs3.complete_part(v_upload, 1);
    RESET ROLE;

    SELECT p.blob_id INTO STRICT v_blob_id
      FROM pgs3.upload_part AS p
     WHERE p.upload_id = v_upload AND p.part_number = 1;
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_blob_id) = 1,
           'a completed pending part must own its canonical blob';

    SET LOCAL ROLE pgs3_sql_tenant_a;
    ASSERT pgs3.delete_bucket('sql-pending-delete'),
           'an otherwise empty general-purpose bucket may be deleted with a pending upload';
    RESET ROLE;

    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload AS u WHERE u.upload_id = v_upload
    ), 'DeleteBucket must atomically abort pending uploads';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload_part AS p WHERE p.upload_id = v_upload
    ), 'pending part rows must cascade during DeleteBucket';
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_blob_id) = 0,
           'DeleteBucket must release pending-part blob references';
    PERFORM pgs3.gc_blobs(1000);
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.blob AS b WHERE b.sha256 = v_blob_id
    ), 'the aborted pending payload must become collectable';
END
$test_delete_bucket_aborts_pending_uploads$;

DO $test_storage_invariants$
DECLARE
    v_blob_id bytea;
    v_small_blob_id bytea;
    v_stream_blob_id bytea;
    v_multipart_blob_id bytea;
    v_source_blob_ids bytea[];
    v_nested_source_blob_ids bytea[];
    v_multipart_version bigint;
    v_versions bigint[];
    v_version bigint;
BEGIN
    SELECT o.blob_id INTO STRICT v_small_blob_id
      FROM pgs3.object AS o
      JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
     WHERE b.name = 'sql-tenant-a'
       AND o.key = 'small.txt'
       AND o.is_latest;
    ASSERT NOT EXISTS (
        SELECT 1
          FROM pgs3.object AS o
         WHERE NOT o.delete_marker AND o.inline IS NOT NULL
    ), 'object.inline must remain NULL for every live version';
    ASSERT (
        SELECT b.storage_kind = 'inline'
               AND b.inline = convert_to('one', 'UTF8')
               AND b.refcount = 3
          FROM pgs3.blob AS b
         WHERE b.sha256 = v_small_blob_id
    ), 'small versions, restore, and fork must share one canonical inline blob';
    ASSERT (
        SELECT o.blob_id = v_small_blob_id AND o.inline IS NULL
          FROM pgs3.object AS o
          JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
         WHERE b.name = 'sql-tenant-a-fork'
           AND o.key = 'small.txt'
           AND o.is_latest
    ), 'forked small content must copy metadata only';

    SELECT o.blob_id INTO STRICT v_blob_id
      FROM pgs3.object AS o
      JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
     WHERE b.name = 'sql-tenant-a' AND o.key = 'large-a.bin' AND o.is_latest;

    ASSERT (SELECT count(*) FROM pgs3.blob WHERE sha256 = v_blob_id) = 1,
           'deduplicated content must have one blob row';
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_blob_id) = 6,
           'copy and duplicate content must share and increment the blob';
    ASSERT (SELECT coalesce(sum(octet_length(data)), 0)
              FROM pgs3.chunk WHERE blob_id = v_blob_id) = 16,
           'chunk bytes must reconstruct the blob size';

    SELECT array_agg(o.version_id ORDER BY o.version_id)
      INTO v_versions
      FROM pgs3.object AS o
      JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
     WHERE b.name = 'sql-tenant-a' AND o.key = 'large-b.bin';
    FOREACH v_version IN ARRAY v_versions LOOP
        PERFORM pgs3.delete('sql-tenant-a', 'large-b.bin', v_version);
    END LOOP;
    -- Other references keep this blob alive; the refcount must nevertheless
    -- have fallen by exactly one.
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_blob_id) = 5,
           'exact-version deletion must decrement one shared reference';

    SELECT o.blob_id INTO STRICT v_stream_blob_id
      FROM pgs3.object AS o
      JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
     WHERE b.name = 'sql-tenant-a'
       AND o.key = 'streamed-large.bin'
       AND o.is_latest;
    ASSERT (
        SELECT storage_kind = 'composite' AND refcount = 1
          FROM pgs3.blob WHERE sha256 = v_stream_blob_id
    ), 'large non-multipart streaming completion must publish an extent blob';
    ASSERT (
        SELECT count(*) = 2
          FROM pgs3.blob_extent
         WHERE final_blob_id = v_stream_blob_id
    ), 'large streaming completion must reuse both canonical staged chunks';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.chunk WHERE blob_id = v_stream_blob_id
    ), 'large streaming completion must not rewrite staged payload into final chunks';

    SELECT o.blob_id, o.version_id
      INTO STRICT v_multipart_blob_id, v_multipart_version
      FROM pgs3.object AS o
      JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
     WHERE b.name = 'sql-tenant-a'
       AND o.key = 'multipart.bin'
       AND o.is_latest;
    SELECT array_agg(e.source_blob_id ORDER BY e.seq)
      INTO STRICT v_source_blob_ids
      FROM pgs3.blob_extent AS e
     WHERE e.final_blob_id = v_multipart_blob_id;
    ASSERT cardinality(v_source_blob_ids) = 2,
           'two completed parts must publish two extents';
    SELECT array_agg(DISTINCT e.source_blob_id)
      INTO v_nested_source_blob_ids
      FROM pgs3.blob_extent AS e
     WHERE e.final_blob_id = ANY (v_source_blob_ids);
    ASSERT (
        SELECT b.storage_kind = 'composite'
               AND b.inline IS NULL
               AND b.refcount = 1
          FROM pgs3.blob AS b
         WHERE b.sha256 = v_multipart_blob_id
    ), 'multipart final blob must be a referenced logical composite';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.chunk AS c WHERE c.blob_id = v_multipart_blob_id
    ), 'multipart completion must not copy payload into final chunk rows';
    ASSERT (
        SELECT bool_and(b.refcount = 1)
          FROM pgs3.blob AS b
         WHERE b.sha256 = ANY (v_source_blob_ids)
    ), 'extent ownership must keep both physical part blobs alive';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.upload_part AS p
         WHERE p.blob_id = ANY (v_source_blob_ids)
    ), 'completed upload rows must not be needed to retain extent sources';

    SET LOCAL ROLE pgs3_sql_tenant_a;
    PERFORM pgs3.delete(
        'sql-tenant-a', 'multipart.bin', v_multipart_version
    );
    RESET ROLE;
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_multipart_blob_id) = 0;
    PERFORM pgs3.gc_blobs(1000);
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.blob
         WHERE sha256 = v_multipart_blob_id
            OR sha256 = ANY (v_source_blob_ids)
            OR (
                v_nested_source_blob_ids IS NOT NULL
                AND sha256 = ANY (v_nested_source_blob_ids)
            )
    ), 'one bounded GC call must transitively remove final, part, and physical blobs';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.blob_extent
         WHERE final_blob_id = v_multipart_blob_id
    ), 'composite GC must cascade its extent metadata';
END
$test_storage_invariants$;

DO $test_all_content_dedup_and_gc$
DECLARE
    v_small_body bytea := convert_to('tiny', 'UTF8');
    v_large_body bytea := convert_to('dedup-large-payload-unique', 'UTF8');
    v_small_blob_id bytea := pgs3.sha256(v_small_body);
    v_large_blob_id bytea := pgs3.sha256(v_large_body);
    v_row record;
    i integer;
BEGIN
    SET LOCAL ROLE pgs3_sql_tenant_a;
    PERFORM pgs3.create_bucket('sql-dedup-source');
    FOR i IN 1..100 LOOP
        PERFORM pgs3.put(
            'sql-dedup-source', format('small-%s', i), v_small_body
        );
        PERFORM pgs3.put(
            'sql-dedup-source', format('large-%s', i), v_large_body
        );
    END LOOP;
    PERFORM pgs3.copy(
        'sql-dedup-source', 'small-1',
        'sql-dedup-source', 'small-copy'
    );
    ASSERT pgs3.fork_bucket(
        'sql-dedup-source', 'sql-dedup-fork'
    ) = 201;
    RESET ROLE;

    ASSERT (
        SELECT count(*) = 1
               AND bool_and(b.refcount = 202)
               AND bool_and(b.storage_kind = 'inline')
               AND bool_and(b.inline = v_small_body)
          FROM pgs3.blob AS b
         WHERE b.sha256 = v_small_blob_id
    ), '100 small uploads plus copy/fork must store one canonical inline payload';
    ASSERT (
        SELECT count(*) = 1
               AND bool_and(b.refcount = 200)
               AND bool_and(b.storage_kind = 'chunked')
               AND bool_and(b.inline IS NULL)
          FROM pgs3.blob AS b
         WHERE b.sha256 = v_large_blob_id
    ), '100 large uploads plus fork must store one canonical chunked payload';
    ASSERT (
        SELECT count(*) = 402 AND bool_and(o.inline IS NULL)
          FROM pgs3.object AS o
          JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
         WHERE b.name IN ('sql-dedup-source', 'sql-dedup-fork')
    ), 'copy and fork must duplicate metadata only, including small objects';
    ASSERT (
        SELECT coalesce(sum(octet_length(c.data)), 0) = octet_length(v_large_body)
          FROM pgs3.chunk AS c
         WHERE c.blob_id = v_large_blob_id
    ), 'large canonical bytes must occur in one physical chunk sequence';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.chunk AS c WHERE c.blob_id = v_small_blob_id
    ), 'small canonical bytes must not be duplicated into chunks';

    SET LOCAL ROLE pgs3_sql_tenant_a;
    FOR v_row IN
        SELECT 'sql-dedup-source'::text AS bucket_name,
               v.key, v.version_id
          FROM pgs3.list_versions('sql-dedup-source') AS v
         WHERE v.key IS NOT NULL
        UNION ALL
        SELECT 'sql-dedup-fork'::text AS bucket_name,
               v.key, v.version_id
          FROM pgs3.list_versions('sql-dedup-fork') AS v
         WHERE v.key IS NOT NULL
    LOOP
        PERFORM pgs3.delete(
            v_row.bucket_name, v_row.key, v_row.version_id
        );
    END LOOP;
    PERFORM pgs3.delete_bucket('sql-dedup-source');
    PERFORM pgs3.delete_bucket('sql-dedup-fork');
    RESET ROLE;

    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_small_blob_id) = 0;
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_large_blob_id) = 0;
    PERFORM pgs3.gc_blobs(1000);
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.blob
         WHERE sha256 IN (v_small_blob_id, v_large_blob_id)
    ), 'GC must remove both canonical blobs after all 100 uploads/copies/forks are gone';
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.chunk WHERE blob_id = v_large_blob_id
    ), 'large canonical chunk rows must cascade to zero';
END
$test_all_content_dedup_and_gc$;

-- Direct grants are optional, but when used RLS must enforce tenant isolation.
GRANT SELECT ON pgs3.bucket, pgs3.object, pgs3.blob, pgs3.chunk, pgs3.blob_extent
    TO pgs3_sql_tenant_a, pgs3_sql_tenant_b;

SET LOCAL ROLE pgs3_sql_tenant_b;
DO $test_rls_b$
DECLARE
    v_detail text;
BEGIN
    ASSERT (SELECT count(*) FROM pgs3.list_buckets()) = 0,
           'tenant B must not list tenant A buckets';
    ASSERT (SELECT count(*) FROM pgs3.bucket) = 0,
           'RLS must hide tenant A bucket rows';
    ASSERT (SELECT count(*) FROM pgs3.object) = 0,
           'RLS must hide tenant A object rows';
    ASSERT (SELECT count(*) FROM pgs3.blob) = 0,
           'RLS must hide tenant A shared blob rows';
    ASSERT (SELECT count(*) FROM pgs3.chunk) = 0,
           'RLS must hide tenant A shared chunk rows';
    ASSERT (SELECT count(*) FROM pgs3.blob_extent) = 0,
           'RLS must hide tenant A blob extent rows';
    BEGIN
        PERFORM pgs3.head_bucket('sql-tenant-a');
        ASSERT false, 'tenant B must not HEAD tenant A bucket';
    EXCEPTION WHEN SQLSTATE 'P3B01' THEN
        NULL;
    END;
    BEGIN
        PERFORM pgs3.create_bucket('sql-tenant-a');
        ASSERT false, 'cross-owner duplicate bucket must fail';
    EXCEPTION WHEN SQLSTATE 'P3E01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=BucketAlreadyExists';
        ASSERT position('sql-tenant-a' IN v_detail) = 0;
    END;
    PERFORM pgs3.create_bucket(
        'sql-tenant-b', '{"region":"ap-southeast-1"}'::jsonb
    );
    PERFORM pgs3.put('sql-tenant-b', 'only-b', convert_to('b', 'UTF8'));
    ASSERT (SELECT count(*) FROM pgs3.list_buckets()) = 1;
    ASSERT pgs3.get_bucket_location('sql-tenant-b') = 'ap-southeast-1';
END
$test_rls_b$;

SET LOCAL ROLE pgs3_sql_tenant_a;
DO $test_rls_a$
BEGIN
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.list_buckets() WHERE name = 'sql-tenant-b'
    ), 'tenant A must not list tenant B bucket';
    BEGIN
        PERFORM pgs3.get('sql-tenant-b', 'only-b');
        ASSERT false, 'tenant A must not GET tenant B object';
    EXCEPTION WHEN SQLSTATE 'P3B01' THEN
        NULL;
    END;
END
$test_rls_a$;

RESET ROLE;

DO $test_credentials$
DECLARE
    v_detail text;
BEGIN
    ASSERT NOT has_function_privilege(
        'pgs3_sql_tenant_a',
        'pgs3._notify_change(text)',
        'EXECUTE'
    ), 'notification helper must not be executable by PUBLIC';
    ASSERT NOT has_function_privilege(
        'pgs3_sql_tenant_a',
        'pgs3.create_credential(text,text,name,boolean)',
        'EXECUTE'
    ), 'credential mutation must not be executable by PUBLIC';
    ASSERT pgs3.create_credential(
        'SQLTESTACCESSKEY', 'original-secret', 'pgs3_sql_tenant_a', true
    );
    BEGIN
        PERFORM pgs3.create_credential(
            'SQLTESTACCESSKEY', 'detail-leak-sentinel-secret',
            'pgs3_sql_tenant_a', true
        );
        ASSERT false, 'duplicate credential must fail';
    EXCEPTION WHEN SQLSTATE 'P3A01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=CredentialError';
        ASSERT position('SQLTESTACCESSKEY' IN v_detail) = 0;
        ASSERT position('detail-leak-sentinel-secret' IN v_detail) = 0;
    END;
    BEGIN
        PERFORM pgs3.set_credential_role(
            'detail-leak-sentinel-access-key', 'pgs3_sql_tenant_a'
        );
        ASSERT false, 'unknown credential role update must fail';
    EXCEPTION WHEN SQLSTATE 'P3A01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=CredentialError';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;
    BEGIN
        PERFORM pgs3.rotate_credential(
            'detail-leak-sentinel-access-key',
            'detail-leak-sentinel-secret'
        );
        ASSERT false, 'unknown credential secret rotation must fail';
    EXCEPTION WHEN SQLSTATE 'P3A01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=CredentialError';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;
    BEGIN
        PERFORM pgs3.set_credential_enabled(
            'detail-leak-sentinel-access-key', false
        );
        ASSERT false, 'unknown credential enable update must fail';
    EXCEPTION WHEN SQLSTATE 'P3A01' THEN
        GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
        ASSERT v_detail = 'pgs3.error=CredentialError';
        ASSERT position('detail-leak-sentinel' IN v_detail) = 0;
    END;
    ASSERT (
        SELECT m.set_option AND NOT m.inherit_option
          FROM pg_catalog.pg_auth_members AS m
          JOIN pg_catalog.pg_roles AS granted_role
            ON granted_role.oid = m.roleid
          JOIN pg_catalog.pg_roles AS member_role
            ON member_role.oid = m.member
         WHERE granted_role.rolname = 'pgs3_sql_tenant_a'
           AND member_role.rolname = coalesce(
               nullif(current_setting('pgs3.server_role', true), ''),
               'pgs3_server'
           )
    ), 'server role needs SET without inherited tenant privileges';
    ASSERT (
        SELECT c.secret = 'original-secret' AND c.enabled
          FROM pgs3.credential AS c
         WHERE c.access_key = 'SQLTESTACCESSKEY'
    ), 'SigV4 credential must retain the original secret';
    ASSERT pgs3.rotate_credential('SQLTESTACCESSKEY', 'rotated-secret');
    ASSERT pgs3.set_credential_role(
        'SQLTESTACCESSKEY', 'pgs3_sql_tenant_b'
    );
    ASSERT pgs3.set_credential_enabled('SQLTESTACCESSKEY', false);
    ASSERT (
        SELECT c.secret = 'rotated-secret'
               AND c.role_name = 'pgs3_sql_tenant_b'
               AND NOT c.enabled
          FROM pgs3.credential AS c
         WHERE c.access_key = 'SQLTESTACCESSKEY'
    );
    BEGIN
        PERFORM pgs3.create_credential(
            'SQLTESTSUPER', 'never-store', session_user::name, true
        );
        ASSERT false, 'credential mappings to a superuser must be rejected';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    ASSERT pgs3.delete_credential('SQLTESTACCESSKEY');
END
$test_credentials$;

-- Exercise refcount-to-zero and physical GC using a disposable large object.
DO $test_gc$
DECLARE
    v_info pgs3.object_info;
    v_blob_id bytea;
BEGIN
    SET LOCAL ROLE pgs3_sql_tenant_a;
    v_info := pgs3.put(
        'sql-tenant-a', 'gc-only.bin', convert_to('unique-gc-payload', 'UTF8')
    );
    RESET ROLE;
    SELECT o.blob_id INTO STRICT v_blob_id
      FROM pgs3.object AS o
      JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
     WHERE b.name = 'sql-tenant-a' AND o.key = 'gc-only.bin' AND o.is_latest;
    SET LOCAL ROLE pgs3_sql_tenant_a;
    PERFORM pgs3.delete('sql-tenant-a', 'gc-only.bin', v_info.version_id);
    RESET ROLE;
    ASSERT (SELECT refcount FROM pgs3.blob WHERE sha256 = v_blob_id) = 0;
    PERFORM pgs3.gc_blobs(1000);
    ASSERT NOT EXISTS (SELECT 1 FROM pgs3.blob WHERE sha256 = v_blob_id);
    ASSERT NOT EXISTS (SELECT 1 FROM pgs3.chunk WHERE blob_id = v_blob_id);
END
$test_gc$;

SELECT 'pgs3 SQL semantics: ok' AS result;

ROLLBACK;
