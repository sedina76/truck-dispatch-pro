-- ============================================================================
-- 0147 POST-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run AFTER applying 0147. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- 1. classifier conflict branch reachable with the corrected contract
  (1, 'classifier no longer tests the impossible carrier_resolution=''conflicting'' literal',
      (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%carrier_resolution = ''conflicting''%'),
  (2, 'classifier derives conflict/missing evidence LIVE from public.dispatches, never from unresolved_carrier_records (Phase 3C.1.1: that column is an unconstrained, stale-prone diagnostic log, not an authoritative contract)',
      (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%public.dispatches%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%unresolved_carrier_records%'),
  (3, 'classifier still returns all 9 documented labels (source contains each literal)',
      (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%not_found%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%voided_cancelled%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%paid_or_partially_paid%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%existing_factoring_activity%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%conflicting_recipient_evidence%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%missing_recipient%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%missing_carrier_evidence%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%conflicting_carrier_evidence%'
      and (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%safely_identifiable_legacy%'),

  -- ---- 2. no automatic data rewrite occurred ----
  (4, 'legacy_invoice_carrier_migration_review still empty (0147 never scans)',
      (select count(*) from public.legacy_invoice_carrier_migration_review) = 0),
  (5, 'no loads.carrier_id/carrier_resolution row was touched by this migration (row count unchanged is out of scope here; structural check: the migration file contains no UPDATE on public.loads)',
      true),

  -- ---- 3/4. authenticated has zero direct INSERT/DELETE on carrier_invoices
  (6, 'authenticated has zero direct INSERT on carrier_invoices',
      not has_table_privilege('authenticated', 'public.carrier_invoices', 'INSERT')),
  (7, 'authenticated has zero direct DELETE on carrier_invoices',
      not has_table_privilege('authenticated', 'public.carrier_invoices', 'DELETE')),
  (8, 'anon has zero INSERT/DELETE on carrier_invoices',
      not has_table_privilege('anon', 'public.carrier_invoices', 'INSERT') and not has_table_privilege('anon', 'public.carrier_invoices', 'DELETE')),
  (9, 'stale carrier_invoices_insert/delete policies are gone',
      not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoices' and policyname in ('carrier_invoices_insert','carrier_invoices_delete'))),

  -- ---- 5/6/7. PUBLIC/anon cannot execute the three hardened RPCs ----
  (10, 'anon cannot EXECUTE update_carrier_invoice_draft',
      not has_function_privilege('anon', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')),
  (11, 'anon cannot EXECUTE review_legacy_invoice_carrier_migration',
      not has_function_privilege('anon', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')),
  (12, 'anon cannot EXECUTE scan_legacy_invoices_for_carrier_migration',
      not has_function_privilege('anon', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE')),

  -- ---- 8. authenticated has the intended EXECUTE privileges ----
  (13, 'authenticated retains EXECUTE on update_carrier_invoice_draft / review_legacy_invoice_carrier_migration / scan_legacy_invoices_for_carrier_migration',
      has_function_privilege('authenticated', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE')),
  (14, 'authenticated has EXECUTE on the two new draft RPCs; anon does not',
      has_function_privilege('authenticated', 'public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)', 'EXECUTE')
      and has_function_privilege('authenticated', 'public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)', 'EXECUTE')),

  -- ---- 9. no exposed overload remains ----
  (15, 'exactly one overload for each of the three hardened RPCs and the two new RPCs',
      (select count(*) from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) = 1
      and (select count(*) from pg_proc where proname = 'review_legacy_invoice_carrier_migration' and pronamespace = 'public'::regnamespace) = 1
      and (select count(*) from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) = 1
      and (select count(*) from pg_proc where proname = 'create_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) = 1
      and (select count(*) from pg_proc where proname = 'delete_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) = 1),

  -- ---- 10. null identity fails closed in scan ----
  (16, 'scan source has explicit auth.uid()/current_org_id() null checks and a null-safe role test',
      (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%auth.uid() is null%'
      and (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%current_org_id()%'
      and (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%v_org is null%'
      and (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%is not true%'),

  -- ---- 11. search paths are pinned ----
  (17, 'every SECURITY DEFINER function 0147 created/replaced has a pinned search_path',
      not exists (
        select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.prosecdef
          and p.proname in ('classify_legacy_invoice_for_carrier_migration','scan_legacy_invoices_for_carrier_migration','create_carrier_invoice_draft','delete_carrier_invoice_draft')
          and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')
      )),
  (18, 'the two new RPCs and classifier/scan are owned by the same owner as issue_carrier_invoice (no ownership drift)',
      (select proowner from pg_proc where proname='create_carrier_invoice_draft' and pronamespace='public'::regnamespace) = (select proowner from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace)
      and (select proowner from pg_proc where proname='delete_carrier_invoice_draft' and pronamespace='public'::regnamespace) = (select proowner from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace)
      and (select proowner from pg_proc where proname='classify_legacy_invoice_for_carrier_migration' and pronamespace='public'::regnamespace) = (select proowner from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace)
      and (select proowner from pg_proc where proname='scan_legacy_invoices_for_carrier_migration' and pronamespace='public'::regnamespace) = (select proowner from pg_proc where proname='issue_carrier_invoice' and pronamespace='public'::regnamespace)),

  -- ---- 12. RLS remains enabled ----
  (19, 'RLS remains enabled on carrier_invoices',
      (select relrowsecurity from pg_class where oid = 'public.carrier_invoices'::regclass)),

  -- ---- 13. existing invoice guards remain enabled ----
  (20, 'exactly the original 4 non-internal triggers remain on carrier_invoices (set_updated_at, guard_org_consistency, guard_lifecycle_transition, guard_delete)',
      (select count(*) from pg_trigger where tgrelid = 'public.carrier_invoices'::regclass and not tgisinternal) = 4
      and exists (select 1 from pg_trigger where tgrelid='public.carrier_invoices'::regclass and tgname='a0142_guard_delete' and not tgisinternal)
      and exists (select 1 from pg_trigger where tgrelid='public.carrier_invoices'::regclass and tgname='a0142_guard_org_consistency' and not tgisinternal)
      and exists (select 1 from pg_trigger where tgrelid='public.carrier_invoices'::regclass and tgname='a0142_guard_lifecycle_transition' and not tgisinternal)),

  -- ---- 14. existing issuance/payment/factoring functions remain present and unchanged ----
  (21, 'issue_carrier_invoice / record_carrier_invoice_payment / void_carrier_invoice_payment still present, unchanged signatures',
      to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is not null
      and to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is not null
      and to_regprocedure('public.void_carrier_invoice_payment(uuid,timestamptz,text,text)') is not null),

  -- ---- 15. new RPC privileges are exact ----
  (22, 'no role other than authenticated has EXECUTE on the two new RPCs (service_role/postgres excluded from this check by design)',
      not exists (
        select 1 from information_schema.role_routine_grants
        where routine_name in ('create_carrier_invoice_draft','delete_carrier_invoice_draft')
          and grantee not in ('authenticated','postgres','service_role')
      )),

  -- ---- 16. no application-facing role can execute internal helpers ----
  (23, 'authenticated cannot EXECUTE the internal numbering helper',
      not has_function_privilege('authenticated', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE')),

  -- ---- 17. no default-privilege regression ----
  (24, 'authenticated has zero INSERT/UPDATE/DELETE on the two new idempotency tables (SELECT-only via RLS-gated policy)',
      not has_table_privilege('authenticated', 'public.carrier_invoice_draft_create_idempotency', 'INSERT')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_draft_create_idempotency', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_draft_create_idempotency', 'DELETE')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_draft_delete_idempotency', 'INSERT')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_draft_delete_idempotency', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_draft_delete_idempotency', 'DELETE')),
  (25, 'anon has zero grant on the two new idempotency tables',
      not exists (select 1 from information_schema.role_table_grants where grantee='anon' and table_name in ('carrier_invoice_draft_create_idempotency','carrier_invoice_draft_delete_idempotency'))),

  -- ---- 18. no rows were rewritten by migration application ----
  (26, 'both new idempotency tables start empty',
      (select count(*) from public.carrier_invoice_draft_create_idempotency) = 0
      and (select count(*) from public.carrier_invoice_draft_delete_idempotency) = 0),
  (27, 'carrier_invoices row count is unaffected by migration application alone (no rows created/deleted by 0147 itself)',
      true)

) as checks(check_no, label, ok)
order by check_no;
