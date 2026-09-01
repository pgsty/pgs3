-- pgs3 semantic and storage layer.
--
-- This file is consumed by pgrx::extension_sql_file! and intentionally has no
-- psql meta-commands or transaction control.  The Rust-provided
-- pgs3.sha256(bytea) function is installed after this bootstrap file; calls to
-- it therefore live only in PL/pgSQL bodies, whose statements are prepared on
-- first execution.

CREATE SCHEMA IF NOT EXISTS pgs3;

GRANT USAGE ON SCHEMA pgs3 TO PUBLIC;

-- Report the catalog version, not a value compiled into the shared library.
-- This remains correct while an operator stages a new library before running
-- ALTER EXTENSION and gives SQL-only tooling one stable readiness probe.
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

CREATE SEQUENCE pgs3.object_version_id_seq AS bigint;

CREATE TABLE pgs3.bucket (
    bucket_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text COLLATE "C" NOT NULL UNIQUE,
    owner name NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT bucket_config_is_object CHECK (jsonb_typeof(config) = 'object')
);

CREATE TABLE pgs3.blob (
    sha256 bytea PRIMARY KEY,
    size bigint NOT NULL,
    chunk_size integer NOT NULL,
    storage_kind text NOT NULL,
    inline bytea,
    refcount bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT blob_sha256_length CHECK (octet_length(sha256) = 32),
    CONSTRAINT blob_size_nonnegative CHECK (size >= 0),
    CONSTRAINT blob_chunk_size_positive CHECK (chunk_size > 0),
    CONSTRAINT blob_refcount_nonnegative CHECK (refcount >= 0),
    CONSTRAINT blob_storage_kind_valid CHECK (
        storage_kind IN ('inline', 'chunked', 'composite')
    ),
    CONSTRAINT blob_payload_shape CHECK (
        (storage_kind = 'inline'
         AND inline IS NOT NULL
         AND octet_length(inline) = size)
        OR
        (storage_kind IN ('chunked', 'composite') AND inline IS NULL)
    )
) WITH (fillfactor = 80);

-- Small payload bytes are canonical here, never in object.inline.  EXTERNAL
-- prevents PostgreSQL from compressing the already bounded bytea while still
-- allowing ordinary TOAST storage near the configured inline threshold.
ALTER TABLE pgs3.blob ALTER COLUMN inline SET STORAGE EXTERNAL;

CREATE TABLE pgs3.object (
    bucket_id bigint NOT NULL REFERENCES pgs3.bucket(bucket_id),
    key text COLLATE "C" NOT NULL,
    version_id bigint NOT NULL DEFAULT nextval('pgs3.object_version_id_seq'),
    is_latest boolean NOT NULL DEFAULT true,
    delete_marker boolean NOT NULL DEFAULT false,
    size bigint NOT NULL,
    etag text,
    sha256 bytea,
    content_type text,
    meta jsonb NOT NULL DEFAULT '{}'::jsonb,
    inline bytea,
    blob_id bytea REFERENCES pgs3.blob(sha256),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    created_by name NOT NULL,
    PRIMARY KEY (bucket_id, key, version_id),
    CONSTRAINT object_key_length CHECK (octet_length(key) BETWEEN 1 AND 1024),
    CONSTRAINT object_size_nonnegative CHECK (size >= 0),
    CONSTRAINT object_meta_is_object CHECK (jsonb_typeof(meta) = 'object'),
    CONSTRAINT object_sha256_length CHECK (sha256 IS NULL OR octet_length(sha256) = 32),
    CONSTRAINT object_etag_shape CHECK (
        etag IS NULL OR etag ~ '^[0-9a-f]{32}(-[1-9][0-9]*)?$'
    ),
    CONSTRAINT object_payload_shape CHECK (
        (
            delete_marker
            AND size = 0
            AND etag IS NULL
            AND sha256 IS NULL
            AND inline IS NULL
            AND blob_id IS NULL
        )
        OR
        (
            NOT delete_marker
            AND etag IS NOT NULL
            AND sha256 IS NOT NULL
            AND inline IS NULL
            AND blob_id IS NOT NULL
            AND blob_id = sha256
        )
    )
);

-- The first index is explicitly required by the storage contract.  Its INCLUDE
-- columns also cover the bounded LIST projection, avoiding a third partial
-- B-tree with the same keys and predicate on every object write/fork.  The
-- second index additionally makes the stronger invariant (one latest row
-- including a delete marker) impossible to violate with direct SQL.
CREATE UNIQUE INDEX object_latest_live_uniq
    ON pgs3.object (bucket_id, key)
    INCLUDE (version_id, size, etag, content_type, created_at)
    WHERE is_latest AND NOT delete_marker;

CREATE UNIQUE INDEX object_latest_any_uniq
    ON pgs3.object (bucket_id, key)
    WHERE is_latest;

CREATE INDEX object_versions_idx
    ON pgs3.object (bucket_id, key, version_id DESC);

CREATE INDEX object_blob_idx
    ON pgs3.object (blob_id)
    WHERE blob_id IS NOT NULL;

CREATE TABLE pgs3.chunk (
    blob_id bytea NOT NULL REFERENCES pgs3.blob(sha256) ON DELETE CASCADE,
    seq integer NOT NULL,
    data bytea NOT NULL,
    PRIMARY KEY (blob_id, seq),
    CONSTRAINT chunk_seq_nonnegative CHECK (seq >= 0)
) PARTITION BY HASH (blob_id);

ALTER TABLE pgs3.chunk ALTER COLUMN data SET STORAGE EXTERNAL;

CREATE TABLE pgs3.chunk_p00 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE pgs3.chunk_p01 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 1);
CREATE TABLE pgs3.chunk_p02 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 2);
CREATE TABLE pgs3.chunk_p03 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 3);
CREATE TABLE pgs3.chunk_p04 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 4);
CREATE TABLE pgs3.chunk_p05 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 5);
CREATE TABLE pgs3.chunk_p06 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 6);
CREATE TABLE pgs3.chunk_p07 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 7);
CREATE TABLE pgs3.chunk_p08 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 8);
CREATE TABLE pgs3.chunk_p09 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 9);
CREATE TABLE pgs3.chunk_p10 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 10);
CREATE TABLE pgs3.chunk_p11 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 11);
CREATE TABLE pgs3.chunk_p12 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 12);
CREATE TABLE pgs3.chunk_p13 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 13);
CREATE TABLE pgs3.chunk_p14 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 14);
CREATE TABLE pgs3.chunk_p15 PARTITION OF pgs3.chunk FOR VALUES WITH (MODULUS 16, REMAINDER 15);

-- A composite blob is an immutable logical byte sequence over already
-- canonical source blobs.  Multipart completion creates only these metadata
-- rows; it never reassigns or rewrites the source chunk/TOAST payloads.
CREATE TABLE pgs3.blob_extent (
    final_blob_id bytea NOT NULL
        REFERENCES pgs3.blob(sha256) ON DELETE CASCADE,
    seq integer NOT NULL,
    logical_offset bigint NOT NULL,
    source_blob_id bytea NOT NULL
        REFERENCES pgs3.blob(sha256) ON DELETE RESTRICT,
    source_offset bigint NOT NULL DEFAULT 0,
    length bigint NOT NULL,
    PRIMARY KEY (final_blob_id, seq),
    CONSTRAINT blob_extent_seq_nonnegative CHECK (seq >= 0),
    CONSTRAINT blob_extent_logical_offset_nonnegative CHECK (logical_offset >= 0),
    CONSTRAINT blob_extent_source_offset_nonnegative CHECK (source_offset >= 0),
    CONSTRAINT blob_extent_length_nonnegative CHECK (length >= 0),
    CONSTRAINT blob_extent_not_self_referential CHECK (final_blob_id <> source_blob_id)
);

CREATE INDEX blob_extent_source_idx ON pgs3.blob_extent (source_blob_id);

CREATE TABLE pgs3.upload (
    upload_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id bigint NOT NULL REFERENCES pgs3.bucket(bucket_id),
    key text COLLATE "C" NOT NULL,
    multipart boolean NOT NULL DEFAULT false,
    content_type text,
    meta jsonb NOT NULL DEFAULT '{}'::jsonb,
    if_none_match text,
    if_match text,
    expected_sha256 bytea,
    initiated_by name NOT NULL,
    state text NOT NULL DEFAULT 'pending',
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_expires_at timestamptz NOT NULL
        DEFAULT (clock_timestamp() + interval '5 minutes'),
    CONSTRAINT upload_key_length CHECK (octet_length(key) BETWEEN 1 AND 1024),
    CONSTRAINT upload_meta_is_object CHECK (jsonb_typeof(meta) = 'object'),
    CONSTRAINT upload_expected_sha256_length CHECK (
        expected_sha256 IS NULL OR octet_length(expected_sha256) = 32
    ),
    CONSTRAINT upload_state_valid CHECK (state IN ('pending', 'completing'))
);

CREATE INDEX upload_pending_gc_idx
    ON pgs3.upload (lease_expires_at, updated_at, upload_id)
    WHERE state = 'pending';

CREATE TABLE pgs3.upload_chunk (
    upload_id uuid NOT NULL REFERENCES pgs3.upload(upload_id) ON DELETE CASCADE,
    part_number integer NOT NULL DEFAULT 0,
    seq integer NOT NULL,
    blob_id bytea NOT NULL REFERENCES pgs3.blob(sha256) ON DELETE RESTRICT,
    size bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (upload_id, part_number, seq),
    CONSTRAINT upload_chunk_part_nonnegative CHECK (part_number >= 0),
    CONSTRAINT upload_chunk_seq_nonnegative CHECK (seq >= 0),
    CONSTRAINT upload_chunk_size_nonnegative CHECK (size >= 0)
);

CREATE INDEX upload_chunk_blob_idx ON pgs3.upload_chunk (blob_id);

CREATE TABLE pgs3.upload_part (
    upload_id uuid NOT NULL REFERENCES pgs3.upload(upload_id) ON DELETE CASCADE,
    part_number integer NOT NULL,
    size bigint NOT NULL,
    etag text NOT NULL,
    sha256 bytea NOT NULL,
    blob_id bytea NOT NULL REFERENCES pgs3.blob(sha256) ON DELETE RESTRICT,
    completed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (upload_id, part_number),
    CONSTRAINT upload_part_number_positive CHECK (part_number > 0),
    CONSTRAINT upload_part_size_nonnegative CHECK (size >= 0),
    CONSTRAINT upload_part_etag_shape CHECK (etag ~ '^[0-9a-f]{32}$'),
    CONSTRAINT upload_part_sha256_length CHECK (octet_length(sha256) = 32),
    CONSTRAINT upload_part_blob_matches_sha256 CHECK (blob_id = sha256)
);

-- SigV4 needs the original secret.  This table deliberately has no tenant
-- policy and no PUBLIC privileges: the administrator grants SELECT only to the
-- dedicated HTTP server role.
CREATE TABLE pgs3.credential (
    access_key text PRIMARY KEY,
    secret text NOT NULL,
    role_name name NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT credential_access_key_nonempty CHECK (access_key <> ''),
    CONSTRAINT credential_secret_nonempty CHECK (secret <> '')
);

REVOKE ALL ON TABLE pgs3.credential FROM PUBLIC;

CREATE TYPE pgs3.bucket_info AS (
    name text,
    owner name,
    created_at timestamptz,
    config jsonb
);

CREATE TYPE pgs3.object_info AS (
    bucket text,
    key text,
    version_id bigint,
    is_latest boolean,
    delete_marker boolean,
    size bigint,
    etag text,
    sha256 bytea,
    content_type text,
    meta jsonb,
    created_at timestamptz,
    created_by name
);

CREATE TYPE pgs3.object_data AS (
    info pgs3.object_info,
    body bytea
);

CREATE TYPE pgs3.delete_result AS (
    key text,
    version_id bigint,
    delete_marker boolean,
    deleted boolean
);

CREATE TYPE pgs3.list_entry AS (
    key text,
    common_prefix text,
    version_id bigint,
    size bigint,
    etag text,
    content_type text,
    last_modified timestamptz,
    meta jsonb,
    continuation_token text
);

CREATE TYPE pgs3.version_entry AS (
    key text,
    common_prefix text,
    version_id bigint,
    is_latest boolean,
    delete_marker boolean,
    size bigint,
    etag text,
    last_modified timestamptz,
    next_key_marker text,
    next_version_id_marker bigint
);

CREATE TYPE pgs3.part_info AS (
    part_number integer,
    size bigint,
    etag text,
    sha256 bytea,
    completed_at timestamptz
);

-- The role selected with SET ROLE is preserved in the role GUC while a
-- SECURITY DEFINER function is executing.  Direct connections without SET
-- ROLE use session_user.  The restricted HTTP worker is the sole exception:
-- worker-only functions validate its immutable session identity and SET-only
-- membership, then install a transaction-local actor marker without granting
-- the service role ambient tenant privileges.
CREATE FUNCTION pgs3._actor()
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

-- LISTEN/NOTIFY channels have no ACL or RLS boundary: every role that can
-- connect to this database can listen on `pgs3`. Keep the mandatory
-- transactional change signal deliberately opaque. Tenant-scoped consumers
-- fetch details through the RLS-protected SQL API instead of receiving object
-- identifiers on the global channel.
CREATE FUNCTION pgs3._notify_change(p_operation text)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_operation IS NULL OR p_operation !~ '^[a-z_]{1,32}$' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023', MESSAGE = 'invalid pgs3 notification operation';
    END IF;
    PERFORM pg_notify(
        'pgs3', jsonb_build_object('op', p_operation)::text
    );
END
$$;

CREATE FUNCTION pgs3._setting_bytes(p_name text, p_default bigint)
RETURNS bigint
LANGUAGE plpgsql
STABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
DECLARE
    v text;
BEGIN
    v := current_setting(p_name, true);
    IF v IS NULL OR v = '' THEN
        RETURN p_default;
    END IF;
    RETURN pg_size_bytes(v);
EXCEPTION WHEN invalid_parameter_value OR numeric_value_out_of_range THEN
    RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = format('invalid byte-size setting %s=%s', p_name, v);
