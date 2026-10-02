-- FIX_LD100038_DRAFT_INVOICE.sql -- ONE-TIME test-data correction (owner-approved).
-- LD-100038's rate was corrected to 7500.00; its invoice still has the freight
-- line at the mistaken 7499.31. Aligns that one line, ONLY if the invoice is
-- still exactly in the reviewed state (draft or sent-but-unpaid, one freight
-- line at 7499.31, load rate 7500.00). Otherwise nothing changes.
begin;
do $$
declare v_inv uuid; v_status text; v_paid numeric; v_n int;
begin
  select i.id, i.status::text, i.amount_paid into v_inv, v_status, v_paid
  from public.invoices i join public.loads l on l.id = i.load_id
  where l.load_number = 'LD-100038';
  if v_inv is null then raise exception 'FIX: LD-100038 has no invoice. STOP -- nothing changed.'; end if;
  if v_status not in ('draft', 'sent') or v_paid <> 0 then
    raise exception 'FIX: invoice is % with % paid -- not changed automatically. STOP -- nothing changed.', v_status, v_paid;
  end if;
  if (select rate from public.load_financials lf join public.loads l on l.id = lf.load_id where l.load_number = 'LD-100038') <> 7500 then
    raise exception 'FIX: LD-100038 rate is not 7500.00 yet -- correct the load first. STOP -- nothing changed.';
  end if;
  update public.invoice_line_items
     set unit_price = 7500
   where invoice_id = v_inv and description like 'Freight charges -- Load %' and quantity = 1 and unit_price = 7499.31;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'FIX: expected exactly 1 freight line at 7499.31, found %. STOP -- nothing changed.', v_n; end if;
  if (select total_amount from public.invoices where id = v_inv) <> 7500 then
    raise exception 'FIX: invoice total is not 7500.00 after the fix (other lines?). STOP -- nothing changed.';
  end if;
  raise notice 'FIX: LD-100038 invoice freight line 7499.31 -> 7500.00; total 7500.00.';
end $$;
commit;
