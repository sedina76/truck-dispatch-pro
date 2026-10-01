-- =============================================================================
-- P02_schema_objects_readonly.sql -- PRODUCTION READ-ONLY DISCOVERY, part 2: schemas, tables, owners, RLS, policies, extensions, sequences, defaults, triggers.
-- PROPOSAL 0152 -- NOT RUN. Owner authorization + the project-reference check in README.md are REQUIRED before running anywhere.
-- ONE SELECT statement (the SQL Editor shows only the last statement's result). It changes NOTHING: catalog reads only; no DDL/DML, no setval/nextval, no lock, no
-- session or setting change. Sequence positions are read from pg_sequences (a view over catalog data; it does not advance a sequence).
-- =============================================================================
with rows as (
  select 10 as ord, 'IDENTITY' as section, 'database / user / version_num' as item, current_database() || ' / ' || current_user || ' / ' || current_setting('server_version_num') as detail
  union all select 20, 'EXTENSIONS', e.extname || ' ' || e.extversion, 'schema=' || n.nspname from pg_extension e join pg_namespace n on n.oid = e.extnamespace
  union all select 30, 'SCHEMAS', n.nspname::text, 'owner=' || pg_get_userbyid(n.nspowner) || ' tables=' || (select count(*) from pg_class c where c.relnamespace = n.oid and c.relkind in ('r', 'p'))::text
         from pg_namespace n where n.nspname !~ '^pg_' and n.nspname <> 'information_schema'
  union all select 40, 'TABLES (schema.table)', n.nspname || '.' || c.relname,
         format('kind=%s owner=%s rls=%s force_rls=%s persistence=%s est_rows=%s', c.relkind, pg_get_userbyid(c.relowner), c.relrowsecurity, c.relforcerowsecurity, c.relpersistence, greatest(c.reltuples, 0)::bigint)
         from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and n.nspname in ('public', 'ops_freeze', 'ops_freeze_v2')
  union all select 50, 'POLICIES (public)', p.tablename || '.' || p.policyname, format('cmd=%s roles=%s permissive=%s', p.cmd, p.roles::text, p.permissive) from pg_policies p where p.schemaname = 'public'
  union all select 60, 'SEQUENCES (public)', s.sequencename::text, format('last_value=%s increment=%s owner=%s', coalesce(s.last_value::text, 'null'), s.increment_by, s.sequenceowner) from pg_sequences s where s.schemaname = 'public'
  union all select 70, 'DEFAULT PRIVILEGES', pg_get_userbyid(d.defaclrole) || ' in ' || coalesce(n.nspname, 'ALL') || ' [' || d.defaclobjtype::text || ']', d.defaclacl::text
         from pg_default_acl d left join pg_namespace n on n.oid = d.defaclnamespace
  union all select 80, 'USER TRIGGERS (public)', c.relname || '.' || t.tgname, format('enabled=%s function=%s def=%s', t.tgenabled, p.proname, left(pg_get_triggerdef(t.oid), 200))
         from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace join pg_proc p on p.oid = t.tgfoid where not t.tgisinternal and n.nspname = 'public'
  union all select 90, 'EVENT TRIGGERS', evtname::text, evtevent::text from pg_event_trigger
  union all select 100, 'PUBLICATIONS / SUBSCRIPTIONS', 'publications', coalesce((select string_agg(pubname, ', ') from pg_publication), '(none)') || ' / subscriptions: ' || coalesce((select string_agg(subname, ', ') from pg_subscription), '(none)')
  union all select 105, '0150 EVIDENCE TABLES (finding F-11: a missing table/column counts as ZERO evidence in 0150)', v.tbl || '.' || v.col,
         case when to_regclass(v.tbl) is null then 'TABLE MISSING' when not exists (select 1 from pg_attribute a where a.attrelid = to_regclass(v.tbl) and a.attname = v.col and not a.attisdropped) then 'COLUMN MISSING' else 'present' end
         from (values ('public.invoices', 'load_id'), ('public.dispatch_advances', 'load_id'), ('public.settlement_line_items', 'load_id'), ('public.driver_settlement_items', 'load_id'), ('public.expenses', 'load_id'),
                      ('public.compliance_overrides', 'load_id'), ('public.dispatch_resource_reassignments', 'load_id'), ('public.carrier_invoice_loads', 'load_id'), ('public.carrier_invoice_line_items', 'source_load_id'),
                      ('public.carrier_dispatch_service_billing_lines', 'load_id'), ('public.profile_share_log', 'load_id')) v(tbl, col)
  union all select 110, 'MIGRATION HISTORY', 'supabase_migrations.schema_migrations present?', (to_regclass('supabase_migrations.schema_migrations') is not null)::text
  union all select 111, 'MIGRATION HISTORY', 'versions (if the table exists)',
         case when to_regclass('supabase_migrations.schema_migrations') is null then '(table not present: history is not tracked by the Supabase CLI here)'
              else coalesce((xpath('/row/v/text()', query_to_xml('select string_agg(version::text, '','' order by version) as v from supabase_migrations.schema_migrations', false, true, '')))[1]::text, '(unreadable)') end
)
select ord, section, item, detail from rows order by ord, section, item;
