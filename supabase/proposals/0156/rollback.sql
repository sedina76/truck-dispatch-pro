-- rollback.sql -- EMERGENCY reversal of proposal 0156 (restores the 0140 universal rejection)
-- PROPOSAL 0156 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 -> 0155 -> 0156 (this). The unrelated proposal 0148 MUST be renumbered to 0153 (unused) or to 0157 or higher, never 0154-0156. Finding F-08.
-- *** SUPERSEDED FOR PRODUCTION USE by proposal 0157 (carrier invoices). NOT PROMOTABLE FOR LEGACY INVOICES: Owner decisions D-08a/D-08b (0156/OWNER_DECISIONS.md) exclude legacy `invoices` from automatic
-- *** factoring. This file is kept, with its tests, as history; its gate stays DISABLED and must never be enabled. ***
-- Restores the EXACT 0140 definition (extracted from the migration), its ACL and SECURITY INVOKER, and removes the gate. Historical rows are PRESERVED: submissions already made and their immutable
-- snapshots stay; the snapshot table is dropped ONLY if it is empty (otherwise it is kept and re-applying 0156 requires a reviewed manual step). REFUSES unless the live function is the reviewed 0156 definition.
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regclass('public.factoring_submission_gate') is null then raise exception 'ROLLBACK 0156 REFUSED: gate missing (0156 not applied or already rolled back). Nothing changed.'; end if;
  if position('factored_invoice_carrier_snapshot_0156' in (select prosrc from pg_proc where oid = to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'))) = 0 then raise exception 'ROLLBACK 0156 REFUSED: live submit_invoice_to_factor is not the reviewed 0156 definition. Nothing changed.'; end if;
end
$mig$;
create or replace function public.submit_invoice_to_factor(
  p_invoice_id uuid,
  p_relationship_id uuid
)
returns jsonb
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_invoice record;
  v_existing_active uuid;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  -- Dispatcher retains this explicit, documented submission authority
  -- (Section A's matrix: "Only if existing business policy explicitly
  -- authorizes it" -- documented in migration 0075's own header comment,
  -- unrelated to and unaffected by this rejection). This role check is
  -- deliberately NOT the thing that blocks a legacy submission -- EVERY
  -- role below, including owner/admin, hits the same unconditional
  -- rejection at the bottom of this function. Authorization and snapshot
  -- eligibility are two independent gates; passing the first only earns
  -- the right to be told "no" by the second.
  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to submit invoices for factoring.';
  end if;

  -- Serializes every concurrent submission ATTEMPT for this exact invoice
  -- (matches 0075's own advisory-lock fix). Still meaningful here even
  -- though every attempt now ends in the same rejection: it guarantees
  -- the "already submitted" check immediately below is race-free, and it
  -- keeps this function's lock behavior directly comparable/testable
  -- against the real two-session scenarios Phase 3B.1.5 Section D
  -- requires. pg_advisory_xact_lock auto-releases on commit or rollback.
  perform pg_advisory_xact_lock(hashtext('factoring_submission:' || p_invoice_id::text));

  select inv.id, inv.organization_id, inv.status, inv.amount_paid
    into v_invoice
  from public.invoices inv
  where inv.id = p_invoice_id;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  -- A genuinely already-submitted invoice gets its OWN specific message
  -- (matches 0073-0075's original behavior exactly) rather than the
  -- generic snapshot-required rejection below -- this is a more accurate
  -- diagnosis and protects historical factored_invoices/factoring_events
  -- rows from ever being reasoned about as if they didn't exist. Race-free
  -- because the advisory lock above is already held for this exact
  -- invoice id.
  select fi.id into v_existing_active
  from public.factored_invoices fi
  where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  -- =====================================================================
  -- Phase 3B.1.5 (Sections A/B): THE unconditional fail-closed rejection.
  --
  -- No column, table, or marker anywhere in this schema records an
  -- authoritative, database-issued snapshot of this invoice's carrier
  -- identity, financial terms, NOA, or remittance instructions at the
  -- moment it was created -- confirmed absent (Phase 3B.1.4's own audit,
  -- reaffirmed here). A live join through dispatch_id/load_id to
  -- dispatches.carrier_id/loads.carrier_id (the previous, now-REMOVED
  -- version of this gate) is CURRENT operational state, mutable by
  -- unrelated actions (a load correction, a default-relationship change,
  -- a policy flip) at any time after this invoice was issued -- it is not
  -- a financial record of what was true and approved when the invoice was
  -- created, and must never be presented or treated as one (Phase 3B.1.5,
  -- Section A). This function therefore stops here, for every invoice,
  -- with no exception -- there is no branch below this comment that ever
  -- proceeds to create a factored_invoices row, a factoring_events row, a
  -- 'submitted' status, or any other side effect.
  --
  -- FUTURE MIGRATION: when the invoice-issuance phase introduces a real,
  -- database-issued snapshot/version marker (e.g., a NOT NULL
  -- invoices.carrier_factoring_snapshot_id referencing an immutable
  -- snapshot row captured at issuance time), THIS is the one place to
  -- replace: swap the unconditional `return jsonb_build_object(...)`
  -- below for a check on that marker's presence, then resume this
  -- function's real submission logic (carrier/company/relationship
  -- validation, fee calculation, the factored_invoices/factoring_events
  -- insert) gated on the SNAPSHOT's own frozen values -- never on a fresh
  -- live derivation. Do not restore the dispatch/load-carrier-derivation
  -- gate this replaced; it was the mistake being corrected.
  -- =====================================================================
  return jsonb_build_object(
    'success', false,
    'code', 'CARRIER_INVOICE_SNAPSHOT_REQUIRED',
    'snapshot_required', true,
    'message', 'This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow.'
  );
end;
$$;
revoke all on function public.submit_invoice_to_factor(uuid,uuid) from public, anon, service_role;
grant execute on function public.submit_invoice_to_factor(uuid,uuid) to authenticated;
drop table public.factoring_submission_gate;
do $mig$
begin
  if not exists (select 1 from public.factored_invoice_carrier_snapshot_0156) then
    drop table public.factored_invoice_carrier_snapshot_0156;
    drop function public.factored_invoice_carrier_snapshot_0156_immutable();
  else
    raise notice 'ROLLBACK 0156: the snapshot table holds historical submissions and was KEPT.';
  end if;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)')) <> 'd620bf87dcc57f377a14a0da44c4c607' then raise exception 'ROLLBACK 0156 postcondition: body is not the 0140 baseline.'; end if;
  raise notice 'ROLLBACK 0156 complete: the 0140 universal rejection is restored.';
end
$mig$;
commit;
