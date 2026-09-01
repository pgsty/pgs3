-- Runtime coordination is deliberately database-local.  PostgreSQL background
-- worker handles are private to the process that registered them, so SQL
-- sessions coordinate through these rows and validate every recorded PID
-- against pg_stat_activity before acting on it.
CREATE TABLE pgs3.worker_state (
    worker_kind text NOT NULL,
    worker_slot integer NOT NULL,
    pid integer,
    launcher_pid integer,
    mode text,
    desired boolean NOT NULL DEFAULT true,
    status text NOT NULL DEFAULT 'starting',
    listen_addr text,
    port integer,
    started_at timestamptz,
    heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    stopped_at timestamptz,
    last_error text,
    PRIMARY KEY (worker_kind, worker_slot),
    CONSTRAINT worker_state_kind_valid
        CHECK (worker_kind IN ('launcher', 'http', 'gc')),
    CONSTRAINT worker_state_slot_valid CHECK (worker_slot >= 0),
    CONSTRAINT worker_state_mode_valid
        CHECK (mode IS NULL OR mode IN ('static', 'dynamic')),
    CONSTRAINT worker_state_status_valid CHECK (
        status IN ('starting', 'running', 'idle', 'stopping', 'stopped', 'error')
    ),
    CONSTRAINT worker_state_port_valid
        CHECK (port IS NULL OR port BETWEEN 1 AND 65535)
);

-- This is the bounded-cardinality counter foundation consumed by pgs3.stats.
-- Bucket, key, role, access-key, request-id, and arbitrary error strings are
-- intentionally not metric dimensions.
CREATE TABLE pgs3.worker_metric (
    worker_kind text NOT NULL,
    worker_slot integer NOT NULL,
    pid integer NOT NULL,
    operation text NOT NULL,
    requests bigint NOT NULL DEFAULT 0,
    errors bigint NOT NULL DEFAULT 0,
    bytes_in bigint NOT NULL DEFAULT 0,
    bytes_out bigint NOT NULL DEFAULT 0,
    in_flight bigint NOT NULL DEFAULT 0,
    latency_us bigint NOT NULL DEFAULT 0,
    latency_le_1ms bigint NOT NULL DEFAULT 0,
    latency_le_5ms bigint NOT NULL DEFAULT 0,
    latency_le_10ms bigint NOT NULL DEFAULT 0,
    latency_le_50ms bigint NOT NULL DEFAULT 0,
    latency_le_100ms bigint NOT NULL DEFAULT 0,
    latency_le_500ms bigint NOT NULL DEFAULT 0,
    latency_le_1s bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (worker_kind, worker_slot, operation),
    CONSTRAINT worker_metric_kind_valid
        CHECK (worker_kind IN ('http', 'gc')),
    CONSTRAINT worker_metric_slot_valid CHECK (worker_slot >= 0),
    CONSTRAINT worker_metric_operation_valid CHECK (
        (worker_kind = 'gc' AND operation IN (
            'gc_pending_uploads', 'gc_blobs'
        ))
        OR
        (worker_kind = 'http' AND operation IN (
            'InvalidRequest', 'ServiceUnavailable',
            'ListBuckets', 'CreateBucket', 'DeleteBucket', 'HeadBucket',
            'GetBucketLocation', 'GetBucketVersioning',
            'ListObjects', 'ListObjectsV2', 'ListObjectVersions',
            'PutObject', 'CopyObject', 'RestoreObject',
            'GetObject', 'HeadObject', 'DeleteObject', 'DeleteObjects',
            'CreateMultipartUpload', 'UploadPart', 'CompleteMultipartUpload',
            'AbortMultipartUpload', 'ListParts'
        ))
    ),
    CONSTRAINT worker_metric_nonnegative CHECK (
        requests >= 0 AND errors >= 0 AND bytes_in >= 0 AND bytes_out >= 0
        AND in_flight >= 0 AND latency_us >= 0
    )
);

