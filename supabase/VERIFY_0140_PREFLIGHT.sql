-- ============================================================================
-- 0140 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0140. Requires 0139 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0139 landmark: carrier_factoring_integrations present',
      to_regclass('public.carrier_factoring_integrations') is not null),
  (2, '0075 landmark: submit_invoice_to_factor(uuid,uuid) present',
      to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is not null),

  -- ---- confirms the gap this migration closes actually exists today ----
  -- Phase 3B.1.6: an INSERT policy has NO `qual` (USING) at all -- only
  -- `with_check` is ever populated for INSERT. Reading `qual` here (as an
  -- earlier version of this check did) compares against NULL and silently
  -- renders neither true nor false in the result set below -- fixed to
  -- read `with_check`, the column that actually holds this policy's rule.
  (3, 'factoring_companies_insert currently permits dispatcher/accountant (the gap 0140 closes)',
      (select with_check from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_insert') ilike '%dispatcher%'),
  (4, 'factoring_relationships_insert currently permits dispatcher/accountant (the gap 0140 closes)',
      (select with_check from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_insert') ilike '%dispatcher%'),

  -- ---- objects 0140 CREATES/REPLACES: no new table/index, so no
  -- "must be absent" guard is meaningful here beyond the function existing
  -- already (checked above) ----
  (5, 'factoring_companies / factoring_relationships have RLS enabled',
      (select relrowsecurity from pg_class where oid = 'public.factoring_companies'::regclass)
      and (select relrowsecurity from pg_class where oid = 'public.factoring_relationships'::regclass))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): existing factored_invoices count (untouched by
-- 0140 either way) and how many currently-eligible (sent/viewed, zero
-- paid) invoices exist. Phase 3B.1.5: after 0140 applies, submission is
-- rejected UNCONDITIONALLY for every invoice, regardless of whether it
-- has a dispatch_id/load_id -- no invoice in this schema carries a
-- database-issued carrier/financial snapshot, so this count is purely
-- informational (how many invoices would now get the structured
-- snapshot-required rejection if someone tried), never a partition of
-- "safe" vs "unsafe" rows.
select
  (select count(*) from public.factored_invoices) as total_factored_invoices,
  (select count(*) from public.invoices i where i.status in ('sent','viewed') and i.amount_paid = 0) as invoices_currently_status_eligible_for_submission_attempt;
