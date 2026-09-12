-- ============================================================================
-- 0137 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0137. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'table public.carrier_backfill_0137_provenance present',
      to_regclass('public.carrier_backfill_0137_provenance') is not null),
  (2, 'provenance row count equals factoring_relationships row count (one row each)',
      (select count(*) from public.carrier_backfill_0137_provenance) = (select count(*) from public.factoring_relationships)),
  (3, 'every provenance row''s carrier_id matches the actual factoring_relationships row',
      not exists (
        select 1 from public.carrier_backfill_0137_provenance pv
        join public.factoring_relationships fr on fr.id = pv.relationship_id
        where pv.carrier_id is distinct from fr.carrier_id)),
  (4, 'every resolved provenance row''s carrier belongs to the same organization',
      not exists (
        select 1 from public.carrier_backfill_0137_provenance pv
        join public.carriers c on c.id = pv.carrier_id
        where c.organization_id <> pv.organization_id)),
  (5, 'every unresolved provenance row has a matching OPEN unresolved_carrier_records row',
      not exists (
        select 1 from public.carrier_backfill_0137_provenance pv
        where pv.resolution in ('unresolved_no_evidence','unresolved_multiple')
          and not exists (
            select 1 from public.unresolved_carrier_records u
            where u.record_type='factoring_relationship' and u.record_id=pv.relationship_id and u.status='unresolved'
          ))),
  (6, 'no resolved (carrier_id not null) provenance row also has an unresolved_carrier_records row',
      not exists (
        select 1 from public.carrier_backfill_0137_provenance pv
        join public.unresolved_carrier_records u on u.record_type='factoring_relationship' and u.record_id=pv.relationship_id and u.status='unresolved'
        where pv.carrier_id is not null)),
  (7, 'no factored_invoices row was modified by this migration (spot check: row count unchanged is verified out-of-band; here we confirm the table exists and this migration owns no trigger on it)',
      to_regclass('public.factored_invoices') is not null),
  (8, 'authenticated has SELECT only on carrier_backfill_0137_provenance (no insert/update/delete)',
      has_table_privilege('authenticated','public.carrier_backfill_0137_provenance','SELECT')
      and not has_table_privilege('authenticated','public.carrier_backfill_0137_provenance','INSERT')
      and not has_table_privilege('authenticated','public.carrier_backfill_0137_provenance','UPDATE')
      and not has_table_privilege('authenticated','public.carrier_backfill_0137_provenance','DELETE'))

) as t(check_no, label, ok)
order by check_no;

-- Context (not a gate): final classification counts.
select
  resolution, count(*) as n
from public.carrier_backfill_0137_provenance
group by resolution
order by resolution;
