-- =============================================================================
-- legacy_conflict_queries.sql -- READ-ONLY queries behind LEGACY_CONFLICT_WORKSHEET.md (one query per conflict; run ONE AT A TIME).
-- PROPOSAL 0152 -- NOT RUN ANYWHERE. Owner authorization + the project-reference check in README.md are required. Each block between the "-- ==== Qnn" markers is ONE SELECT/WITH
-- statement that reads only (no DDL/DML, no function that writes, no locks beyond ordinary SELECT). Results contain business identifiers and MUST be handled as confidential; never
-- paste them into chat or commit them. PRE = valid on the current 0129-boundary production schema (predictive; loads.carrier_id does not exist yet). POST = valid only after the
-- named migration has been applied inside the maintenance window. These queries were syntax-checked on a disposable local database only (tests_production_package.py); they have
-- NOT been run against any schema containing the real tables and must be re-validated on a disposable copy of the migrated schema before the window.
-- =============================================================================

-- ==== Q01 PRE+POST  unresolved_carrier_records by type and status (POST only; table exists from 0130)
select record_type, status, count(*) as records, min(created_at) as oldest, max(created_at) as newest
from public.unresolved_carrier_records group by record_type, status order by record_type, status;

-- ==== Q02 PRE  factoring relationships: predicted 0137 outcome from dispatch evidence only (R1 single-carrier org / R2 provable / R3 no evidence / R4 multiple)
with occ as (select organization_id, count(*) as n_carriers from public.carriers group by organization_id),
ev as (
  select fr.id as relationship_id, count(fi.id) as factored_invoices,
         array_agg(distinct d.carrier_id) filter (where d.carrier_id is not null) as carrier_ids,
         count(fi.id) filter (where d.carrier_id is null) as invoices_without_dispatch_carrier
  from public.factoring_relationships fr
  left join public.factored_invoices fi on fi.factoring_relationship_id = fr.id
  left join public.invoices i on i.id = fi.invoice_id
  left join public.dispatches d on d.id = i.dispatch_id
  group by fr.id
)
select fr.organization_id, fr.id as relationship_id, fr.relationship_name, fr.is_default, fr.is_active, coalesce(occ.n_carriers, 0) as org_carriers, ev.factored_invoices,
       coalesce(array_length(ev.carrier_ids, 1), 0) as evidence_carriers, ev.invoices_without_dispatch_carrier,
       case when occ.n_carriers = 1 then 'R1_single_carrier_org'
            when array_length(ev.carrier_ids, 1) = 1 then 'R2_provable_from_dispatch_evidence'
            when coalesce(array_length(ev.carrier_ids, 1), 0) = 0 then 'R3_unresolved_no_evidence'
            else 'R4_unresolved_multiple' end as predicted_0137_resolution
from public.factoring_relationships fr
left join occ on occ.organization_id = fr.organization_id
join ev on ev.relationship_id = fr.id
order by predicted_0137_resolution, fr.organization_id, fr.id;

-- ==== Q03 PRE  relationships that 0137 would resolve on PARTIAL evidence (2+ carriers in the org, exactly one evidence carrier, but some factored invoices have no resolvable carrier) -- adversarial finding F-01
with occ as (select organization_id, count(*) as n_carriers from public.carriers group by organization_id)
select fr.organization_id, fr.id as relationship_id, fr.relationship_name, occ.n_carriers as org_carriers,
       count(fi.id) as factored_invoices, count(fi.id) filter (where d.carrier_id is null) as invoices_without_dispatch_carrier,
       array_agg(distinct d.carrier_id) filter (where d.carrier_id is not null) as the_single_evidence_carrier
from public.factoring_relationships fr
join occ on occ.organization_id = fr.organization_id and occ.n_carriers > 1
join public.factored_invoices fi on fi.factoring_relationship_id = fr.id
join public.invoices i on i.id = fi.invoice_id
left join public.dispatches d on d.id = i.dispatch_id
group by fr.organization_id, fr.id, fr.relationship_name, occ.n_carriers
having count(distinct d.carrier_id) filter (where d.carrier_id is not null) = 1 and count(fi.id) filter (where d.carrier_id is null) > 0
order by fr.organization_id, fr.id;

