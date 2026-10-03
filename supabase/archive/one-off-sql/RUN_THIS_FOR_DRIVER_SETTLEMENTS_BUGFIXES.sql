-- =============================================================================
-- 0032_driver_settlements_bugfixes.sql
-- Two real bugs found during live testing of 0031_driver_settlements.sql.
-- Fixes a real bug found during live testing of 0031_driver_settlements.sql:
-- the pre-existing dispatch_advances_deduction_consistency check constraint
-- (0013_dispatch_advances.sql) only knows about deducted_invoice_id/
-- deducted_settlement_id -- it was never updated when 0031 added
-- deducted_driver_settlement_id. Requiring status='deducted' to also have
-- exactly one of ONLY the first two columns set meant marking an advance
-- deducted via a driver settlement (the new, third target) always violated
-- this constraint, even though 0031's own dispatch_advances_single_deduction_target
-- check (an "at most one of three" rule) was satisfied. Replaces it with
-- the three-target-aware equivalent: status='deducted' requires exactly one
-- of the three target columns set; any other status requires all three null.
-- =============================================================================

alter table public.dispatch_advances drop constraint if exists dispatch_advances_deduction_consistency;

alter table public.dispatch_advances add constraint dispatch_advances_deduction_consistency check (
  (
    status = 'deducted'
    and (
      (case when deducted_invoice_id is not null then 1 else 0 end)
      + (case when deducted_settlement_id is not null then 1 else 0 end)
      + (case when deducted_driver_settlement_id is not null then 1 else 0 end)
    ) = 1
  )
  or (
    status <> 'deducted'
    and deducted_invoice_id is null
    and deducted_settlement_id is null
    and deducted_driver_settlement_id is null
  )
);

-- ---------------------------------------------------------------------------
-- Second real bug found in the same live test session: driver_pay_rates
-- (0031) has a SELECT and an INSERT policy but NO UPDATE policy. RLS with
-- no matching policy for a command doesn't error -- it silently matches
-- zero rows. guard_driver_pay_rate_effective_dates() is NOT security
-- definer, so its internal `update ... set effective_to = ...` (closing
-- the previously-open rate row) ran with the CALLING user's own RLS and
-- silently updated 0 rows for any real authenticated user -- the old row
-- was never actually closed, so the immediately-following overlap
-- safety-check correctly (if confusingly) rejected the insert, because
-- from RLS's point of view the two rows genuinely still overlapped. Only
-- service_role (which bypasses RLS) ever exercised the intended path.
-- Adding the missing policy, same tier as insert, fixes the real update.
-- ---------------------------------------------------------------------------
create policy driver_pay_rates_update on public.driver_pay_rates
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
