-- NOT APPROVED FOR PRODUCTION. Test instrumentation, excluded from the model manifest.
CREATE SCHEMA _td0148;
REVOKE ALL ON SCHEMA _td0148 FROM PUBLIC;
CREATE TABLE _td0148.expected(boundary text PRIMARY KEY, catalog jsonb NOT NULL, rows jsonb NOT NULL, full_rows jsonb NOT NULL);
CREATE FUNCTION _td0148.local_only() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF inet_server_addr() IS NOT NULL OR current_setting('listen_addresses') <> ''
    OR current_user <> 'postgres' OR current_database() NOT IN ('td0148_reference','td0148_model')
    OR current_setting('port') <> '55489'
    OR current_setting('data_directory') !~ '^/private/tmp/td0148-local-[a-zA-Z0-9_]+/data$'
    OR current_setting('unix_socket_directories') <> regexp_replace(current_setting('data_directory'), '/data$', '/socket')
 THEN RAISE EXCEPTION '0148_REFUSED_NOT_DISPOSABLE'; END IF;
END $$;
CREATE FUNCTION _td0148.catalog() RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE dup_report text; result jsonb;
BEGIN
WITH ns AS (SELECT oid,nspname,nspowner,nspacl FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname NOT IN ('information_schema','_td0148')),
rel AS (SELECT c.*,n.nspname FROM pg_class c JOIN ns n ON n.oid=c.relnamespace),
objects AS (
 SELECT 'schema'::text kind,nspname::text key,jsonb_build_object('owner',pg_get_userbyid(nspowner),'acl',(SELECT jsonb_agg(x::text ORDER BY x::text) FROM unnest(nspacl) x)) value FROM ns
 UNION ALL SELECT 'relation',nspname||'.'||relname,jsonb_build_object('kind',relkind,'owner',pg_get_userbyid(relowner),'acl',(SELECT jsonb_agg(x::text ORDER BY x::text) FROM unnest(relacl) x),'rls',relrowsecurity,'force_rls',relforcerowsecurity,'options',reloptions,'persistence',relpersistence,'replica_identity',relreplident,'view',CASE WHEN relkind IN ('v','m') THEN pg_get_viewdef(oid,true) END,'comment',obj_description(oid,'pg_class')) FROM rel
 UNION ALL SELECT 'column',r.nspname||'.'||r.relname||'.'||a.attname,jsonb_build_object('type',format_type(a.atttypid,a.atttypmod),'not_null',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,'default',pg_get_expr(d.adbin,d.adrelid),'acl',(SELECT jsonb_agg(x::text ORDER BY x::text) FROM unnest(a.attacl) x),'collation',a.attcollation::regcollation::text,'comment',col_description(r.oid,a.attnum)) FROM rel r JOIN pg_attribute a ON a.attrelid=r.oid AND a.attnum>0 AND NOT a.attisdropped LEFT JOIN pg_attrdef d ON d.adrelid=r.oid AND d.adnum=a.attnum
 UNION ALL SELECT 'constraint',r.nspname||'.'||r.relname||'.'||c.conname,jsonb_build_object('definition',pg_get_constraintdef(c.oid,true),'validated',c.convalidated,'deferrable',c.condeferrable,'deferred',c.condeferred) FROM pg_constraint c JOIN rel r ON r.oid=c.conrelid
 UNION ALL SELECT 'index',r.nspname||'.'||r.relname,jsonb_build_object('definition',pg_get_indexdef(i.indexrelid),'valid',i.indisvalid,'ready',i.indisready,'live',i.indislive,'predicate',pg_get_expr(i.indpred,i.indrelid),'expressions',pg_get_expr(i.indexprs,i.indrelid)) FROM pg_index i JOIN rel r ON r.oid=i.indexrelid
 UNION ALL SELECT 'function',n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',jsonb_build_object('definition',pg_get_functiondef(p.oid),'owner',pg_get_userbyid(p.proowner),'acl',(SELECT jsonb_agg(x::text ORDER BY x::text) FROM unnest(p.proacl) x),'volatility',p.provolatile,'security_definer',p.prosecdef,'config',p.proconfig,'parallel',p.proparallel,'leakproof',p.proleakproof,'strict',p.proisstrict,'comment',obj_description(p.oid,'pg_proc')) FROM pg_proc p JOIN ns n ON n.oid=p.pronamespace WHERE p.prokind IN ('f','p')
 UNION ALL SELECT 'trigger',r.nspname||'.'||r.relname||'.'||t.tgname,jsonb_build_object('definition',pg_get_triggerdef(t.oid,true),'enabled',t.tgenabled) FROM pg_trigger t JOIN rel r ON r.oid=t.tgrelid WHERE NOT t.tgisinternal
 UNION ALL SELECT 'policy',schemaname||'.'||tablename||'.'||policyname,to_jsonb(p) FROM pg_policies p WHERE schemaname IN (SELECT nspname FROM ns)
 UNION ALL SELECT 'type',n.nspname||'.'||t.typname,jsonb_build_object('kind',t.typtype,'base',t.typbasetype::regtype::text,'element',t.typelem::regtype::text,'not_null',t.typnotnull,'default',t.typdefault,'owner',pg_get_userbyid(t.typowner),'acl',(SELECT jsonb_agg(x::text ORDER BY x::text) FROM unnest(t.typacl) x),'labels',(SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid=t.oid)) FROM pg_type t JOIN ns n ON n.oid=t.typnamespace
 UNION ALL SELECT 'default_acl',pg_get_userbyid(d.defaclrole)||'.'||coalesce(n.nspname,'GLOBAL')||'.'||d.defaclobjtype::text,(SELECT jsonb_agg(x::text ORDER BY x::text) FROM unnest(d.defaclacl) x) FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace WHERE n.nspname IS DISTINCT FROM '_td0148'
 UNION ALL SELECT 'sequence',schemaname||'.'||sequencename,to_jsonb(s) FROM pg_sequences s WHERE schemaname IN (SELECT nspname FROM ns)
 UNION ALL SELECT 'role',rolname::text,jsonb_build_object('superuser',rolsuper,'inherit',rolinherit,'login',rolcanlogin,'bypassrls',rolbypassrls,'config',rolconfig) FROM pg_roles WHERE rolname !~ '^pg_'
 UNION ALL SELECT 'extension',extname::text,jsonb_build_object('version',extversion,'schema',extnamespace::regnamespace::text,'owner',pg_get_userbyid(extowner)) FROM pg_extension
 UNION ALL SELECT 'event_trigger',evtname::text,jsonb_build_object('event',evtevent,'enabled',evtenabled,'function',evtfoid::regprocedure::text,'tags',evttags,'owner',pg_get_userbyid(evtowner)) FROM pg_event_trigger
 UNION ALL SELECT 'membership',pg_get_userbyid(roleid)||'.'||pg_get_userbyid(member),jsonb_build_object('grantor',pg_get_userbyid(grantor),'admin',admin_option) FROM pg_auth_members
)
SELECT
 (SELECT string_agg(format('kind=%s key=%s (seen %s times)',d.kind,d.key,d.cnt),E'\n' ORDER BY d.kind,d.key)
  FROM (SELECT kind,key,count(*) cnt FROM objects GROUP BY kind,key HAVING count(*)>1) d),
 (SELECT coalesce(jsonb_object_agg(kind||':'||key,value ORDER BY kind,key),'{}'::jsonb) FROM objects)