-- ==== Q04 POST(0137)  factored invoices whose invoice-derived carrier differs from the relationship's carrier (recipient-routing conflict)
select fi.organization_id, fi.id as factored_invoice_id, fi.invoice_id, fi.factoring_relationship_id, fr.carrier_id as relationship_carrier_id,
       coalesce(d.carrier_id, l.carrier_id) as invoice_carrier_id, fi.status
from public.factored_invoices fi
join public.factoring_relationships fr on fr.id = fi.factoring_relationship_id
join public.invoices i on i.id = fi.invoice_id
left join public.dispatches d on d.id = i.dispatch_id
left join public.loads l on l.id = i.load_id
where fr.carrier_id is not null and coalesce(d.carrier_id, l.carrier_id) is not null and coalesce(d.carrier_id, l.carrier_id) <> fr.carrier_id
order by fi.organization_id, fi.id;

-- ==== Q05 PRE  loads whose financial-controller dispatch carrier is contradicted by a live non-cancelled dispatch of another carrier (0133 C1 controller conflict = migration ABORT)
select l.organization_id, l.id as load_id, l.load_number, l.financial_dispatch_id, fdc.carrier_id as controller_carrier_id,
       array_agg(distinct d.carrier_id) filter (where d.status <> 'cancelled' and d.carrier_id <> fdc.carrier_id) as conflicting_live_carriers
from public.loads l
join public.dispatches fdc on fdc.id = l.financial_dispatch_id
join public.dispatches d on d.load_id = l.id
group by l.organization_id, l.id, l.load_number, l.financial_dispatch_id, fdc.carrier_id
having count(*) filter (where d.status <> 'cancelled' and d.carrier_id <> fdc.carrier_id) > 0
order by l.organization_id, l.load_number;

-- ==== Q06 PRE  loads with 2+ distinct carriers across NON-CANCELLED dispatches and no financial controller (0133 C4 -> carrier_resolution=unresolved)
select l.organization_id, l.id as load_id, l.load_number, l.financial_dispatch_id, count(distinct d.carrier_id) as distinct_carriers, array_agg(distinct d.carrier_id) as carrier_ids
from public.loads l
join public.dispatches d on d.load_id = l.id and d.status <> 'cancelled'
where l.financial_dispatch_id is null
group by l.organization_id, l.id, l.load_number, l.financial_dispatch_id
having count(distinct d.carrier_id) > 1
order by l.organization_id, l.load_number;

-- ==== Q07 PRE  loads with NO dispatch of any status (0133 C4_zero_dispatch; the pool 0150 reviews) -- counts per organization only
select l.organization_id, count(*) as zero_dispatch_loads, min(l.created_at) as oldest, max(l.created_at) as newest
from public.loads l where not exists (select 1 from public.dispatches d where d.load_id = l.id)
group by l.organization_id order by l.organization_id;

-- ==== Q08 PRE  invoices by predicted 0147 legacy classification inputs (recipient evidence, load link, status, payment state); counts only
select i.organization_id,
       case when i.status = 'void' then 'voided_cancelled'
            when i.status = 'paid' or (i.amount_paid > 0 and i.amount_paid < i.total_amount) then 'paid_or_partially_paid'
            when exists (select 1 from public.factored_invoices fi where fi.invoice_id = i.id) then 'existing_factoring_activity'
            when i.broker_id is not null and i.customer_id is not null then 'conflicting_recipient_evidence'
            when i.broker_id is null and i.customer_id is null then 'missing_recipient'
            when i.load_id is null then 'missing_carrier_evidence'
            else 'has_load_link (carrier evidence decided after 0132/0133)' end as predicted_class,
       count(*) as invoices, sum(i.total_amount) as total_amount
from public.invoices i group by 1, 2 order by 1, 2;

-- ==== Q09 POST(0147)  authoritative legacy-invoice classification (the installed classifier; owner-only function, run as the SQL Editor operator); counts only
select public.classify_legacy_invoice_for_carrier_migration(i.id) as classification, count(*) as invoices, sum(i.total_amount) as total_amount
from public.invoices i group by 1 order by 1;

