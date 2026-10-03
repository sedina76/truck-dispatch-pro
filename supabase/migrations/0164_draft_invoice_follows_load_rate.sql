-- ============================================================================
-- 0164_draft_invoice_follows_load_rate.sql
--
-- A load's invoice copies the rate when it is created (auto-invoice on
-- delivery, or New Invoice). Correcting the load's rate afterwards left the
-- invoice on the old amount -- e.g. LD-100038: rate fixed to 7500.00, its
-- invoice still 7499.31. The load page already tells users that a SENT
-- invoice is not updated by a rate change, implying a DRAFT is -- but nothing
-- did that.
--
-- Now: when load_financials.rate changes, the load's invoice follows ONLY if
--   * the invoice is still a draft (never sent, so the customer has not seen
--     an amount), and
--   * it has exactly one freight line ('Freight charges -- Load ...',
--     quantity 1) still at the OLD rate (i.e. nobody adjusted it by hand).
-- invoice_line_items_recalculate (0009) then updates subtotal/total.
-- Sent / paid / void invoices, and hand-edited drafts, are never touched.
--
-- No blanket catch-up of drafts that are already out of step: an old rate
-- cannot be told apart from a deliberate hand edit, so existing drafts are
-- corrected one by one (see maintenance/FIX_LD100038_DRAFT_INVOICE.sql).
--
-- SECURITY DEFINER trigger: the caller already passed load_financials RLS
-- to change the rate; the trigger only touches that load's own draft
-- invoice. One transaction; safe to re-run.
-- ============================================================================

begin;

create or replace function public.sync_draft_invoice_freight_from_rate()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if new.rate is distinct from old.rate then
    update public.invoice_line_items li
       set unit_price = new.rate
      from public.invoices i
     where i.load_id = new.load_id
       and i.organization_id = new.organization_id
       and i.status = 'draft'
       and li.invoice_id = i.id
       and li.description like 'Freight charges -- Load %'
       and li.quantity = 1
       and li.unit_price = old.rate
       and (select count(*) from public.invoice_line_items x
             where x.invoice_id = i.id and x.description like 'Freight charges -- Load %') = 1;
  end if;
  return new;
end;
$$;

comment on function public.sync_draft_invoice_freight_from_rate() is
  '0164: when a load rate changes, its DRAFT invoice''s single untouched freight line follows. Sent/paid/void or hand-edited invoices are never changed.';

revoke all on function public.sync_draft_invoice_freight_from_rate() from public, anon, authenticated, service_role;

drop trigger if exists load_financials_sync_draft_invoice on public.load_financials;
create trigger load_financials_sync_draft_invoice
  after update of rate on public.load_financials
  for each row execute function public.sync_draft_invoice_freight_from_rate();

do $post$
begin
  if not exists (select 1 from pg_trigger where tgname = 'load_financials_sync_draft_invoice' and tgrelid = 'public.load_financials'::regclass) then
    raise exception '0164 postcondition: trigger missing.';
  end if;
  if has_function_privilege('authenticated', 'public.sync_draft_invoice_freight_from_rate()'::regprocedure, 'execute') then
    raise exception '0164 postcondition: trigger function is client-callable.';
  end if;
end $post$;

commit;
