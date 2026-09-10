-- Run AFTER applying 0112_invoice_party_organization_guard.sql. Read-only.

-- 1. Trigger and function now exist, attached to public.invoices.
select tgname, tgrelid::regclass as table_name, tgenabled from pg_trigger where tgname = 'invoices_guard_party_org';
-- expect: 1 row, table_name = invoices, tgenabled = 'O' (enabled)

select pg_get_functiondef(oid) like '%new.load_id is not null%'
  and pg_get_functiondef(oid) like '%new.broker_id is not null%'
  and pg_get_functiondef(oid) like '%new.customer_id is not null%'
  and pg_get_functiondef(oid) like '%is distinct from v_load_broker_id%'
  and pg_get_functiondef(oid) like '%tg_op = ''UPDATE'' and new.load_id is distinct from old.load_id%' as covers_org_party_match_and_load_id_immutability
from pg_proc where proname = 'guard_invoice_party_organization' and pronamespace = 'public'::regnamespace;
-- expect: true (confirms the organization-ownership check, the
-- load-party-agreement check, AND the Phase A1 load_id-immutability check
-- are all live)

-- 2. Historical invoices remain untouched -- same three checks as
--    PREFLIGHT query 2, expected to return the identical result (a BEFORE
--    trigger cannot have changed any existing row).
select i.id as invoice_id, i.organization_id as invoice_org, l.organization_id as load_org
from public.invoices i
join public.loads l on l.id = i.load_id
where i.load_id is not null and l.organization_id <> i.organization_id;

select i.id as invoice_id, i.organization_id as invoice_org, b.organization_id as broker_org
from public.invoices i
join public.brokers b on b.id = i.broker_id
where i.broker_id is not null and b.organization_id <> i.organization_id;

select i.id as invoice_id, i.organization_id as invoice_org, c.organization_id as customer_org
from public.invoices i
join public.customers c on c.id = i.customer_id
where i.customer_id is not null and c.organization_id <> i.organization_id;
-- expect: identical to the PREFLIGHT capture. Neither confirms nor denies
-- 0112 was safe to apply -- these rows (if any) are pre-existing data
-- 0112 cannot retroactively touch; it only guarantees no NEW one can be
-- created or edited into existence from this point forward.

-- 3. Sanity: the automatic on-delivery invoice trigger still fires
--    normally (this guard must never block it, since it always inserts
--    load_id/organization_id from the same load). Confirm the trigger is
--    still present and enabled -- does not fabricate a live delivery event.
select tgname, tgenabled from pg_trigger where tgname = 'auto_generate_invoice_on_delivery';
-- expect: 1 row, tgenabled = 'O'

-- 4. Same load-party-agreement check as PREFLIGHT query 4 -- expected
--    identical (0 rows if PREFLIGHT was 0 rows; unchanged either way,
--    since this trigger cannot retroactively touch existing rows). Does
--    not confirm or deny 0112's safety to apply -- see PREFLIGHT query 4's
--    own comment for why.
select i.id as invoice_id, i.organization_id, i.load_id, i.broker_id as invoice_broker_id, l.broker_id as load_broker_id,
  i.customer_id as invoice_customer_id, l.customer_id as load_customer_id
from public.invoices i
join public.loads l on l.id = i.load_id and l.organization_id = i.organization_id
where i.load_id is not null
  and (i.broker_id is distinct from l.broker_id or i.customer_id is distinct from l.customer_id);

-- 5. Same Phase A1 historical-REVIEW check as PREFLIGHT query 5 --
--    SUSPECTED HISTORICAL UNLINKING REQUIRING REVIEW, still only
--    circumstantial, expected identical to that capture (this trigger
--    cannot retroactively repair an invoice already stripped of its
--    load_id by the pre-repair APPLICATION bug -- a separate, already-
--    fixed issue from what 0112 itself addresses; it only prevents new
--    occurrences of the underlying pattern going forward). If this query
--    returns any row: STOP for manual review before proceeding further;
--    report the exact identifiers, do not auto-correct.
select i.id as invoice_id, i.organization_id, i.invoice_number, i.load_id, li.description
from public.invoices i
join public.invoice_line_items li on li.invoice_id = i.id
where i.load_id is null and li.description ilike 'Freight charges -- Load %';
