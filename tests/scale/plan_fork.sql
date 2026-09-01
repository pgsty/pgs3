\set ON_ERROR_STOP on
EXPLAIN (
    ANALYZE, BUFFERS, WAL, SETTINGS, TIMING OFF, SUMMARY ON, FORMAT JSON
)
SELECT pgs3.fork_bucket(
    'scale-fork-source',
    'scale-fork-destination'
) AS forked_objects;
