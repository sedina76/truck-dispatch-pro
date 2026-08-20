-- =============================================================================
-- 0077_factoring_settlement_reconciliation_rpc.sql
-- Phase 2H.6: the normal post-funding settlement lifecycle -- customer/
-- broker payment to the factor reported (one-time, cumulative/final),
-- reserve release (cumulative, multiple releases), a genuine MONEY-based
-- reconciliation calculation, and closing once fully reconciled.
-- PROPOSED ONLY -- NOT APPLIED.
--
-- Every business rule here was resolved against the LIVE schema, not
-- assumed:
--   - customer_paid_factor_amount/_at are single scalars with no child
--     table -- report_customer_payment_to_factor() is therefore a
--     ONE-TIME action, blocked outright on a second call. Not an
--     invented limitation -- the schema genuinely has no way to
--     represent a second, distinct report without silently overwriting
--     the first.
--   - reserve_released_amount is cumulative (the existing
--     `outstanding_reserve = reserve_amount - reserve_released_amount`
--     generated column and `factored_invoices_reserve_not_over_released`
--     CHECK, both 0071, only make sense under that reading) -- multiple
--     releases are genuinely representable, with per-release amounts and
--     timestamps preserved forever in factoring_events, never collapsed.
--   - All three event types this phase needs (customer_payment_reported,
--     reserve_released, closed) already exist in factoring_events'
--     event_type CHECK (present since 0071, confirmed unchanged through
--     0076) -- no CHECK-constraint change in this migration, a first for
--     this phase series.
--
-- Two schema additions in this file, both scoped to reserve-release
-- events only:
--   1. factoring_events.idempotency_key (nullable text column) --
--      APPLICATION REQUEST identity, distinct from `reference` (real-
--      world factor/bank/statement identity). Row locking alone prevents
--      lost cumulative updates between two DIFFERENT concurrent
--      requests, but does nothing to stop the SAME logical request (a
--      network retry, a double-submit) from being recorded twice
--      sequentially -- that requires a caller-supplied, retry-stable key
--      the server can deduplicate against, which is what this column and
--      its unique index (below) exist for.
--   2. A separate partial unique index on `reference` is ALSO kept, for
--      its own distinct, legitimate purpose: catching accidental reuse
--      of the same REAL factor reference number on the same factored
--      invoice (a near-certain data-entry error) -- never relied upon as
--      an idempotency substitute, since there is no evidence every
--      reserve release carries one.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- factored_invoice_reconciliation_status -- the single, shared formula for
-- reconciliation_status, called from both report_customer_payment_to_factor()
-- and release_factoring_reserve() so the rule can never drift between the
-- two call sites. Same STABLE-SQL-helper idiom this schema already uses
-- (invoice_effective_status(), 0026) -- not a new convention.
--
-- Money-based, per Phase 2H.6 refinement -- NOT merely "payment reported
-- + reserve empty":
--   expected_net_proceeds  = invoice_face_value - factoring_fee_amount - other_fees
--   actual_carrier_proceeds = coalesce(actual_funded_amount, 0) + reserve_released_amount
--   variance = expected_net_proceeds - actual_carrier_proceeds
-- All NUMERIC(10,2) arithmetic -- exact, no floating point, no invented
-- tolerance: `variance <> 0` is a safe, exact comparison at this fixed
-- decimal scale.
--
-- coalesce(actual_funded_amount, 0) is defensive only: fund_factored_invoice()
-- (0076) is the ONLY code path that ever sets status to 'funded', and it
-- always requires actual_funded_amount > 0 -- by the time either caller
-- below runs (both gated on status in ('funded','partially_settled')),
-- actual_funded_amount is already guaranteed non-null by construction,
-- confirmed by inspection, not assumed. The coalesce costs nothing and
-- protects against any future code path anomaly.
-- ---------------------------------------------------------------------------
create or replace function public.factored_invoice_reconciliation_status(
  p_customer_paid_factor_at timestamptz,
  p_outstanding_reserve numeric,
  p_invoice_face_value numeric,
  p_factoring_fee_amount numeric,
  p_other_fees numeric,
  p_actual_funded_amount numeric,
  p_reserve_released_amount numeric
)
returns text
language sql
stable
as $$
  select case
    when p_customer_paid_factor_at is null then 'unreconciled'
    when p_outstanding_reserve > 0 then 'partially_reconciled'
    when (p_invoice_face_value - p_factoring_fee_amount - p_other_fees)
         - (coalesce(p_actual_funded_amount, 0) + p_reserve_released_amount) <> 0 then 'partially_reconciled'
    else 'reconciled'
  end;
$$;

