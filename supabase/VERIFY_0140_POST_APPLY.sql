-- ============================================================================
-- 0140 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0140. Every row must show ok = true.
-- ============================================================================
select * from ( values

  -- ---- A. authorization tightening ----
  -- Phase 3B.1.6: an INSERT policy has NO `qual` (USING) -- only
  -- `with_check` is ever populated for INSERT. Checks 1/3 below read
  -- `with_check` for the two `_insert` policies (previously read `qual`,
  -- which is always NULL for them and silently rendered neither true nor
  -- false); `_delete` policies have only `qual` (no WITH CHECK exists for
  -- DELETE), which is what checks 1/3 correctly still read for those.
  (1, 'factoring_companies_insert no longer mentions dispatcher/accountant',
      (select with_check from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_insert') not ilike '%dispatcher%'
      and (select with_check from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_insert') not ilike '%accountant%'),
  (2, 'factoring_companies_update/_delete are also owner/admin only',
      (select qual from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_update') ilike '%owner%admin%'
      and (select qual from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_update') not ilike '%dispatcher%'
      and (select qual from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_delete') not ilike '%dispatcher%'),
  (3, 'factoring_relationships_insert/_delete no longer mention dispatcher/accountant',
      (select with_check from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_insert') not ilike '%dispatcher%'
      and (select with_check from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_insert') not ilike '%accountant%'
      and (select qual from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_delete') not ilike '%dispatcher%'),
  (4, 'factoring_relationships_update mentions accountant but NOT dispatcher',
      (select qual from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_update') ilike '%accountant%'
      and (select qual from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_update') not ilike '%dispatcher%'),
  (5, 'SELECT policies on both tables are UNCHANGED (still all FINANCIAL_ROLES, dispatcher included) -- view-only visibility preserved',
      (select qual from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_select') ilike '%dispatcher%'
      and (select qual from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_select') ilike '%dispatcher%'),

  -- ---- B. legacy submission: unconditional structured rejection (Phase 3B.1.5) ----
  (6, 'submit_invoice_to_factor(uuid,uuid) present after replace, now returning jsonb (not table(...))',
      to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is not null
      and (select data_type from information_schema.routines where routine_schema='public' and routine_name='submit_invoice_to_factor' limit 1) = 'jsonb'),
  (7, 'submit_invoice_to_factor is still callable by all four FINANCIAL_ROLES (dispatcher submission remains an explicitly authorized business policy, documented in migration 0075 -- authorization is independent of, and does not bypass, the snapshot-required rejection)',
      has_function_privilege('authenticated', 'public.submit_invoice_to_factor(uuid,uuid)', 'EXECUTE')),
  (8, 'the function source no longer references dispatches.carrier_id or loads.carrier_id as a submission gate (Phase 3B.1.5: live derivation must never authorize submission)',
      (select prosrc from pg_proc where proname = 'submit_invoice_to_factor' and pronamespace = 'public'::regnamespace) not ilike '%d.carrier_id%'
      and (select prosrc from pg_proc where proname = 'submit_invoice_to_factor' and pronamespace = 'public'::regnamespace) not ilike '%l.carrier_id%'),
  (9, 'the function source contains the CARRIER_INVOICE_SNAPSHOT_REQUIRED rejection code',
      (select prosrc from pg_proc where proname = 'submit_invoice_to_factor' and pronamespace = 'public'::regnamespace) ilike '%CARRIER_INVOICE_SNAPSHOT_REQUIRED%')

) as t(check_no, label, ok)
order by check_no;
