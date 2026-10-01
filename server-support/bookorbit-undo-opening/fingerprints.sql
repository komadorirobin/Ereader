\set ON_ERROR_STOP on
-- Compare existing tables around an offline migration; no row contents are printed.
SELECT format(
  'SELECT %L || ''|'' || count(*) || ''|'' || md5(coalesce(string_agg(md5(to_jsonb(t)::text), '','' ORDER BY md5(to_jsonb(t)::text)), '''')) FROM %I.%I t;',
  table_schema || '.' || table_name, table_schema, table_name
)
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
  AND table_name <> 'reading_openings'
ORDER BY table_schema, table_name
\gexec
