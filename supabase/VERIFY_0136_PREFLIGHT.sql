-- ============================================================================
-- 0136 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0136. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0071 landmark: public.factoring_relationships present',
      to_regclass('public.factoring_relationships') is not null),
  (2, '0130 landmark: public.unresolved_carrier_records present',
      to_regclass('public.unresolved_carrier_records') is not null),
  (3, '0008 landmark: public.integration_settings present',
      to_regclass('public.integration_settings') is not null),

  -- ---- objects 0136 CREATES must be ABSENT (rerun guard) ----
  (4, 'carriers.factoring_mode does NOT yet exist',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='factoring_mode')),
  (5, 'factoring_relationships.carrier_id does NOT yet exist',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id')),
  (6, 'type public.carrier_factoring_mode does NOT yet exist',
      to_regtype('public.carrier_factoring_mode') is null),
  (7, 'type public.factoring_submission_method does NOT yet exist',
      to_regtype('public.factoring_submission_method') is null)

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): current factoring_relationships row count and how
-- many organizations/carriers already exist -- informs the 0137 backfill.
select
  (select count(*) from public.factoring_relationships) as existing_relationship_count,
  (select count(*) from public.factoring_companies) as existing_company_count,
  (select count(distinct organization_id) from public.carriers) as orgs_with_carriers,
  (select count(*) from public.carriers) as total_carriers;
