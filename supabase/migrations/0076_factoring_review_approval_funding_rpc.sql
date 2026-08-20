-- =============================================================================
-- 0076_factoring_review_approval_funding_rpc.sql
-- Phase 2H.5: the factor's own review lifecycle -- submitted -> pending
-- (review started), pending -> approved, pending -> rejected, and
-- approved -> funded (recording an actual, human-confirmed funding
-- amount). PROPOSED ONLY -- NOT APPLIED.
--
-- No table, column, or enum is added. The ONLY schema change is widening
-- factoring_events' existing event_type CHECK constraint (a plain text
-- CHECK, not an enum -- no 55P04 same-transaction restriction applies)
-- to add 'pending', a genuinely missing value confirmed live (a deliberate
-- insert with event_type='pending' against a real row returned 23514
-- "violates check constraint \"factoring_events_event_type_check\"" --
-- that exact name, read from Postgres's own error, not guessed from
-- reading 0071's inline `check (event_type in (...))` syntax, which
-- never named the constraint explicitly).
--
-- Every business rule reproduces exactly the transition graph
-- guard_factored_invoice_status_transition() (0071) already enforces --
-- none of these functions disables, bypasses, or races that trigger; each
-- one's UPDATE naturally satisfies it because the application-level
-- status pre-check below always matches the trigger's own allowed pairs
-- exactly:
--   submitted -> pending   (mark_factored_invoice_pending)
--   pending   -> approved  (approve_factored_invoice)
--   pending   -> rejected  (reject_factored_invoice)
--   approved  -> funded    (fund_factored_invoice)
-- Note there is NO submitted -> rejected transition in the live graph --
-- a submitted row must move to pending first. No function here offers
-- that transition; the UI does not offer a Reject action while a row is
-- still 'submitted' either (see the corresponding application change).
--
-- SECURITY INVOKER throughout: factored_invoices_update (0071) already
-- grants UPDATE to all four FINANCIAL_ROLES (owner/admin/dispatcher/
-- accountant) -- confirmed live by direct inspection of the policy text,
-- unchanged since 0071 and never touched by 0072-0075. This is the
-- opposite situation from invoices_update (0010), which excludes
-- dispatcher and caused the real 0075 defect when combined with
-- `SELECT ... FOR UPDATE` -- factored_invoices does not have that
-- mismatch, so a plain row lock here is safe for every FINANCIAL_ROLES
-- member, with no advisory-lock workaround needed.
--
-- Snapshot fields (invoice_face_value, advance_percentage,
-- factoring_fee_percentage, reserve_percentage, expected_advance_amount,
-- factoring_fee_amount, reserve_amount, other_fees, fee_timing,
-- expected_funding_amount) are never referenced or written by any
-- function in this file -- exactly the Phase 2H.4 snapshot-immutability
-- guarantee, now also held through the entire review/approval/funding
-- lifecycle, not just submission.
--
-- No write to invoices, payments, statements, or any collections table
-- appears anywhere in this file -- funding a factoring transaction is
-- economically distinct from the customer paying the org, and remains so
-- here exactly as it did at submission (Phase 2H.4).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- A. Widen factoring_events' event_type CHECK to add 'pending'. Every
-- existing value is preserved verbatim, in the same order, plus the one
-- addition at the end -- nothing removed, nothing renamed.
-- ---------------------------------------------------------------------------
alter table public.factoring_events drop constraint if exists factoring_events_event_type_check;
alter table public.factoring_events add constraint factoring_events_event_type_check check (event_type in (
  'submitted', 'approved', 'rejected', 'funded', 'customer_payment_reported',
  'reserve_released', 'disputed', 'recourse_started', 'chargeback', 'buyback',
  'closed', 'cancelled', 'pending'
));

-- ---------------------------------------------------------------------------
-- B. mark_factored_invoice_pending -- submitted -> pending. No dedicated
-- pending_at/pending_by columns exist on factored_invoices (confirmed
-- live, not invented here) -- the factoring_events row this writes is the
-- sole audit record of when/who started the review.
-- ---------------------------------------------------------------------------
create or replace function public.mark_factored_invoice_pending(p_factored_invoice_id uuid)
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

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'submitted' then
    raise exception 'This factored invoice is not awaiting review.';
  end if;

  update public.factored_invoices
  set status = 'pending'
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by)
  values (v_org_id, p_factored_invoice_id, 'pending', 'submitted', 'pending', auth.uid());
