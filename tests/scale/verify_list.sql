\set ON_ERROR_STOP on

CREATE FUNCTION pg_temp.scale_assert(p_ok boolean, p_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT coalesce(p_ok, false) THEN
        RAISE EXCEPTION 'scale assertion failed: %', p_message;
    END IF;
END
$$;

WITH page AS MATERIALIZED (
    SELECT *
      FROM pgs3.list_objects_v2(
          'scale-list', 'tree/000001/', NULL,
          NULL, NULL, (:'page_size')::integer
      )
)
SELECT pg_temp.scale_assert(
    count(*) = (:'page_size')::integer
        AND count(*) FILTER (WHERE continuation_token IS NOT NULL) = 1
        AND count(*) FILTER (
            WHERE key LIKE 'tree/000001/%' AND common_prefix IS NULL
        ) = (:'page_size')::integer,
    'ordinary LIST did not return the requested direct keys'
)
  FROM page;

WITH page AS MATERIALIZED (
    SELECT *
      FROM pgs3.list_objects_v2(
          'scale-list', 'tree/', '/',
          NULL, NULL, (:'page_size')::integer
      )
)
SELECT pg_temp.scale_assert(
    count(*) = (:'page_size')::integer
        AND count(*) FILTER (WHERE continuation_token IS NOT NULL) = 1
        AND count(DISTINCT common_prefix) = (:'page_size')::integer
        AND count(*) FILTER (
            WHERE key IS NULL
              AND common_prefix LIKE 'tree/%/'
        ) = (:'page_size')::integer,
    'delimiter LIST did not return distinct child prefixes'
)
  FROM page;

SELECT 'ordinary and delimiter LIST result shapes passed' AS result;