-- ==== Q10 PRE  payments recorded against invoices with a recipient conflict, no load link, or no carrier evidence (financial-history rows the migration must not reassign)
select p.organization_id, p.id as payment_id, p.invoice_id, p.amount, p.received_at, i.status as invoice_status, i.broker_id is not null as has_broker, i.customer_id is not null as has_customer,
       i.load_id is not null as has_load, (select count(*) from public.dispatches d where d.load_id = i.load_id) as dispatches_on_load
from public.payments p join public.invoices i on i.id = p.invoice_id
where i.load_id is null or (i.broker_id is not null and i.customer_id is not null) or (i.broker_id is null and i.customer_id is null)
   or not exists (select 1 from public.dispatches d where d.load_id = i.load_id)
order by p.organization_id, p.received_at;

-- ==== Q11 POST(0136)  carriers still factoring_mode = 'unconfigured' that have factoring history (an owner/admin must set the policy before invoicing)
select c.organization_id, c.id as carrier_id, c.factoring_mode,
       (select count(*) from public.factoring_relationships fr where fr.carrier_id = c.id) as relationships,
       (select count(*) from public.factored_invoices fi join public.factoring_relationships fr on fr.id = fi.factoring_relationship_id where fr.carrier_id = c.id) as factored_invoices
from public.carriers c
where c.factoring_mode = 'unconfigured'
  and exists (select 1 from public.factoring_relationships fr where fr.carrier_id = c.id)
order by c.organization_id, c.id;

-- ==== Q12 POST(0137)  active defaults that would break 0138's per-carrier unique index or have no carrier
select fr.organization_id, fr.carrier_id, count(*) as active_defaults, array_agg(fr.id) as relationship_ids
from public.factoring_relationships fr where fr.is_default and fr.is_active group by fr.organization_id, fr.carrier_id
having fr.carrier_id is null or count(*) > 1
order by fr.organization_id;

-- ==== Q13 POST(0137)  unresolved relationships that are inactive-vs-active, default, or referenced by factored invoices (what a human must decide first)
select p.resolution, fr.organization_id, fr.id as relationship_id, fr.is_active, fr.is_default, p.evidence_carrier_ids,
       (select count(*) from public.factored_invoices fi where fi.factoring_relationship_id = fr.id) as factored_invoices
from public.carrier_backfill_0137_provenance p join public.factoring_relationships fr on fr.id = p.relationship_id
where p.resolution in ('unresolved_no_evidence', 'unresolved_multiple')
order by p.resolution, fr.organization_id, fr.id;

-- ==== Q14 POST(0133)  loads with carrier_resolution = 'unresolved' AND at least one dispatch (0150 never touches these; each needs a human carrier decision)
select l.organization_id, l.id as load_id, l.load_number, l.status, count(d.id) as dispatches, array_agg(distinct d.carrier_id) filter (where d.carrier_id is not null) as dispatch_carriers
from public.loads l join public.dispatches d on d.load_id = l.id
where l.carrier_resolution = 'unresolved'
group by l.organization_id, l.id, l.load_number, l.status order by l.organization_id, l.load_number;

-- ==== Q15 POST(0133)  legacy-record types with open exception rows that no migration in 0130-0147 produces (payment/document/trailer/factored_invoice/dispatch_fee_candidate/other): expected EMPTY
select record_type, count(*) as open_records from public.unresolved_carrier_records
where status = 'unresolved' and record_type in ('payment', 'document', 'trailer', 'factored_invoice', 'dispatch_fee_candidate', 'other') group by record_type order by record_type;

-- ==== Q16 PRE  zero-dispatch loads that a shared profile (profile_share_log) already ties to a carrier or a recipient: 0150's evidence list does NOT include this table (finding F-10); any row here must be reviewed before the 0150 approval
select l.organization_id, l.id as load_id, l.load_number, count(p.id) as profile_shares, array_agg(distinct p.carrier_id) filter (where p.carrier_id is not null) as carriers_named
from public.loads l join public.profile_share_log p on p.load_id = l.id
where not exists (select 1 from public.dispatches d where d.load_id = l.id)
group by l.organization_id, l.id, l.load_number order by l.organization_id, l.load_number;