end;
$$;

grant execute on function public.mark_factored_invoice_pending(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- C. approve_factored_invoice -- pending -> approved.
-- ---------------------------------------------------------------------------
create or replace function public.approve_factored_invoice(p_factored_invoice_id uuid)
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

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'pending' then
    raise exception 'This factored invoice is not pending review.';
  end if;

  update public.factored_invoices
  set status = 'approved', approved_at = now(), approved_by = auth.uid()
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by)
  values (v_org_id, p_factored_invoice_id, 'approved', 'pending', 'approved', auth.uid());
end;
$$;

grant execute on function public.approve_factored_invoice(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- D. reject_factored_invoice -- pending -> rejected. p_reason is required
-- (a business-rule choice on top of the nullable rejection_reason column,
-- not a schema requirement) -- trimmed, rejected if empty. No length cap
-- added: rejection_reason is unbounded text with no existing UI
-- convention to match, and none of this migration's rules require one.
-- ---------------------------------------------------------------------------
create or replace function public.reject_factored_invoice(p_factored_invoice_id uuid, p_reason text)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_reason text;
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
    raise exception 'A rejection reason is required.';
  end if;

  select fi.id, fi.organization_id, fi.status
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'pending' then
    raise exception 'This factored invoice is not pending review.';
  end if;

  update public.factored_invoices
  set status = 'rejected', rejected_at = now(), rejected_by = auth.uid(), rejection_reason = v_reason
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, notes, performed_by)
  values (v_org_id, p_factored_invoice_id, 'rejected', 'pending', 'rejected', v_reason, auth.uid());
end;
$$;

grant execute on function public.reject_factored_invoice(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- E. fund_factored_invoice -- approved -> funded. p_actual_funded_amount
-- must be > 0 (not merely >= 0): a 'funded' row with a recorded $0 would
-- be semantically contradictory ("funded" implies real money moved) and
-- no zero-dollar funding case exists anywhere in this schema or spec to
-- justify allowing it. Never validated against expected_funding_amount --
-- a real factor may legitimately fund a different amount than the
-- submission-time estimate; that estimate is never treated as
-- authoritative here or anywhere else in this schema.
--
-- external_reference: audited live -- no writer has EVER populated this
-- column (submit_invoice_to_factor(), 0073-0075, never sets it; the only
-- existing reference to it anywhere in the application is a read-only
-- display mapping on Invoice Detail, Phase 2H.4). Every existing row's
-- external_reference is therefore null today. Still, the rule below is
-- written to be correct going forward and on any future repeat funding
-- correction: a null/blank p_external_reference NEVER erases an existing
-- value -- `coalesce(nullif(trim(p_external_reference), ''), <existing>)`.
-- Note factored_invoices_external_reference_unique (0071, a partial
-- unique index on (organization_id, factoring_company_id,
-- external_reference) where not null) means a colliding reference value
-- will raise 23505 here -- left to the application layer to translate
-- into a friendly message, the same convention used throughout this app
-- for constraint-driven errors.
-- ---------------------------------------------------------------------------
create or replace function public.fund_factored_invoice(
  p_factored_invoice_id uuid,
  p_actual_funded_amount numeric,
  p_external_reference text default null
)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_fi record;
  v_reference text;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to manage factoring review.';
  end if;

  if p_actual_funded_amount is null or p_actual_funded_amount <= 0 then
    raise exception 'Funded amount must be greater than zero.';
  end if;

  select fi.id, fi.organization_id, fi.status, fi.external_reference
    into v_fi
  from public.factored_invoices fi
  where fi.id = p_factored_invoice_id
  for update;

  if v_fi.id is null or v_fi.organization_id <> v_org_id then
    raise exception 'Factored invoice not found.';
  end if;
  if v_fi.status <> 'approved' then
    raise exception 'This factored invoice is not approved for funding.';
  end if;

  v_reference := coalesce(nullif(trim(p_external_reference), ''), v_fi.external_reference);

  update public.factored_invoices
  set status = 'funded', actual_funded_amount = p_actual_funded_amount, funded_at = now(), external_reference = v_reference
  where id = p_factored_invoice_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, amount, reference, performed_by)
  values (v_org_id, p_factored_invoice_id, 'funded', 'approved', 'funded', p_actual_funded_amount, v_reference, auth.uid());
end;
$$;

grant execute on function public.fund_factored_invoice(uuid, numeric, text) to authenticated;
