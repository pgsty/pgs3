\set ON_ERROR_STOP on
-- The HTTP workers are persistent PostgreSQL backends.  Warm the PL/pgSQL/SPI
-- plans in this same backend; the runner's earlier warmup covers shared data.
SELECT count(*)
  FROM pgs3.list_objects_v2(
      'scale-list', 'tree/000001/', NULL, NULL, NULL,
      (:'page_size')::integer
  ) \g /dev/null
EXPLAIN (
    ANALYZE, BUFFERS, WAL, SETTINGS, TIMING OFF, SUMMARY ON, FORMAT JSON
)
SELECT *
  FROM pgs3.list_objects_v2(
      'scale-list',
      'tree/000001/',
      NULL,
      NULL,
      NULL,
      (:'page_size')::integer
  );
