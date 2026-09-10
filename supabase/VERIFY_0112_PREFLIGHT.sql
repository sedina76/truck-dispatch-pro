-- Run BEFORE applying 0112_invoice_party_organization_guard.sql. Read-only.

-- 1. Confirm the trigger/function do not already exist (this is a genuinely
--    new object, not a re-apply).
select count(*) as existing_trigger_count from pg_trigger where tgname = 'invoices_guard_party_org';
select count(*) as existing_function_count from pg_proc where proname = 'guard_invoice_party_organization' and pronamespace = 'public'::regnamespace;
-- expect: 0, 0

-- 2. Historical data check: does any EXISTING invoice already reference a
--    load/broker/customer in a different organization? A BEFORE
--    INSERT/UPDATE trigger cannot retroactively fix these, only prevent
--    new ones -- if any exist, they are a separate, pre-existing data
--    problem to report, not something 0112 touches.
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
-- Does NOT block applying 0112: this trigger only governs future
-- INSERT/UPDATE statements, so it is safe to apply regardless of what
-- these three queries return. A row here means a pre-existing,
-- already-committed cross-organization link exists in production TODAY,
-- with or without 0112 -- 0112 stops it from ever happening again, it
-- does not (and structurally cannot) fix a row that already exists.
-- Report any row found for a separate, manual, evidence-based
-- data-correction decision -- never auto-fix cross-organization data.

-- 3. Confirm the pre-existing duplicate-invoice protection this repair
--    relies on (and does not change) is actually live.
select indexname, indexdef from pg_indexes where indexname = 'invoices_load_id_unique_idx';
-- expect: 1 row, definition matches "UNIQUE INDEX ... ON invoices (load_id) WHERE load_id IS NOT NULL"

-- 4. Follow-up party-integrity audit, Section 6: does any EXISTING
--    load-linked invoice already disagree with its own load's
--    broker_id/customer_id while still belonging to the same
--    organization? (Same-organization is a given here since query 2 above
--    already checked for the cross-organization case -- this isolates the
--    narrower "right org, wrong party" case the follow-up audit raised.)
--    Most likely source if any appear: invoices/[id]/page.tsx's edit form,
--    which lets broker_id/customer_id be changed independently of load_id
--    with no existing cross-check (this is exactly why guard_invoice_
--    party_organization() is being extended, not why it was fine before).
select i.id as invoice_id, i.organization_id, i.load_id, i.broker_id as invoice_broker_id, l.broker_id as load_broker_id,
  i.customer_id as invoice_customer_id, l.customer_id as load_customer_id
from public.invoices i
join public.loads l on l.id = i.load_id and l.organization_id = i.organization_id
where i.load_id is not null
  and (i.broker_id is distinct from l.broker_id or i.customer_id is distinct from l.customer_id);
-- Does NOT block applying 0112, same reasoning as query 2: a party
-- mismatch already committed today is a pre-existing data fact 0112
-- cannot retroactively touch (BEFORE triggers only evaluate rows an
-- INSERT/UPDATE statement actually writes). Applying 0112 guarantees no
-- NEW mismatch can ever be created or edited into existence -- it does
-- not, and cannot, repair one that already exists. Report any row found
-- for a separate, manual, evidence-based decision.

