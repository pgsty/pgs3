-- pgs3 0.1.0 -> 0.1.1
--
-- PostgreSQL executes an extension update script in one transaction.  Do not
-- add psql meta-commands or transaction control here.  Existing functions are
-- replaced without changing their identity or privileges; new worker-only
-- functions are explicitly removed from PUBLIC before the service-role grants.

ALTER TABLE pgs3.blob SET (fillfactor = 80);

CREATE FUNCTION pgs3.extension_version()
RETURNS text
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT e.extversion
      FROM pg_catalog.pg_extension AS e
     WHERE e.extname = 'pgs3'
$$;

COMMENT ON FUNCTION pgs3.extension_version() IS
    'Return the installed pgs3 extension catalog version';

CREATE OR REPLACE FUNCTION pgs3._actor()
RETURNS name
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $$
    SELECT CASE
        WHEN current_setting('role', true) IS NOT NULL
         AND current_setting('role', true) NOT IN ('', 'none')
        THEN current_setting('role', true)::name
        WHEN nullif(current_setting('pgs3.worker_actor', true), '') IS NOT NULL
         AND session_user::text = coalesce(
                 nullif(current_setting('pgs3.server_role', true), ''),
                 'pgs3_server'
             )
         AND EXISTS (
                 SELECT 1
                   FROM pg_catalog.pg_roles AS actor
                  WHERE actor.rolname =
                        current_setting('pgs3.worker_actor', true)::name
                    AND pg_catalog.pg_has_role(
                            session_user,
                            actor.rolname,
                            'SET'
                        )
             )
        THEN current_setting('pgs3.worker_actor', true)::name
        ELSE session_user::name
END
$$;

CREATE OR REPLACE FUNCTION pgs3._ensure_blob(p_sha256 bytea, p_body bytea)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_inserted integer;
    v_size bigint := octet_length(p_body);
    v_chunk_size bigint := pgs3._setting_bytes('pgs3.chunk_size', 4194304);
    v_inline_threshold bigint := pgs3._setting_bytes('pgs3.inline_threshold', 65536);
    v_existing_size bigint;
    v_storage_kind text;
BEGIN
    IF octet_length(p_sha256) <> 32 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'SHA-256 must be 32 bytes';
    END IF;
    IF v_chunk_size <= 0 OR v_chunk_size > 1073741824 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'pgs3.chunk_size is out of range';
    END IF;

    INSERT INTO pgs3.blob (
        sha256, size, chunk_size, storage_kind, inline
    ) VALUES (
        p_sha256,
        v_size,
        v_chunk_size::integer,
        CASE WHEN v_size <= greatest(v_inline_threshold, 0)
             THEN 'inline' ELSE 'chunked' END,
        CASE WHEN v_size <= greatest(v_inline_threshold, 0)
             THEN p_body ELSE NULL END
    )
    ON CONFLICT (sha256) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    -- This row lock closes the refcount-zero/GC race until the object row and
    -- its refcount trigger have completed.
    SELECT b.size, b.storage_kind
      INTO v_existing_size, v_storage_kind
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_sha256
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'blob disappeared while being stored';
    END IF;
    IF v_existing_size <> v_size THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'SHA-256 collision with different blob size';
    END IF;

    IF v_inserted = 1 AND v_storage_kind = 'chunked' AND v_size > 0 THEN
        -- The overwhelmingly common streaming case already hands this helper
        -- one storage-sized piece.  Avoid making PostgreSQL allocate and copy
        -- that bytea again through substring()/generate_series().
        IF v_size <= v_chunk_size THEN
            INSERT INTO pgs3.chunk (blob_id, seq, data)
            VALUES (p_sha256, 0, p_body);
        ELSE
            INSERT INTO pgs3.chunk (blob_id, seq, data)
            SELECT p_sha256,
                   n::integer,
                   substring(
                       p_body
                       FROM (n * v_chunk_size + 1)::integer
                       FOR v_chunk_size::integer
                   )
              FROM generate_series(
                       0::bigint,
                       ((v_size - 1) / v_chunk_size)::bigint
                   ) AS n;
        END IF;
    END IF;

    RETURN p_sha256;
