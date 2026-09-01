\set ON_ERROR_STOP on
SET search_path = pg_catalog;

SELECT format(
           'database_acl|%s',
           coalesce((
               SELECT string_agg(acl::text, ',' ORDER BY acl::text)
                 FROM unnest(d.datacl) AS acl
           ), '')
       )
  FROM pg_database AS d
 WHERE d.datname = current_database();

SELECT format(
           'schema_acl|%s',
           coalesce((
               SELECT string_agg(acl::text, ',' ORDER BY acl::text)
                 FROM unnest(n.nspacl) AS acl
           ), '')
       )
  FROM pg_namespace AS n
 WHERE n.nspname = 'pgs3';

SELECT format(
           'relation|%s|%s|%s|%s',
           c.relname,
           c.relkind,
           coalesce((
               SELECT string_agg(acl::text, ',' ORDER BY acl::text)
                 FROM unnest(c.relacl) AS acl
           ), ''),
           coalesce((
               SELECT string_agg(option, ',' ORDER BY option)
                 FROM unnest(c.reloptions) AS option
           ), '')
       )
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pgs3'
 ORDER BY c.relname;

SELECT format(
           'attribute|%s|%s|%s|%s|%s|%s|%s|%s',
           c.relname,
           a.attnum,
           a.attname,
           format_type(a.atttypid, a.atttypmod),
           a.attnotnull,
           a.attidentity,
           a.attgenerated,
           coalesce(pg_get_expr(d.adbin, d.adrelid), '')
       )
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
  JOIN pg_attribute AS a ON a.attrelid = c.oid
  LEFT JOIN pg_attrdef AS d
    ON d.adrelid = a.attrelid AND d.adnum = a.attnum
 WHERE n.nspname = 'pgs3'
   AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
   AND a.attnum > 0
   AND NOT a.attisdropped
 ORDER BY c.relname, a.attnum;

SELECT format(
           'constraint|%s|%s|%s',
           c.conrelid::regclass,
           c.conname,
           pg_get_constraintdef(c.oid, false)
       )
  FROM pg_constraint AS c
  JOIN pg_namespace AS n ON n.oid = c.connamespace
 WHERE n.nspname = 'pgs3'
 ORDER BY c.conrelid::regclass::text, c.conname;

SELECT format('index|%s|%s', c.relname, pg_get_indexdef(c.oid))
  FROM pg_class AS c
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pgs3'
   AND c.relkind = 'i'
 ORDER BY c.relname;

SELECT format(
           'function|%s|%s|%s|%s|%s|%s|%s|%s',
           p.oid::regprocedure,
           p.provolatile,
           p.proparallel,
           p.prosecdef,
           coalesce(p.proconfig::text, ''),
           coalesce((
               SELECT string_agg(acl::text, ',' ORDER BY acl::text)
                 FROM unnest(p.proacl) AS acl
           ), ''),
           md5(pg_get_functiondef(p.oid)),
           coalesce(obj_description(p.oid, 'pg_proc'), '')
       )
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
 WHERE n.nspname = 'pgs3'
 ORDER BY p.oid::regprocedure::text;

SELECT format(
           'policy|%s|%s|%s|%s|%s|%s',
           p.schemaname,
           p.tablename,
           p.policyname,
           p.cmd,
           coalesce(p.qual, ''),
           coalesce(p.with_check, '')
       )
  FROM pg_policies AS p
 WHERE p.schemaname = 'pgs3'
 ORDER BY p.tablename, p.policyname;

SELECT format(
           'trigger|%s|%s|%s',
           t.tgrelid::regclass,
           t.tgname,
           pg_get_triggerdef(t.oid, false)
       )
  FROM pg_trigger AS t
  JOIN pg_class AS c ON c.oid = t.tgrelid
  JOIN pg_namespace AS n ON n.oid = c.relnamespace
 WHERE n.nspname = 'pgs3'
   AND NOT t.tgisinternal
 ORDER BY t.tgrelid::regclass::text, t.tgname;

SELECT format(
           'member|%s|%s',
           d.classid::regclass,
           pg_describe_object(d.classid, d.objid, d.objsubid)
       )
  FROM pg_depend AS d
  JOIN pg_extension AS e
    ON e.oid = d.refobjid
   AND d.refclassid = 'pg_extension'::regclass
 WHERE e.extname = 'pgs3'
   AND d.deptype = 'e'
 ORDER BY d.classid::regclass::text,
          pg_describe_object(d.classid, d.objid, d.objsubid);
