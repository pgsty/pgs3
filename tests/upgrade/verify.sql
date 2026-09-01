\set ON_ERROR_STOP on

DO $version$
BEGIN
    ASSERT (
        SELECT extversion = '0.1.1'
          FROM pg_catalog.pg_extension
         WHERE extname = 'pgs3'
    ), 'ALTER EXTENSION did not reach pgs3 0.1.1';
    ASSERT pgs3.extension_version() = '0.1.1';
    ASSERT (
        SELECT c.reloptions @> ARRAY['fillfactor=80']::text[]
          FROM pg_catalog.pg_class AS c
         WHERE c.oid = 'pgs3.blob'::regclass
    ), 'pgs3.blob fillfactor was not upgraded to 80';
    ASSERT to_regprocedure('pgs3._worker_set_actor(name)') IS NOT NULL;
    ASSERT to_regprocedure(
        'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)'
    ) IS NOT NULL;
    ASSERT to_regprocedure(
        'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])'
    ) IS NOT NULL;
    ASSERT NOT has_function_privilege(
        'pgs3_upgrade_tenant_a',
        'pgs3._worker_set_actor(name)',
        'EXECUTE'
    );
    ASSERT has_function_privilege(
        'pgs3_upgrade_server',
        'pgs3._worker_set_actor(name)',
        'EXECUTE'
    );
    ASSERT has_function_privilege(
        'pgs3_upgrade_server',
        'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)',
        'EXECUTE'
    );
    ASSERT has_function_privilege(
        'pgs3_upgrade_server',
        'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])',
        'EXECUTE'
    );
    ASSERT has_function_privilege(
        'pgs3_upgrade_server',
        'pgs3._worker_set_state(text,integer,integer,text,text,integer,text)',
        'EXECUTE'
    );
    ASSERT has_function_privilege(
        'pgs3_upgrade_server',
        'pgs3._worker_add_metric(text,integer,text,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint)',
        'EXECUTE'
    );
    ASSERT has_database_privilege(
        'pgs3_upgrade_server', current_database(), 'CONNECT'
    );
    ASSERT has_schema_privilege(
        'pgs3_upgrade_server', 'pgs3', 'USAGE'
    );
    ASSERT has_table_privilege(
        'pgs3_upgrade_server', 'pgs3.credential', 'SELECT'
    );
    ASSERT NOT has_table_privilege(
        'pgs3_server', 'pgs3.credential', 'SELECT'
    ), 'upgrade must remove the obsolete literal server-role table grant';
    ASSERT NOT has_function_privilege(
        'pgs3_server',
        'pgs3._worker_set_state(text,integer,integer,text,text,integer,text)',
        'EXECUTE'
    ), 'upgrade must remove the obsolete literal server-role function grant';
    ASSERT NOT has_function_privilege(
        'pgs3_server',
        'pgs3._worker_add_metric(text,integer,text,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint)',
        'EXECUTE'
    ), 'upgrade must remove the obsolete literal server-role metric grant';
    ASSERT (
        SELECT p.proparallel = 'u'
          FROM pg_catalog.pg_proc AS p
         WHERE p.oid = 'pgs3._actor()'::regprocedure
    ), '_actor must become parallel-unsafe when it reads worker actor state';
    ASSERT EXISTS (
        SELECT 1
          FROM pg_catalog.pg_depend AS d
          JOIN pg_catalog.pg_extension AS e
            ON e.oid = d.refobjid
           AND d.refclassid = 'pg_catalog.pg_extension'::regclass
         WHERE e.extname = 'pgs3'
           AND d.classid = 'pg_catalog.pg_proc'::regclass
           AND d.objid = 'pgs3.extension_version()'::regprocedure
           AND d.deptype = 'e'
    ), 'extension_version must be owned by the extension';
END
$version$;

SELECT public.pgs3_assert_upgrade_fixture();

DO $fingerprint$
BEGIN
    ASSERT public.pgs3_upgrade_fingerprint() = (
        SELECT value
          FROM public.pgs3_upgrade_expected
         WHERE name = 'data_fingerprint'
    ), 'extension update changed stored object/upload/credential state';
END
$fingerprint$;

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

SET SESSION AUTHORIZATION pgs3_upgrade_server;
BEGIN;
SELECT pgs3._worker_set_actor('pgs3_upgrade_tenant_a');
ROLLBACK;
RESET SESSION AUTHORIZATION;

SELECT 'pgs3 0.1.0 to 0.1.1 upgrade: ok' AS result;