END
$$;

CREATE FUNCTION pgs3._worker_set_actor(p_actor name)
RETURNS name
LANGUAGE plpgsql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_server name := coalesce(
        nullif(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
    v_service record;
    v_actor record;
BEGIN
    IF session_user::name IS DISTINCT FROM v_server
       OR (current_setting('role', true) IS NOT NULL
           AND current_setting('role', true) NOT IN ('', 'none'))
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'worker actor context requires the restricted service session';
    END IF;

    SELECT * INTO v_service
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = v_server;
    IF NOT FOUND OR v_service.rolcanlogin OR v_service.rolinherit
       OR v_service.rolsuper OR v_service.rolbypassrls
       OR v_service.rolcreatedb OR v_service.rolcreaterole
       OR v_service.rolreplication
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.member = v_service.oid
              AND (m.admin_option OR m.inherit_option)
       )
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.roleid = v_service.oid
       )
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'pgs3.server_role is not a restricted service role';
    END IF;

    SELECT * INTO v_actor
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = p_actor;
    IF NOT FOUND OR v_actor.rolsuper OR v_actor.rolbypassrls
       OR v_actor.rolcreatedb OR v_actor.rolcreaterole
       OR v_actor.rolreplication
       OR NOT pg_catalog.pg_has_role(session_user, p_actor, 'SET')
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'worker actor is unavailable or privileged';
    END IF;

    PERFORM pg_catalog.set_config('pgs3.worker_actor', p_actor::text, true);
    RETURN p_actor;
END
$$;

