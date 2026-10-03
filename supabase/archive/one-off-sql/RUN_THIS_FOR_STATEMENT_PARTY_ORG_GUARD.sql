-- =============================================================================
-- 0030_statement_party_org_guard.sql
-- Fixes a real bug found during live cross-org security testing of
-- 0029_statements.sql: statements_insert's RLS check only validates
-- organization_id = current_org_id() -- it never confirmed that broker_id/
-- customer_id (a foreign key into another org-scoped table) actually
-- belongs to THAT SAME organization. A user could insert a statement row
-- in their own org that references another organization's real broker_id,
-- exactly the way guard_invoice_collector_assignment() (0027_collections.sql)
-- already prevents for invoices.assigned_collector_id.
--
-- Impact was contained (no financial figures actually leaked -- every real
-- read path, get_ar_invoices()/get_statement_period_summary()/etc.,
-- re-derives its own numbers from RLS-scoped invoices/payments and would
-- have returned zero/empty for a cross-org id regardless), but the row
-- itself should never have been insertable at all.
-- =============================================================================

create or replace function public.guard_statement_party_org()
returns trigger
language plpgsql
as $$
declare
  v_party_org uuid;
begin
  if new.broker_id is not null then
    select organization_id into v_party_org from public.brokers where id = new.broker_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Statement broker must belong to the same organization as the statement.';
    end if;
  end if;

  if new.customer_id is not null then
    select organization_id into v_party_org from public.customers where id = new.customer_id;
    if v_party_org is null or v_party_org <> new.organization_id then
      raise exception 'Statement customer must belong to the same organization as the statement.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists statements_guard_party_org on public.statements;
create trigger statements_guard_party_org
  before insert or update on public.statements
  for each row execute function public.guard_statement_party_org();