-- 5. Phase A1 historical-review check -- SUSPECTED HISTORICAL UNLINKING
--    REQUIRING REVIEW, not proof of anything. updateInvoice()'s pre-repair
--    bug unconditionally nulled load_id on every single invoice edit; this
--    query looks for a specific, plausible FOOTPRINT of that bug having
--    already fired on a real invoice -- an invoice with load_id IS NULL
--    whose own line-item description still reads "Freight charges -- Load
--    <number>" (the exact, fixed text createInvoice() writes ONLY for a
--    load-linked invoice's auto-generated first line item). This is
--    CIRCUMSTANTIAL, not definitive: the same description text could in
--    principle have been typed manually via addInvoiceLineItem() on a
--    genuinely manual invoice, or the line item could have been edited
--    since. Do not treat a match as confirmed proof, and do not attempt
--    any automatic repair -- there is no reliable way to reconstruct which
--    load a stripped invoice used to point at from this data alone.
--
--    Does NOT block applying 0112 either: this is a symptom of the
--    APPLICATION-layer bug (already fixed this session, independent of
--    0112), not something 0112 was ever able to prevent or cause -- 0112
--    only adds the DATABASE-level backstop for the same already-fixed
--    application bug, going forward.
--
--    If this query returns any row: STOP here for manual review before
--    proceeding with anything else in this file. Report the exact
--    invoice_id/invoice_number/organization_id values listed and do not
--    take any corrective action on them without separate, explicit
--    authorization.
--    UPDATE (post-review): several rows this query previously surfaced
--    have since been individually reviewed and classified by business
--    decision, not by this query -- the classification column below
--    labels them explicitly rather than filtering them out. A row's
--    presence in this result set is never silently resolved by editing
--    this query; only a human classification decision, recorded here by
--    exact id, does that. Any row NOT matching one of the named ids below
--    is, by definition, still unresolved and still requires the same
--    "STOP and report" treatment as before.
select i.id as invoice_id, i.organization_id, i.invoice_number, i.load_id, li.description,
  case i.id
    when 'bd083e64-0ab7-4736-bb76-862a51cdca49'::uuid then 'CONFIRMED PRODUCTION REPAIR TARGET A -- INV-000022/LD-100022 -- see REPAIR_INV000022_LOAD_LINK_AND_STATUS.sql (not yet applied)'
    when '34a322dd-ebac-4aa7-8923-d7e0c192bf29'::uuid then 'CONFIRMED PRODUCTION REPAIR TARGET B -- INV-2026-00010, duplicate of INV-2026-00018 for LD-10027 -- void via the normal payment/invoice void workflow, PAY-000034 first'
    else 'UNCLASSIFIED -- STOP and report identifiers; do not auto-correct'
  end as classification
from public.invoices i
join public.invoice_line_items li on li.invoice_id = i.id
where i.load_id is null and li.description ilike 'Freight charges -- Load %'
union
-- Test/demo rows explicitly reviewed and excluded from repair, listed by
-- exact id so their presence here is a recorded decision, not an
-- assumption -- included via UNION so this file still shows the complete
-- picture in one place rather than requiring a second query to remember
-- why they were never in the "unclassified" bucket. These may not
-- individually match the WHERE clause above (e.g. INV-000024's load is
-- missing, not merely unlinked) -- listed explicitly regardless, so
-- nothing already reviewed can be mistaken for newly unresolved.
select i.id, i.organization_id, i.invoice_number, i.load_id, null::text,
  case i.invoice_number
    when 'INV-000021' then 'TEST/DEMO -- reviewed, leave unchanged (LD-10011 test load)'
    when 'INV-000027' then 'TEST/DEMO -- reviewed, leave unchanged (LD-10011 test load)'
    when 'INV-000001' then 'TEST FIXTURE -- reviewed, leave unchanged'
    when 'INV-000002' then 'TEST FIXTURE -- reviewed, leave unchanged'
    when 'INV-000003' then 'TEST FIXTURE -- reviewed, leave unchanged'
    when 'INV-000024' then 'UNRESOLVED, DEFERRED -- references a missing load; leave unchanged for later review (not part of this repair)'
  end
from public.invoices i
where i.invoice_number in ('INV-000021', 'INV-000027', 'INV-000001', 'INV-000002', 'INV-000003', 'INV-000024');
-- A database with none of the above rows returns only genuinely new,
-- unclassified findings (if any). Anything labeled UNCLASSIFIED must still
-- STOP for manual review and be reported by exact identifier -- this
-- update only ever ADDS labels for rows a human has already reviewed, it
-- never suppresses a row or widens what counts as "resolved."
