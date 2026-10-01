-- Catalog rows compared by the drift check (one row per schema item in public).
-- Used by make-drift-check.sh; keep identical in the generated query.

  select 'columns' as kind, c.relname as grp, a.attname::text as name,
         format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end as fp
  from pg_attribute a join pg_class c on c.oid = a.attrelid
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m') and a.attnum > 0 and not a.attisdropped
  union all
  select 'table', c.relname, '', c.relkind::text || case when c.relrowsecurity then ' rls' else '' end
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m')
  union all
  select 'function', p.oid::regprocedure::text, '',
         regexp_replace(lower(regexp_replace(p.prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')
         || '|' || p.prosecdef::text || '|' || coalesce(array_to_string(p.proconfig, ','), '') || '|' || p.provolatile::text
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
  union all
  select 'policies', pol.tablename::text, pol.policyname::text,
         pol.cmd || '|' || array_to_string(pol.roles, ',') || '|' || pol.permissive || '|'
         || regexp_replace(coalesce(pol.qual, ''), '\s+', '', 'g') || '|' || regexp_replace(coalesce(pol.with_check, ''), '\s+', '', 'g')
  from pg_policies pol where pol.schemaname = 'public'
  union all
  select 'triggers', c.relname, t.tgname::text, pg_get_triggerdef(t.oid) || '|' || t.tgenabled::text
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
  union all
  select 'constraints', c.relname, con.conname::text, pg_get_constraintdef(con.oid)
  from pg_constraint con join pg_class c on c.oid = con.conrelid
  where c.relnamespace = 'public'::regnamespace
  union all
  select 'indexes', t.relname, i.relname::text, regexp_replace(pg_get_indexdef(i.oid), '\s+', ' ', 'g')
  from pg_index x join pg_class i on i.oid = x.indexrelid join pg_class t on t.oid = x.indrelid
  where t.relnamespace = 'public'::regnamespace
  union all
  select 'enum', t.typname, '', string_agg(e.enumlabel, ',' order by e.enumsortorder)
  from pg_type t join pg_enum e on e.enumtypid = t.oid
  where t.typnamespace = 'public'::regnamespace group by t.typname
