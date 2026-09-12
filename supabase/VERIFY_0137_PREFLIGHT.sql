-- ============================================================================
-- 0137 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0137_deterministic_factoring_carrier_backfill.sql.
-- Requires 0136 live. Every row of the matrix must show ok = true.
--
-- Never guesses: the bottom section PREVIEWS the exact deterministic plan
-- (which relationship resolves via which rule, and which stay unresolved)
-- so you can review it before applying -- 0137 will NOT abort on ambiguity
-- (an ambiguous relationship is recorded unresolved, not guessed), but it
-- WILL abort on a genuine structural conflict (see check 6 below).
-- ============================================================================
select * from ( values

  (1, '0136 landmark: factoring_relationships.carrier_id present',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id')),
  (2, '0130 landmark: public.unresolved_carrier_records present',
      to_regclass('public.unresolved_carrier_records') is not null),
  (3, '0130 landmark: public.record_unresolved_carrier_record(...) present',
      to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)') is not null),

  -- ---- rerun guard ----
  (4, 'factoring_relationships.carrier_id is entirely NULL (0137 not yet applied)',
      (select count(*) from public.factoring_relationships where carrier_id is not null) = 0),
  (5, 'table public.carrier_backfill_0137_provenance does NOT yet exist',
      to_regclass('public.carrier_backfill_0137_provenance') is null),

  -- ---- structural sanity (0137 aborts on these; confirm clean now) ----
  (6, 'NO single factored_invoice resolves to different carriers via its dispatch vs. its load',
      not exists (
        select 1
        from public.factored_invoices fi
        join public.invoices i on i.id = fi.invoice_id
        left join public.dispatches d on d.id = i.dispatch_id
        left join public.loads l on l.id = i.load_id
        where d.carrier_id is not null and l.carrier_id is not null and d.carrier_id <> l.carrier_id)),
  (7, 'NO organization has more than one active+default factoring_relationships row (0071''s own invariant)',
      not exists (
        select 1 from public.factoring_relationships
        where is_default and is_active
        group by organization_id having count(*) > 1))

) as t(check_no, label, ok)
order by check_no;

-- ---- PREVIEW of the exact resolution plan 0137 will apply ----------------
with org_carrier_counts as (
  select organization_id, count(*) as n_carriers from public.carriers group by organization_id
),
invoice_evidence as (
  select
    fr.id as relationship_id,
    d.carrier_id as dispatch_carrier_id,
    l.carrier_id as load_carrier_id,
    coalesce(d.carrier_id, l.carrier_id) as resolved_invoice_carrier_id
  from public.factoring_relationships fr
  join public.factored_invoices fi on fi.factoring_relationship_id = fr.id
  join public.invoices i on i.id = fi.invoice_id
  left join public.dispatches d on d.id = i.dispatch_id
  left join public.loads l on l.id = i.load_id
)
select
  fr.id as relationship_id,
  fr.organization_id,
  fr.relationship_name,
  coalesce(occ.n_carriers, 0) as org_carrier_count,
  coalesce(array_agg(distinct ie.resolved_invoice_carrier_id) filter (where ie.resolved_invoice_carrier_id is not null), '{}'::uuid[]) as evidence_carrier_ids,
  case
    when coalesce(occ.n_carriers, 0) = 1 then 'single_carrier_org'
    when array_length(array_agg(distinct ie.resolved_invoice_carrier_id) filter (where ie.resolved_invoice_carrier_id is not null), 1) = 1 then 'multi_carrier_org_provable'
    when coalesce(array_length(array_agg(distinct ie.resolved_invoice_carrier_id) filter (where ie.resolved_invoice_carrier_id is not null), 1), 0) = 0 then 'unresolved_no_evidence'
    else 'unresolved_multiple'
  end as predicted_resolution,
  fr.effective_to is not null and fr.effective_to < current_date as is_expired,
  fr.is_active, fr.is_default
from public.factoring_relationships fr
left join org_carrier_counts occ on occ.organization_id = fr.organization_id
left join invoice_evidence ie on ie.relationship_id = fr.id
group by fr.id, fr.organization_id, fr.relationship_name, occ.n_carriers, fr.effective_to, fr.is_active, fr.is_default
order by predicted_resolution, fr.organization_id;
