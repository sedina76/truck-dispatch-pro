-- ============================================================================
-- 0139 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0139. Requires 0138 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0138 landmark: factoring_relationships_one_default_per_carrier index present',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier')),
  (2, '0138 landmark: classify_carrier_factoring_readiness(...) present',
      to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null),
  (3, '0136 landmark: carriers.factoring_mode is three-state (unconfigured/direct/factored)',
      (select array_agg(enumlabel::text order by enumsortorder) from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='carrier_factoring_mode')
      = array['unconfigured','direct','factored']::text[]),

  -- ---- objects 0139 CREATES must be ABSENT (rerun guard) ----
  (4, 'carrier_factoring_integrations does NOT yet exist',
      to_regclass('public.carrier_factoring_integrations') is null),
  (5, 'set_carrier_factoring_policy(...) does NOT yet exist',
      to_regprocedure('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)') is null),
  (6, 'factoring_policy_idempotency does NOT yet exist',
      to_regclass('public.factoring_policy_idempotency') is null),
  (7, 'factoring_relationships_new_writes_need_carrier constraint does NOT yet exist',
      not exists (select 1 from pg_constraint where conname='factoring_relationships_new_writes_need_carrier')),
  (8, 'carrier_brokers/carrier_customers direct-billing-exception columns do NOT yet exist',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name in ('carrier_brokers','carrier_customers') and column_name='factoring_ineligible_direct_billing_approved')),

  -- ---- the exact privilege gaps 0139 fixes must currently be present (so
  -- this preflight also proves the fix will actually change something) ----
  (9, 'unresolved_carrier_records currently grants INSERT or DELETE to authenticated (gap to be closed)',
      has_table_privilege('authenticated','public.unresolved_carrier_records','INSERT')
      or has_table_privilege('authenticated','public.unresolved_carrier_records','DELETE')),
  (10, 'financial_idempotency_keys currently grants INSERT/UPDATE/DELETE to authenticated (gap to be closed)',
      has_table_privilege('authenticated','public.financial_idempotency_keys','INSERT')
      or has_table_privilege('authenticated','public.financial_idempotency_keys','UPDATE')
      or has_table_privilege('authenticated','public.financial_idempotency_keys','DELETE')),
  (11, 'carrier_backfill_0133_provenance currently grants INSERT/UPDATE/DELETE to authenticated (gap to be closed)',
      has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','INSERT')
      or has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','UPDATE')
      or has_table_privilege('authenticated','public.carrier_backfill_0133_provenance','DELETE')),

  -- ---- structural sanity the NOT VALID constraint needs to be safe to add ----
  (12, 'no CURRENTLY active+default relationship has a null carrier_id (would already violate 0138''s own index -- defensive re-check)',
      not exists (select 1 from public.factoring_relationships where is_default and is_active and carrier_id is null))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): how many null-carrier factoring_relationships rows
-- exist today (these are the rows 0139's NOT VALID constraint grandfathers
-- -- they will become immutable-until-resolved once 0139 applies).
select count(*) as null_carrier_relationship_count
from public.factoring_relationships
where carrier_id is null;