grant execute on function public.factored_invoice_reconciliation_status(timestamptz, numeric, numeric, numeric, numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- report_customer_payment_to_factor -- ONE-TIME final/cumulative report
-- that the customer/broker paid the factor. Blocked if
-- customer_paid_factor_at is already set -- never silently overwrites
-- prior financial history. Requires funded/partially_settled; transitions
-- funded -> partially_settled on first settlement activity (no-op if
-- already partially_settled -- same value, guard trigger's own no-op
-- path handles it, no duplicate status-transition event is possible
-- since this function only ever inserts ONE event per call regardless).
-- ---------------------------------------------------------------------------
create or replace function public.report_customer_payment_to_factor(
  p_factored_invoice_id uuid,
  p_amount numeric
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_new_status public.factored_invoice_status;
  v_reconciliation text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Customer payment amount must be greater than zero.';
  end if;

  select fi.id, fi.organization_id, fi.status, fi.customer_paid_factor_at,
         fi.invoice_face_value, fi.factoring_fee_amount, fi.other_fees,
         fi.actual_funded_amount, fi.reserve_released_amount, fi.outstanding_reserve
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status not in ('funded', 'partially_settled') then
    raise exception 'This factored invoice is not ready for customer payment reporting.';
  end if;
  if v_fi.customer_paid_factor_at is not null then
    raise exception 'Customer payment to the factor has already been reported for this factored invoice.';
  end if;

  v_new_status := case when v_fi.status = 'funded' then 'partially_settled' else v_fi.status end;
  v_reconciliation := public.factored_invoice_reconciliation_status(
    now(), v_fi.outstanding_reserve, v_fi.invoice_face_value, v_fi.factoring_fee_amount, v_fi.other_fees,
    v_fi.actual_funded_amount, v_fi.reserve_released_amount
  );

  update public.factored_invoices
  set customer_paid_factor_at = now(),
      customer_paid_factor_amount = p_amount,
      status = v_new_status,
      reconciliation_status = v_reconciliation
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, amount, performed_by)
  values (v_org_id, p_factored_invoice_id, 'customer_payment_reported', v_fi.status, v_new_status, p_amount, auth.uid());
end;
$$;

grant execute on function public.report_customer_payment_to_factor(uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- factoring_events.idempotency_key -- nullable (historical/non-money
-- events, and events predating this migration, never need one).
-- Genuinely distinct from `reference`: idempotency_key identifies THIS
-- APPLICATION REQUEST (caller-generated, retry-stable, meaningless
-- outside this system); reference identifies a REAL-WORLD factor/bank
-- artifact (meaningful to the factor, optional, never generated by this
-- app). Never repurposing one for the other.
-- ---------------------------------------------------------------------------
alter table public.factoring_events add column if not exists idempotency_key text;

-- PRIMARY duplicate-request protection for reserve releases -- the same
-- request (same key) can never be recorded twice against the SAME
-- factored invoice; a different factored invoice may reuse the same
-- generated key with no collision (organization_id + factored_invoice_id
-- scoped, not global).
create unique index if not exists factoring_events_reserve_released_idempotency_key_unique
  on public.factoring_events (organization_id, factored_invoice_id, event_type, idempotency_key)
  where event_type = 'reserve_released' and idempotency_key is not null;

-- SEPARATE, secondary safeguard -- kept for its own distinct purpose (see
-- header comment), not as an idempotency substitute: catches the same
-- REAL factor reference being entered twice for the same factored
-- invoice. p_reference remains OPTIONAL on the function below, matching
-- fund_factored_invoice()'s own existing precedent (0076) -- there is no
-- confirmed evidence every reserve release carries a citable reference.
create unique index if not exists factoring_events_reserve_released_reference_unique
  on public.factoring_events (organization_id, factored_invoice_id, reference)
  where event_type = 'reserve_released' and reference is not null;

-- ---------------------------------------------------------------------------
-- release_factoring_reserve -- cumulative, multiple releases supported.
-- Requires customer_paid_factor_at already set (approved ordering rule:
-- normal settlement path only). Never allows cumulative total above
-- reserve_amount -- pre-checked here for a clean message, with
-- factored_invoices_reserve_not_over_released (0071) as the final,
-- unconditional backstop. reserve_released_at is always "most recent
-- release" -- each individual release's own timestamp is permanently
-- available via its own factoring_events.created_at row, never collapsed
-- or overwritten.
--
-- p_idempotency_key is REQUIRED (no default) and placed BEFORE
-- p_reference (which keeps its default) -- PostgreSQL does not allow a
-- required parameter after a defaulted one. This is a signature choice
-- on a function that has never been applied/called live (0077 has never
-- been applied), so there is no existing caller contract to preserve and
-- no 42P13 risk in choosing this order now. The caller must generate the
-- key ONCE per intended release and resend the SAME value on any retry
-- -- generating it inside this function would defeat the whole purpose,
-- since a retry's fresh RPC call would get a fresh key and never
-- deduplicate against the original attempt.
--
-- IDEMPOTENCY ALGORITHM: after acquiring the row lock (which already
-- serializes every concurrent call targeting this exact factored invoice,
-- same-key or not), check whether an event with this exact key already
-- exists for this factored invoice. If so, return immediately -- no
-- further reads, no update, no new event -- an idempotent
-- acknowledgment of a release that was already recorded (matching this
-- app's own existing precedent for a lost/duplicate race,
-- generatePacket()'s handling of its own unique-version race,
-- billing-packet-actions.ts). Because the row lock guarantees any two
-- calls targeting the same factored invoice fully serialize (the second
-- can only proceed once the first has committed or rolled back), this
-- check is race-free by construction -- reserve_released_amount can
-- provably change AT MOST ONCE per distinct idempotency key. The unique
-- index above remains a structural, unconditional backstop regardless.
-- ---------------------------------------------------------------------------
create or replace function public.release_factoring_reserve(
  p_factored_invoice_id uuid,
  p_amount numeric,
  p_idempotency_key text,
  p_reference text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_new_total numeric(10, 2);
  v_new_status public.factored_invoice_status;
  v_reconciliation text;
  v_reference text;
  v_idempotency_key text;
  v_already_recorded boolean;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Reserve release amount must be greater than zero.';
  end if;

  v_idempotency_key := nullif(trim(p_idempotency_key), '');
  if v_idempotency_key is null then
    raise exception 'A request identifier is required to record a reserve release.';
  end if;

  select fi.id, fi.organization_id, fi.status, fi.customer_paid_factor_at,
         fi.invoice_face_value, fi.factoring_fee_amount, fi.other_fees,
         fi.actual_funded_amount, fi.reserve_amount, fi.reserve_released_amount
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status not in ('funded', 'partially_settled') then
    raise exception 'This factored invoice is not ready for reserve release.';
  end if;
  if v_fi.customer_paid_factor_at is null then
    raise exception 'Customer payment to the factor must be reported before releasing the reserve.';
  end if;

  -- Idempotent no-op: this exact request was already recorded (a retry,
  -- a double-submit) -- race-free because the row lock above already
  -- serializes every call targeting this factored invoice.
  select exists (
    select 1 from public.factoring_events ev
    where ev.factored_invoice_id = p_factored_invoice_id
      and ev.event_type = 'reserve_released'
      and ev.idempotency_key = v_idempotency_key
  ) into v_already_recorded;
  if v_already_recorded then
    return;
  end if;

  -- Concurrency (spec section 8): new_total computed from the row's
  -- CURRENT reserve_released_amount, read AFTER the row lock above --
  -- two simultaneous DIFFERENT-key releases can never both compute from
  -- the same stale base, so neither loses the other's increment.
  v_new_total := v_fi.reserve_released_amount + p_amount;
  if v_new_total > v_fi.reserve_amount then
    raise exception 'Reserve release exceeds the remaining reserve.';
  end if;

  v_new_status := case when v_fi.status = 'funded' then 'partially_settled' else v_fi.status end;
  v_reconciliation := public.factored_invoice_reconciliation_status(
    v_fi.customer_paid_factor_at, v_fi.reserve_amount - v_new_total, v_fi.invoice_face_value, v_fi.factoring_fee_amount, v_fi.other_fees,
    v_fi.actual_funded_amount, v_new_total
  );
  v_reference := nullif(trim(p_reference), '');

  update public.factored_invoices
  set reserve_released_amount = v_new_total,
      reserve_released_at = now(),
      status = v_new_status,
      reconciliation_status = v_reconciliation
  where id = p_factored_invoice_id;

  -- amount = ONLY this incremental release, never the running total --
  -- the cumulative figure lives solely on factored_invoices.reserve_released_amount.
  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, amount, reference, idempotency_key, performed_by)
  values (v_org_id, p_factored_invoice_id, 'reserve_released', v_fi.status, v_new_status, p_amount, v_reference, v_idempotency_key, auth.uid());
end;
$$;

grant execute on function public.release_factoring_reserve(uuid, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- close_factored_invoice -- succeeds only when status is funded/
-- partially_settled AND reconciliation_status = 'reconciled'. Given the
-- money-based reconciliation formula above, 'reconciled' already
-- mathematically guarantees: customer payment was reported, reserve is
-- fully released (or was legitimately zero from the start -- the
-- zero-reserve case needs no fake $0 release event, since
-- outstanding_reserve is 0 from the moment of funding and the variance
-- check alone then gates reconciliation), and actual carrier proceeds
-- equal expected net proceeds exactly. No separate re-derivation needed
-- here -- checking the stored column is sufficient and correct because
-- both writers above keep it authoritative.
-- ---------------------------------------------------------------------------
create or replace function public.close_factored_invoice(p_factored_invoice_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  select fi.id, fi.organization_id, fi.status, fi.reconciliation_status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status not in ('funded', 'partially_settled') then
    raise exception 'This factored invoice is not ready to be closed.';
  end if;
  if v_fi.reconciliation_status <> 'reconciled' then
    raise exception 'This factoring transaction is not fully reconciled.';
  end if;

  update public.factored_invoices
  set status = 'closed', closed_at = now(), closed_by = auth.uid()
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by)
  values (v_org_id, p_factored_invoice_id, 'closed', v_fi.status, 'closed', auth.uid());
end;
$$;

grant execute on function public.close_factored_invoice(uuid) to authenticated;
