-- ============================================================================
-- 0138 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0138. Requires 0137 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0137 landmark: public.carrier_backfill_0137_provenance present',
      to_regclass('public.carrier_backfill_0137_provenance') is not null),
  (2, '0071 landmark: factoring_relationships_one_default_per_org index still present (pre-cutover)',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_org')),
  (3, '0072 landmark: set_default_factoring_relationship(uuid) present',
      to_regprocedure('public.set_default_factoring_relationship(uuid)') is not null),

  -- ---- objects 0138 CREATES must be ABSENT (rerun guard) ----
  (4, 'classify_carrier_factoring_readiness(...) does NOT yet exist',
      to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null),
  (5, 'approve_factoring_relationship_noa(...) does NOT yet exist',
      to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)') is null),
  (6, 'factoring_relationships_one_default_per_carrier index does NOT yet exist',
      not exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier')),

  -- ---- structural sanity 0138's cutover index requires ----
  (7, 'NO active+default relationship has a null carrier_id',
      not exists (select 1 from public.factoring_relationships where is_default and is_active and carrier_id is null)),
  (8, 'NO carrier has more than one active+default relationship (would violate the new index immediately)',
      not exists (
        select 1 from public.factoring_relationships
        where is_default and is_active and carrier_id is not null
        group by carrier_id having count(*) > 1))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): every carrier with an active+default relationship
-- that would become subject to the new index, and its resolved carrier_id.
select carrier_id, count(*) as active_default_count
from public.factoring_relationships
where is_default and is_active
group by carrier_id
order by active_default_count desc;