INTO dup_report,result;
IF dup_report IS NOT NULL THEN
 RAISE EXCEPTION '0148_CATALOG_DUPLICATE_KEY: %',dup_report;
END IF;
RETURN result;
END
$$;
CREATE FUNCTION _td0148.diff_catalog(actual jsonb,expected jsonb) RETURNS text LANGUAGE sql STABLE AS $$
WITH akeys AS (SELECT jsonb_object_keys(coalesce(actual,'{}'::jsonb)) k),
ekeys AS (SELECT jsonb_object_keys(coalesce(expected,'{}'::jsonb)) k),
missing AS (SELECT k FROM ekeys EXCEPT SELECT k FROM akeys),
extra AS (SELECT k FROM akeys EXCEPT SELECT k FROM ekeys),
common AS (SELECT k FROM akeys INTERSECT SELECT k FROM ekeys),
different AS (SELECT k FROM common WHERE actual->k IS DISTINCT FROM expected->k),
lines AS (
 SELECT k,'missing' classification,expected->k expected_value,NULL::jsonb actual_value FROM missing
 UNION ALL SELECT k,'extra',NULL::jsonb,actual->k FROM extra
 UNION ALL SELECT k,'different',expected->k,actual->k FROM different
)
SELECT string_agg(
 format('classification=%s kind=%s key=%s expected=%s actual=%s',
  classification,
  split_part(k,':',1),
  substring(k from position(':' in k)+1),
  coalesce(expected_value::text,'<absent>'),
  coalesce(actual_value::text,'<absent>')),
 E'\n' ORDER BY k)
