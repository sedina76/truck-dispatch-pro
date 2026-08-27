-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Invoice Eligibility + Duplicate-Invoice Repair.
--
-- DO NOT APPLY WITHOUT APPROVAL.
--
-- ROOT CAUSE (audited first, not assumed -- see repair report Section A/H):
-- public.invoices has a FK each to loads(id), brokers(id), and
-- customers(id), but invoices_insert's RLS policy (0010_rls_policies.sql,
-- the financial_tables loop) only checks
--   organization_id = public.current_org_id()
-- -- it never confirms load_id/broker_id/customer_id actually belong to
-- THAT SAME organization. This is the EXACT defect class already found and
-- fixed once before in this schema, for a different table:
-- 0030_statement_party_org_guard.sql's own header comment describes
-- discovering the identical gap on public.statements ("A user could insert
-- a statement row in their own org that references another organization's
-- real broker_id"), and invoices.assigned_collector_id already has its own
-- narrower guard for exactly this reason
-- (guard_invoice_collector_assignment(), 0027_collections.sql) -- but
-- nothing equivalent exists for invoices.load_id/broker_id/customer_id.
--
-- Concretely: src/app/(app)/invoices/actions.ts's createInvoice() (before
-- this repair) inserted whatever load_id/broker_id/customer_id the
-- submitted form contained, with no server-side check that those rows
-- belonged to the caller's organization. A forged direct call with another
-- organization's real load_id would have succeeded at the database level,
-- creating a cross-organization-linked invoice -- and because
-- invoices_load_id_unique_idx (0022_auto_invoice_on_delivery.sql) is a
-- single global unique index on load_id (correct, since a load already
-- belongs to exactly one organization), that bogus invoice would have
-- permanently occupied the real owning organization's load_id slot,
-- blocking their own legitimate invoice (manual or automatic) for that
-- load forever. This migration closes the write path; it does not touch
-- the unique index, which is already correct as-is.
--
-- Impact of NOT having this guard yet was contained in the same way 0030's
-- was: no real financial figures leak, because every legitimate read path
-- (RLS-scoped selects, the AR/collections RPCs) already re-derives its own
-- numbers and would return nothing for a cross-org id -- but the bad row
-- itself, and the load_id-slot-squatting it enables, should never have
-- been insertable at all.
--
-- REPAIR: guard_invoice_party_organization(), a BEFORE INSERT OR UPDATE
-- trigger on public.invoices, byte-for-byte mirroring
-- guard_statement_party_org()'s (0030) own structure -- same per-column
-- "look up the referenced row's own organization_id, reject if null or
-- different" pattern -- extended to cover load_id in addition to
-- broker_id/customer_id, since invoices (unlike statements) also carry a
-- load reference. dispatch_id is deliberately NOT covered: it is never a
-- form-submitted field on any invoice-creation path (createInvoice()'s own
-- invoiceValues() does not accept it), and it is only ever set by
-- auto_generate_invoice_from_delivered_load() (0022/0028) from the same
-- load's own dispatch, which is inherently same-organization by
-- construction.
--
-- This trigger cannot break the existing automatic-invoice trigger:
-- auto_generate_invoice_from_delivered_load() always inserts
-- organization_id = NEW.organization_id (the load's own org) alongside
-- load_id = NEW.id (that same load), so the two are always consistent by
-- construction and this guard never fires for it. It also cannot
-- retroactively affect any existing invoice row -- a BEFORE UPDATE trigger
-- only evaluates rows an UPDATE statement actually touches, so no
-- historical invoice is read, re-validated, or changed by applying this
-- migration.
--
-- REVISION -- follow-up integrity audit found a second, related gap this
-- function did not originally close: checking that broker_id/customer_id
-- belong to the invoice's own organization is not the same as checking
-- they are the CORRECT party for the invoice's own linked load. public.
-- loads.broker_id/customer_id are this schema's own authoritative
-- billing-party fields -- auto_generate_invoice_from_delivered_load()
-- (0022/0028) copies them onto the invoice verbatim, never substituting a
-- different same-org party -- but nothing enforced that same agreement for
-- a manually created or edited invoice. Concretely: src/app/(app)/
-- invoices/[id]/page.tsx's edit form renders fully independent Broker/
-- Customer selects with no cross-check against the invoice's own load_id,
-- so updateInvoice() could re-point a load-linked invoice at any other
-- same-organization broker/customer. Added below: when load_id is not
-- null, new.broker_id/new.customer_id must exactly match the linked
-- load's own broker_id/customer_id (IS NOT DISTINCT FROM semantics via
-- `is distinct from`, so both-null is correctly treated as a match). The
-- original organization-ownership checks are kept unconditionally, as
-- defense in depth, not replaced by this addition.
--
-- REVISION 2 -- Phase A1 (invoice edit corruption repair): a live,
-- separate defect was found and already fixed at the application layer
-- (src/app/(app)/invoices/actions.ts's updateInvoice()): invoiceValues()
-- always included load_id from the submitted form, but the edit page
-- never rendered that field at all, so it was always null and got written
-- verbatim on every single edit -- silently unlinking any load-linked
-- invoice from its load. Confirmed before adding this: no workflow
-- anywhere in this codebase legitimately changes an invoice's load_id
-- after creation (checked every write path into public.invoices). Added
-- below: an UPDATE that changes load_id at all -- to a different load, to
-- null, or from null to a load -- is rejected outright. This is a
-- database-level backstop for the same rule the application layer now
-- also enforces; either layer alone would already prevent the original
-- bug, but neither should be the only one. INSERT is completely
-- unaffected (OLD does not exist on insert, so the added check is
-- unconditionally gated on TG_OP = 'UPDATE') -- auto_generate_invoice_
-- from_delivered_load() and createInvoice() both only ever INSERT.
-- ---------------------------------------------------------------------------

create or replace function public.guard_invoice_party_organization()
returns trigger
language plpgsql
as $$
declare
  v_party_org uuid;
  v_load_broker_id uuid;
  v_load_customer_id uuid;
begin
  if tg_op = 'UPDATE' and new.load_id is distinct from old.load_id then
    raise exception 'An invoice''s linked load cannot be changed once set.';
  end if;

  if new.load_id is not null then
    select organization_id, broker_id, customer_id
      into v_party_org, v_load_broker_id, v_load_customer_id
      from public.loads where id = new.load_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Invoice load must belong to the same organization as the invoice.';
    end if;
    if new.broker_id is distinct from v_load_broker_id or new.customer_id is distinct from v_load_customer_id then
      raise exception 'Invoice broker/customer must match the linked load''s own broker/customer.';
    end if;
  end if;

  if new.broker_id is not null then
    select organization_id into v_party_org from public.brokers where id = new.broker_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Invoice broker must belong to the same organization as the invoice.';
    end if;
  end if;

  if new.customer_id is not null then
    select organization_id into v_party_org from public.customers where id = new.customer_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Invoice customer must belong to the same organization as the invoice.';
    end if;
  end if;

  return new;
end;
$$;

comment on function public.guard_invoice_party_organization() is
  'BEFORE INSERT OR UPDATE guard on public.invoices: load_id is immutable once set (an UPDATE may never change it, in either direction); load_id/broker_id/customer_id must each belong to the same organization_id as the invoice itself; and when load_id is set, broker_id/customer_id must exactly match that load''s own broker_id/customer_id (public.loads is the authoritative billing-party source -- see auto_generate_invoice_from_delivered_load(), 0022/0028). Mirrors guard_statement_party_org() (0030) for the organization-ownership half; dispatch_id is not covered because it is never client-submitted and is inherently same-organization when auto-set from a load.';

drop trigger if exists invoices_guard_party_org on public.invoices;
create trigger invoices_guard_party_org
  before insert or update on public.invoices
  for each row execute function public.guard_invoice_party_organization();
