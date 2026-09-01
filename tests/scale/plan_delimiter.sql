\set ON_ERROR_STOP on
-- Keep the procedural index-jump plan warm in the same persistent-backend
-- shape used by an HTTP worker; the runner separately warms shared data.
SELECT count(*)
  FROM pgs3.list_objects_v2(
      'scale-list', 'tree/', '/', NULL, NULL,
      (:'page_size')::integer
  ) \g /dev/null
EXPLAIN (
    ANALYZE, BUFFERS, WAL, SETTINGS, TIMING OFF, SUMMARY ON, FORMAT JSON
)
SELECT *
  FROM pgs3.list_objects_v2(
      'scale-list',
      'tree/',
      '/',
      NULL,
      NULL,
      (:'page_size')::integer
  );
