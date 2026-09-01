\set ON_ERROR_STOP on

BEGIN;

CREATE ROLE pgs3_worker_bridge
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
CREATE ROLE pgs3_worker_target
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
GRANT pgs3_server TO pgs3_worker_bridge WITH SET TRUE, INHERIT FALSE;

DO $worker_sealed$
DECLARE
    v_server name := coalesce(
        nullif(current_setting('pgs3.server_role', true), ''),
        'pgs3_server'
    )::name;
BEGIN
    ASSERT to_regprocedure('pgs3._worker_set_actor(name)') IS NOT NULL;
    ASSERT to_regprocedure(
        'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])'
    ) IS NOT NULL;

    ASSERT (
        SELECT bool_and(p.prosecdef AND p.provolatile = 'v')
          FROM pg_catalog.pg_proc AS p
         WHERE p.oid = ANY (ARRAY[
             'pgs3._worker_set_actor(name)'::regprocedure,
             'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)'::regprocedure,
             'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])'::regprocedure
         ])
    ), 'worker-sealed helpers must be VOLATILE SECURITY DEFINER functions';

    ASSERT NOT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_proc AS p
          CROSS JOIN LATERAL pg_catalog.aclexplode(
              coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
          ) AS a
         WHERE p.oid = ANY (ARRAY[
             'pgs3._worker_set_actor(name)'::regprocedure,
             'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)'::regprocedure,
             'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])'::regprocedure
         ])
           AND a.grantee = 0
           AND a.privilege_type = 'EXECUTE'
    ), 'PUBLIC must not execute worker-sealed helpers';

    ASSERT pg_catalog.has_function_privilege(
        v_server,
        'pgs3._worker_set_actor(name)',
        'EXECUTE'
    );
    ASSERT pg_catalog.has_function_privilege(
        v_server,
        'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)',
        'EXECUTE'
    );
    ASSERT pg_catalog.has_function_privilege(
        v_server,
        'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])',
        'EXECUTE'
    );

    -- A custom GUC is not an authentication token.  _actor ignores a marker
    -- unless the immutable session identity is the configured NOLOGIN worker.
    PERFORM pg_catalog.set_config(
        'pgs3.worker_actor', session_user::text, true
    );
    ASSERT pgs3._actor() = session_user::name;

    BEGIN
        PERFORM pgs3._worker_set_actor(session_user::name);
        ASSERT false, 'an ordinary SQL session must not seal worker digests';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    BEGIN
        PERFORM pgs3.create_credential(
            'WORKERBRIDGEKEY', 'must-not-persist',
            'pgs3_worker_target'::name, true
        );
        ASSERT false,
               'a service role with an inbound member must not receive tenant membership';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    ASSERT NOT EXISTS (
        SELECT 1 FROM pgs3.credential
         WHERE access_key = 'WORKERBRIDGEKEY'
    );
END
$worker_sealed$;

ROLLBACK;

SELECT 'pgs3 worker-sealed digest boundary: ok' AS result;