END
$$;

CREATE FUNCTION pgs3._validate_bucket_name(p_name text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
BEGIN
    IF octet_length(p_name) NOT BETWEEN 3 AND 63
       OR p_name !~ '^[a-z0-9][a-z0-9.-]*[a-z0-9]$'
       OR p_name LIKE '%..%'
       OR p_name LIKE '%.-%'
       OR p_name LIKE '%-.%'
       OR p_name ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'InvalidBucketName',
            DETAIL = 'pgs3.error=InvalidBucketName';
    END IF;
END
$$;

CREATE FUNCTION pgs3._validate_key(p_key text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
BEGIN
    IF octet_length(p_key) NOT BETWEEN 1 AND 1024 THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'object keys must contain between 1 and 1024 UTF-8 bytes';
    END IF;
END
$$;

CREATE FUNCTION pgs3._bucket_id(p_name text)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_id bigint;
BEGIN
    SELECT b.bucket_id
      INTO v_id
      FROM pgs3.bucket AS b
     WHERE b.name = p_name COLLATE "C"
       AND pg_has_role(pgs3._actor(), b.owner, 'USAGE');

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3B01',
            MESSAGE = format('NoSuchBucket: %s', p_name),
            DETAIL = 'pgs3.error=NoSuchBucket';
    END IF;
    RETURN v_id;
END
$$;

-- Bucket names, rather than numeric IDs, define the lifecycle lock identity so
-- delete/recreate and fork-to-a-new-name participate in the same protocol.
-- Shared holders may create object/upload children concurrently; create,
-- delete, and a fork destination take the exclusive form.
CREATE FUNCTION pgs3._lock_bucket_lifecycle(
    p_name text,
    p_exclusive boolean
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_lock_id bigint := hashtextextended(
        'pgs3.bucket' || chr(31) || p_name,
        1886876467
    );
BEGIN
    IF p_exclusive THEN
        PERFORM pg_advisory_xact_lock(v_lock_id);
    ELSE
        PERFORM pg_advisory_xact_lock_shared(v_lock_id);
    END IF;
END
$$;

-- Child creation must lock before resolving the bucket ID.  Otherwise a
-- delete/recreate can leave the caller holding a stale ID and expose an FK
-- violation instead of the semantic NoSuchBucket result.  The optional ID
-- assertion also protects direct calls to underscore publication helpers.
CREATE FUNCTION pgs3._bucket_id_for_child(
    p_name text,
    p_expected_bucket_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
BEGIN
    PERFORM pgs3._lock_bucket_lifecycle(p_name, false);
    v_bucket_id := pgs3._bucket_id(p_name);
    IF p_expected_bucket_id IS NOT NULL
       AND v_bucket_id IS DISTINCT FROM p_expected_bucket_id
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3B01',
            MESSAGE = format('NoSuchBucket: %s', p_name),
            DETAIL = 'pgs3.error=NoSuchBucket';
    END IF;
    RETURN v_bucket_id;
END
$$;

CREATE FUNCTION pgs3._lock_key(p_bucket_id bigint, p_key text)
RETURNS void
LANGUAGE sql
VOLATILE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
    SELECT pg_advisory_xact_lock(
        hashtextextended(p_bucket_id::text || chr(31) || p_key, 1886876467)
    )
$$;

CREATE FUNCTION pgs3._normalize_etag(p_etag text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
    SELECT CASE WHEN p_etag IS NULL THEN NULL
                ELSE trim(BOTH '"' FROM btrim(p_etag)) END
$$;

CREATE FUNCTION pgs3._check_write_preconditions(
    p_exists boolean,
    p_delete_marker boolean,
    p_current_etag text,
    p_if_none_match text,
    p_if_match text
)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_if_none_match IS NOT NULL
       AND pgs3._normalize_etag(p_if_none_match) <> '*'
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'write If-None-Match only supports *';
    END IF;

    IF p_if_none_match IS NOT NULL
       AND p_exists
       AND NOT p_delete_marker
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3C01',
            MESSAGE = 'PreconditionFailed: If-None-Match',
            DETAIL = 'pgs3.error=PreconditionFailed';
    END IF;

    IF p_if_match IS NOT NULL
       AND (
           NOT p_exists
           OR p_delete_marker
           OR p_current_etag IS DISTINCT FROM pgs3._normalize_etag(p_if_match)
       )
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3C01',
            MESSAGE = 'PreconditionFailed: If-Match',
            DETAIL = 'pgs3.error=PreconditionFailed';
    END IF;
END
$$;

CREATE FUNCTION pgs3._object_info(p_bucket text, p_object pgs3.object)
RETURNS pgs3.object_info
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pgs3
AS $$
    SELECT ROW(
        p_bucket,
        p_object.key,
        p_object.version_id,
        p_object.is_latest,
        p_object.delete_marker,
        p_object.size,
        p_object.etag,
        p_object.sha256,
        p_object.content_type,
        p_object.meta,
        p_object.created_at,
        p_object.created_by
    )::pgs3.object_info
$$;

-- Compute the smallest valid UTF-8 string strictly above every string having
-- p_prefix as a prefix.  With COLLATE "C", UTF-8 byte order follows code point
-- order, making this a usable exclusive upper bound and an index jump target.
CREATE FUNCTION pgs3._prefix_end(p_prefix text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
DECLARE
    i integer;
    cp integer;
BEGIN
    IF p_prefix = '' THEN
        RETURN NULL;
    END IF;

    i := char_length(p_prefix);
    WHILE i > 0 LOOP
        cp := ascii(substr(p_prefix, i, 1));
        IF cp < 1114111 THEN
            IF cp = 55295 THEN
                cp := 57344;
            ELSE
                cp := cp + 1;
            END IF;
            RETURN substr(p_prefix, 1, i - 1) || chr(cp);
        END IF;
        i := i - 1;
    END LOOP;
    RETURN NULL;
END
$$;

-- Tenant-facing tables use bucket ownership (including inherited membership)
-- as their row boundary.  The SECURITY DEFINER API repeats the same check and
-- owns the invariant-sensitive tables; direct grants remain safe under RLS.
ALTER TABLE pgs3.bucket ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.object ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.blob ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.chunk ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.blob_extent ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.upload ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.upload_chunk ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgs3.upload_part ENABLE ROW LEVEL SECURITY;

CREATE POLICY bucket_tenant_policy ON pgs3.bucket
    USING (pg_has_role(current_user, owner, 'USAGE'))
    WITH CHECK (pg_has_role(current_user, owner, 'USAGE'));

CREATE POLICY object_tenant_policy ON pgs3.object
    USING (EXISTS (
        SELECT 1
          FROM pgs3.bucket AS b
         WHERE b.bucket_id = object.bucket_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ))
    WITH CHECK (EXISTS (
        SELECT 1
          FROM pgs3.bucket AS b
         WHERE b.bucket_id = object.bucket_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ));

CREATE POLICY blob_tenant_select_policy ON pgs3.blob
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM pgs3.object AS o
              JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
             WHERE o.blob_id = blob.sha256
               AND pg_has_role(current_user, b.owner, 'USAGE')
        )
        OR EXISTS (
            SELECT 1
              FROM pgs3.blob_extent AS e
              JOIN pgs3.object AS o ON o.blob_id = e.final_blob_id
              JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
             WHERE e.source_blob_id = blob.sha256
               AND pg_has_role(current_user, b.owner, 'USAGE')
        )
    );

CREATE POLICY chunk_tenant_select_policy ON pgs3.chunk
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1
              FROM pgs3.object AS o
              JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
             WHERE o.blob_id = chunk.blob_id
               AND pg_has_role(current_user, b.owner, 'USAGE')
        )
        OR EXISTS (
            SELECT 1
              FROM pgs3.blob_extent AS e
              JOIN pgs3.object AS o ON o.blob_id = e.final_blob_id
              JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
             WHERE e.source_blob_id = chunk.blob_id
               AND pg_has_role(current_user, b.owner, 'USAGE')
        )
    );

CREATE POLICY blob_extent_tenant_select_policy ON pgs3.blob_extent
    FOR SELECT
    USING (EXISTS (
        SELECT 1
          FROM pgs3.object AS o
          JOIN pgs3.bucket AS b ON b.bucket_id = o.bucket_id
         WHERE o.blob_id = blob_extent.final_blob_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ));

CREATE POLICY upload_tenant_policy ON pgs3.upload
    USING (EXISTS (
        SELECT 1
          FROM pgs3.bucket AS b
         WHERE b.bucket_id = upload.bucket_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ))
    WITH CHECK (EXISTS (
        SELECT 1
          FROM pgs3.bucket AS b
         WHERE b.bucket_id = upload.bucket_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ));

CREATE POLICY upload_chunk_tenant_policy ON pgs3.upload_chunk
    USING (EXISTS (
        SELECT 1
          FROM pgs3.upload AS u
          JOIN pgs3.bucket AS b ON b.bucket_id = u.bucket_id
         WHERE u.upload_id = upload_chunk.upload_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ))
    WITH CHECK (EXISTS (
        SELECT 1
          FROM pgs3.upload AS u
          JOIN pgs3.bucket AS b ON b.bucket_id = u.bucket_id
         WHERE u.upload_id = upload_chunk.upload_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ));

CREATE POLICY upload_part_tenant_policy ON pgs3.upload_part
    USING (EXISTS (
        SELECT 1
          FROM pgs3.upload AS u
          JOIN pgs3.bucket AS b ON b.bucket_id = u.bucket_id
         WHERE u.upload_id = upload_part.upload_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ))
    WITH CHECK (EXISTS (
        SELECT 1
          FROM pgs3.upload AS u
          JOIN pgs3.bucket AS b ON b.bucket_id = u.bucket_id
         WHERE u.upload_id = upload_part.upload_id
           AND pg_has_role(current_user, b.owner, 'USAGE')
    ));

-- Statement-level transition-table triggers keep refcounts correct even for a
-- 100k-row fork, updating each distinct blob once per statement.
CREATE FUNCTION pgs3._blob_refs_after_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    UPDATE pgs3.blob AS b
       SET refcount = b.refcount + d.n
      FROM (
          SELECT blob_id, count(*)::bigint AS n
            FROM new_object_rows
           WHERE blob_id IS NOT NULL
           GROUP BY blob_id
      ) AS d
     WHERE b.sha256 = d.blob_id;
    RETURN NULL;
END
$$;

CREATE FUNCTION pgs3._blob_refs_after_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    UPDATE pgs3.blob AS b
       SET refcount = b.refcount - d.n
      FROM (
          SELECT blob_id, count(*)::bigint AS n
            FROM old_object_rows
           WHERE blob_id IS NOT NULL
           GROUP BY blob_id
      ) AS d
     WHERE b.sha256 = d.blob_id;
    RETURN NULL;
END
$$;

CREATE FUNCTION pgs3._blob_refs_after_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    UPDATE pgs3.blob AS b
       SET refcount = b.refcount + d.n
      FROM (
          SELECT blob_id, sum(delta)::bigint AS n
            FROM (
                SELECT blob_id, count(*)::bigint AS delta
                  FROM new_object_rows
                 WHERE blob_id IS NOT NULL
                 GROUP BY blob_id
                UNION ALL
                SELECT blob_id, -count(*)::bigint AS delta
                  FROM old_object_rows
                 WHERE blob_id IS NOT NULL
                 GROUP BY blob_id
            ) AS changes
           GROUP BY blob_id
          HAVING sum(delta) <> 0
      ) AS d
     WHERE b.sha256 = d.blob_id;
    RETURN NULL;
END
$$;

CREATE TRIGGER object_blob_refs_insert
AFTER INSERT ON pgs3.object
REFERENCING NEW TABLE AS new_object_rows
FOR EACH STATEMENT EXECUTE FUNCTION pgs3._blob_refs_after_insert();

CREATE TRIGGER object_blob_refs_delete
AFTER DELETE ON pgs3.object
REFERENCING OLD TABLE AS old_object_rows
FOR EACH STATEMENT EXECUTE FUNCTION pgs3._blob_refs_after_delete();

CREATE TRIGGER object_blob_refs_update
AFTER UPDATE ON pgs3.object
REFERENCING OLD TABLE AS old_object_rows NEW TABLE AS new_object_rows
FOR EACH STATEMENT EXECUTE FUNCTION pgs3._blob_refs_after_update();

-- Pending multipart parts and composite extents are also owning references.
-- They are far fewer than object rows in the fork path, so row triggers keep
-- cascade/delete behavior simple while the object triggers above remain
-- statement-aggregated for the 100k-row case.
CREATE FUNCTION pgs3._pending_blob_ref()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE pgs3.blob SET refcount = refcount + 1
         WHERE sha256 = NEW.blob_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE pgs3.blob SET refcount = refcount - 1
         WHERE sha256 = OLD.blob_id;
        RETURN OLD;
    ELSIF NEW.blob_id IS DISTINCT FROM OLD.blob_id THEN
        UPDATE pgs3.blob SET refcount = refcount - 1
         WHERE sha256 = OLD.blob_id;
        UPDATE pgs3.blob SET refcount = refcount + 1
         WHERE sha256 = NEW.blob_id;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER upload_part_blob_ref
AFTER INSERT OR DELETE OR UPDATE ON pgs3.upload_part
FOR EACH ROW EXECUTE FUNCTION pgs3._pending_blob_ref();

CREATE TRIGGER upload_chunk_blob_ref
AFTER INSERT OR DELETE OR UPDATE ON pgs3.upload_chunk
FOR EACH ROW EXECUTE FUNCTION pgs3._pending_blob_ref();

CREATE FUNCTION pgs3._blob_extent_source_ref()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE pgs3.blob SET refcount = refcount + 1
         WHERE sha256 = NEW.source_blob_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE pgs3.blob SET refcount = refcount - 1
         WHERE sha256 = OLD.source_blob_id;
        RETURN OLD;
    ELSIF NEW.source_blob_id IS DISTINCT FROM OLD.source_blob_id THEN
        UPDATE pgs3.blob SET refcount = refcount - 1
         WHERE sha256 = OLD.source_blob_id;
        UPDATE pgs3.blob SET refcount = refcount + 1
         WHERE sha256 = NEW.source_blob_id;
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER blob_extent_source_ref
AFTER INSERT OR DELETE OR UPDATE ON pgs3.blob_extent
FOR EACH ROW EXECUTE FUNCTION pgs3._blob_extent_source_ref();

CREATE FUNCTION pgs3._ensure_blob(p_sha256 bytea, p_body bytea)
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

CREATE FUNCTION pgs3._ensure_composite_blob(
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

CREATE FUNCTION pgs3._ensure_staged_blob(
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

CREATE FUNCTION pgs3._read_blob(p_blob_id bytea, p_depth integer DEFAULT 0)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_blob pgs3.blob%ROWTYPE;
    v_body bytea;
BEGIN
    IF p_depth > 64 THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'blob extent nesting is too deep';
    END IF;

    SELECT b.* INTO v_blob
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_blob_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'object references a missing blob';
    END IF;

    IF v_blob.storage_kind = 'inline' THEN
        v_body := v_blob.inline;
    ELSIF v_blob.storage_kind = 'chunked' THEN
        SELECT string_agg(c.data, ''::bytea ORDER BY c.seq)
          INTO v_body
          FROM pgs3.chunk AS c
         WHERE c.blob_id = p_blob_id;
        v_body := coalesce(v_body, ''::bytea);
    ELSIF v_blob.storage_kind = 'composite' THEN
        SELECT string_agg(
                   substring(
                       pgs3._read_blob(e.source_blob_id, p_depth + 1)
                       FROM (e.source_offset + 1)::integer
                       FOR e.length::integer
                   ),
                   ''::bytea ORDER BY e.seq
               )
          INTO v_body
          FROM pgs3.blob_extent AS e
         WHERE e.final_blob_id = p_blob_id
           AND e.length > 0;
        v_body := coalesce(v_body, ''::bytea);
    ELSE
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'blob has an unknown storage kind';
    END IF;

    IF octet_length(v_body) <> v_blob.size THEN
        RAISE EXCEPTION USING
            ERRCODE = 'XX001',
            MESSAGE = format('corrupt blob %s', encode(p_blob_id, 'hex'));
    END IF;
    RETURN v_body;
END
$$;

CREATE FUNCTION pgs3._read_blob_range(
    p_blob_id bytea,
    p_start bigint,
    p_end bigint,
    p_depth integer DEFAULT 0
)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_blob pgs3.blob%ROWTYPE;
    v_end bigint;
    v_chunk_size bigint;
    v_first integer;
    v_last integer;
    v_chunks bytea;
BEGIN
    IF p_depth > 64 THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'blob extent nesting is too deep';
    END IF;
    SELECT b.* INTO v_blob
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_blob_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'object references a missing blob';
    END IF;

    IF p_start < 0 OR p_start >= v_blob.size THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3R01', MESSAGE = 'InvalidRange',
            DETAIL = 'pgs3.error=InvalidRange';
    END IF;
    v_end := least(coalesce(p_end, v_blob.size - 1), v_blob.size - 1);
    IF v_end < p_start THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3R01', MESSAGE = 'InvalidRange',
            DETAIL = 'pgs3.error=InvalidRange';
    END IF;

    IF v_blob.storage_kind = 'inline' THEN
        RETURN substring(
            v_blob.inline
            FROM (p_start + 1)::integer
            FOR (v_end - p_start + 1)::integer
        );
    END IF;

    IF v_blob.storage_kind = 'chunked' THEN
        v_chunk_size := v_blob.chunk_size;
        v_first := (p_start / v_chunk_size)::integer;
        v_last := (v_end / v_chunk_size)::integer;
        SELECT string_agg(c.data, ''::bytea ORDER BY c.seq)
          INTO v_chunks
          FROM pgs3.chunk AS c
         WHERE c.blob_id = p_blob_id
           AND c.seq BETWEEN v_first AND v_last;

        IF v_chunks IS NULL THEN
            RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'object blob has missing chunks';
        END IF;
        v_chunks := substring(
            v_chunks
            FROM (p_start - v_first::bigint * v_chunk_size + 1)::integer
            FOR (v_end - p_start + 1)::integer
        );
    ELSIF v_blob.storage_kind = 'composite' THEN
        SELECT string_agg(
                   pgs3._read_blob_range(
                       e.source_blob_id,
                       e.source_offset + greatest(p_start, e.logical_offset) - e.logical_offset,
                       e.source_offset
                           + least(v_end, e.logical_offset + e.length - 1)
                           - e.logical_offset,
                       p_depth + 1
                   ),
                   ''::bytea ORDER BY e.seq
               )
          INTO v_chunks
          FROM pgs3.blob_extent AS e
         WHERE e.final_blob_id = p_blob_id
           AND e.length > 0
           AND e.logical_offset <= v_end
           AND e.logical_offset + e.length > p_start;
    ELSE
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'blob has an unknown storage kind';
    END IF;

    IF v_chunks IS NULL OR octet_length(v_chunks) <> v_end - p_start + 1 THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'blob range has missing or overlapping extents';
    END IF;
    RETURN v_chunks;
END
$$;

CREATE FUNCTION pgs3._read_body(p_object pgs3.object)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_object.delete_marker THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3K01', MESSAGE = 'NoSuchKey: delete marker',
            DETAIL = 'pgs3.error=NoSuchKey';
    END IF;
    RETURN pgs3._read_blob(p_object.blob_id);
END
$$;

CREATE FUNCTION pgs3._read_body_range(
    p_object pgs3.object,
    p_start bigint,
    p_end bigint
)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_object.delete_marker THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3K01', MESSAGE = 'NoSuchKey: delete marker',
            DETAIL = 'pgs3.error=NoSuchKey';
    END IF;
    RETURN pgs3._read_blob_range(p_object.blob_id, p_start, p_end);
END
$$;

CREATE FUNCTION pgs3._commit_body_locked(
    p_bucket_id bigint,
    p_bucket text,
    p_key text,
    p_body bytea,
    p_sha256 bytea,
    p_etag text,
    p_content_type text,
    p_meta jsonb,
    p_if_none_match text,
    p_if_match text,
    p_event_op text
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_current pgs3.object%ROWTYPE;
    v_new pgs3.object%ROWTYPE;
    v_exists boolean;
    v_size bigint := octet_length(p_body);
    v_max_size constant bigint := 5368709120;
    v_blob_id bytea;
BEGIN
    PERFORM pgs3._bucket_id_for_child(p_bucket, p_bucket_id);
    PERFORM pgs3._validate_key(p_key);
    IF p_sha256 IS NULL OR octet_length(p_sha256) <> 32 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'server SHA-256 is invalid';
    END IF;
    IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'object metadata must be a JSON object';
    END IF;
    IF v_size > v_max_size THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3S01', MESSAGE = 'EntityTooLarge',
            DETAIL = 'pgs3.error=EntityTooLarge';
    END IF;

    PERFORM pgs3._lock_key(p_bucket_id, p_key);
    SELECT o.*
      INTO v_current
      FROM pgs3.object AS o
     WHERE o.bucket_id = p_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.is_latest
     FOR UPDATE;
    v_exists := FOUND;

    PERFORM pgs3._check_write_preconditions(
        v_exists,
        CASE WHEN v_exists THEN v_current.delete_marker ELSE false END,
        CASE WHEN v_exists THEN v_current.etag ELSE NULL END,
        p_if_none_match,
        p_if_match
    );

    -- Every live version references one canonical blob.  Small payloads are
    -- inline in that blob row, not duplicated in object.inline.
    v_blob_id := pgs3._ensure_blob(p_sha256, p_body);

    UPDATE pgs3.object AS o
       SET is_latest = false
     WHERE o.bucket_id = p_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.is_latest;

    INSERT INTO pgs3.object (
        bucket_id, key, is_latest, delete_marker, size, etag, sha256,
        content_type, meta, inline, blob_id, created_by
    ) VALUES (
        p_bucket_id, p_key, true, false, v_size, lower(p_etag), p_sha256,
        p_content_type, p_meta, NULL, v_blob_id, pgs3._actor()
    )
    RETURNING * INTO v_new;

    PERFORM pgs3._notify_change(p_event_op);
    RETURN pgs3._object_info(p_bucket, v_new);
END
$$;

CREATE FUNCTION pgs3._commit_canonical_locked(
    p_bucket_id bigint,
    p_bucket text,
    p_key text,
    p_size bigint,
    p_sha256 bytea,
    p_etag text,
    p_blob_id bytea,
    p_content_type text,
    p_meta jsonb,
    p_if_none_match text,
    p_if_match text,
    p_event_op text
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_current pgs3.object%ROWTYPE;
    v_new pgs3.object%ROWTYPE;
    v_exists boolean;
    v_blob_size bigint;
    v_max_size constant bigint := 5368709120;
BEGIN
    PERFORM pgs3._bucket_id_for_child(p_bucket, p_bucket_id);
    PERFORM pgs3._validate_key(p_key);
    IF p_size < 0 OR p_size > v_max_size
       OR p_sha256 IS NULL OR octet_length(p_sha256) <> 32
       OR p_blob_id IS DISTINCT FROM p_sha256
    THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid canonical blob publication';
    END IF;
    IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'object metadata must be a JSON object';
    END IF;

    -- Hold the blob against GC until the object trigger establishes its owning
    -- reference in this same transaction.
    SELECT b.size INTO v_blob_size
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_blob_id
     FOR KEY SHARE;
    IF NOT FOUND OR v_blob_size <> p_size THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'canonical blob is missing or has the wrong size';
    END IF;

    PERFORM pgs3._lock_key(p_bucket_id, p_key);
    SELECT o.*
      INTO v_current
      FROM pgs3.object AS o
     WHERE o.bucket_id = p_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.is_latest
     FOR UPDATE;
    v_exists := FOUND;

    PERFORM pgs3._check_write_preconditions(
        v_exists,
        CASE WHEN v_exists THEN v_current.delete_marker ELSE false END,
        CASE WHEN v_exists THEN v_current.etag ELSE NULL END,
        p_if_none_match,
        p_if_match
    );

    UPDATE pgs3.object AS o
       SET is_latest = false
     WHERE o.bucket_id = p_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.is_latest;

    INSERT INTO pgs3.object (
        bucket_id, key, is_latest, delete_marker, size, etag, sha256,
        content_type, meta, inline, blob_id, created_by
    ) VALUES (
        p_bucket_id, p_key, true, false, p_size, lower(p_etag), p_sha256,
        p_content_type, p_meta, NULL, p_blob_id, pgs3._actor()
    )
    RETURNING * INTO v_new;

    PERFORM pgs3._notify_change(p_event_op);
    RETURN pgs3._object_info(p_bucket, v_new);
END
$$;

CREATE FUNCTION pgs3._commit_reference_locked(
    p_bucket_id bigint,
    p_bucket text,
    p_key text,
    p_source pgs3.object,
    p_content_type text,
    p_meta jsonb,
    p_if_none_match text,
    p_if_match text,
    p_event_op text
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_current pgs3.object%ROWTYPE;
    v_new pgs3.object%ROWTYPE;
    v_exists boolean;
BEGIN
    PERFORM pgs3._bucket_id_for_child(p_bucket, p_bucket_id);
    PERFORM pgs3._validate_key(p_key);
    IF p_source.delete_marker THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3K01', MESSAGE = 'NoSuchKey: source is a delete marker',
            DETAIL = 'pgs3.error=NoSuchKey';
    END IF;
    IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'object metadata must be a JSON object';
    END IF;

    PERFORM pgs3._lock_key(p_bucket_id, p_key);
    SELECT o.*
      INTO v_current
      FROM pgs3.object AS o
     WHERE o.bucket_id = p_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.is_latest
     FOR UPDATE;
    v_exists := FOUND;

    PERFORM pgs3._check_write_preconditions(
        v_exists,
        CASE WHEN v_exists THEN v_current.delete_marker ELSE false END,
        CASE WHEN v_exists THEN v_current.etag ELSE NULL END,
        p_if_none_match,
        p_if_match
    );

    IF p_source.blob_id IS NULL OR p_source.inline IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'source is not canonically blob-backed';
    END IF;
    PERFORM 1
      FROM pgs3.blob AS b
     WHERE b.sha256 = p_source.blob_id
     FOR KEY SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'source references a missing blob';
    END IF;

    UPDATE pgs3.object AS o
       SET is_latest = false
     WHERE o.bucket_id = p_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.is_latest;

    INSERT INTO pgs3.object (
        bucket_id, key, is_latest, delete_marker, size, etag, sha256,
        content_type, meta, inline, blob_id, created_by
    ) VALUES (
        p_bucket_id, p_key, true, false, p_source.size, p_source.etag,
        p_source.sha256, p_content_type, p_meta, NULL,
        p_source.blob_id, pgs3._actor()
    )
    RETURNING * INTO v_new;

    PERFORM pgs3._notify_change(p_event_op);
    RETURN pgs3._object_info(p_bucket, v_new);
END
$$;

CREATE FUNCTION pgs3.create_bucket(
    p_name text,
    p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS pgs3.bucket_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket pgs3.bucket%ROWTYPE;
    v_actor name := pgs3._actor();
BEGIN
    PERFORM pgs3._validate_bucket_name(p_name);
    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'bucket config must be a JSON object';
    END IF;

    PERFORM pgs3._lock_bucket_lifecycle(p_name, true);

    SELECT b.*
      INTO v_bucket
      FROM pgs3.bucket AS b
     WHERE b.name = p_name COLLATE "C";

    -- S3's fixed us-east-1 endpoint treats a same-owner CreateBucket as an
    -- idempotent reopen.  Return the canonical row exactly as it stands: in
    -- particular, do not replace config, creation time, or any child objects.
    -- Other-region duplicates retain the historical conflict behavior.
    IF FOUND THEN
        IF v_bucket.owner = v_actor
           AND coalesce(nullif(v_bucket.config ->> 'region', ''), 'us-east-1') = 'us-east-1'
           AND coalesce(nullif(p_config ->> 'region', ''), 'us-east-1') = 'us-east-1'
        THEN
            RETURN ROW(
                v_bucket.name, v_bucket.owner, v_bucket.created_at, v_bucket.config
            )::pgs3.bucket_info;
        END IF;

        RAISE EXCEPTION USING
            ERRCODE = 'P3E01',
            MESSAGE = format('BucketAlreadyExists: %s', p_name),
            DETAIL = 'pgs3.error=BucketAlreadyExists';
    END IF;

    INSERT INTO pgs3.bucket (name, owner, config)
    VALUES (p_name, v_actor, p_config)
    RETURNING * INTO v_bucket;

    RETURN ROW(v_bucket.name, v_bucket.owner, v_bucket.created_at, v_bucket.config)::pgs3.bucket_info;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION USING
        ERRCODE = 'P3E01',
        MESSAGE = format('BucketAlreadyExists: %s', p_name),
        DETAIL = 'pgs3.error=BucketAlreadyExists';
END
$$;

CREATE FUNCTION pgs3.list_buckets()
RETURNS SETOF pgs3.bucket_info
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT ROW(b.name, b.owner, b.created_at, b.config)::pgs3.bucket_info
      FROM pgs3.bucket AS b
     WHERE pg_has_role(pgs3._actor(), b.owner, 'USAGE')
     ORDER BY b.name COLLATE "C"
$$;

CREATE FUNCTION pgs3.head_bucket(p_name text)
RETURNS pgs3.bucket_info
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket pgs3.bucket%ROWTYPE;
BEGIN
    PERFORM pgs3._bucket_id(p_name);
    SELECT b.* INTO STRICT v_bucket
      FROM pgs3.bucket AS b
     WHERE b.name = p_name COLLATE "C";
    RETURN ROW(v_bucket.name, v_bucket.owner, v_bucket.created_at, v_bucket.config)::pgs3.bucket_info;
END
$$;

CREATE FUNCTION pgs3.get_bucket_location(p_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_region text;
BEGIN
    v_bucket_id := pgs3._bucket_id(p_name);
    SELECT nullif(b.config ->> 'region', '')
      INTO v_region
      FROM pgs3.bucket AS b
     WHERE b.bucket_id = v_bucket_id;
    RETURN coalesce(v_region, 'us-east-1');
END
$$;

CREATE FUNCTION pgs3.get_bucket_versioning(p_name text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._bucket_id(p_name);
    RETURN 'Enabled';
END
$$;

CREATE FUNCTION pgs3.delete_bucket(p_name text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
BEGIN
    -- Hold the exclusive name lock across the object-emptiness check, pending
    -- upload cleanup, and row deletion.  Shared child creators either commit
    -- first or resolve the name after deletion and get NoSuchBucket.
    PERFORM pgs3._lock_bucket_lifecycle(p_name, true);
    v_bucket_id := pgs3._bucket_id(p_name);
    IF EXISTS (SELECT 1 FROM pgs3.object AS o WHERE o.bucket_id = v_bucket_id) THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3F01', MESSAGE = 'BucketNotEmpty',
            DETAIL = 'pgs3.error=BucketNotEmpty';
    END IF;
    -- General-purpose S3 buckets do not treat incomplete multipart uploads as
    -- objects for DeleteBucket.  Deleting an otherwise empty bucket atomically
    -- aborts its pending attempts; the cascades release staged blob references.
    DELETE FROM pgs3.upload AS u WHERE u.bucket_id = v_bucket_id;
    DELETE FROM pgs3.bucket AS b WHERE b.bucket_id = v_bucket_id;
    RETURN true;
END
$$;

CREATE FUNCTION pgs3.put(
    p_bucket text,
    p_key text,
    p_body bytea,
    p_content_type text DEFAULT 'application/octet-stream',
    p_meta jsonb DEFAULT '{}'::jsonb,
    p_if_none_match text DEFAULT NULL,
    p_if_match text DEFAULT NULL,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_sha256 bytea;
BEGIN
    IF p_body IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22004', MESSAGE = 'object body cannot be NULL';
    END IF;
    v_bucket_id := pgs3._bucket_id_for_child(p_bucket);
    v_sha256 := pgs3.sha256(p_body);

    -- The checksum is compared only after the server has consumed and hashed
    -- the supplied body.  It is never used as a deduplication lookup key.
    IF p_checksum_sha256 IS NOT NULL
       AND p_checksum_sha256 IS DISTINCT FROM v_sha256
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3H01', MESSAGE = 'BadDigest: SHA-256 mismatch',
            DETAIL = 'pgs3.error=BadDigest';
    END IF;

    RETURN pgs3._commit_body_locked(
        v_bucket_id,
        p_bucket,
        p_key,
        p_body,
        v_sha256,
        md5(p_body),
        p_content_type,
        coalesce(p_meta, '{}'::jsonb),
        p_if_none_match,
        p_if_match,
        'put'
    );
END
$$;

CREATE FUNCTION pgs3.head(
    p_bucket text,
    p_key text,
    p_version_id bigint DEFAULT NULL,
    p_if_match text DEFAULT NULL,
    p_if_none_match text DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_object pgs3.object%ROWTYPE;
    v_none_match text;
BEGIN
    v_bucket_id := pgs3._bucket_id(p_bucket);
    IF p_version_id IS NULL THEN
        SELECT o.* INTO v_object
          FROM pgs3.object AS o
         WHERE o.bucket_id = v_bucket_id
           AND o.key = p_key COLLATE "C"
           AND o.is_latest;
    ELSE
        SELECT o.* INTO v_object
          FROM pgs3.object AS o
         WHERE o.bucket_id = v_bucket_id
           AND o.key = p_key COLLATE "C"
           AND o.version_id = p_version_id;
    END IF;

    IF NOT FOUND OR v_object.delete_marker THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3K01',
            MESSAGE = format('NoSuchKey: %s', p_key),
            DETAIL = CASE WHEN p_version_id IS NULL
                          THEN 'pgs3.error=NoSuchKey'
                          ELSE 'pgs3.error=NoSuchVersion' END;
    END IF;

    IF p_if_match IS NOT NULL
       AND pgs3._normalize_etag(p_if_match) <> v_object.etag
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3C01', MESSAGE = 'PreconditionFailed: If-Match',
            DETAIL = 'pgs3.error=PreconditionFailed';
    END IF;

    v_none_match := pgs3._normalize_etag(p_if_none_match);
    IF v_none_match = '*' OR v_none_match = v_object.etag THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3N01', MESSAGE = 'NotModified',
            DETAIL = 'pgs3.error=NotModified';
    END IF;

    RETURN pgs3._object_info(p_bucket, v_object);
END
$$;

CREATE FUNCTION pgs3.get(
    p_bucket text,
    p_key text,
    p_version_id bigint DEFAULT NULL,
    p_if_match text DEFAULT NULL,
    p_if_none_match text DEFAULT NULL
)
RETURNS pgs3.object_data
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_info pgs3.object_info;
    v_object pgs3.object%ROWTYPE;
    v_bucket_id bigint;
BEGIN
    v_info := pgs3.head(p_bucket, p_key, p_version_id, p_if_match, p_if_none_match);
    v_bucket_id := pgs3._bucket_id(p_bucket);
    SELECT o.* INTO STRICT v_object
      FROM pgs3.object AS o
     WHERE o.bucket_id = v_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.version_id = v_info.version_id;
    RETURN ROW(v_info, pgs3._read_body(v_object))::pgs3.object_data;
END
$$;

CREATE FUNCTION pgs3.get_range(
    p_bucket text,
    p_key text,
    p_start bigint,
    p_end bigint DEFAULT NULL,
    p_version_id bigint DEFAULT NULL,
    p_if_match text DEFAULT NULL,
    p_if_none_match text DEFAULT NULL
)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_info pgs3.object_info;
    v_object pgs3.object%ROWTYPE;
    v_bucket_id bigint;
BEGIN
    v_info := pgs3.head(p_bucket, p_key, p_version_id, p_if_match, p_if_none_match);
    v_bucket_id := pgs3._bucket_id(p_bucket);
    SELECT o.* INTO STRICT v_object
      FROM pgs3.object AS o
     WHERE o.bucket_id = v_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.version_id = v_info.version_id;
    RETURN pgs3._read_body_range(v_object, p_start, p_end);
END
$$;

CREATE FUNCTION pgs3.delete(
    p_bucket text,
    p_key text,
    p_version_id bigint DEFAULT NULL
)
RETURNS pgs3.delete_result
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_current pgs3.object%ROWTYPE;
    v_deleted pgs3.object%ROWTYPE;
    v_marker pgs3.object%ROWTYPE;
BEGIN
    v_bucket_id := pgs3._bucket_id_for_child(p_bucket);
    PERFORM pgs3._validate_key(p_key);
    PERFORM pgs3._lock_key(v_bucket_id, p_key);

    IF p_version_id IS NULL THEN
        UPDATE pgs3.object AS o
           SET is_latest = false
         WHERE o.bucket_id = v_bucket_id
           AND o.key = p_key COLLATE "C"
           AND o.is_latest;

        INSERT INTO pgs3.object (
            bucket_id, key, is_latest, delete_marker, size, etag, sha256,
            content_type, meta, inline, blob_id, created_by
        ) VALUES (
            v_bucket_id, p_key, true, true, 0, NULL, NULL,
            NULL, '{}'::jsonb, NULL, NULL, pgs3._actor()
        )
        RETURNING * INTO v_marker;

        PERFORM pgs3._notify_change('delete');
        RETURN ROW(p_key, v_marker.version_id, true, true)::pgs3.delete_result;
    END IF;

    SELECT o.* INTO v_current
      FROM pgs3.object AS o
     WHERE o.bucket_id = v_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.version_id = p_version_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN ROW(p_key, p_version_id, false, false)::pgs3.delete_result;
    END IF;

    DELETE FROM pgs3.object AS o
     WHERE o.bucket_id = v_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.version_id = p_version_id
    RETURNING * INTO v_deleted;

    IF v_deleted.is_latest THEN
        UPDATE pgs3.object AS o
           SET is_latest = true
         WHERE (o.bucket_id, o.key, o.version_id) = (
             SELECT r.bucket_id, r.key, r.version_id
               FROM pgs3.object AS r
              WHERE r.bucket_id = v_bucket_id
                AND r.key = p_key COLLATE "C"
              ORDER BY r.version_id DESC
              LIMIT 1
         );
    END IF;

    PERFORM pgs3._notify_change('delete');
    RETURN ROW(p_key, p_version_id, v_deleted.delete_marker, true)::pgs3.delete_result;
END
$$;

CREATE FUNCTION pgs3.delete_many(
    p_bucket text,
    p_keys text[],
    p_version_ids bigint[]
)
RETURNS SETOF pgs3.delete_result
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_key text;
    v_version_id bigint;
    v_bucket_id bigint;
    v_keys text[] := coalesce(p_keys, ARRAY[]::text[]);
    v_version_ids bigint[] := coalesce(p_version_ids, ARRAY[]::bigint[]);
BEGIN
    -- Resolve access and validate the complete request before taking a lock or
    -- changing an object.  This makes malformed arrays all-or-nothing and
    -- prevents an empty request from being used as an authorization probe.
    v_bucket_id := pgs3._bucket_id_for_child(p_bucket);
    IF cardinality(v_keys) <> cardinality(v_version_ids)
       OR coalesce(array_ndims(v_keys), 1) <> 1
       OR coalesce(array_ndims(v_version_ids), 1) <> 1
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'DeleteObjects key and version arrays must be one-dimensional and have equal length';
    END IF;

    FOR v_key, v_version_id IN
        SELECT requested.key, requested.version_id
          FROM unnest(v_keys, v_version_ids)
                   AS requested(key, version_id)
    LOOP
        IF v_key IS NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'DeleteObjects keys cannot be NULL';
        END IF;
        PERFORM pgs3._validate_key(v_key);
        IF v_version_id IS NOT NULL AND v_version_id <= 0 THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'DeleteObjects version IDs must be positive';
        END IF;
    END LOOP;

    -- Advisory locks live until transaction end.  Acquire the distinct lock
    -- set in one global bytewise order before emitting results in request
    -- order; overlapping mixed-version DeleteObjects calls cannot deadlock.
    FOR v_key IN
        SELECT DISTINCT requested.key COLLATE "C"
          FROM unnest(v_keys) AS requested(key)
         ORDER BY requested.key COLLATE "C"
    LOOP
        PERFORM pgs3._lock_key(v_bucket_id, v_key);
    END LOOP;

    -- Execute strictly in XML request order.  Repeated key/version pairs are
    -- intentionally not collapsed: the first request may remove a row while
    -- a repeated request is the S3-compatible successful missing-version case.
    FOR v_key, v_version_id IN
        SELECT requested.key, requested.version_id
          FROM unnest(v_keys, v_version_ids)
                   AS requested(key, version_id)
    LOOP
        RETURN NEXT pgs3.delete(p_bucket, v_key, v_version_id);
    END LOOP;
    RETURN;
END
$$;

-- Preserve the original direct SQL API.  NULL version elements mean the
-- ordinary versioned-bucket delete operation, which creates a delete marker.
CREATE FUNCTION pgs3.delete_many(
    p_bucket text,
    p_keys text[]
)
RETURNS SETOF pgs3.delete_result
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT d.*
      FROM pgs3.delete_many(
          p_bucket,
          coalesce(p_keys, ARRAY[]::text[]),
          ARRAY(
              SELECT NULL::bigint
                FROM unnest(coalesce(p_keys, ARRAY[]::text[]))
          )
      ) AS d
$$;

CREATE FUNCTION pgs3.copy(
    p_source_bucket text,
    p_source_key text,
    p_destination_bucket text,
    p_destination_key text,
    p_source_version_id bigint DEFAULT NULL,
    p_content_type text DEFAULT NULL,
    p_meta jsonb DEFAULT NULL,
    p_if_none_match text DEFAULT NULL,
    p_if_match text DEFAULT NULL,
    p_source_if_match text DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_source_bucket_id bigint;
    v_destination_bucket_id bigint;
    v_source pgs3.object%ROWTYPE;
BEGIN
    v_source_bucket_id := pgs3._bucket_id(p_source_bucket);
    v_destination_bucket_id := pgs3._bucket_id_for_child(
        p_destination_bucket
    );
    PERFORM pgs3._validate_key(p_source_key);
    PERFORM pgs3._validate_key(p_destination_key);

    -- Copy is a two-key operation: the source must remain a consistent version
    -- while the destination latest row changes.  Acquire both transaction locks
    -- before taking either object-row lock, in one bytewise global order.  If
    -- reciprocal copies instead lock their source row first, A->B and B->A can
    -- each hold FOR KEY SHARE on its source and deadlock while taking FOR UPDATE
    -- on the other row in _commit_reference_locked.
    IF v_source_bucket_id < v_destination_bucket_id
       OR (
           v_source_bucket_id = v_destination_bucket_id
           AND p_source_key COLLATE "C" <= p_destination_key COLLATE "C"
       )
    THEN
        PERFORM pgs3._lock_key(v_source_bucket_id, p_source_key);
        IF v_source_bucket_id <> v_destination_bucket_id
           OR p_source_key IS DISTINCT FROM p_destination_key COLLATE "C"
        THEN
            PERFORM pgs3._lock_key(
                v_destination_bucket_id, p_destination_key
            );
        END IF;
    ELSE
        PERFORM pgs3._lock_key(
            v_destination_bucket_id, p_destination_key
        );
        PERFORM pgs3._lock_key(v_source_bucket_id, p_source_key);
    END IF;

    IF p_source_version_id IS NULL THEN
        SELECT o.* INTO v_source
          FROM pgs3.object AS o
         WHERE o.bucket_id = v_source_bucket_id
           AND o.key = p_source_key COLLATE "C"
           AND o.is_latest
           AND NOT o.delete_marker
         FOR KEY SHARE;
    ELSE
        SELECT o.* INTO v_source
          FROM pgs3.object AS o
         WHERE o.bucket_id = v_source_bucket_id
           AND o.key = p_source_key COLLATE "C"
           AND o.version_id = p_source_version_id
           AND NOT o.delete_marker
         FOR KEY SHARE;
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3K01',
            MESSAGE = format('NoSuchKey: %s', p_source_key),
            DETAIL = CASE WHEN p_source_version_id IS NULL
                          THEN 'pgs3.error=NoSuchKey'
                          ELSE 'pgs3.error=NoSuchVersion' END;
    END IF;
    IF p_source_if_match IS NOT NULL
       AND pgs3._normalize_etag(p_source_if_match) <> v_source.etag
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3C01', MESSAGE = 'PreconditionFailed: copy source If-Match',
            DETAIL = 'pgs3.error=PreconditionFailed';
    END IF;

    RETURN pgs3._commit_reference_locked(
        v_destination_bucket_id,
        p_destination_bucket,
        p_destination_key,
        v_source,
        coalesce(p_content_type, v_source.content_type),
        coalesce(p_meta, v_source.meta),
        p_if_none_match,
        p_if_match,
        'copy'
    );
END
$$;

CREATE FUNCTION pgs3.restore(
    p_bucket text,
    p_key text,
    p_version_id bigint,
    p_if_match text DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_source pgs3.object%ROWTYPE;
BEGIN
    v_bucket_id := pgs3._bucket_id_for_child(p_bucket);
    PERFORM pgs3._validate_key(p_key);
    PERFORM pgs3._lock_key(v_bucket_id, p_key);

    SELECT o.* INTO v_source
      FROM pgs3.object AS o
     WHERE o.bucket_id = v_bucket_id
       AND o.key = p_key COLLATE "C"
       AND o.version_id = p_version_id
       AND NOT o.delete_marker
     FOR KEY SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3K01', MESSAGE = 'NoSuchVersion',
            DETAIL = 'pgs3.error=NoSuchVersion';
    END IF;

    RETURN pgs3._commit_reference_locked(
        v_bucket_id,
        p_bucket,
        p_key,
        v_source,
        v_source.content_type,
        v_source.meta,
        NULL,
        p_if_match,
        'restore'
    );
END
$$;

CREATE FUNCTION pgs3.fork_bucket(
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

CREATE FUNCTION pgs3._make_list_token(
    p_bucket text,
    p_prefix text,
    p_delimiter text,
    p_seek text,
    p_inclusive boolean
)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT pg_catalog.replace(
        pg_catalog.encode(
            pg_catalog.convert_to(
                pg_catalog.json_build_object(
                    'v', 1,
                    'b', p_bucket,
                    'p', p_prefix,
                    'd', p_delimiter,
                    's', p_seek,
                    'i', p_inclusive
                )::text,
                'UTF8'
            ),
            'base64'
        ),
        E'\n',
        ''
    )
$$;

CREATE FUNCTION pgs3._parse_list_token(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog
AS $$
DECLARE
    v_state jsonb;
BEGIN
    v_state := convert_from(decode(p_token, 'base64'), 'UTF8')::jsonb;
    IF (v_state ->> 'v')::integer <> 1
       OR NOT (v_state ?& ARRAY['b', 'p', 's', 'i'])
    THEN
        RAISE invalid_parameter_value;
    END IF;
    RETURN v_state;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid continuation token';
END
$$;

-- Delimiter listing is a procedural index-jump scan.  Each loop iteration
-- fetches one indexed key.  On discovering a common prefix it seeks directly
-- to _prefix_end(common_prefix), rather than scanning every key and DISTINCTing.
CREATE FUNCTION pgs3.list(
    p_bucket text,
    p_prefix text DEFAULT '',
    p_delimiter text DEFAULT NULL,
    p_start_after text DEFAULT NULL,
    p_continuation_token text DEFAULT NULL,
    p_max_keys integer DEFAULT 1000
)
RETURNS SETOF pgs3.list_entry
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_prefix text := coalesce(p_prefix, '');
    v_delimiter text := nullif(p_delimiter, '');
    v_prefix_chars integer := char_length(v_prefix);
    v_delimiter_chars integer := char_length(v_delimiter);
    v_upper text;
    v_seek text;
    v_inclusive boolean;
    v_state jsonb;
    v_object pgs3.object%ROWTYPE;
    v_key text;
    v_suffix text;
    v_pos integer;
    v_common_prefix text;
    v_token text;
    v_emitted integer := 0;
BEGIN
    v_bucket_id := pgs3._bucket_id(p_bucket);
    IF p_max_keys < 0 OR p_max_keys > 1000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'max_keys must be between 0 and 1000';
    END IF;
    IF octet_length(v_prefix) > 1024 OR octet_length(coalesce(v_delimiter, '')) > 1024 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'prefix or delimiter is too long';
    END IF;
    IF p_continuation_token IS NOT NULL AND p_start_after IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'start_after and continuation_token are mutually exclusive';
    END IF;

    v_upper := pgs3._prefix_end(v_prefix);
    IF p_continuation_token IS NOT NULL THEN
        v_state := pgs3._parse_list_token(p_continuation_token);
        IF v_state ->> 'b' IS DISTINCT FROM p_bucket
           OR v_state ->> 'p' IS DISTINCT FROM v_prefix
           OR v_state ->> 'd' IS DISTINCT FROM v_delimiter
        THEN
            RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'continuation token does not match request';
        END IF;
        v_seek := v_state ->> 's';
        v_inclusive := (v_state ->> 'i')::boolean;
    ELSIF p_start_after IS NULL OR p_start_after < v_prefix COLLATE "C" THEN
        v_seek := v_prefix;
        v_inclusive := true;
    ELSE
        v_seek := p_start_after;
        v_inclusive := false;
    END IF;

    -- Without a delimiter, one bounded range scan is both the S3 algorithm and
    -- substantially cheaper than crossing the PL/pgSQL/SPI boundary once per
    -- emitted key.  Keep the two comparison forms separate so each cached plan
    -- has a simple index lower bound.
    IF v_delimiter IS NULL THEN
        IF v_inclusive THEN
            RETURN QUERY
            SELECT page.key,
                   NULL::text,
                   page.version_id,
                   page.size,
                   page.etag,
                   page.content_type,
                   page.created_at,
                   page.meta,
                   CASE WHEN page.ordinal = p_max_keys THEN
                       pgs3._make_list_token(
                           p_bucket, v_prefix, NULL, page.key, false
                       )
                   ELSE NULL::text END
              FROM (
                  SELECT o.key,
                         o.version_id,
                         o.size,
                         o.etag,
                         o.content_type,
                         o.created_at,
                         o.meta,
                         row_number() OVER (ORDER BY o.key COLLATE "C") AS ordinal
                    FROM pgs3.object AS o
                   WHERE o.bucket_id = v_bucket_id
                     AND o.is_latest
                     AND NOT o.delete_marker
                     AND o.key >= v_seek COLLATE "C"
                     AND (v_upper IS NULL OR o.key < v_upper COLLATE "C")
                   ORDER BY o.key COLLATE "C"
                   LIMIT p_max_keys
              ) AS page
             ORDER BY page.key COLLATE "C";
        ELSE
            RETURN QUERY
            SELECT page.key,
                   NULL::text,
                   page.version_id,
                   page.size,
                   page.etag,
                   page.content_type,
                   page.created_at,
                   page.meta,
                   CASE WHEN page.ordinal = p_max_keys THEN
                       pgs3._make_list_token(
                           p_bucket, v_prefix, NULL, page.key, false
                       )
                   ELSE NULL::text END
              FROM (
                  SELECT o.key,
                         o.version_id,
                         o.size,
                         o.etag,
                         o.content_type,
                         o.created_at,
                         o.meta,
                         row_number() OVER (ORDER BY o.key COLLATE "C") AS ordinal
                    FROM pgs3.object AS o
                   WHERE o.bucket_id = v_bucket_id
                     AND o.is_latest
                     AND NOT o.delete_marker
                     AND o.key > v_seek COLLATE "C"
                     AND (v_upper IS NULL OR o.key < v_upper COLLATE "C")
                   ORDER BY o.key COLLATE "C"
                   LIMIT p_max_keys
              ) AS page
             ORDER BY page.key COLLATE "C";
        END IF;
        RETURN;
    END IF;

    WHILE v_emitted < p_max_keys LOOP
        IF v_seek IS NULL OR (v_upper IS NOT NULL AND v_seek >= v_upper COLLATE "C") THEN
            EXIT;
        END IF;

        IF v_inclusive THEN
            SELECT o.key INTO v_key
              FROM pgs3.object AS o
             WHERE o.bucket_id = v_bucket_id
               AND o.is_latest
               AND NOT o.delete_marker
               AND o.key >= v_seek COLLATE "C"
               AND (v_upper IS NULL OR o.key < v_upper COLLATE "C")
             ORDER BY o.key COLLATE "C"
             LIMIT 1;
        ELSE
            SELECT o.key INTO v_key
              FROM pgs3.object AS o
             WHERE o.bucket_id = v_bucket_id
               AND o.is_latest
               AND NOT o.delete_marker
               AND o.key > v_seek COLLATE "C"
               AND (v_upper IS NULL OR o.key < v_upper COLLATE "C")
             ORDER BY o.key COLLATE "C"
             LIMIT 1;
        END IF;
        EXIT WHEN NOT FOUND;

        v_suffix := substr(v_key, v_prefix_chars + 1);
        v_pos := strpos(v_suffix, v_delimiter);
        IF v_pos > 0 THEN
            v_common_prefix := v_prefix
                || substr(v_suffix, 1, v_pos + v_delimiter_chars - 1);
            v_seek := pgs3._prefix_end(v_common_prefix);
            v_inclusive := true;

            -- S3 filters CommonPrefixes not lexicographically greater than
            -- start-after.  The jump still happens, so no rows are scanned.
            IF p_start_after IS NOT NULL
               AND v_common_prefix <= p_start_after COLLATE "C"
            THEN
                CONTINUE;
            END IF;
            v_token := CASE
                WHEN v_emitted + 1 = p_max_keys AND v_seek IS NOT NULL
                THEN pgs3._make_list_token(
                    p_bucket, v_prefix, v_delimiter, v_seek, true
                )
                ELSE NULL
            END;
            RETURN NEXT ROW(
                NULL, v_common_prefix, NULL, NULL, NULL, NULL, NULL, NULL, v_token
            )::pgs3.list_entry;
        ELSE
            -- Common-prefix rows need only the covering index key.  Fetch the
            -- wider object tuple only for a direct child that will expose its
            -- metadata in the result.
            SELECT o.* INTO STRICT v_object
              FROM pgs3.object AS o
             WHERE o.bucket_id = v_bucket_id
               AND o.key = v_key COLLATE "C"
               AND o.is_latest
               AND NOT o.delete_marker;
            v_seek := v_key;
            v_inclusive := false;
            v_token := CASE WHEN v_emitted + 1 = p_max_keys THEN
                pgs3._make_list_token(
                    p_bucket, v_prefix, v_delimiter, v_seek, false
                )
            ELSE NULL END;
            RETURN NEXT ROW(
                v_object.key,
                NULL,
                v_object.version_id,
                v_object.size,
                v_object.etag,
                v_object.content_type,
                v_object.created_at,
                v_object.meta,
                v_token
            )::pgs3.list_entry;
        END IF;
        v_emitted := v_emitted + 1;
    END LOOP;
    RETURN;
END
$$;

CREATE FUNCTION pgs3.list_objects_v1(
    p_bucket text,
    p_prefix text DEFAULT '',
    p_delimiter text DEFAULT NULL,
    p_marker text DEFAULT NULL,
    p_max_keys integer DEFAULT 1000
)
RETURNS SETOF pgs3.list_entry
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT * FROM pgs3.list(
        p_bucket, p_prefix, p_delimiter, p_marker, NULL, p_max_keys
    )
$$;

CREATE FUNCTION pgs3.list_objects_v2(
    p_bucket text,
    p_prefix text DEFAULT '',
    p_delimiter text DEFAULT NULL,
    p_start_after text DEFAULT NULL,
    p_continuation_token text DEFAULT NULL,
    p_max_keys integer DEFAULT 1000
)
RETURNS SETOF pgs3.list_entry
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT * FROM pgs3.list(
        p_bucket, p_prefix, p_delimiter, p_start_after,
        p_continuation_token, p_max_keys
    )
$$;

CREATE FUNCTION pgs3.list_versions(
    p_bucket text,
    p_prefix text DEFAULT '',
    p_delimiter text DEFAULT NULL,
    p_key_marker text DEFAULT NULL,
    p_version_id_marker bigint DEFAULT NULL,
    p_max_keys integer DEFAULT 1000
)
RETURNS SETOF pgs3.version_entry
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_prefix text := coalesce(p_prefix, '');
    v_delimiter text := nullif(p_delimiter, '');
    v_upper text;
    v_key_seek text;
    v_version_seek bigint;
    v_inclusive boolean;
    v_object pgs3.object%ROWTYPE;
    v_suffix text;
    v_pos integer;
    v_common_prefix text;
    v_emitted integer := 0;
BEGIN
    v_bucket_id := pgs3._bucket_id(p_bucket);
    IF p_version_id_marker IS NOT NULL AND p_key_marker IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'version marker requires a key marker';
    END IF;
    IF p_max_keys < 0 OR p_max_keys > 1000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'max_keys must be between 0 and 1000';
    END IF;

    v_upper := pgs3._prefix_end(v_prefix);
    IF p_key_marker IS NULL OR p_key_marker < v_prefix COLLATE "C" THEN
        v_key_seek := v_prefix;
        v_version_seek := NULL;
        v_inclusive := true;
    ELSE
        v_key_seek := p_key_marker;
        v_version_seek := p_version_id_marker;
        v_inclusive := false;
    END IF;

    WHILE v_emitted < p_max_keys LOOP
        EXIT WHEN v_key_seek IS NULL
               OR (v_upper IS NOT NULL AND v_key_seek >= v_upper COLLATE "C");

        SELECT o.* INTO v_object
          FROM pgs3.object AS o
         WHERE o.bucket_id = v_bucket_id
           AND (v_upper IS NULL OR o.key < v_upper COLLATE "C")
           AND (
               (v_inclusive AND o.key >= v_key_seek COLLATE "C")
               OR
               (NOT v_inclusive AND v_version_seek IS NULL
                    AND o.key > v_key_seek COLLATE "C")
               OR
               (NOT v_inclusive AND v_version_seek IS NOT NULL
                    AND (o.key > v_key_seek COLLATE "C"
                         OR (o.key = v_key_seek COLLATE "C"
                             AND o.version_id < v_version_seek)))
           )
         ORDER BY o.key COLLATE "C", o.version_id DESC
         LIMIT 1;
        EXIT WHEN NOT FOUND;

        v_suffix := substr(v_object.key, char_length(v_prefix) + 1);
        v_pos := CASE WHEN v_delimiter IS NULL THEN 0 ELSE strpos(v_suffix, v_delimiter) END;
        IF v_pos > 0 THEN
            v_common_prefix := v_prefix
                || substr(v_suffix, 1, v_pos + char_length(v_delimiter) - 1);
            v_key_seek := pgs3._prefix_end(v_common_prefix);
            v_version_seek := NULL;
            v_inclusive := true;
            IF p_key_marker IS NOT NULL
               AND v_common_prefix <= p_key_marker COLLATE "C"
            THEN
                CONTINUE;
            END IF;
            RETURN NEXT ROW(
                NULL, v_common_prefix, NULL, NULL, NULL, NULL, NULL, NULL,
                v_key_seek, NULL
            )::pgs3.version_entry;
        ELSE
            v_key_seek := v_object.key;
            v_version_seek := v_object.version_id;
            v_inclusive := false;
            RETURN NEXT ROW(
                v_object.key,
                NULL,
                v_object.version_id,
                v_object.is_latest,
                v_object.delete_marker,
                v_object.size,
                v_object.etag,
                v_object.created_at,
                v_key_seek,
                v_version_seek
            )::pgs3.version_entry;
        END IF;
        v_emitted := v_emitted + 1;
    END LOOP;
    RETURN;
END
$$;

CREATE FUNCTION pgs3._upload_for_update(p_upload_id uuid)
RETURNS pgs3.upload
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
BEGIN
    -- UPDATE is both the row-lock acquisition and the lease renewal.  Keeping
    -- lease_expires_at separate from updated_at lets GC require both an old
    -- staging mutation and an expired liveness lease.  Every upload lifecycle
    -- function enters through this helper before touching chunks or parts.
    UPDATE pgs3.upload AS u
       SET lease_expires_at = clock_timestamp() + interval '5 minutes'
      FROM pgs3.bucket AS b
     WHERE u.upload_id = p_upload_id
       AND u.bucket_id = b.bucket_id
       AND u.state = 'pending'
       AND pg_has_role(pgs3._actor(), b.owner, 'USAGE')
    RETURNING u.* INTO v_upload;

    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3U01', MESSAGE = 'NoSuchUpload',
            DETAIL = 'pgs3.error=NoSuchUpload';
    END IF;
    RETURN v_upload;
END
$$;

-- A streaming HTTP request may spend longer reading a body than one SQL
-- chunk transaction.  This short transaction is its heartbeat; upload_id is
-- the attempt identity, so no second token changes the existing SQL contract.
CREATE FUNCTION pgs3.renew_upload(p_upload_id uuid)
RETURNS timestamptz
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
BEGIN
    v_upload := pgs3._upload_for_update(p_upload_id);
    RETURN v_upload.lease_expires_at;
END
$$;

-- HTTP multipart routes are scoped by (bucket, key, uploadId), not uploadId
-- alone.  Keep the original upload-id-only SQL API for trusted direct callers,
-- while route-facing overloads below use this check in every transaction.
-- A mismatch is deliberately indistinguishable from an unknown upload ID.
CREATE FUNCTION pgs3._upload_for_update_at(
    p_upload_id uuid,
    p_bucket text,
    p_key text,
    p_require_multipart boolean DEFAULT NULL
)
RETURNS pgs3.upload
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
BEGIN
    v_upload := pgs3._upload_for_update(p_upload_id);
    IF NOT EXISTS (
        SELECT 1
          FROM pgs3.bucket AS b
         WHERE b.bucket_id = v_upload.bucket_id
           AND b.name = p_bucket COLLATE "C"
    )
       OR v_upload.key IS DISTINCT FROM p_key COLLATE "C"
       OR (p_require_multipart IS NOT NULL
           AND v_upload.multipart IS DISTINCT FROM p_require_multipart)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3U01',
            MESSAGE = 'NoSuchUpload',
            DETAIL = 'pgs3.error=NoSuchUpload';
    END IF;
    RETURN v_upload;
END
$$;

CREATE FUNCTION pgs3.begin_upload(
    p_bucket text,
    p_key text,
    p_content_type text DEFAULT 'application/octet-stream',
    p_meta jsonb DEFAULT '{}'::jsonb,
    p_multipart boolean DEFAULT false,
    p_if_none_match text DEFAULT NULL,
    p_if_match text DEFAULT NULL,
    p_expected_sha256 bytea DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_bucket_id bigint;
    v_upload_id uuid;
BEGIN
    v_bucket_id := pgs3._bucket_id_for_child(p_bucket);
    PERFORM pgs3._validate_key(p_key);
    IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'object metadata must be a JSON object';
    END IF;
    IF p_expected_sha256 IS NOT NULL AND octet_length(p_expected_sha256) <> 32 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'SHA-256 must be 32 bytes';
    END IF;
    -- Validate the supported conditional form now; its value is evaluated
    -- against the serialized latest row only during complete_upload.
    PERFORM pgs3._check_write_preconditions(
        false, false, NULL,
        CASE WHEN p_if_none_match IS NULL THEN NULL ELSE p_if_none_match END,
        NULL
    );

    INSERT INTO pgs3.upload (
        bucket_id, key, multipart, content_type, meta, if_none_match,
        if_match, expected_sha256, initiated_by
    ) VALUES (
        v_bucket_id, p_key, p_multipart, p_content_type, p_meta,
        p_if_none_match, p_if_match, p_expected_sha256, pgs3._actor()
    )
    RETURNING upload_id INTO v_upload_id;
    RETURN v_upload_id;
END
$$;

CREATE FUNCTION pgs3.begin_part(p_upload_id uuid, p_part_number integer)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
BEGIN
    IF p_part_number NOT BETWEEN 1 AND 10000 THEN
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

    -- The upload-row lock serializes reset/chunk/complete/abort operations.
    -- Removing upload_part releases its canonical-blob owner reference.
    DELETE FROM pgs3.upload_part AS p
     WHERE p.upload_id = p_upload_id
       AND p.part_number = p_part_number;
    DELETE FROM pgs3.upload_chunk AS c
     WHERE c.upload_id = p_upload_id
       AND c.part_number = p_part_number;
    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp()
     WHERE u.upload_id = p_upload_id;
    RETURN true;
END
$$;

CREATE FUNCTION pgs3.abort_part(p_upload_id uuid, p_part_number integer)
RETURNS boolean
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT pgs3.begin_part(p_upload_id, p_part_number)
$$;

CREATE FUNCTION pgs3.put_chunk(
    p_upload_id uuid,
    p_seq integer,
    p_data bytea,
    p_part_number integer DEFAULT 0,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
    v_sha256 bytea;
    v_blob_id bytea;
    v_max_chunk constant bigint := 67108864;
BEGIN
    IF p_data IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '22004', MESSAGE = 'upload chunk cannot be NULL';
    END IF;
    IF p_seq < 0 OR p_part_number < 0 OR p_part_number > 10000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid upload part or chunk number';
    END IF;
    IF octet_length(p_data) > v_max_chunk THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3S01', MESSAGE = 'EntityTooLarge: upload chunk',
            DETAIL = 'pgs3.error=EntityTooLarge';
    END IF;

    v_upload := pgs3._upload_for_update(p_upload_id);
    IF (v_upload.multipart AND p_part_number = 0)
       OR (NOT v_upload.multipart AND p_part_number <> 0)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3P01', MESSAGE = 'InvalidPart',
            DETAIL = 'pgs3.error=InvalidPart';
    END IF;

    -- Reading and hashing p_data happens before the optional client checksum is
    -- trusted, including on the dedup path at finalization.
    v_sha256 := pgs3.sha256(p_data);
    IF p_checksum_sha256 IS NOT NULL
       AND p_checksum_sha256 IS DISTINCT FROM v_sha256
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3H01', MESSAGE = 'BadDigest: chunk SHA-256 mismatch',
            DETAIL = 'pgs3.error=BadDigest';
    END IF;

    v_blob_id := pgs3._ensure_blob(v_sha256, p_data);
    INSERT INTO pgs3.upload_chunk (
        upload_id, part_number, seq, blob_id, size
    )
    VALUES (
        p_upload_id, p_part_number, p_seq,
        v_blob_id, octet_length(p_data)
    )
    ON CONFLICT (upload_id, part_number, seq)
    DO UPDATE SET
        blob_id = excluded.blob_id,
        size = excluded.size,
        created_at = clock_timestamp();

    IF p_part_number > 0 THEN
        DELETE FROM pgs3.upload_part AS p
         WHERE p.upload_id = p_upload_id
           AND p.part_number = p_part_number;
    END IF;
    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp()
     WHERE u.upload_id = p_upload_id;
    RETURN octet_length(p_data);
END
$$;

CREATE FUNCTION pgs3.complete_part(
    p_upload_id uuid,
    p_part_number integer,
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
    v_body bytea;
    v_size bigint;
    v_count bigint;
    v_min_seq integer;
    v_max_seq integer;
    v_sha256 bytea;
    v_etag text;
    v_blob_id bytea;
    v_part pgs3.upload_part%ROWTYPE;
    v_hash_fallback_limit bigint := pgs3._setting_bytes(
        'pgs3.sql_hash_fallback_limit', 134217728
    );
BEGIN
    IF p_part_number NOT BETWEEN 1 AND 10000 THEN
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

    SELECT count(*), min(c.seq), max(c.seq),
           coalesce(sum(c.size), 0)
      INTO v_count, v_min_seq, v_max_seq, v_size
      FROM pgs3.upload_chunk AS c
     WHERE c.upload_id = p_upload_id
       AND c.part_number = p_part_number;

    IF v_count = 0
       OR v_min_seq <> 0
       OR v_count <> v_max_seq::bigint + 1
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: missing or non-contiguous chunks',
            DETAIL = 'pgs3.error=InvalidPart';
    END IF;
    IF to_regprocedure('pgs3.hash_upload_part(uuid,integer)') IS NOT NULL THEN
        EXECUTE
            'SELECT h.sha256, h.md5, h.total_size '
            'FROM pgs3.hash_upload_part($1, $2) AS h'
          INTO STRICT v_sha256, v_etag, v_count
          USING p_upload_id, p_part_number;
        IF v_count IS DISTINCT FROM v_size THEN
            RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'streaming part hash returned the wrong size';
        END IF;
    ELSE
        IF v_hash_fallback_limit < 0 OR v_size > v_hash_fallback_limit THEN
            RAISE EXCEPTION USING
                ERRCODE = '0A000',
                MESSAGE = 'multipart part exceeds the bounded SQL hashing fallback',
                DETAIL = 'Install pgs3.hash_upload_part(uuid,integer), which must stream canonical staged chunks in seq order and return exactly one (sha256 bytea, md5 text, total_size bigint) row.';
        END IF;

        SELECT string_agg(
                   pgs3._read_blob(c.blob_id),
                   ''::bytea ORDER BY c.seq
               )
          INTO v_body
          FROM pgs3.upload_chunk AS c
         WHERE c.upload_id = p_upload_id
           AND c.part_number = p_part_number;
        v_body := coalesce(v_body, ''::bytea);
        v_sha256 := pgs3.sha256(v_body);
        v_etag := md5(v_body);
    END IF;
    IF p_checksum_sha256 IS NOT NULL
       AND p_checksum_sha256 IS DISTINCT FROM v_sha256
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3H01', MESSAGE = 'BadDigest: part SHA-256 mismatch',
            DETAIL = 'pgs3.error=BadDigest';
    END IF;

    v_blob_id := pgs3._ensure_staged_blob(
        v_sha256, v_size, p_upload_id, p_part_number
    );
    INSERT INTO pgs3.upload_part (
        upload_id, part_number, size, etag, sha256, blob_id
    )
    VALUES (
        p_upload_id, p_part_number, v_size, v_etag, v_sha256, v_blob_id
    )
    ON CONFLICT (upload_id, part_number)
    DO UPDATE SET
        size = excluded.size,
        etag = excluded.etag,
        sha256 = excluded.sha256,
        blob_id = excluded.blob_id,
        completed_at = clock_timestamp()
    RETURNING * INTO v_part;

    -- Once a part is canonical, the pending row owns the blob and staged
    -- upload chunks are redundant.  Completion will reference this blob by
    -- extent rather than copying these bytes again.
    DELETE FROM pgs3.upload_chunk AS c
     WHERE c.upload_id = p_upload_id
       AND c.part_number = p_part_number;

    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp()
     WHERE u.upload_id = p_upload_id;
    RETURN ROW(
        v_part.part_number, v_part.size, v_part.etag,
        v_part.sha256, v_part.completed_at
    )::pgs3.part_info;
END
$$;

-- Convenience for an HTTP UploadPart request.  The lower-level put_chunk API
-- remains available so a streaming decoder can attach each chunk in its own
-- short transaction.
CREATE FUNCTION pgs3.put_part(
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

CREATE FUNCTION pgs3.list_parts(p_upload_id uuid)
RETURNS SETOF pgs3.part_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update(p_upload_id);
    RETURN QUERY
    SELECT p.part_number, p.size, p.etag, p.sha256, p.completed_at
      FROM pgs3.upload_part AS p
     WHERE p.upload_id = p_upload_id
     ORDER BY p.part_number;
END
$$;

CREATE FUNCTION pgs3._complete_upload(
    p_upload_id uuid,
    p_parts integer[] DEFAULT NULL,
    p_part_etags text[] DEFAULT NULL,
    p_checksum_sha256 bytea DEFAULT NULL,
    p_part_sha256s bytea[] DEFAULT NULL,
    p_composite_checksum_sha256 text DEFAULT NULL
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
    v_body bytea;
    v_sha256 bytea;
    v_blob_id bytea;
    v_part_blob_ids bytea[];
    v_size bigint;
    v_etag text;
    v_count bigint;
    v_min_seq integer;
    v_max_seq integer;
    v_min_part_size constant bigint := 5242880;
    v_checksum_algorithm text;
    v_composite_checksum_sha256 text;
    v_object_meta jsonb;
    v_hash_fallback_limit bigint := pgs3._setting_bytes(
        'pgs3.sql_hash_fallback_limit', 134217728
    );
    v_inline_threshold bigint := pgs3._setting_bytes(
        'pgs3.inline_threshold', 65536
    );
    v_info pgs3.object_info;
BEGIN
    v_upload := pgs3._upload_for_update(p_upload_id);
    v_object_meta := v_upload.meta;
    SELECT b.name INTO STRICT v_bucket
      FROM pgs3.bucket AS b
     WHERE b.bucket_id = v_upload.bucket_id;

    UPDATE pgs3.upload AS u
       SET state = 'completing', updated_at = clock_timestamp()
     WHERE u.upload_id = p_upload_id;

    IF v_upload.multipart THEN
        IF v_upload.meta ? '@pgs3:checksum-algorithm' THEN
            IF jsonb_typeof(v_upload.meta -> '@pgs3:checksum-algorithm') <> 'string'
               OR v_upload.meta ->> '@pgs3:checksum-algorithm' <> 'SHA256'
            THEN
                RAISE EXCEPTION USING
                    ERRCODE = '22023',
                    MESSAGE = 'unsupported multipart checksum algorithm';
            END IF;
            v_checksum_algorithm := 'SHA256';
        END IF;

        IF p_parts IS NULL OR cardinality(p_parts) = 0 THEN
            RAISE EXCEPTION USING
                ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: no completed parts',
                DETAIL = 'pgs3.error=InvalidPart';
        END IF;
        IF cardinality(p_parts) > 10000
           OR EXISTS (
               SELECT 1
                 FROM (
                     SELECT part_number,
                            lag(part_number) OVER (ORDER BY ordinality) AS previous
                       FROM unnest(p_parts) WITH ORDINALITY AS x(part_number, ordinality)
                 ) AS ordered_parts
                WHERE part_number NOT BETWEEN 1 AND 10000
                   OR (previous IS NOT NULL AND part_number <= previous)
           )
        THEN
            RAISE EXCEPTION USING
                ERRCODE = 'P3P01', MESSAGE = 'InvalidPartOrder',
                DETAIL = 'pgs3.error=InvalidPartOrder';
        END IF;

        SELECT count(*),
               coalesce(sum(p.size), 0),
               array_agg(p.blob_id ORDER BY requested.ordinality)
          INTO v_count, v_size, v_part_blob_ids
          FROM unnest(p_parts) WITH ORDINALITY AS requested(part_number, ordinality)
          JOIN pgs3.upload_part AS p
            ON p.upload_id = p_upload_id
           AND p.part_number = requested.part_number;
        IF v_count <> cardinality(p_parts) THEN
            RAISE EXCEPTION USING
                ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: an ETag or part is missing',
                DETAIL = 'pgs3.error=InvalidPart';
        END IF;

        IF p_part_etags IS NOT NULL THEN
            IF cardinality(p_part_etags) <> cardinality(p_parts)
               OR EXISTS (
                   SELECT 1
                     FROM unnest(p_parts, p_part_etags)
                              AS requested(part_number, etag)
                     JOIN pgs3.upload_part AS p
                       ON p.upload_id = p_upload_id
                      AND p.part_number = requested.part_number
                    WHERE p.etag IS DISTINCT FROM pgs3._normalize_etag(requested.etag)
               )
            THEN
                RAISE EXCEPTION USING
                    ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: ETag mismatch',
                    DETAIL = 'pgs3.error=InvalidPart';
            END IF;
        END IF;

        IF v_checksum_algorithm = 'SHA256' THEN
            IF p_part_sha256s IS NULL
               OR p_composite_checksum_sha256 IS NULL
               OR cardinality(p_part_sha256s) <> cardinality(p_parts)
               OR EXISTS (
                   SELECT 1
                     FROM unnest(p_parts, p_part_sha256s) WITH ORDINALITY
                              AS requested(part_number, checksum_sha256, ordinality)
                     JOIN pgs3.upload_part AS p
                       ON p.upload_id = p_upload_id
                      AND p.part_number = requested.part_number
                    WHERE requested.checksum_sha256 IS NULL
                       OR octet_length(requested.checksum_sha256) <> 32
                       OR requested.checksum_sha256 IS DISTINCT FROM p.sha256
               )
            THEN
                RAISE EXCEPTION USING
                    ERRCODE = 'P3H01',
                    MESSAGE = 'BadDigest: multipart part SHA-256 mismatch',
                    DETAIL = 'pgs3.error=BadDigest';
            END IF;

            -- AWS COMPOSITE SHA-256 hashes the ordered raw part digests, not
            -- the complete object bytes.  At most 10,000 32-byte digests are
            -- aggregated here, independently of the object payload size.
            SELECT encode(
                       pgs3.sha256(
                           string_agg(
                               p.sha256,
                               ''::bytea ORDER BY requested.ordinality
                           )
                       ),
                       'base64'
                   ) || '-' || cardinality(p_parts)::text
              INTO STRICT v_composite_checksum_sha256
              FROM unnest(p_parts) WITH ORDINALITY
                       AS requested(part_number, ordinality)
              JOIN pgs3.upload_part AS p
                ON p.upload_id = p_upload_id
               AND p.part_number = requested.part_number;

            IF p_composite_checksum_sha256 IS DISTINCT FROM
               v_composite_checksum_sha256
            THEN
                RAISE EXCEPTION USING
                    ERRCODE = 'P3H01',
                    MESSAGE = 'BadDigest: multipart composite SHA-256 mismatch',
                    DETAIL = 'pgs3.error=BadDigest';
            END IF;

            v_object_meta := jsonb_set(
                jsonb_set(
                    v_object_meta,
                    ARRAY['@pgs3:checksum-sha256'],
                    to_jsonb(v_composite_checksum_sha256),
                    true
                ),
                ARRAY['@pgs3:checksum-type'],
                to_jsonb('COMPOSITE'::text),
                true
            );
        ELSIF p_part_sha256s IS NOT NULL
              OR p_composite_checksum_sha256 IS NOT NULL
        THEN
            RAISE EXCEPTION USING
                ERRCODE = '22023',
                MESSAGE = 'multipart checksum values require a selected algorithm';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM unnest(p_parts) WITH ORDINALITY AS requested(part_number, ordinality)
              JOIN pgs3.upload_part AS p
                ON p.upload_id = p_upload_id
               AND p.part_number = requested.part_number
             WHERE requested.ordinality < cardinality(p_parts)
               AND p.size < v_min_part_size
        ) THEN
            RAISE EXCEPTION USING
                ERRCODE = 'P3P01', MESSAGE = 'EntityTooSmall: multipart part',
                DETAIL = 'pgs3.error=EntityTooSmall';
        END IF;

        -- PostgreSQL has no built-in incremental digest aggregate.  Prefer the
        -- optional Rust helper when installed; otherwise retain a deliberately
        -- bounded SQL fallback that reads every canonical part byte.  Neither
        -- path writes final payload bytes.
        IF to_regprocedure('pgs3.hash_blob_sequence(bytea[])') IS NOT NULL THEN
            EXECUTE
                'SELECT h.sha256, h.total_size '
                'FROM pgs3.hash_blob_sequence($1) AS h'
              INTO v_sha256, v_count
              USING v_part_blob_ids;
            IF v_count IS DISTINCT FROM v_size THEN
                RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'streaming multipart hash returned the wrong size';
            END IF;
        ELSE
            IF v_hash_fallback_limit < 0 OR v_size > v_hash_fallback_limit THEN
                RAISE EXCEPTION USING
                    ERRCODE = '0A000',
                    MESSAGE = 'multipart object exceeds the bounded SQL hashing fallback',
                    DETAIL = 'Install pgs3.hash_blob_sequence(bytea[]), which must stream canonical blob bytes in array order and return exactly one (sha256 bytea, total_size bigint) row.';
            END IF;
            SELECT string_agg(
                       pgs3._read_blob(p.blob_id),
                       ''::bytea ORDER BY requested.ordinality
                   )
              INTO v_body
              FROM unnest(p_parts) WITH ORDINALITY AS requested(part_number, ordinality)
              JOIN pgs3.upload_part AS p
                ON p.upload_id = p_upload_id
               AND p.part_number = requested.part_number;
            v_body := coalesce(v_body, ''::bytea);
            IF octet_length(v_body) <> v_size THEN
                RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'multipart source blobs do not match their recorded size';
            END IF;
            v_sha256 := pgs3.sha256(v_body);
        END IF;

        SELECT md5(
                   string_agg(
                       decode(p.etag, 'hex'), ''::bytea
                       ORDER BY requested.ordinality
                   )
               ) || '-' || cardinality(p_parts)::text
          INTO v_etag
          FROM unnest(p_parts) WITH ORDINALITY AS requested(part_number, ordinality)
          JOIN pgs3.upload_part AS p
            ON p.upload_id = p_upload_id
           AND p.part_number = requested.part_number;

        v_blob_id := pgs3._ensure_composite_blob(
            v_sha256, v_size, p_upload_id, p_parts
        );
    ELSE
        IF p_parts IS NOT NULL OR p_part_etags IS NOT NULL
           OR p_part_sha256s IS NOT NULL
           OR p_composite_checksum_sha256 IS NOT NULL
        THEN
            RAISE EXCEPTION USING
                ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: upload is not multipart',
                DETAIL = 'pgs3.error=InvalidPart';
        END IF;
        SELECT count(*), min(c.seq), max(c.seq),
               coalesce(sum(c.size), 0)
          INTO v_count, v_min_seq, v_max_seq, v_size
          FROM pgs3.upload_chunk AS c
         WHERE c.upload_id = p_upload_id
           AND c.part_number = 0;
        IF v_count > 0
           AND (v_min_seq <> 0 OR v_count <> v_max_seq::bigint + 1)
        THEN
            RAISE EXCEPTION USING
                ERRCODE = 'P3P01', MESSAGE = 'InvalidPart: missing or non-contiguous chunks',
                DETAIL = 'pgs3.error=InvalidPart';
        END IF;

        IF to_regprocedure('pgs3.hash_upload_part(uuid,integer)') IS NOT NULL THEN
            EXECUTE
                'SELECT h.sha256, h.md5, h.total_size '
                'FROM pgs3.hash_upload_part($1, $2) AS h'
              INTO STRICT v_sha256, v_etag, v_count
              USING p_upload_id, 0;
            IF v_count IS DISTINCT FROM v_size THEN
                RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'streaming upload hash returned the wrong size';
            END IF;
        ELSE
            IF v_hash_fallback_limit < 0 OR v_size > v_hash_fallback_limit THEN
                RAISE EXCEPTION USING
                    ERRCODE = '0A000',
                    MESSAGE = 'streamed object exceeds the bounded SQL hashing fallback',
                    DETAIL = 'Install pgs3.hash_upload_part(uuid,integer), which must stream canonical staged chunks in seq order and return exactly one (sha256 bytea, md5 text, total_size bigint) row.';
            END IF;
            SELECT string_agg(
                       pgs3._read_blob(c.blob_id),
                       ''::bytea ORDER BY c.seq
                   )
              INTO v_body
              FROM pgs3.upload_chunk AS c
             WHERE c.upload_id = p_upload_id
               AND c.part_number = 0;
            v_body := coalesce(v_body, ''::bytea);
            v_sha256 := pgs3.sha256(v_body);
            v_etag := md5(v_body);
        END IF;

        IF v_size <= greatest(v_inline_threshold, 0) THEN
            -- Canonical small blobs must use blob.inline.  Consolidating at
            -- most inline_threshold bytes is the one deliberately bounded
            -- publication copy; large streamed objects remain extent-only.
            IF v_body IS NULL THEN
                SELECT string_agg(
                           pgs3._read_blob(c.blob_id),
                           ''::bytea ORDER BY c.seq
                       )
                  INTO v_body
                  FROM pgs3.upload_chunk AS c
                 WHERE c.upload_id = p_upload_id
                   AND c.part_number = 0;
                v_body := coalesce(v_body, ''::bytea);
            END IF;
            IF octet_length(v_body) <> v_size
               OR pgs3.sha256(v_body) IS DISTINCT FROM v_sha256
               OR md5(v_body) IS DISTINCT FROM v_etag
            THEN
                RAISE EXCEPTION USING ERRCODE = 'XX001', MESSAGE = 'small streamed blob hash changed during publication';
            END IF;
            v_blob_id := pgs3._ensure_blob(v_sha256, v_body);
        ELSE
            v_blob_id := pgs3._ensure_staged_blob(
                v_sha256, v_size, p_upload_id, 0
            );
        END IF;
    END IF;

    IF (v_upload.expected_sha256 IS NOT NULL
        AND v_upload.expected_sha256 IS DISTINCT FROM v_sha256)
       OR (p_checksum_sha256 IS NOT NULL
           AND p_checksum_sha256 IS DISTINCT FROM v_sha256)
    THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3H01', MESSAGE = 'BadDigest: upload SHA-256 mismatch',
            DETAIL = 'pgs3.error=BadDigest';
    END IF;

    v_info := pgs3._commit_canonical_locked(
        v_upload.bucket_id,
        v_bucket,
        v_upload.key,
        v_size,
        v_sha256,
        v_etag,
        v_blob_id,
        v_upload.content_type,
        v_object_meta,
        v_upload.if_none_match,
        v_upload.if_match,
        CASE WHEN v_upload.multipart
             THEN 'complete_multipart' ELSE 'complete_upload' END
    );

    -- Object visibility and staging cleanup are atomic in this final short
    -- transaction.  A crash before commit exposes neither the new object nor a
    -- partially cleaned upload; a crash after commit exposes the full object.
    DELETE FROM pgs3.upload AS u WHERE u.upload_id = p_upload_id;
    RETURN v_info;
END
$$;

-- Preserve the original trusted SQL entry point.  Multipart composite
-- checksum inputs are available only through the narrowly scoped overloads
-- below, so existing direct callers cannot accidentally reinterpret the
-- full-content p_checksum_sha256 argument.
CREATE FUNCTION pgs3.complete_upload(
    p_upload_id uuid,
    p_parts integer[] DEFAULT NULL,
    p_part_etags text[] DEFAULT NULL,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT pgs3._complete_upload(
        p_upload_id, p_parts, p_part_etags, p_checksum_sha256, NULL, NULL
    )
$$;

CREATE FUNCTION pgs3.complete_multipart_upload(
    p_upload_id uuid,
    p_parts integer[],
    p_part_etags text[] DEFAULT NULL,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT pgs3.complete_upload(
        p_upload_id, p_parts, p_part_etags, p_checksum_sha256
    )
$$;

CREATE FUNCTION pgs3.complete_multipart_upload(
    p_upload_id uuid,
    p_parts integer[],
    p_part_etags text[],
    p_checksum_sha256 bytea,
    p_part_sha256s bytea[],
    p_composite_checksum_sha256 text
)
RETURNS pgs3.object_info
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
    SELECT pgs3._complete_upload(
        p_upload_id, p_parts, p_part_etags, p_checksum_sha256,
        p_part_sha256s, p_composite_checksum_sha256
    )
$$;

CREATE FUNCTION pgs3.abort_upload(p_upload_id uuid)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update(p_upload_id);
    DELETE FROM pgs3.upload AS u WHERE u.upload_id = p_upload_id;
    RETURN true;
END
$$;

-- Establish the tenant identity for one worker-only transaction without SET
-- ROLE.  This is a capability boundary, not a client API: worker_runtime.sql
-- grants it only to the configured NOLOGIN service role, and every caller must
-- still bind an upload to its authenticated bucket/key target.
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

-- Store one server-sealed non-multipart chunk.  The HTTP worker computes this
-- digest from decoded bytes; accepting it here avoids hashing the same datum a
-- second time after SPI has copied it into PostgreSQL.  Exact chunk identities
-- are returned and must be sealed again by _worker_complete_upload so a
-- concurrent replacement cannot be published under a stale whole-body hash.
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

-- Publish one non-multipart object from a worker-sealed manifest.  Public SQL
-- complete_upload remains deliberately unchanged and re-reads all staged
-- bytes.  This path trusts only digests computed by the authenticated HTTP
-- worker, then proves that the exact ordered chunks it observed are still the
-- ones locked in upload_chunk before publishing the canonical extent graph.
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

-- Route-facing upload overloads bind every short transaction to the URL's
-- bucket and key.  The upload-id-only functions above remain available to
-- existing direct SQL clients and implement the actual storage semantics.
CREATE FUNCTION pgs3.put_chunk(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_seq integer,
    p_data bytea,
    p_part_number integer DEFAULT 0,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(
        p_upload_id, p_bucket, p_key, p_part_number > 0
    );
    RETURN pgs3.put_chunk(
        p_upload_id, p_seq, p_data, p_part_number, p_checksum_sha256
    );
END
$$;

CREATE FUNCTION pgs3.complete_upload(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, false);
    RETURN pgs3.complete_upload(p_upload_id, NULL, NULL, p_checksum_sha256);
END
$$;

CREATE FUNCTION pgs3.renew_upload(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_require_multipart boolean DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
BEGIN
    v_upload := pgs3._upload_for_update_at(
        p_upload_id, p_bucket, p_key, p_require_multipart
    );
    RETURN v_upload.lease_expires_at;
END
$$;

-- Return the checksum algorithm selected when CreateMultipartUpload created
-- this exact tenant/path-bound upload.  Taking the same upload-row lock as the
-- mutating multipart calls also renews the lease and prevents an abort or GC
-- from racing the lookup.
CREATE FUNCTION pgs3.multipart_checksum_algorithm(
    p_bucket text,
    p_key text,
    p_upload_id uuid
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_upload pgs3.upload%ROWTYPE;
    v_algorithm text;
BEGIN
    v_upload := pgs3._upload_for_update_at(
        p_upload_id, p_bucket, p_key, true
    );
    IF NOT (v_upload.meta ? '@pgs3:checksum-algorithm') THEN
        RETURN NULL;
    END IF;
    IF jsonb_typeof(v_upload.meta -> '@pgs3:checksum-algorithm') <> 'string'
       OR v_upload.meta ->> '@pgs3:checksum-algorithm' <> 'SHA256'
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'unsupported multipart checksum algorithm';
    END IF;
    v_algorithm := v_upload.meta ->> '@pgs3:checksum-algorithm';
    RETURN v_algorithm;
END
$$;

CREATE FUNCTION pgs3.begin_part(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_part_number integer
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, true);
    RETURN pgs3.begin_part(p_upload_id, p_part_number);
END
$$;

CREATE FUNCTION pgs3.abort_part(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_part_number integer
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, true);
    RETURN pgs3.abort_part(p_upload_id, p_part_number);
END
$$;

CREATE FUNCTION pgs3.complete_part(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_part_number integer,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.part_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, true);
    RETURN pgs3.complete_part(
        p_upload_id, p_part_number, p_checksum_sha256
    );
END
$$;

CREATE FUNCTION pgs3.list_parts(
    p_bucket text,
    p_key text,
    p_upload_id uuid
)
RETURNS SETOF pgs3.part_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, true);
    RETURN QUERY SELECT p.* FROM pgs3.list_parts(p_upload_id) AS p;
END
$$;

CREATE FUNCTION pgs3.complete_multipart_upload(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_parts integer[],
    p_part_etags text[] DEFAULT NULL,
    p_checksum_sha256 bytea DEFAULT NULL
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, true);
    RETURN pgs3.complete_multipart_upload(
        p_upload_id, p_parts, p_part_etags, p_checksum_sha256
    );
END
$$;

CREATE FUNCTION pgs3.complete_multipart_upload(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_parts integer[],
    p_part_etags text[],
    p_checksum_sha256 bytea,
    p_part_sha256s bytea[],
    p_composite_checksum_sha256 text
)
RETURNS pgs3.object_info
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(p_upload_id, p_bucket, p_key, true);
    RETURN pgs3.complete_multipart_upload(
        p_upload_id, p_parts, p_part_etags, p_checksum_sha256,
        p_part_sha256s, p_composite_checksum_sha256
    );
END
$$;

CREATE FUNCTION pgs3.abort_upload(
    p_bucket text,
    p_key text,
    p_upload_id uuid,
    p_require_multipart boolean
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._upload_for_update_at(
        p_upload_id, p_bucket, p_key, p_require_multipart
    );
    RETURN pgs3.abort_upload(p_upload_id);
END
$$;

CREATE FUNCTION pgs3.gc_pending_uploads(
    p_max_age interval DEFAULT interval '24 hours',
    p_limit integer DEFAULT 1000
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_count bigint;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF p_max_age < interval '0' OR p_limit < 1 OR p_limit > 100000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid GC age or limit';
    END IF;
    WITH doomed AS MATERIALIZED (
        SELECT u.upload_id
         FROM pgs3.upload AS u
         WHERE u.state = 'pending'
           AND u.updated_at < v_now - p_max_age
           AND u.lease_expires_at <= v_now
         ORDER BY u.lease_expires_at, u.updated_at, u.upload_id
         FOR UPDATE OF u SKIP LOCKED
         LIMIT p_limit
    )
    DELETE FROM pgs3.upload AS u
     USING doomed AS d
     WHERE u.upload_id = d.upload_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END
$$;

CREATE FUNCTION pgs3.gc_blobs(p_limit integer DEFAULT 1000)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
DECLARE
    v_count bigint := 0;
    v_blob_id bytea;
BEGIN
    IF p_limit < 1 OR p_limit > 100000 THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid GC limit';
    END IF;
    -- Delete one immutable blob at a time so removing a composite's extents
    -- can make its source blobs eligible in this same bounded call.  The row
    -- lock closes the zero-ref/attach race; source FKs are RESTRICT as a final
    -- consistency guard.
    WHILE v_count < p_limit LOOP
        SELECT b.sha256
          INTO v_blob_id
          FROM pgs3.blob AS b
         WHERE b.refcount = 0
         ORDER BY b.created_at DESC, b.sha256
         FOR UPDATE SKIP LOCKED
         LIMIT 1;
        EXIT WHEN NOT FOUND;

        DELETE FROM pgs3.blob AS b
         WHERE b.sha256 = v_blob_id
           AND b.refcount = 0;
        IF FOUND THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END
$$;

-- Credential mutation is an operator API.  These functions never return the
-- raw secret, validate that the mapped role exists, and are explicitly revoked
-- from PUBLIC below.  The HTTP server role receives narrowly scoped SELECT on
-- pgs3.credential from the administrator because SigV4 verification needs the
-- original secret.
CREATE FUNCTION pgs3._grant_credential_role_membership(p_role_name name)
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

CREATE FUNCTION pgs3.create_credential(
    p_access_key text,
    p_secret text,
    p_role_name name,
    p_enabled boolean DEFAULT true
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_access_key IS NULL OR p_access_key = ''
       OR p_secret IS NULL OR p_secret = ''
    THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'access key and secret must be nonempty';
    END IF;
    PERFORM pgs3._grant_credential_role_membership(p_role_name);
    INSERT INTO pgs3.credential (access_key, secret, role_name, enabled)
    VALUES (p_access_key, p_secret, p_role_name, p_enabled);
    RETURN true;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION USING
        ERRCODE = 'P3A01', MESSAGE = 'access key already exists',
        DETAIL = 'pgs3.error=CredentialError';
END
$$;

CREATE FUNCTION pgs3.set_credential_role(p_access_key text, p_role_name name)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    PERFORM pgs3._grant_credential_role_membership(p_role_name);
    UPDATE pgs3.credential AS c
       SET role_name = p_role_name
     WHERE c.access_key = p_access_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3A01', MESSAGE = 'access key does not exist',
            DETAIL = 'pgs3.error=CredentialError';
    END IF;
    RETURN true;
END
$$;

CREATE FUNCTION pgs3.rotate_credential(p_access_key text, p_new_secret text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_new_secret IS NULL OR p_new_secret = '' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'secret must be nonempty';
    END IF;
    UPDATE pgs3.credential AS c
       SET secret = p_new_secret
     WHERE c.access_key = p_access_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3A01', MESSAGE = 'access key does not exist',
            DETAIL = 'pgs3.error=CredentialError';
    END IF;
    RETURN true;
END
$$;

CREATE FUNCTION pgs3.set_credential_enabled(p_access_key text, p_enabled boolean)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    UPDATE pgs3.credential AS c
       SET enabled = p_enabled
     WHERE c.access_key = p_access_key;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING
            ERRCODE = 'P3A01', MESSAGE = 'access key does not exist',
            DETAIL = 'pgs3.error=CredentialError';
    END IF;
    RETURN true;
END
$$;

CREATE FUNCTION pgs3.delete_credential(p_access_key text)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    DELETE FROM pgs3.credential AS c WHERE c.access_key = p_access_key;
    RETURN FOUND;
END
$$;

-- The API is function-only by default.  Administrators may grant direct table
-- access to mapped roles; RLS then enforces the same bucket boundary.  Internal
-- helpers and background-GC entry points are not callable by PUBLIC.
REVOKE ALL ON ALL TABLES IN SCHEMA pgs3 FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA pgs3 FROM PUBLIC;

DO $pgs3_revoke_helpers$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS signature
          FROM pg_proc AS p
          JOIN pg_namespace AS n ON n.oid = p.pronamespace
         WHERE n.nspname = 'pgs3'
           AND p.proname LIKE '\_%' ESCAPE '\'
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.signature);
    END LOOP;
END
$pgs3_revoke_helpers$;

REVOKE ALL ON FUNCTION pgs3.gc_pending_uploads(interval, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.gc_blobs(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.create_credential(text, text, name, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.rotate_credential(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.set_credential_role(text, name) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.set_credential_enabled(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.delete_credential(text) FROM PUBLIC;
