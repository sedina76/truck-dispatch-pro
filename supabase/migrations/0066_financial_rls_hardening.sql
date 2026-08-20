-- =============================================================================
-- 0066_financial_rls_hardening.sql
-- Phase 2G.6: Financial/office-data RLS hardening.
--
-- PROPOSED ONLY -- NOT APPLIED. See the Phase 2G.6 report for the full
-- pre-migration security writeup this accompanies.
--
-- PROBLEM (confirmed live via direct inspection + a disposable-role test
-- pass, not assumed): every financial table audited uses the same
-- `select using (organization_id = public.current_org_id())` policy --
-- SELECT open to ANY org member, including profiles.role = 'driver' or
-- 'viewer'. This was a deliberate, documented choice at the time
-- (0010_rls_policies.sql: "select: any org member. write: owner/admin/
-- accountant"), but Phase 2G.5 added page-level nav hiding for driver/
-- viewer on top of it without also narrowing the underlying policy --
-- meaning a driver/viewer who typed a direct URL, or who simply called
-- e.g. `supabase.rpc('get_ar_summary')` from the browser console with
-- their own real session, still got real financial data back. Phase
-- 2G.6's new requireRole()/requireRoleForApi() page guards
-- (src/lib/auth/require-role.ts) close the "typed a URL" half of that gap
-- today, without a migration. This migration closes the other half -- the
-- actual data-layer boundary -- for direct table queries AND for every
-- non-SECURITY-DEFINER reporting RPC that inherits caller RLS
-- (get_ar_summary, get_ar_invoices, get_party_ar_summary,
-- get_collections_queue, get_collections_summary,
-- get_load_billing_readiness, get_ready_to_bill_loads -- none of these
-- are security definer, confirmed by inspection, so tightening the
-- underlying tables' SELECT policy automatically tightens all of them at
-- once with no separate per-RPC change needed).
--
-- SCOPE: every table below is either invoice/payment/AR/collections data,
-- outbound settlement/advance data, general business expenses, or the
-- internal email send log -- exactly the categories the Financial Data
-- Rule names. Two categories audited and DELIBERATELY EXCLUDED:
--   - fuel_logs / maintenance_records: fleet-operational, not "office
--     financial" in the sense this rule means, and Phase 2G.5 already
--     deliberately kept Fuel/Maintenance nav open to every role (Fleet
--     section, unrestricted) -- tightening their RLS here would silently
--     contradict a decision already made and shipped.
--   - loads / dispatches (rate, load_rate, dispatch_fee_amount,
--     carrier_net_amount): these are NOT touched here. A real, working,
--     ALREADY-EXISTING mechanism for this exact problem exists --
--     getDispatchDrawerData() (src/app/(app)/dispatch/board-actions.ts)
--     computes `canSeeFinancials = role !== "driver"` and strips
--     financial fields server-side before the response is ever built,
--     specifically because loads/dispatches must stay fully queryable at
--     the ROW level for Operations (Dispatch Board, Load Detail) to work
--     for every role at all -- an RLS-level cut is not the right tool for
--     a column-level, per-role redaction problem, and retrofitting one
--     here risks breaking Operations for roles that legitimately need it.
--     See the Phase 2G.6 report's "remaining risks" section for what IS
--     still open on this front (Load Detail's Rate field is not
--     role-filtered the way the Dispatch Drawer is).
--
-- ROLE TIER: identical to FINANCIAL_ROLES in src/lib/auth/require-role.ts
-- and to the Billing nav section's own visibility rule from Phase 2G.5 --
-- owner, admin, dispatcher, accountant. Every one of these tables is
-- either something dispatcher already has a real, documented operational
-- need to see (Ready to Bill, advances against a dispatch they run) or is
-- already owner/admin/accountant-only for WRITE today, just not for read.
-- Viewer is not included in any of them: no "explicitly approved
-- non-sensitive area" has been defined for viewer among these tables (all
-- of them are financial), matching require-role.ts's own stated
-- reasoning.
--
-- WRITE policies (insert/update/delete) are UNCHANGED -- they already
-- enforce the correct, tighter owner/admin/accountant (or +dispatcher for
-- ops-cost-adjacent tables) tier from 0010/0013/0026/0027/0029/0031/0039.
-- Only SELECT is being narrowed here.
--
-- CROSS-ORG BEHAVIOR: unchanged and unaffected -- `organization_id =
-- current_org_id()` remains the first condition on every policy below;
-- this migration only ever narrows WHICH ROLES within an org may read,
-- never which organization's rows are visible.
--
-- COMPATIBILITY RISK: any UI surface that currently queries one of these
-- tables directly (not through a page already guarded by requireRole())
-- with a driver/viewer session would start receiving empty results
-- instead of real rows post-migration. Audited: no driver-portal code
-- path uses a caller-scoped client against any of these tables (driver
-- portal is a fully separate auth system -- driver_portal_sessions,
-- service-role only, see src/lib/driver-portal/session.ts -- entirely
-- unaffected by this migration). The Phase 2G.6 page guards already
-- redirect driver/viewer away from every page that reads these tables
-- before this policy would even be reached in practice; this migration
-- is the second, data-layer half of the same fix, not a change expected
-- to alter any currently-working screen for owner/admin/dispatcher/
-- accountant.
-- =============================================================================

do $$
declare
  t text;
  -- financial_tables (0010) -- select currently any org member.
  -- ops_cost_tables (0010) -- narrowed here to `expenses` ONLY; fuel_logs
  -- and maintenance_records are deliberately excluded, see header.
  -- child_tables (0010).
  -- Standalone tables added in later migrations, each with the same
  -- any-org-member select policy: dispatch_advances (0013), statements
  -- (0029), billing_packets (0024), email_send_log (0039), the AR/
  -- collections detail tables (0026/0027), and the driver settlements
  -- family (0031).
  hardened_tables text[] := array[
    'invoices', 'settlements', 'invoice_line_items', 'payments', 'settlement_line_items',
    'expenses', 'dispatch_advances', 'email_send_log', 'statements', 'billing_packets',
    'payment_promises', 'invoice_collection_activity', 'invoice_disputes', 'invoice_reminders',
    'driver_settlements', 'driver_settlement_items', 'driver_settlement_adjustments',
    'driver_settlement_payments', 'driver_pay_rates'
  ];
begin
  foreach t in array hardened_tables loop
    execute format('drop policy if exists %1$I_select on public.%1$I;', t);
    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
        );
    $p$, t);
  end loop;
end $$;

-- 0065_billing_readiness.sql has not been applied yet either -- its two
-- new tables' select policies are fixed IN PLACE there (same reasoning as
-- above) rather than re-touched here, so there is only ever one correct
-- version of that not-yet-live migration to review.
