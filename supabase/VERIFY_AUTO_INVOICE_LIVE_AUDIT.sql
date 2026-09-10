-- Phase A2 -- Auto-Invoice Retirement Preparation. Entirely read-only.
-- Verified exact live names from the migration source before writing this
-- (0022_auto_invoice_on_delivery.sql creates them; 0028/0044/0049/0068
-- each redefine the FUNCTION body via `create or replace`, never renaming
-- either object):
--   trigger:  auto_generate_invoice_on_delivery   (on public.loads)
--   function: auto_generate_invoice_from_delivered_load()
-- No migration is authored or applied here -- this is audit input only.

-- 1. Trigger existence and enabled state.
select tgname, tgrelid::regclass as table_name, tgenabled, tgtype
from pg_trigger
where tgname = 'auto_generate_invoice_on_delivery';
-- tgenabled: 'O' = enabled (normal), 'D' = disabled, 'R'/'A' = replica/always only.

-- 2. Full live function definition -- confirms exactly what is deployed
-- right now, not just what the migration source says should be (the two
-- could differ if a hotfix or manual change was ever applied out of band).
select pg_get_functiondef(oid) as live_definition
from pg_proc
where proname = 'auto_generate_invoice_from_delivered_load' and pronamespace = 'public'::regnamespace;

-- 3. Draft invoices apparently auto-created on delivery.
-- Distinguishing marker (Section 14 -- how reliable this actually is):
-- the function hardcodes notes = 'Auto-generated on delivery for load ' ||
-- load_number verbatim, in the SAME field a manually-created invoice
-- (createInvoice()) instead populates from whatever free text a staff
-- member typed into the Notes textarea. A manual invoice matching this
-- exact string is not IMPOSSIBLE (someone could type it by hand), only
-- extremely implausible -- this is strong circumstantial evidence, not a
-- durable, first-class "created_by system" marker, because none exists in
-- the schema (see closing note).
select id, invoice_number, load_id, organization_id, status, total_amount, broker_id, customer_id, created_at
from public.invoices
where notes ilike 'Auto-generated on delivery for load %'
order by created_at desc;

-- 4. Delivered (or later) loads with no invoice at all -- the auto-invoice
-- trigger's own "no broker/customer on file" early-return case (or a
-- since-voided/deleted invoice -- invoices are never hard-deleted in this
-- schema, so this should only ever mean "never invoiced").
select l.id as load_id, l.organization_id, l.load_number, l.status, l.broker_id, l.customer_id
from public.loads l
where l.status in ('delivered', 'pod_received', 'invoiced', 'closed')
  and not exists (select 1 from public.invoices i where i.load_id = l.id);

-- 5. $0.00 auto-created invoices -- the exact risk this audit's Section 3
-- (auto_generate_invoice_from_delivered_load()'s rate/load_financials
-- handling) identified: coalesce(v_rate, 0) silently produces a $0 draft
-- invoice for a load with a zero or missing load_financials.rate, with no
-- warning raised anywhere.
select id, invoice_number, load_id, organization_id, created_at
from public.invoices
where notes ilike 'Auto-generated on delivery for load %' and total_amount = 0;

-- 6. Auto-created invoices with a missing party. Per the live function
-- body (query 2), this combination should be STRUCTURALLY IMPOSSIBLE: the
-- function returns early (creates nothing at all) when NEW.broker_id AND
-- NEW.customer_id are both null. This query exists to confirm that
-- reading is actually correct against live data, not to find an expected
-- population of rows.
select id, invoice_number, load_id, organization_id
from public.invoices
where notes ilike 'Auto-generated on delivery for load %' and broker_id is null and customer_id is null;
-- expect: 0 rows. Any row here means either the live function differs from
-- what query 2 shows (a hotfix applied out of band), or the load's own
-- broker_id/customer_id was cleared AFTER the invoice was created (which
-- would itself be worth investigating separately, since 0112 -- once
-- applied -- makes that specific combination impossible going forward for
-- a load-linked invoice's own broker_id/customer_id to diverge from its
-- load).

-- ---------------------------------------------------------------------------
-- Section 14 answer, stated plainly: there is NO durable, first-class
-- marker anywhere in this schema that distinguishes an auto-created
-- invoice from a manually-created one. invoices has no created_by column,
-- no source/origin column, and no dedicated activity_logs action distinct
-- from the manual path (both call log_activity('invoice', id, 'created',
-- ...)). Query 3's notes-text heuristic is the best available signal and
-- is reported as circumstantial, not proof -- do not treat its result
-- count as an exact, guaranteed count of auto-created invoices, and do not
-- build the retirement migration's safety argument on it being perfectly
-- precise.
-- ---------------------------------------------------------------------------
