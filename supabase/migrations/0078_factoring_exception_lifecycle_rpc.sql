-- =============================================================================
-- 0078_factoring_exception_lifecycle_rpc.sql
-- Phase 2H.7: dispute / recourse / chargeback / buyback lifecycle on top of
-- the normal post-funding settlement path (0077). PROPOSED ONLY -- NOT
-- APPLIED.
--
-- Every business rule here was resolved against the LIVE schema and the
-- LIVE guard_factored_invoice_status_transition() (0071) transition graph,
-- not assumed or invented:
--
--   - The graph already contains every transition this phase needs:
--       funded -> disputed, partially_settled -> disputed,
--       disputed -> recourse, disputed -> partially_settled,
--       recourse -> chargeback, recourse -> closed
--     No trigger change in this migration.
--
--   - 'chargeback' never appears as a FROM-state in the graph -- it is
--     structurally terminal. There is no chargeback -> closed pair, and
--     this migration does not add one.
--
--   - The live factored_invoice_status enum (0071) has NO 'buyback' value.
--     'buyback' is, and remains, an EVENT TYPE only. record_factoring_buyback()
--     below resolves recourse via the EXISTING recourse -> closed pair --
--     it does not invent a new status or a new transition.
--
--   - recourse_amount and chargeback_amount (0071) are plain scalars with
--     no generated "outstanding" column (unlike reserve_released_amount /
--     outstanding_reserve) and no supporting CHECK relating either to the
--     other. Combined with the graph shape -- disputed -> recourse and
--     recourse -> chargeback can each only ever happen ONCE per row, since
--     neither status has a path back to its own precondition state -- both
--     are modeled here as ONE-TIME totals, matching what the schema
--     actually supports. chargeback_amount is NOT constrained against
--     recourse_amount (no <=, no equality) -- no such rule exists in the
--     live schema and none is invented here; factors may charge back a
--     different amount than the recourse figure depending on fees/
--     adjustments.
--
--   - Neither recourse_amount nor chargeback_amount has a dedicated actor/
--     timestamp column pair (no recourse_at/recourse_by, no
--     chargeback_at/chargeback_by -- confirmed absent, same absence
--     pattern as 0076's 'pending' transition). factoring_events
--     (created_at + performed_by) is the sole authoritative actor/
--     timestamp record for every action in this migration, exactly as it
--     already is for the 'pending' transition. No such columns are added.
--
--   - Buyback needs no new persistent column: factoring_events.amount/
--     reference/notes fully and immutably capture the buyback, and the
--     row is closed (terminal) in the same transaction -- there is no
--     ongoing exposure to track separately from that one event, unlike
--     recourse_amount/chargeback_amount which matter while the row is
--     still active.
--
--   - Reconciliation is handled deliberately conservatively:
--       * mark_factored_invoice_disputed(), start_factoring_recourse(),
--         and record_factoring_chargeback() all force
--         reconciliation_status = 'unreconciled' -- an exception-path row
--         is never marked reconciled by these functions.
--       * record_factoring_buyback() also forces 'unreconciled' on close
--         -- a buyback-closed transaction is a different kind of
--         resolution than a normally fully-reconciled one, and reusing
--         'reconciled' here would misrepresent it. Whether/how
--         recourse_amount or chargeback_amount should ever factor into a
--         reconciliation FORMULA is explicitly left to a future
--         accounting-integration phase -- the 0077 formula
--         (factored_invoice_reconciliation_status()) is not modified or
--         extended in this migration.
--       * resolve_factoring_dispute() is the one exception, by design: a
--         dispute that resolves back to partially_settled must not stay
--         permanently 'unreconciled' merely because no later reserve/
--         payment action occurs. It RECOMPUTES reconciliation_status using
--         the EXISTING 0077 helper factored_invoice_reconciliation_status()
--         against the row's own current (unchanged) settlement figures --
--         no duplicate formula, no new logic, same shared single source
--         of truth 0077 already established for the normal path.
--
--   - No new idempotency_key column/index is added. Every action below
--     moves the row OUT of the exact status its own precondition requires
--     (disputed -> recourse, recourse -> chargeback, recourse -> closed,
--     disputed -> partially_settled), so an exact retry after commit finds
--     the row no longer in the required source status and fails cleanly
--     on its own status pre-check -- the row lock + post-lock status
--     re-validation (the same pattern used by every RPC since 0073) is
--     sufficient by construction. This does not touch, weaken, or relax
--     0077's release_factoring_reserve() idempotency design in any way --
--     that RPC remains the only one where the SAME source status
--     legitimately accepts multiple distinct real-world actions.
--
--   - Only ONE schema change in this migration: widen
--     factoring_events_event_type_check to add 'dispute_resolved' -- the
--     one genuinely missing event type (disputed -> partially_settled has
--     no existing event type to record it under). Every currently-valid
--     value is preserved verbatim, nothing removed or renamed, matching
--     0076's own precedent for widening this exact constraint.
--
--   - No invoice/payments/collections/statements table is touched by any
--     function below. No AR posting, no accounting journal, no factor
--     API, no automatic recourse decision -- all explicitly out of bounds
--     for this phase.
--
--   - Deliberately NOT implemented (graph-legal but no safe business gate
--     without a recorded financial resolution): a generic disputed ->
--     closed action, and a generic recourse -> closed action other than
--     via record_factoring_buyback(). Closing directly out of an
--     unresolved exception state would leave recourse_amount/
--     chargeback_amount unaccounted for.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- factoring_events_event_type_check -- widen to add 'dispute_resolved'
-- only. Exact current constraint text re-confirmed live from 0076 before
-- this replacement (same discipline 0076 itself used against 0071's
-- unnamed inline check) -- every one of the 13 existing values preserved
-- verbatim, nothing removed or renamed.
-- ---------------------------------------------------------------------------
alter table public.factoring_events drop constraint if exists factoring_events_event_type_check;
alter table public.factoring_events add constraint factoring_events_event_type_check check (event_type in (
  'submitted', 'approved', 'rejected', 'funded', 'customer_payment_reported',
  'reserve_released', 'disputed', 'recourse_started', 'chargeback', 'buyback',
  'closed', 'cancelled', 'pending', 'dispute_resolved'
));

-- ---------------------------------------------------------------------------
-- mark_factored_invoice_disputed -- funded/partially_settled -> disputed.
-- p_reason is REQUIRED (there is no dedicated dispute-reason column --
-- factoring_events.notes is the sole record, so an empty reason would
-- leave no explanation anywhere). Conservative reset: reconciliation_status
-- is forced to 'unreconciled' regardless of its prior value -- an active
-- dispute is never left implying the transaction is still reconciled. All
-- financial snapshot columns and normal settlement amounts
-- (customer_paid_factor_amount, reserve_released_amount, etc.) are left
-- completely untouched -- this function only ever writes status,
-- reconciliation_status, and one event row.
-- ---------------------------------------------------------------------------
create or replace function public.mark_factored_invoice_disputed(
  p_factored_invoice_id uuid,
  p_reason text,
  p_reference text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_reason text;
  v_reference text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  v_reason := nullif(trim(p_reason), '');
  if v_reason is null then
    raise exception 'A reason is required to mark this factored invoice as disputed.';
  end if;

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status not in ('funded', 'partially_settled') then
    raise exception 'This factored invoice is not in a state that can be marked disputed.';
  end if;

  v_reference := nullif(trim(p_reference), '');

  update public.factored_invoices
  set status = 'disputed',
      reconciliation_status = 'unreconciled'
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, reference, notes, performed_by)
  values (v_org_id, p_factored_invoice_id, 'disputed', v_fi.status, 'disputed', v_reference, v_reason, auth.uid());
end;
$$;

grant execute on function public.mark_factored_invoice_disputed(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- resolve_factoring_dispute -- disputed -> partially_settled. The one
-- action in this migration that does NOT force 'unreconciled': it
-- RECOMPUTES reconciliation_status against the row's own current, unchanged
-- settlement figures via the EXISTING 0077 helper
-- factored_invoice_reconciliation_status() -- no duplicated formula. A
-- dispute that turns out to have no bearing on the underlying settlement
-- figures (e.g. resolved as a non-financial disagreement) correctly
-- returns to whatever reconciliation state those figures actually support
-- (unreconciled / partially_reconciled / reconciled), rather than being
-- stuck 'unreconciled' forever absent a later reserve/payment action.
-- ---------------------------------------------------------------------------
create or replace function public.resolve_factoring_dispute(
  p_factored_invoice_id uuid,
  p_notes text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_notes text;
  v_reconciliation text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
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
  if v_fi.status <> 'disputed' then
    raise exception 'This factored invoice is not currently disputed.';
  end if;

  v_notes := nullif(trim(p_notes), '');
  v_reconciliation := public.factored_invoice_reconciliation_status(
    v_fi.customer_paid_factor_at, v_fi.outstanding_reserve, v_fi.invoice_face_value, v_fi.factoring_fee_amount, v_fi.other_fees,
    v_fi.actual_funded_amount, v_fi.reserve_released_amount
  );

  update public.factored_invoices
  set status = 'partially_settled',
      reconciliation_status = v_reconciliation
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, notes, performed_by)
  values (v_org_id, p_factored_invoice_id, 'dispute_resolved', 'disputed', 'partially_settled', v_notes, auth.uid());
end;
$$;

grant execute on function public.resolve_factoring_dispute(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- start_factoring_recourse -- disputed -> recourse. ONE-TIME by
-- construction: recourse is only reachable from disputed, and there is no
-- path back to disputed from recourse, so a second call structurally
-- cannot succeed once the first has committed (its own status pre-check
-- fails). recourse_amount is set (not accumulated) -- a plain scalar with
-- no generated "outstanding" column, matching what the live schema
-- actually supports.
-- ---------------------------------------------------------------------------
create or replace function public.start_factoring_recourse(
  p_factored_invoice_id uuid,
  p_amount numeric,
  p_reason text,
  p_reference text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_reason text;
  v_reference text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Recourse amount must be greater than zero.';
  end if;

  v_reason := nullif(trim(p_reason), '');
  if v_reason is null then
    raise exception 'A reason is required to start recourse on this factored invoice.';
  end if;

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'disputed' then
    raise exception 'This factored invoice is not currently disputed.';
  end if;

  v_reference := nullif(trim(p_reference), '');

  update public.factored_invoices
  set status = 'recourse',
      recourse_amount = p_amount,
      reconciliation_status = 'unreconciled'
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, amount, reference, notes, performed_by)
  values (v_org_id, p_factored_invoice_id, 'recourse_started', 'disputed', 'recourse', p_amount, v_reference, v_reason, auth.uid());
end;
$$;

grant execute on function public.start_factoring_recourse(uuid, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_factoring_chargeback -- recourse -> chargeback (TERMINAL: no
-- chargeback -> closed pair exists in the live transition graph, and none
-- is added here). ONE-TIME by construction, same reasoning as recourse.
-- chargeback_amount is deliberately NOT constrained against recourse_amount
-- (no <=, no equality) -- no such rule exists in the live schema and none
-- is invented here; a factor may charge back a different amount than the
-- recourse figure depending on fees/adjustments.
-- ---------------------------------------------------------------------------
create or replace function public.record_factoring_chargeback(
  p_factored_invoice_id uuid,
  p_amount numeric,
  p_reference text default null,
  p_reason text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_reason text;
  v_reference text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Chargeback amount must be greater than zero.';
  end if;

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'recourse' then
    raise exception 'This factored invoice is not currently in recourse.';
  end if;

  v_reference := nullif(trim(p_reference), '');
  v_reason := nullif(trim(p_reason), '');

  update public.factored_invoices
  set status = 'chargeback',
      chargeback_amount = p_amount,
      reconciliation_status = 'unreconciled'
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, amount, reference, notes, performed_by)
  values (v_org_id, p_factored_invoice_id, 'chargeback', 'recourse', 'chargeback', p_amount, v_reference, v_reason, auth.uid());
end;
$$;

grant execute on function public.record_factoring_chargeback(uuid, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_factoring_buyback -- recourse -> closed. Resolves the EXISTING
-- recourse -> closed pair (0071) -- no new status, no new transition.
-- factoring_events (amount/reference/notes) is the sole, sufficient,
-- immutable record of the buyback -- recourse_amount and chargeback_amount
-- are never overwritten or reused to carry the buyback figure.
-- closed_at/closed_by are populated the same way close_factored_invoice()
-- (0077) populates them on the normal path, for consistent "who/when
-- closed this" regardless of path. reconciliation_status is forced to
-- 'unreconciled' -- a buyback-closed transaction is a different kind of
-- resolution than a normally fully-reconciled one; whether/how it should
-- ever read 'reconciled' is left to a future accounting-integration phase.
-- ---------------------------------------------------------------------------
create or replace function public.record_factoring_buyback(
  p_factored_invoice_id uuid,
  p_amount numeric,
  p_reference text default null,
  p_notes text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_notes text;
  v_reference text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Buyback amount must be greater than zero.';
  end if;

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'recourse' then
    raise exception 'This factored invoice is not currently in recourse.';
  end if;

  v_reference := nullif(trim(p_reference), '');
  v_notes := nullif(trim(p_notes), '');

  update public.factored_invoices
  set status = 'closed',
      closed_at = now(),
      closed_by = auth.uid(),
      reconciliation_status = 'unreconciled'
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, amount, reference, notes, performed_by)
  values (v_org_id, p_factored_invoice_id, 'buyback', 'recourse', 'closed', p_amount, v_reference, v_notes, auth.uid());
end;
$$;

grant execute on function public.record_factoring_buyback(uuid, numeric, text, text) to authenticated;