CREATE FUNCTION pgs3._worker_set_state(
    p_kind text,
    p_slot integer,
    p_launcher_pid integer,
    p_status text,
    p_listen_addr text,
    p_port integer,
    p_error text
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_kind NOT IN ('http', 'gc') OR p_slot < 0
       OR p_status NOT IN ('starting', 'running', 'idle', 'stopping', 'stopped', 'error')
       OR p_launcher_pid IS NULL
    THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid worker state';
    END IF;

    INSERT INTO pgs3.worker_state (
        worker_kind, worker_slot, pid, launcher_pid, desired, status,
        listen_addr, port, started_at, heartbeat_at, stopped_at, last_error
    )
    VALUES (
        p_kind, p_slot, pg_backend_pid(), p_launcher_pid, true, p_status,
        p_listen_addr, p_port,
        CASE WHEN p_status IN ('running', 'idle') THEN clock_timestamp() END,
        clock_timestamp(),
        CASE WHEN p_status = 'stopped' THEN clock_timestamp() END,
        left(p_error, 1024)
    )
    ON CONFLICT (worker_kind, worker_slot) DO UPDATE
       SET pid = EXCLUDED.pid,
           launcher_pid = EXCLUDED.launcher_pid,
           desired = EXCLUDED.desired,
           status = EXCLUDED.status,
           listen_addr = EXCLUDED.listen_addr,
           port = EXCLUDED.port,
           started_at = CASE
               WHEN pgs3.worker_state.pid = EXCLUDED.pid
                   THEN COALESCE(pgs3.worker_state.started_at, EXCLUDED.started_at)
               ELSE EXCLUDED.started_at
           END,
           heartbeat_at = EXCLUDED.heartbeat_at,
           stopped_at = EXCLUDED.stopped_at,
           last_error = EXCLUDED.last_error
     WHERE pgs3.worker_state.launcher_pid IS NULL
        OR pgs3.worker_state.launcher_pid = EXCLUDED.launcher_pid;

    -- A graceful stop closes every live connection before recording this state.
    -- Clear the materialized gauge as a final guard if its buffered decrement
    -- could not be flushed; cumulative counters remain intact.
    IF p_status = 'stopped' THEN
        UPDATE pgs3.worker_metric AS m
           SET in_flight = 0,
               updated_at = clock_timestamp()
         WHERE m.worker_kind = p_kind
           AND m.worker_slot = p_slot
           AND m.pid = pg_backend_pid();
    END IF;
END
$$;

CREATE FUNCTION pgs3._worker_add_metric(
    p_kind text,
    p_slot integer,
    p_operation text,
    p_requests bigint,
    p_errors bigint,
    p_bytes_in bigint,
    p_bytes_out bigint,
    p_in_flight_delta bigint,
    p_latency_us bigint,
    p_latency_le_1ms bigint,
    p_latency_le_5ms bigint,
    p_latency_le_10ms bigint,
    p_latency_le_50ms bigint,
    p_latency_le_100ms bigint,
    p_latency_le_500ms bigint,
    p_latency_le_1s bigint
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pgs3
AS $$
BEGIN
    IF p_kind NOT IN ('http', 'gc') OR p_slot < 0 OR p_operation IS NULL
       OR p_operation = '' OR p_requests < 0 OR p_errors < 0
       OR p_bytes_in < 0 OR p_bytes_out < 0 OR p_latency_us < 0
       OR p_latency_le_1ms < 0 OR p_latency_le_5ms < 0
       OR p_latency_le_10ms < 0 OR p_latency_le_50ms < 0
       OR p_latency_le_100ms < 0 OR p_latency_le_500ms < 0
       OR p_latency_le_1s < 0
    THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'invalid worker metric';
    END IF;

    INSERT INTO pgs3.worker_metric (
        worker_kind, worker_slot, pid, operation, requests, errors,
        bytes_in, bytes_out, in_flight, latency_us,
        latency_le_1ms, latency_le_5ms, latency_le_10ms,
        latency_le_50ms, latency_le_100ms, latency_le_500ms,
        latency_le_1s, updated_at
    )
    VALUES (
        p_kind, p_slot, pg_backend_pid(), p_operation, p_requests, p_errors,
        p_bytes_in, p_bytes_out, greatest(p_in_flight_delta, 0), p_latency_us,
        p_latency_le_1ms, p_latency_le_5ms, p_latency_le_10ms,
        p_latency_le_50ms, p_latency_le_100ms, p_latency_le_500ms,
        p_latency_le_1s,
        clock_timestamp()
    )
    ON CONFLICT (worker_kind, worker_slot, operation) DO UPDATE
       SET pid = EXCLUDED.pid,
           requests = pgs3.worker_metric.requests + EXCLUDED.requests,
           errors = pgs3.worker_metric.errors + EXCLUDED.errors,
           bytes_in = pgs3.worker_metric.bytes_in + EXCLUDED.bytes_in,
           bytes_out = pgs3.worker_metric.bytes_out + EXCLUDED.bytes_out,
           in_flight = CASE
               WHEN pgs3.worker_metric.pid = EXCLUDED.pid THEN greatest(
                   pgs3.worker_metric.in_flight + p_in_flight_delta, 0
               )
               -- A replacement process owns no connection from the old PID.
               -- Reset rather than inheriting a gauge leaked by a crash.
               ELSE greatest(p_in_flight_delta, 0)
           END,
           latency_us = pgs3.worker_metric.latency_us + EXCLUDED.latency_us,
           latency_le_1ms = pgs3.worker_metric.latency_le_1ms + EXCLUDED.latency_le_1ms,
           latency_le_5ms = pgs3.worker_metric.latency_le_5ms + EXCLUDED.latency_le_5ms,
           latency_le_10ms = pgs3.worker_metric.latency_le_10ms + EXCLUDED.latency_le_10ms,
           latency_le_50ms = pgs3.worker_metric.latency_le_50ms + EXCLUDED.latency_le_50ms,
           latency_le_100ms = pgs3.worker_metric.latency_le_100ms + EXCLUDED.latency_le_100ms,
           latency_le_500ms = pgs3.worker_metric.latency_le_500ms + EXCLUDED.latency_le_500ms,
           latency_le_1s = pgs3.worker_metric.latency_le_1s + EXCLUDED.latency_le_1s,
           updated_at = EXCLUDED.updated_at;

    UPDATE pgs3.worker_state AS s
       SET heartbeat_at = clock_timestamp()
     WHERE s.worker_kind = p_kind
       AND s.worker_slot = p_slot
       AND s.pid = pg_backend_pid();
END
$$;

CREATE VIEW pgs3.stats AS
SELECT s.worker_kind,
       s.worker_slot,
       s.pid,
       s.launcher_pid,
       s.desired,
       CASE
           WHEN a.pid IS NULL AND s.status NOT IN ('stopped', 'error') THEN 'stopped'
           ELSE s.status
       END AS worker_state,
       COALESCE(m.operation, 'worker') AS operation,
       COALESCE(m.requests, 0) AS requests,
       COALESCE(m.errors, 0) AS errors,
       COALESCE(m.bytes_in, 0) AS bytes_in,
       COALESCE(m.bytes_out, 0) AS bytes_out,
       CASE
           WHEN a.pid IS NULL OR m.pid IS DISTINCT FROM s.pid THEN 0
           ELSE COALESCE(m.in_flight, 0)
       END AS in_flight,
       COALESCE(m.latency_us, 0) AS latency_us,
       COALESCE(m.latency_le_1ms, 0) AS latency_le_1ms,
       COALESCE(m.latency_le_5ms, 0) AS latency_le_5ms,
       COALESCE(m.latency_le_10ms, 0) AS latency_le_10ms,
       COALESCE(m.latency_le_50ms, 0) AS latency_le_50ms,
       COALESCE(m.latency_le_100ms, 0) AS latency_le_100ms,
       COALESCE(m.latency_le_500ms, 0) AS latency_le_500ms,
       COALESCE(m.latency_le_1s, 0) AS latency_le_1s,
       s.listen_addr,
       s.port,
       s.started_at,
       s.heartbeat_at,
       s.last_error
  FROM pgs3.worker_state AS s
  LEFT JOIN pg_catalog.pg_stat_activity AS a
    ON a.pid = s.pid
   AND a.datname = current_database()
   AND a.backend_type = CASE s.worker_kind
       WHEN 'launcher' THEN 'pgs3 launcher'
       WHEN 'http' THEN 'pgs3 http'
       WHEN 'gc' THEN 'pgs3 gc'
   END
  LEFT JOIN pgs3.worker_metric AS m
    ON m.worker_kind = s.worker_kind
   AND m.worker_slot = s.worker_slot;

REVOKE ALL ON TABLE pgs3.worker_state FROM PUBLIC;
REVOKE ALL ON TABLE pgs3.worker_metric FROM PUBLIC;
REVOKE ALL ON TABLE pgs3.stats FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3._worker_set_state(text, integer, integer, text, text, integer, text)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3._worker_add_metric(text, integer, text, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint)
    FROM PUBLIC;

-- The default server role is cluster-wide and intentionally survives DROP
-- EXTENSION.  A later installation in another database reuses it.  Refuse to
-- adopt an existing role with ambient privileges instead of silently weakening
-- the RLS boundary.
DO $pgs3_server_role$
DECLARE
    r record;
    v_server name := coalesce(
        nullif(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
BEGIN
    SELECT * INTO r
      FROM pg_catalog.pg_roles
     WHERE rolname = v_server;

    IF NOT FOUND THEN
        IF v_server = 'pgs3_server'::name THEN
            CREATE ROLE pgs3_server
                NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
                NOREPLICATION NOBYPASSRLS;
        ELSE
            RAISE EXCEPTION USING
                ERRCODE = '42501',
                MESSAGE = 'configured pgs3.server_role does not exist';
        END IF;
    ELSIF r.rolcanlogin OR r.rolinherit OR r.rolsuper OR r.rolcreatedb
          OR r.rolcreaterole OR r.rolreplication OR r.rolbypassrls
          OR EXISTS (
              SELECT 1
                FROM pg_catalog.pg_auth_members AS m
               WHERE m.member = r.oid
                 AND (m.admin_option OR m.inherit_option)
          )
          OR EXISTS (
              SELECT 1
                FROM pg_catalog.pg_auth_members AS m
               WHERE m.roleid = r.oid
          )
    THEN
        RAISE EXCEPTION USING
            ERRCODE = '42501',
            MESSAGE = 'configured pgs3.server_role is not a restricted service role';
    END IF;
END
$pgs3_server_role$;

DO $pgs3_server_grants$
DECLARE
    v_server name := coalesce(
        nullif(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
BEGIN
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
$pgs3_server_grants$;

-- Every credential role must be reachable through SET LOCAL ROLE, but the
-- service role must not inherit tenant rights outside a request.  PostgreSQL
-- 17/18 membership options make that distinction explicit.
CREATE FUNCTION pgs3._credential_grant_server_membership()
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

CREATE TRIGGER credential_grant_server_membership
BEFORE INSERT OR UPDATE OF role_name ON pgs3.credential
FOR EACH ROW EXECUTE FUNCTION pgs3._credential_grant_server_membership();

-- Also covers credentials present when this runtime SQL is used by a future
-- upgrade script.  The no-op assignment fires the membership trigger without
-- exposing or rewriting secrets.
UPDATE pgs3.credential SET role_name = role_name;

REVOKE ALL ON FUNCTION pgs3._credential_grant_server_membership() FROM PUBLIC;