FROM lines
$$;
CREATE FUNCTION _td0148.diff_rows(label text,actual jsonb,expected jsonb) RETURNS text LANGUAGE sql STABLE AS $$
WITH akeys AS (SELECT jsonb_object_keys(coalesce(actual,'{}'::jsonb)) k),
ekeys AS (SELECT jsonb_object_keys(coalesce(expected,'{}'::jsonb)) k),
missing AS (SELECT k FROM ekeys EXCEPT SELECT k FROM akeys),
extra AS (SELECT k FROM akeys EXCEPT SELECT k FROM ekeys),
common AS (SELECT k FROM akeys INTERSECT SELECT k FROM ekeys),
different AS (SELECT k FROM common WHERE actual->k IS DISTINCT FROM expected->k),
lines AS (
 SELECT k,'missing' classification,expected->k expected_value,NULL::jsonb actual_value FROM missing
 UNION ALL SELECT k,'extra',NULL::jsonb,actual->k FROM extra
 UNION ALL SELECT k,'different',expected->k,actual->k FROM different
)
SELECT string_agg(
 format('classification=%s kind=%s key=%s expected=%s actual=%s',
  classification,label,k,
  coalesce(expected_value::text,'<absent>'),
  coalesce(actual_value::text,'<absent>')),
 E'\n' ORDER BY k)
FROM lines
$$;
CREATE FUNCTION _td0148.rows(original_columns boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE r record; result jsonb := '{}'; payload jsonb; subtract text[];
BEGIN
 FOR r IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname !~ '^pg_' AND n.nspname NOT IN ('information_schema','_td0148') ORDER BY n.nspname,c.relname LOOP
  subtract := '{}';
  IF original_columns AND r.nspname='public' AND r.relname='carriers' THEN subtract := ARRAY['factoring_mode']; END IF;
  IF original_columns AND r.nspname='public' AND r.relname='factoring_relationships' THEN subtract := ARRAY['carrier_id','remittance_instructions','remittance_reference','noa_template_text','noa_document_id','noa_reference','noa_effective_date','noa_approved','noa_approved_by','noa_approved_at','submission_method','submission_destination_email','submission_integration_id','submission_notes']; END IF;
  EXECUTE format('SELECT jsonb_build_object(''count'',count(*),''sha256'',encode(sha256(convert_to(coalesce(jsonb_agg(j ORDER BY j::text)::text,''[]''),''UTF8'')),''hex'')) FROM (SELECT to_jsonb(t)-$1 AS j FROM %I.%I t) q',r.nspname,r.relname) INTO payload USING subtract;
  result := result || jsonb_build_object(r.nspname||'.'||r.relname,payload);
 END LOOP;
 RETURN result;
END $$;
CREATE FUNCTION _td0148.check_state(boundary_name text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
 expected_catalog jsonb; expected_rows jsonb; expected_full_rows jsonb;
 actual_catalog jsonb; actual_rows jsonb; actual_full_rows jsonb;
BEGIN
 PERFORM _td0148.local_only();
 SELECT catalog,rows,full_rows INTO expected_catalog,expected_rows,expected_full_rows FROM _td0148.expected WHERE boundary=boundary_name;
 IF expected_catalog IS NULL THEN
  RAISE EXCEPTION '0148_REFUSED_CATALOG_%: no expected snapshot recorded for this boundary',boundary_name;
 END IF;
 actual_catalog := _td0148.catalog();
 IF actual_catalog IS DISTINCT FROM expected_catalog THEN
  RAISE EXCEPTION '0148_REFUSED_CATALOG_%: %',boundary_name,_td0148.diff_catalog(actual_catalog,expected_catalog);
 END IF;
 actual_full_rows := _td0148.rows(false);
 IF actual_full_rows IS DISTINCT FROM expected_full_rows THEN
  RAISE EXCEPTION '0148_REFUSED_FULL_DATA_%: %',boundary_name,_td0148.diff_rows('full_row_hash',actual_full_rows,expected_full_rows);
 END IF;
 actual_rows := _td0148.rows(true);
 IF actual_rows IS DISTINCT FROM expected_rows THEN
  RAISE EXCEPTION '0148_REFUSED_DATA_%: %',boundary_name,_td0148.diff_rows('row_hash',actual_rows,expected_rows);
 END IF;
END $$;
CREATE FUNCTION _td0148.lock_model() RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
 PERFORM _td0148.local_only();
 IF NOT pg_try_advisory_xact_lock(148,148) THEN RAISE EXCEPTION '0148_REFUSED_BUSY'; END IF;
 FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename LOOP
  EXECUTE format('LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE',r.tablename);
 END LOOP;
END $$;