CREATE FUNCTION pgs3._worker_put_chunk(
    p_actor name,
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_seq integer,
    p_data bytea,
    p_server_sha256 bytea
)
RETURNS TABLE(blob_id bytea, size bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
    v_size bigint;
    v_max_chunk constant bigint := 67108864;
BEGIN
    PERFORM pgs3._worker_set_actor(p_actor);
    IF p_data IS NULL OR p_server_sha256 IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22004', MESSAGE = 'sealed upload chunk cannot be NULL';
    END IF;
    v_size := octet_length(p_data);
    IF p_seq < 0 OR octet_length(p_server_sha256) <> 32 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid sealed upload chunk';
    END IF;
    IF v_size > v_max_chunk THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3S01', MESSAGE = 'EntityTooLarge: upload chunk',
            DETAIL = 'pgs3.error=EntityTooLarge';
    END IF;

    v_upload := pgs3._upload_for_update_at(
        p_upload_id, p_bucket, p_key, false
    );
    PERFORM pgs3._ensure_blob(p_server_sha256, p_data);
    INSERT INTO pgs3.upload_chunk (
        upload_id, part_number, seq, blob_id, size
    ) VALUES (
        p_upload_id, 0, p_seq, p_server_sha256, v_size
    )
    ON CONFLICT (upload_id, part_number, seq)
    DO UPDATE SET
        blob_id = excluded.blob_id,
        size = excluded.size,
        created_at = clock_timestamp();

    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp()
     WHERE u.upload_id = p_upload_id;
    RETURN QUERY SELECT p_server_sha256, v_size;
END
$$;

CREATE FUNCTION pgs3._worker_complete_upload(
    p_actor name,
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_checksum_sha256 bytea,
    p_server_sha256 bytea,
    p_server_md5 text,
    p_server_size bigint,
    p_chunk_blob_ids bytea[],
    p_chunk_sizes bigint[]
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
    v_bucket text;
    v_count bigint;
    v_min_seq integer;
    v_max_seq integer;
    v_size bigint;
    v_blob_ids bytea[];
    v_sizes bigint[];
    v_blob_id bytea;
    v_inline_threshold bigint := pgs3._setting_bytes(
        'pgs3.inline_threshold', 65536
    );
    v_info pgs3.object_info;
BEGIN
    PERFORM pgs3._worker_set_actor(p_actor);
    IF p_server_sha256 IS NULL OR p_server_md5 IS NULL
       OR p_server_size IS NULL OR p_chunk_blob_ids IS NULL
       OR p_chunk_sizes IS NULL
       OR octet_length(p_server_sha256) <> 32
       OR p_server_md5 !~ '^[0-9a-f]{32}$'
       OR p_server_size < 0
       OR cardinality(p_chunk_blob_ids) = 0
       OR cardinality(p_chunk_blob_ids) <> cardinality(p_chunk_sizes)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023', MESSAGE = 'invalid worker-sealed upload manifest';
    END IF;

    v_upload := pgs3._upload_for_update_at(
        p_upload_id, p_bucket, p_key, false
    );

    SELECT count(*), min(c.seq), max(c.seq), coalesce(sum(c.size), 0),
           array_agg(c.blob_id ORDER BY c.seq),
           array_agg(c.size ORDER BY c.seq)
      INTO v_count, v_min_seq, v_max_seq, v_size, v_blob_ids, v_sizes
      FROM pgs3.upload_chunk AS c
     WHERE c.upload_id = p_upload_id
       AND c.part_number = 0;
    IF v_count = 0
       OR v_min_seq <> 0
       OR v_count <> v_max_seq::bigint + 1
       OR v_size IS DISTINCT FROM p_server_size
       OR v_blob_ids IS DISTINCT FROM p_chunk_blob_ids
       OR v_sizes IS DISTINCT FROM p_chunk_sizes
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3P01',
            MESSAGE = 'InvalidPart: sealed upload chunks changed',
            DETAIL = 'pgs3.error=InvalidPart';
    END IF;

    -- Staged small bodies are intentionally canonicalized into blob.inline.
    -- Their existing bounded readback still applies, but only after the exact
    -- worker-observed manifest has been locked and matched.  Otherwise a
    -- same-tenant replacement could make the stored body disagree with the
    -- already verified HTTP checksum/trailer response.
    IF p_server_size <= greatest(v_inline_threshold, 0) THEN
        RETURN pgs3.complete_upload(
            p_upload_id, NULL, NULL, p_checksum_sha256
        );
    END IF;

    IF (v_upload.expected_sha256 IS NOT NULL
        AND v_upload.expected_sha256 IS DISTINCT FROM p_server_sha256)
       OR (p_checksum_sha256 IS NOT NULL
           AND p_checksum_sha256 IS DISTINCT FROM p_server_sha256)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3H01', MESSAGE = 'BadDigest: upload SHA-256 mismatch',
            DETAIL = 'pgs3.error=BadDigest';
    END IF;

    SELECT b.name INTO STRICT v_bucket
      FROM pgs3.bucket AS b
     WHERE b.bucket_id = v_upload.bucket_id;
    UPDATE pgs3.upload AS u
       SET state = 'completing', updated_at = clock_timestamp()
     WHERE u.upload_id = p_upload_id;

    v_blob_id := pgs3._ensure_staged_blob(
        p_server_sha256, p_server_size, p_upload_id, 0
    );
    v_info := pgs3._commit_canonical_locked(
        v_upload.bucket_id,
        v_bucket,
        v_upload.key,
        p_server_size,
        p_server_sha256,
        p_server_md5,
        v_blob_id,
        v_upload.content_type,
        v_upload.meta,
        v_upload.if_none_match,
        v_upload.if_match,
        'complete_upload'
    );
    DELETE FROM pgs3.upload AS u WHERE u.upload_id = p_upload_id;
    RETURN v_info;
END
$$;


CREATE OR REPLACE FUNCTION pgs3._ensure_composite_blob(
    p_sha256 bytea,
    p_size bigint,
    p_upload_id uuid,
    p_parts integer[]
)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_inserted integer;
    v_existing_size bigint;
    v_part_count bigint;
    v_source_size bigint;
    v_chunk_size bigint := pgs3._setting_bytes('pgs3.chunk_size', 4194304);
BEGIN
    IF octet_length(p_sha256) <> 32 OR p_size < 0 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid composite blob identity';
    END IF;
    IF v_chunk_size <= 0 OR v_chunk_size > 1073741824 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'pgs3.chunk_size is out of range';
    END IF;

    SELECT count(*), coalesce(sum(p.size), 0)
      INTO v_part_count, v_source_size
      FROM unnest(p_parts) WITH ORDINALITY AS requested(part_number, ordinality)
      JOIN pgs3.upload_part AS p
        ON p.upload_id = p_upload_id
       AND p.part_number = requested.part_number;
    IF v_part_count <> cardinality(p_parts) OR v_source_size <> p_size THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'composite source parts changed during completion';
    END IF;

    INSERT INTO pgs3.blob (
        sha256, size, chunk_size, storage_kind, inline
    ) VALUES (
        p_sha256, p_size, v_chunk_size::integer, 'composite', NULL
    )
    ON CONFLICT (sha256) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    SELECT b.size
      INTO v_existing_size
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_sha256
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'composite blob disappeared while being stored';
    END IF;
    IF v_existing_size <> p_size THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'SHA-256 collision with different blob size';
    END IF;

    IF v_inserted = 1 THEN
        INSERT INTO pgs3.blob_extent (
            final_blob_id, seq, logical_offset,
            source_blob_id, source_offset, length
        )
        SELECT p_sha256,
               (requested.ordinality - 1)::integer,
               coalesce(
                   sum(p.size) OVER (
                       ORDER BY requested.ordinality
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                   ),
                   0
               )::bigint,
               p.blob_id,
               0,
               p.size
          FROM unnest(p_parts) WITH ORDINALITY AS requested(part_number, ordinality)
          JOIN pgs3.upload_part AS p
            ON p.upload_id = p_upload_id
           AND p.part_number = requested.part_number
         ORDER BY requested.ordinality;
    END IF;

    RETURN p_sha256;
END
$$;

CREATE OR REPLACE FUNCTION pgs3._ensure_staged_blob(
    p_sha256 bytea,
    p_size bigint,
    p_upload_id uuid,
    p_part_number integer
)
RETURNS bytea
LANGUAGE plpgsql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_inserted integer;
    v_existing_size bigint;
    v_source_size bigint;
    v_chunk_size bigint := pgs3._setting_bytes('pgs3.chunk_size', 4194304);
BEGIN
    IF octet_length(p_sha256) <> 32 OR p_size < 0 OR p_part_number < 0 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid staged blob identity';
    END IF;
    IF v_chunk_size <= 0 OR v_chunk_size > 1073741824 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'pgs3.chunk_size is out of range';
    END IF;

    SELECT coalesce(sum(c.size), 0)
      INTO v_source_size
      FROM pgs3.upload_chunk AS c
     WHERE c.upload_id = p_upload_id
       AND c.part_number = p_part_number;
    IF v_source_size <> p_size THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'staged chunks changed during publication';
    END IF;

    INSERT INTO pgs3.blob (
        sha256, size, chunk_size, storage_kind, inline
    ) VALUES (
        p_sha256, p_size, v_chunk_size::integer, 'composite', NULL
    )
    ON CONFLICT (sha256) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    SELECT b.size
      INTO v_existing_size
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_sha256
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'staged blob disappeared while being stored';
    END IF;
    IF v_existing_size <> p_size THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'SHA-256 collision with different blob size';
    END IF;

    IF v_inserted = 1 THEN
        INSERT INTO pgs3.blob_extent (
            final_blob_id, seq, logical_offset,
            source_blob_id, source_offset, length
        )
        SELECT p_sha256,
               c.seq,
               coalesce(
                   sum(c.size) OVER (
                       ORDER BY c.seq
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                   ),
                   0
               )::bigint,
               c.blob_id,
               0,
               c.size
          FROM pgs3.upload_chunk AS c
         WHERE c.upload_id = p_upload_id
           AND c.part_number = p_part_number
         ORDER BY c.seq;
    END IF;
    RETURN p_sha256;
END
$$;

CREATE OR REPLACE FUNCTION pgs3.put_part(
    p_upload_id uuid,
    p_part_number integer,
    p_body bytea,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.part_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
    v_chunk_size bigint := pgs3._setting_bytes('pgs3.chunk_size', 4194304);
    v_seq bigint;
    v_piece bytea;
BEGIN
    IF p_body IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22004', MESSAGE = 'part body cannot be NULL';
    END IF;
    IF p_part_number NOT BETWEEN 1 AND 10000 OR v_chunk_size <= 0 THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3P01', MESSAGE = 'InvalidPart',
            DETAIL = 'pgs3.error=InvalidPart';
    END IF;
    v_upload := pgs3._upload_for_update(p_upload_id);
    IF NOT v_upload.multipart THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: upload is not multipart',
            DETAIL = 'pgs3.error=InvalidPart';
    END IF;

    PERFORM pgs3.begin_part(p_upload_id, p_part_number);

    IF octet_length(p_body) = 0 THEN
        PERFORM pgs3.put_chunk(
            p_upload_id, 0, ''::bytea, p_part_number, NULL
        );
    ELSE
        FOR v_seq IN 0..((octet_length(p_body) - 1) / v_chunk_size)::bigint LOOP
            v_piece := substring(
                p_body
                FROM (v_seq * v_chunk_size + 1)::integer
                FOR v_chunk_size::integer
            );
            PERFORM pgs3.put_chunk(
                p_upload_id, v_seq::integer, v_piece, p_part_number, NULL
            );
        END LOOP;
    END IF;
    RETURN pgs3.complete_part(p_upload_id, p_part_number, p_checksum_sha256);
END
$$;

CREATE OR REPLACE FUNCTION pgs3._grant_credential_role_membership(p_role_name name)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_server name := coalesce(
        nullif(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
    v_target record;
    v_server_role record;
BEGIN
    SELECT * INTO v_target
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = p_role_name;
    IF NOT FOUND OR p_role_name = v_server
       OR v_target.rolsuper OR v_target.rolbypassrls
       OR v_target.rolcreatedb OR v_target.rolcreaterole
       OR v_target.rolreplication
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'credential target role must exist and be unprivileged';
    END IF;

    SELECT * INTO v_server_role
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = v_server;
    IF NOT FOUND OR v_server_role.rolcanlogin OR v_server_role.rolinherit
       OR v_server_role.rolsuper OR v_server_role.rolbypassrls
       OR v_server_role.rolcreatedb OR v_server_role.rolcreaterole
       OR v_server_role.rolreplication
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.member = v_server_role.oid
              AND (m.admin_option OR m.inherit_option)
       )
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.roleid = v_server_role.oid
       )
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'pgs3.server_role must exist and be unprivileged',
            DETAIL = 'The worker-runtime install step creates pgs3_server; credential APIs are unavailable until that step succeeds.';
    END IF;

    EXECUTE format(
        'GRANT %I TO %I WITH SET TRUE, INHERIT FALSE',
        p_role_name,
        v_server
    );
END
$$;

CREATE OR REPLACE FUNCTION pgs3._credential_grant_server_membership()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_server name := COALESCE(
        NULLIF(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
    v_target record;
    v_server_role record;
BEGIN
    SELECT * INTO v_server_role
      FROM pg_catalog.pg_roles
     WHERE rolname = v_server;
    IF NOT FOUND OR v_server_role.rolcanlogin OR v_server_role.rolinherit
       OR v_server_role.rolsuper OR v_server_role.rolbypassrls
       OR v_server_role.rolcreatedb OR v_server_role.rolcreaterole
       OR v_server_role.rolreplication
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.member = v_server_role.oid
              AND (m.admin_option OR m.inherit_option)
       )
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.roleid = v_server_role.oid
       )
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'pgs3.server_role must exist and be unprivileged';
    END IF;

    SELECT * INTO v_target
      FROM pg_catalog.pg_roles
     WHERE rolname = NEW.role_name;
    IF NOT FOUND OR NEW.role_name = v_server
       OR v_target.rolsuper OR v_target.rolbypassrls
       OR v_target.rolcreatedb OR v_target.rolcreaterole
       OR v_target.rolreplication
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'credential target role must exist and be unprivileged';
    END IF;

    EXECUTE format(
        'GRANT %I TO %I WITH SET TRUE, INHERIT FALSE',
        NEW.role_name,
        v_server
    );
    RETURN NEW;
END
$$;

-- Re-run the membership trigger for credentials already present at 0.1.0.
-- The assignment does not expose or change the secret-bearing row values.
UPDATE pgs3.credential SET role_name = role_name;



CREATE OR REPLACE FUNCTION pgs3.fork_bucket(
    p_source_bucket text,
    p_destination_bucket text,
    p_destination_config jsonb DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
SET work_mem = '64MB'
AS $$
DECLARE
    v_source_bucket_id bigint;
    v_destination_bucket_id bigint;
    v_source_config jsonb;
    v_actor name;
    v_forked_at timestamptz;
    v_count bigint;
    v_replication_role text;
BEGIN
    PERFORM pgs3._validate_bucket_name(p_destination_bucket);
    IF p_destination_config IS NOT NULL
       AND jsonb_typeof(p_destination_config) <> 'object'
    THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'bucket config must be a JSON object';
    END IF;

    -- A fork is a two-name lifecycle operation.  Lock source/shared and
    -- destination/exclusive in bytewise name order so concurrent forks cannot
    -- deadlock.  Shared source mode excludes drop while preserving ordinary
    -- per-key writer concurrency; INSERT ... SELECT supplies the MVCC snapshot.
    IF p_source_bucket COLLATE "C" < p_destination_bucket COLLATE "C" THEN
        PERFORM pgs3._lock_bucket_lifecycle(p_source_bucket, false);
        PERFORM pgs3._lock_bucket_lifecycle(p_destination_bucket, true);
    ELSIF p_source_bucket COLLATE "C" > p_destination_bucket COLLATE "C" THEN
        PERFORM pgs3._lock_bucket_lifecycle(p_destination_bucket, true);
        PERFORM pgs3._lock_bucket_lifecycle(p_source_bucket, false);
    ELSE
        PERFORM pgs3._lock_bucket_lifecycle(p_source_bucket, true);
    END IF;

    v_source_bucket_id := pgs3._bucket_id(p_source_bucket);
    SELECT b.config INTO STRICT v_source_config
      FROM pgs3.bucket AS b
     WHERE b.bucket_id = v_source_bucket_id;
    v_actor := pgs3._actor();

    INSERT INTO pgs3.bucket (name, owner, config)
    VALUES (
        p_destination_bucket,
        v_actor,
        coalesce(p_destination_config, v_source_config)
    )
    RETURNING bucket_id INTO v_destination_bucket_id;
    v_forked_at := clock_timestamp();

    -- Every copied bucket/blob reference is already protected by a source row,
    -- while the destination bucket was inserted above under its lifecycle
    -- lock.  Skip the per-row FK probes and object refcount trigger only for
    -- this trusted bulk INSERT; CHECK constraints and unique/index maintenance
    -- remain active.  Restore the caller's exact trigger mode on both paths.
    v_replication_role := current_setting('session_replication_role');
    BEGIN
        PERFORM set_config('session_replication_role', 'replica', true);
        -- Feed the actually inserted blob IDs directly into the set-wise
        -- refcount update.  A materialized DML CTE avoids rescanning the new
        -- 100k-row destination heap/index while retaining one statement
        -- snapshot under concurrent source-key writes.
        WITH inserted AS MATERIALIZED (
            INSERT INTO pgs3.object (
                bucket_id, key, version_id, is_latest, delete_marker, size,
                etag, sha256, content_type, meta, inline, blob_id, created_at,
                created_by
            )
            SELECT v_destination_bucket_id,
                   o.key,
                   nextval('pgs3.object_version_id_seq'),
                   true,
                   o.delete_marker,
                   o.size,
                   o.etag,
                   o.sha256,
                   o.content_type,
                   o.meta,
                   NULL,
                   o.blob_id,
                   v_forked_at,
                   v_actor
              FROM pgs3.object AS o
             WHERE o.bucket_id = v_source_bucket_id
               AND o.is_latest
            RETURNING blob_id
        ), refs AS MATERIALIZED (
            SELECT i.blob_id, count(*)::bigint AS n
              FROM inserted AS i
             WHERE i.blob_id IS NOT NULL
             GROUP BY i.blob_id
        ), bumped AS (
            UPDATE pgs3.blob AS b
               SET refcount = b.refcount + refs.n
              FROM refs
             WHERE b.sha256 = refs.blob_id
            RETURNING b.sha256
        )
        SELECT count(*) INTO STRICT v_count FROM inserted;
        PERFORM set_config(
            'session_replication_role', v_replication_role, true
        );
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config(
            'session_replication_role', v_replication_role, true
        );
        RAISE;
    END;

    PERFORM pgs3._notify_change('fork_bucket');
    RETURN v_count;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION USING
        ERRCODE = 'P3E01',
        MESSAGE = format('BucketAlreadyExists: %s', p_destination_bucket),
        DETAIL = 'pgs3.error=BucketAlreadyExists';
END
$$;


REVOKE ALL ON FUNCTION pgs3._worker_set_actor(name) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3._worker_put_chunk(
    name, text, text, uuid, integer, bytea, bytea
) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3._worker_complete_upload(
    name, text, text, uuid, bytea, bytea, text, bigint, bytea[], bigint[]
) FROM PUBLIC;

DO $pgs3_upgrade_server_grants$
DECLARE
    v_server name := coalesce(
        nullif(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
    v_role record;
BEGIN
    SELECT * INTO v_role
      FROM pg_catalog.pg_roles AS r
     WHERE r.rolname = v_server;
    IF NOT FOUND OR v_role.rolcanlogin OR v_role.rolinherit
       OR v_role.rolsuper OR v_role.rolbypassrls
       OR v_role.rolcreatedb OR v_role.rolcreaterole
       OR v_role.rolreplication
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.member = v_role.oid
              AND (m.admin_option OR m.inherit_option)
       )
       OR EXISTS (
           SELECT 1
             FROM pg_catalog.pg_auth_members AS m
            WHERE m.roleid = v_role.oid
       )
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'pgs3.server_role must exist and be restricted';
    END IF;

    -- 0.1.0 granted these capabilities to the literal pgs3_server role even
    -- when the GUC selected another service role.  Remove only that historical
    -- grant set in this database before installing the configured set below.
    IF EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'pgs3_server'
    ) THEN
        EXECUTE format(
            'REVOKE CONNECT ON DATABASE %I FROM pgs3_server',
            current_database()
        );
        REVOKE USAGE ON SCHEMA pgs3 FROM pgs3_server;
        REVOKE SELECT ON TABLE pgs3.credential FROM pgs3_server;
        REVOKE EXECUTE ON FUNCTION pgs3._worker_set_state(
            text, integer, integer, text, text, integer, text
        ) FROM pgs3_server;
        REVOKE EXECUTE ON FUNCTION pgs3._worker_add_metric(
            text, integer, text, bigint, bigint, bigint, bigint, bigint,
            bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint
        ) FROM pgs3_server;
    END IF;

    EXECUTE format(
        'GRANT CONNECT ON DATABASE %I TO %I',
        current_database(), v_server
    );
    EXECUTE format('GRANT USAGE ON SCHEMA pgs3 TO %I', v_server);
    EXECUTE format('GRANT SELECT ON TABLE pgs3.credential TO %I', v_server);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgs3._worker_set_state(text, integer, integer, text, text, integer, text) TO %I',
        v_server
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgs3._worker_add_metric(text, integer, text, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint) TO %I',
        v_server
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgs3._worker_set_actor(name) TO %I',
        v_server
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgs3._worker_put_chunk(name, text, text, uuid, integer, bytea, bytea) TO %I',
        v_server
    );
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgs3._worker_complete_upload(name, text, text, uuid, bytea, bytea, text, bigint, bytea[], bigint[]) TO %I',
        v_server
    );
END
$pgs3_upgrade_server_grants$;
