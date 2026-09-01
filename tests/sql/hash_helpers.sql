\set ON_ERROR_STOP on

BEGIN;

DO $hash_helpers$
DECLARE
    -- Keep this at or below the packaged semantic-test threshold (8 bytes).
    v_small bytea := convert_to('inline', 'UTF8');
    v_large bytea := decode(repeat('ab', 200000), 'hex');
    v_multipart_large bytea := decode(repeat('cd', 5242880), 'hex');
    v_combined bytea;
    v_small_id bytea;
    v_large_id bytea;
    v_upload uuid;
    v_empty_upload uuid;
    v_sha256 bytea;
    v_md5 text;
    v_size bigint;
    v_info pgs3.object_info;
    v_multipart_info pgs3.object_info;
    v_part_one pgs3.part_info;
    v_part_two pgs3.part_info;
    v_multipart_upload uuid;
    v_many_ids bytea[] := ARRAY[]::bytea[];
    v_many_payload bytea := ''::bytea;
    v_many_piece bytea;
    v_rejected boolean;
    v_cycle_a bytea := decode(repeat('11', 32), 'hex');
    v_cycle_b bytea := decode(repeat('22', 32), 'hex');
BEGIN
    ASSERT to_regprocedure('pgs3.hash_upload_part(uuid,integer)') IS NOT NULL,
           'hash_upload_part was not generated';
    ASSERT to_regprocedure('pgs3.hash_blob_sequence(bytea[])') IS NOT NULL,
           'hash_blob_sequence was not generated';

    ASSERT (
        SELECT p.prosecdef AND p.proisstrict AND p.provolatile = 's'
          FROM pg_catalog.pg_proc AS p
         WHERE p.oid = 'pgs3.hash_upload_part(uuid,integer)'::regprocedure
    ), 'hash_upload_part must be STABLE, STRICT, and SECURITY DEFINER';
    ASSERT (
        SELECT p.prosecdef AND p.proisstrict AND p.provolatile = 's'
          FROM pg_catalog.pg_proc AS p
         WHERE p.oid = 'pgs3.hash_blob_sequence(bytea[])'::regprocedure
    ), 'hash_blob_sequence must be STABLE, STRICT, and SECURITY DEFINER';
    ASSERT NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc AS p
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(
                  p.proacl,
                  pg_catalog.acldefault('f', p.proowner)
              )
          ) AS a
         WHERE p.oid IN (
                   'pgs3.hash_upload_part(uuid,integer)'::regprocedure,
                   'pgs3.hash_blob_sequence(bytea[])'::regprocedure
               )
           AND a.grantee = 0
           AND a.privilege_type = 'EXECUTE'
    ), 'PUBLIC must not have direct EXECUTE on streaming hash helpers';

    v_combined := v_small || v_large;
    v_small_id := pgs3._ensure_blob(pgs3.sha256(v_small), v_small);
    v_large_id := pgs3._ensure_blob(pgs3.sha256(v_large), v_large);

    ASSERT (
        SELECT b.storage_kind = 'inline'
          FROM pgs3.blob AS b
         WHERE b.sha256 = v_small_id
    ), 'small test blob must use inline storage';
    ASSERT (
        SELECT b.storage_kind = 'chunked'
               AND count(c.*) = ((b.size - 1) / b.chunk_size + 1)
          FROM pgs3.blob AS b
          LEFT JOIN pgs3.chunk AS c ON c.blob_id = b.sha256
         WHERE b.sha256 = v_large_id
         GROUP BY b.storage_kind, b.size, b.chunk_size
    ), 'large test blob must use the canonical dense chunk layout';

    SELECT h.sha256, h.total_size
      INTO STRICT v_sha256, v_size
      FROM pgs3.hash_blob_sequence(ARRAY[v_small_id]::bytea[]) AS h;
    ASSERT v_sha256 = pgs3.sha256(v_small)
       AND v_size = octet_length(v_small),
           'inline blob streaming digest is wrong';

    SELECT h.sha256, h.total_size
      INTO STRICT v_sha256, v_size
      FROM pgs3.hash_blob_sequence(ARRAY[v_large_id]::bytea[]) AS h;
    ASSERT v_sha256 = pgs3.sha256(v_large)
       AND v_size = octet_length(v_large),
           'chunked blob streaming digest is wrong';

    SELECT h.sha256, h.total_size
      INTO STRICT v_sha256, v_size
      FROM pgs3.hash_blob_sequence(
               ARRAY[v_small_id, v_large_id]::bytea[]
           ) AS h;
    ASSERT v_sha256 = pgs3.sha256(v_combined)
       AND v_size = octet_length(v_combined),
           'ordered blob-sequence digest is wrong';

    -- Keep more than a dozen distinct identifiers in one PostgreSQL-owned
    -- array, forcing repeated nested SPI connect/teardown cycles.
    -- hash_blob_sequence must eagerly copy every bytea datum before its first
    -- nested Spi::connect; a lazy array iterator can otherwise retain dangling
    -- pointers while hashing later elements.
    FOR v_index IN 1..17 LOOP
        v_many_piece := convert_to(
            'array-lifetime-entry-' || v_index::text || ':'
                || repeat(chr(64 + v_index), v_index),
            'UTF8'
        );
        v_many_ids := array_append(
            v_many_ids,
            pgs3._ensure_blob(pgs3.sha256(v_many_piece), v_many_piece)
        );
        v_many_payload := v_many_payload || v_many_piece;
    END LOOP;
    ASSERT cardinality(v_many_ids) = 17
       AND (SELECT count(DISTINCT id) FROM unnest(v_many_ids) AS ids(id)) = 17,
           'array lifetime regression requires 17 distinct blob IDs';
    SELECT h.sha256, h.total_size
      INTO STRICT v_sha256, v_size
      FROM pgs3.hash_blob_sequence(v_many_ids) AS h;
    ASSERT v_sha256 = pgs3.sha256(v_many_payload)
       AND v_size = octet_length(v_many_payload),
           '17-entry blob array was not copied before nested SPI calls';

    PERFORM pgs3.create_bucket('hash-helper-test');
    v_upload := pgs3.begin_upload(
        'hash-helper-test', 'streamed-object', p_multipart => false
    );
    PERFORM pgs3.put_chunk(v_upload, 0, v_small, 0);
    PERFORM pgs3.put_chunk(v_upload, 1, v_large, 0);

    SELECT h.sha256, h.md5, h.total_size
      INTO STRICT v_sha256, v_md5, v_size
      FROM pgs3.hash_upload_part(v_upload, 0) AS h;
    ASSERT v_sha256 = pgs3.sha256(v_combined)
       AND v_md5 = md5(v_combined)
       AND v_size = octet_length(v_combined),
           'ordinary streaming PUT digest is wrong';

    -- complete_upload invokes hash_upload_part internally and publishes a
    -- zero-copy composite over the two staged canonical blobs.
    v_info := pgs3.complete_upload(v_upload);
    ASSERT v_info.sha256 = pgs3.sha256(v_combined)
       AND v_info.etag = md5(v_combined)
       AND v_info.size = octet_length(v_combined),
           'complete_upload did not use the trusted streaming digest';
    ASSERT (
        SELECT b.storage_kind = 'composite' AND count(e.*) = 2
          FROM pgs3.blob AS b
          LEFT JOIN pgs3.blob_extent AS e ON e.final_blob_id = b.sha256
         WHERE b.sha256 = v_info.sha256
         GROUP BY b.storage_kind
    ), 'large staged PUT must publish a two-extent composite';

    SELECT h.sha256, h.total_size
      INTO STRICT v_sha256, v_size
      FROM pgs3.hash_blob_sequence(ARRAY[v_info.sha256]::bytea[]) AS h;
    ASSERT v_sha256 = v_info.sha256
       AND v_size = v_info.size,
           'recursive composite streaming digest is wrong';

    -- Multipart completion exercises hash_upload_part for positive part
    -- numbers and then hash_blob_sequence over the ordered canonical parts.
    v_multipart_upload := pgs3.begin_upload(
        'hash-helper-test', 'multipart-object', p_multipart => true
    );
    v_part_one := pgs3.put_part(
        v_multipart_upload, 1, v_multipart_large
    );
    v_part_two := pgs3.put_part(v_multipart_upload, 2, v_small);
    v_multipart_info := pgs3.complete_multipart_upload(
        v_multipart_upload,
        ARRAY[1, 2],
        ARRAY[v_part_one.etag, v_part_two.etag]
    );
    ASSERT v_multipart_info.sha256 = pgs3.sha256(
               v_multipart_large || v_small
           )
       AND v_multipart_info.size = octet_length(v_multipart_large)
                                    + octet_length(v_small),
           'multipart completion did not use both streaming hash helpers';

    -- A non-multipart part_number=0 upload may be empty and still returns
    -- exactly one standards-compatible digest row.
    v_empty_upload := pgs3.begin_upload(
        'hash-helper-test', 'empty-streamed-object', p_multipart => false
    );
    SELECT h.sha256, h.md5, h.total_size
      INTO STRICT v_sha256, v_md5, v_size
      FROM pgs3.hash_upload_part(v_empty_upload, 0) AS h;
    ASSERT v_sha256 = pgs3.sha256(''::bytea)
       AND v_md5 = md5(''::bytea)
       AND v_size = 0,
           'empty streaming PUT digest is wrong';
    PERFORM pgs3.abort_upload(v_empty_upload);

    -- Structural offsets are checked independently of the final digest.
    v_rejected := false;
    BEGIN
        UPDATE pgs3.blob_extent AS e
           SET logical_offset = logical_offset + 1
         WHERE e.final_blob_id = v_info.sha256
           AND e.seq = 1;
        PERFORM 1
          FROM pgs3.hash_blob_sequence(ARRAY[v_info.sha256]::bytea[]);
    EXCEPTION WHEN OTHERS THEN
        v_rejected := SQLERRM LIKE 'pgs3 canonical blob corruption:%';
    END;
    ASSERT v_rejected, 'a non-contiguous composite extent was accepted';

    -- Same-size byte corruption is caught by re-hashing each referenced blob
    -- against its content-addressed identifier.
    v_rejected := false;
    BEGIN
        UPDATE pgs3.chunk AS c
           SET data = pg_catalog.set_byte(c.data, 0, 0)
         WHERE c.blob_id = v_large_id
           AND c.seq = 0;
        PERFORM 1
          FROM pgs3.hash_blob_sequence(ARRAY[v_large_id]::bytea[]);
    EXCEPTION WHEN OTHERS THEN
        v_rejected := SQLERRM LIKE 'pgs3 canonical blob corruption:%';
    END;
    ASSERT v_rejected, 'same-size chunk payload corruption was accepted';

    -- Indirect cycles cannot be created by normal APIs, but the reader still
    -- rejects them defensively before recursion can become unbounded.
    INSERT INTO pgs3.blob (
        sha256, size, chunk_size, storage_kind, inline
    ) VALUES
        (v_cycle_a, 1, 65536, 'composite', NULL),
        (v_cycle_b, 1, 65536, 'composite', NULL);
    INSERT INTO pgs3.blob_extent (
        final_blob_id, seq, logical_offset,
        source_blob_id, source_offset, length
    ) VALUES
        (v_cycle_a, 0, 0, v_cycle_b, 0, 1),
        (v_cycle_b, 0, 0, v_cycle_a, 0, 1);
    v_rejected := false;
    BEGIN
        PERFORM 1
          FROM pgs3.hash_blob_sequence(ARRAY[v_cycle_a]::bytea[]);
    EXCEPTION WHEN OTHERS THEN
        v_rejected := SQLERRM LIKE '%contains a cycle%';
    END;
    ASSERT v_rejected, 'an indirect blob-extent cycle was accepted';

    v_rejected := false;
    BEGIN
        PERFORM 1
          FROM pgs3.hash_blob_sequence(
                   ARRAY[v_small_id, NULL]::bytea[]
               );
    EXCEPTION WHEN OTHERS THEN
        v_rejected := SQLERRM LIKE 'invalid pgs3 hash helper input:%';
    END;
    ASSERT v_rejected, 'a NULL blob ID array element was accepted';

    v_rejected := false;
    BEGIN
        PERFORM 1
          FROM pgs3.hash_blob_sequence(
                   ARRAY[decode(repeat('00', 31), 'hex')]::bytea[]
               );
    EXCEPTION WHEN OTHERS THEN
        v_rejected := SQLERRM LIKE 'invalid pgs3 hash helper input:%';
    END;
    ASSERT v_rejected, 'a non-32-byte blob ID was accepted';
END
$hash_helpers$;

ROLLBACK;

SELECT 'pgs3 streaming hash helpers: ok' AS result;
