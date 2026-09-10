-- =============================================================================
-- 0126_backfill_load_financial_dispatch.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0125 to be live. APPLY IN THE SAME MAINTENANCE WINDOW AS 0125,
-- with dispatch-creation paused, so no re-dispatch occurs between them.
--
-- DATA MIGRATION. Deterministically populates public.loads.financial_dispatch_id
-- for existing loads so that the (later) model-aware auto-invoice trigger
-- binds each freight invoice to a real, deterministically-chosen dispatch
-- instead of the current non-deterministic `SELECT id ... LIMIT 1`.
--
-- DETERMINISTIC RESOLUTION (first rule that yields a single answer):
--   R1  load's freight-invoice dispatch_id, if non-NULL and a dispatch of this load
--   R2  else non-void settlement load_pay dispatch_id, if uniquely valid
--   R3  else the sole dispatch for the load (any status)
--   R4  else, with >1 dispatch, the sole non-cancelled dispatch
--   R5  else NULL  (zero dispatches, or only cancelled dispatches with no doc link)
--   R6  else AMBIGUOUS  (>1 non-cancelled dispatch, no document-backed answer) -> ABORT
--
-- CONFLICT / ABORT conditions (any one -> RAISE, roll back, ZERO writes):
--   * a load resolves to R6 (ambiguous)
--   * >1 distinct freight-invoice dispatch_id for one load
--   * >1 distinct non-void settlement load_pay dispatch_id for one load
--   * freight-invoice dispatch and settlement dispatch disagree for one load
--   * a document dispatch_id is not a dispatch of that load
--   * a pre-existing loads.financial_dispatch_id (set by 0125's AFTER INSERT
--     trigger for a dispatch created between 0125 and 0126) is structurally
--     invalid, or disagrees with a document-backed answer
--   * an auto-invoice-eligible undelivered dispatched load would remain
--     unresolved (financial_dispatch_id NULL)
--
-- WHAT THIS MIGRATION WRITES: public.loads.financial_dispatch_id ONLY, and
-- ONLY on rows where it is currently NULL and the deterministic answer is
-- non-NULL. A pre-existing (trigger-set) value is validated, never overwritten.
--
-- WHAT THIS MIGRATION DOES NOT DO / DOES NOT TOUCH:
--   * does NOT change any invoices.dispatch_id or settlement_line_items.dispatch_id
--   * does NOT change any amount, status, document, or historical dispatch
--   * does NOT stamp any dispatches.proceeds_model (they stay NULL)
--   * does NOT enable Model A (platform_settings.model_a_enabled stays false)
--   * does NOT touch invoices, invoice_line_items, payments, settlements,
--     carrier_settlement_payments, dispatch_financials, load_financials,
--     billing_records, organization_subscriptions, subscription_plans, any
--     Stripe object, any QuickBooks object, middleware, migration 0115, or
--     migrations 0119-0124
--   * does NOT create/replace/drop auto_generate_invoice_from_delivered_load()
--
-- DATA EFFECT (honest):
--   * public.loads.financial_dispatch_id is written on the deterministically
--     resolvable subset of loads (currently ~15 of 24 -- see PHASE 3 notice).
--   * those loads' updated_at is bumped by the pre-existing shared
--     set_updated_at trigger on loads. No amount / status / document change.
--   * genuine zero-dispatch loads (currently 9) and R5 loads remain NULL.
--
-- STRUCTURE: PHASE 0 = rerun rejection + schema preconditions + baseline
-- snapshots. PHASE 1 (DO block) = build the deterministic plan into a temp
-- table and RAISE on any conflict/ambiguity. PHASE 2 = the single UPDATE.
-- PHASE 3 (DO block) = postconditions + set the "backfilled" comment marker.
-- One transaction; any RAISE rolls everything back. NOT idempotent after
-- success: a re-run RAISEs in PHASE 0 on the comment marker.
-- =============================================================================

-- ======================= PHASE 0 -- PRECONDITIONS + SNAPSHOTS ===============
do $mig$
declare
  v_attnum smallint;
begin
  -- rerun rejection
  select attnum into v_attnum from pg_attribute
  where attrelid = 'public.loads'::regclass and attname = 'financial_dispatch_id' and not attisdropped;
  if v_attnum is null then
    raise exception '0126 precondition: loads.financial_dispatch_id is missing -- apply 0125 first. STOP.';
  end if;
  if coalesce(col_description('public.loads'::regclass, v_attnum), '') ilike '%backfilled by migration 0126%' then
    raise exception '0126 precondition: loads.financial_dispatch_id comment already carries the 0126 backfill marker -- already applied. STOP.';
  end if;

  -- 0125 must be live
  if to_regclass('public.platform_settings') is null then
    raise exception '0126 precondition: public.platform_settings missing -- apply 0125 first. STOP.';
  end if;
  if to_regprocedure('public.resolve_dispatch_proceeds_model(uuid)') is null then
    raise exception '0126 precondition: resolve_dispatch_proceeds_model(uuid) missing -- apply 0125 first. STOP.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='dispatches_assign_financial_controller' and tgrelid='public.dispatches'::regclass and not tgisinternal) then
    raise exception '0126 precondition: trigger dispatches_assign_financial_controller missing -- apply 0125 first. STOP.';
  end if;
  if not exists (select 1 from pg_trigger where tgname='loads_financial_dispatch_ref_guard' and tgrelid='public.loads'::regclass and not tgisinternal) then
    raise exception '0126 precondition: trigger loads_financial_dispatch_ref_guard missing -- apply 0125 first. STOP.';
  end if;
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='proceeds_model') then
    raise exception '0126 precondition: type public.proceeds_model missing -- apply 0125 first. STOP.';
  end if;
  if not exists (
    select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='dispatch_status' and e.enumlabel='cancelled'
  ) then
    raise exception '0126 precondition: enum public.dispatch_status has no ''cancelled'' member. STOP.';
  end if;

  -- Model A must be OFF for the whole backfill.
  if (select model_a_enabled from public.platform_settings where id = true) is not false then
    raise exception '0126 precondition: platform_settings.model_a_enabled is not FALSE. Backfill must run with Model A disabled. STOP.';
  end if;

  -- No dispatch has been stamped Model A (belt-and-suspenders vs the gate).
  if exists (select 1 from public.dispatches where proceeds_model = 'carrier_paid_directly') then
    raise exception '0126 precondition: a dispatch is already stamped carrier_paid_directly while Model A is off -- inconsistent. STOP.';
  end if;

  -- baseline snapshots for PHASE 3 immutability checks
  create temp table _mig0126_inv_snap on commit drop as
    select id, load_id, dispatch_id from public.invoices;
  create temp table _mig0126_sli_snap on commit drop as
    select id, load_id, dispatch_id, item_type, settlement_id from public.settlement_line_items;
  create temp table _mig0126_settle_snap on commit drop as
    select id, status, gross_amount, adjustments_amount, deductions_amount, advances_amount,
           quick_pay_fee_amount, net_amount, amount_paid, balance_due from public.settlements;
  create temp table _mig0126_counts on commit drop as
    select
      (select count(*) from public.organizations)              as n_org,
      (select count(*) from public.carriers)                   as n_carrier,
      (select count(*) from public.dispatches)                 as n_dispatch,
      (select count(*) from public.loads)                      as n_load,
      (select count(*) from public.invoices)                   as n_invoice,
      (select count(*) from public.invoice_line_items)         as n_invoice_li,
      (select count(*) from public.payments)                   as n_payment,
      (select count(*) from public.settlements)                as n_settlement,
      (select count(*) from public.settlement_line_items)      as n_sli,
      (select count(*) from public.carrier_settlement_payments) as n_csp,
      (select count(*) from public.billing_records)            as n_billing_records,
      (select count(*) from public.organization_subscriptions) as n_orgsub,
      (select count(*) from public.subscription_plans)         as n_plan,
      (select count(*) from public.loads where financial_dispatch_id is not null) as n_load_fdi_start;

  raise notice '0126 PHASE 0 preconditions passed. Snapshots captured.';
end
$mig$;

-- ======================= PHASE 1 -- BUILD PLAN + VALIDATE ===================
do $mig$
declare
  v_conflict     integer;
  v_ambiguous    integer;
  v_pre_conflict integer;
  v_unresolved   integer;
  v_bad_ref      integer;
begin
  create temp table _mig0126_plan on commit drop as
  with per_load as (
    select
      l.id                as load_id,
      l.organization_id   as load_org,
      l.status            as load_status,
      (l.broker_id is not null or l.customer_id is not null) as has_bill_to,
      l.financial_dispatch_id as existing_fdi,
      coalesce((select array_agg(distinct d.id)
                from public.dispatches d where d.load_id = l.id), '{}'::uuid[])            as disp_ids,
      coalesce((select array_agg(distinct d.id)
                from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), '{}'::uuid[]) as noncanc_ids,
      coalesce((select count(*) from public.dispatches d where d.load_id = l.id), 0)        as n_disp,
      coalesce((select count(*) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled'), 0) as n_noncanc,
      coalesce((select array_agg(distinct i.dispatch_id)
                from public.invoices i where i.load_id = l.id and i.dispatch_id is not null), '{}'::uuid[])   as inv_disp,
      coalesce((select array_agg(distinct sli.dispatch_id)
                from public.settlement_line_items sli
                join public.settlements s on s.id = sli.settlement_id
                where sli.load_id = l.id and sli.item_type = 'load_pay'
                  and sli.dispatch_id is not null and s.status <> 'void'), '{}'::uuid[])   as sli_disp
    from public.loads l
  ),
  calc as (
    select
      p.*,
      (case when coalesce(array_length(p.inv_disp,1),0) = 1 then p.inv_disp[1] end) as doc_from_inv,
      (case when coalesce(array_length(p.sli_disp,1),0) = 1 then p.sli_disp[1] end) as doc_from_sli
    from per_load p
  ),
  flags as (
    select
      c.*,
      (
        coalesce(array_length(c.inv_disp,1),0) > 1
        or coalesce(array_length(c.sli_disp,1),0) > 1
        or (c.doc_from_inv is not null and c.doc_from_sli is not null and c.doc_from_inv <> c.doc_from_sli)
        or (c.doc_from_inv is not null and not (c.doc_from_inv = any(c.disp_ids)))
        or (c.doc_from_sli is not null and not (c.doc_from_sli = any(c.disp_ids)))
      ) as is_conflict
    from calc c
  ),
  resolved as (
    select
      f.*,
      coalesce(f.doc_from_inv, f.doc_from_sli) as doc_disp,
      (case
         when f.is_conflict then null
         when coalesce(f.doc_from_inv, f.doc_from_sli) is not null then coalesce(f.doc_from_inv, f.doc_from_sli)   -- R1 / R2
         when f.n_disp = 1 then f.disp_ids[1]                                                                      -- R3
         when f.n_disp > 1 and f.n_noncanc = 1 then f.noncanc_ids[1]                                               -- R4
         else null                                                                                                -- R5 / R6
       end) as resolved_dispatch_id,
      (not f.is_conflict
        and coalesce(f.doc_from_inv, f.doc_from_sli) is null
        and f.n_noncanc > 1) as is_ambiguous
    from flags f
  )
  select
    r.load_id, r.load_org, r.load_status, r.has_bill_to, r.existing_fdi,
    r.disp_ids, r.n_disp, r.n_noncanc, r.inv_disp, r.sli_disp, r.doc_disp,
    r.is_conflict, r.is_ambiguous,
    r.resolved_dispatch_id,
    -- which rule fired (for the PHASE 3 report / verification)
    (case
       when r.is_conflict then 'CONFLICT'
       when r.is_ambiguous then 'AMBIGUOUS'
       when r.doc_from_inv is not null then 'R1_invoice'
       when r.doc_from_sli is not null then 'R2_settlement'
       when r.n_disp = 1 then 'R3_sole'
       when r.n_disp > 1 and r.n_noncanc = 1 then 'R4_sole_noncancelled'
       when r.n_disp = 0 then 'R5_zero_dispatch'
       else 'R5_only_cancelled'
     end) as rule_applied,
    -- pre-existing (trigger-set) controller reconciliation
    (r.existing_fdi is not null
      and (
        not (r.existing_fdi = any(r.disp_ids))
        or (coalesce(r.doc_from_inv, r.doc_from_sli) is not null and not r.is_conflict
            and r.existing_fdi <> coalesce(r.doc_from_inv, r.doc_from_sli))
      )) as preexisting_conflict,
    -- auto-invoice regression: undelivered eligible dispatched load with no answer
    (r.load_status not in ('delivered','pod_received','invoiced','closed','cancelled')
      and r.has_bill_to and r.n_disp >= 1
      and r.existing_fdi is null
      and r.resolved_dispatch_id is null) as unresolved_regression
  from resolved r;

  select count(*) into v_conflict     from _mig0126_plan where is_conflict;
  select count(*) into v_ambiguous    from _mig0126_plan where is_ambiguous;
  select count(*) into v_pre_conflict from _mig0126_plan where preexisting_conflict;
  select count(*) into v_unresolved   from _mig0126_plan where unresolved_regression;
  -- resolved dispatch (if any) must belong to the same load + org
  select count(*) into v_bad_ref
  from _mig0126_plan p
  join public.dispatches d on d.id = p.resolved_dispatch_id
  where p.resolved_dispatch_id is not null
    and (d.load_id <> p.load_id or d.organization_id <> p.load_org);

  if v_conflict > 0 or v_ambiguous > 0 or v_pre_conflict > 0 or v_unresolved > 0 or v_bad_ref > 0 then
    raise exception E'0126 ABORT -- deterministic controller resolution has % conflict, % ambiguous, % pre-existing-conflict, % unresolved-regression, % bad-ref load(s). No UPDATE performed. Offending loads (short id | rule | n_disp | n_noncanc):\n%',
      v_conflict, v_ambiguous, v_pre_conflict, v_unresolved, v_bad_ref,
      (select string_agg(left(load_id::text,8) || ' | ' || rule_applied
                         || case when preexisting_conflict then ' | PREEXISTING_CONFLICT' else '' end
                         || case when unresolved_regression then ' | UNRESOLVED_REGRESSION' else '' end
                         || ' | ' || n_disp || ' | ' || n_noncanc, E'\n' order by load_id)
       from _mig0126_plan
       where is_conflict or is_ambiguous or preexisting_conflict or unresolved_regression
          or (resolved_dispatch_id is not null and not exists (
                select 1 from public.dispatches d where d.id = resolved_dispatch_id
                  and d.load_id = load_id and d.organization_id = load_org)));
  end if;

  raise notice '0126 PHASE 1: plan built and validated. 0 conflicts / 0 ambiguous / 0 pre-existing-conflict / 0 unresolved-regression / 0 bad-ref.';
end
$mig$;

-- ======================= PHASE 2 -- THE SINGLE UPDATE ======================
-- Writes loads.financial_dispatch_id ONLY, and ONLY where it is currently
-- NULL and the deterministic answer is non-NULL. A pre-existing (trigger-set)
-- value is left untouched. The loads_financial_dispatch_ref_guard trigger
-- (0125) re-validates same-load/same-org on every row written.
update public.loads l
set financial_dispatch_id = p.resolved_dispatch_id
from _mig0126_plan p
where l.id = p.load_id
  and p.resolved_dispatch_id is not null
  and l.financial_dispatch_id is null;

-- ======================= PHASE 3 -- POSTCONDITIONS + MARKER ================
do $mig$
declare
  b record;
  v_n integer;
  v_updated integer;
begin
  select * into b from _mig0126_counts;

  -- exactly the planned rows were assigned
  select count(*) into v_updated
  from public.loads l join _mig0126_plan p on p.load_id = l.id
  where p.resolved_dispatch_id is not null
    and l.financial_dispatch_id = p.resolved_dispatch_id;
  -- (loads that already had a valid pre-existing value are not counted here;
  --  they are covered by the structural checks below.)

  -- every non-NULL financial_dispatch_id references a dispatch of the SAME load + org
  select count(*) into v_n
  from public.loads l join public.dispatches d on d.id = l.financial_dispatch_id
  where l.financial_dispatch_id is not null
    and (d.load_id <> l.id or d.organization_id <> l.organization_id);
  if v_n <> 0 then
    raise exception '0126 postcondition: % load(s) have a financial_dispatch_id pointing at a dispatch of a different load/org.', v_n;
  end if;

  -- R1 preservation: every load whose freight invoice carries a dispatch_id now points at it
  select count(*) into v_n
  from public.invoices i
  join public.loads l on l.id = i.load_id
  where i.load_id is not null and i.dispatch_id is not null
    and l.financial_dispatch_id is distinct from i.dispatch_id;
  if v_n <> 0 then
    raise exception '0126 postcondition: % load(s) with an invoice dispatch_id do not have financial_dispatch_id = that dispatch_id.', v_n;
  end if;

  -- R2 preservation: every load with a non-void load_pay dispatch_id and NO invoice dispatch_id now points at it
  select count(*) into v_n
  from public.loads l
  where l.financial_dispatch_id is distinct from (
          select distinct sli.dispatch_id
          from public.settlement_line_items sli
          join public.settlements s on s.id = sli.settlement_id
          where sli.load_id = l.id and sli.item_type = 'load_pay'
            and sli.dispatch_id is not null and s.status <> 'void')
    and exists (
          select 1 from public.settlement_line_items sli
          join public.settlements s on s.id = sli.settlement_id
          where sli.load_id = l.id and sli.item_type = 'load_pay'
            and sli.dispatch_id is not null and s.status <> 'void')
    and not exists (
          select 1 from public.invoices i
          where i.load_id = l.id and i.dispatch_id is not null);
  if v_n <> 0 then
    raise exception '0126 postcondition: % load(s) with a unique non-void load_pay dispatch_id (and no invoice dispatch_id) do not point at it.', v_n;
  end if;

  -- no auto-invoice-eligible undelivered dispatched load left unresolved
  select count(*) into v_n
  from public.loads l
  where l.status not in ('delivered','pod_received','invoiced','closed','cancelled')
    and (l.broker_id is not null or l.customer_id is not null)
    and exists (select 1 from public.dispatches d where d.load_id = l.id)
    and l.financial_dispatch_id is null;
  if v_n <> 0 then
    raise exception '0126 postcondition: % auto-invoice-eligible undelivered dispatched load(s) still have financial_dispatch_id = NULL.', v_n;
  end if;

  -- IMMUTABILITY: invoices.dispatch_id / load_id unchanged
  if exists (
    select 1 from public.invoices i
    join _mig0126_inv_snap s on s.id = i.id
    where i.dispatch_id is distinct from s.dispatch_id or i.load_id is distinct from s.load_id
  ) or (select count(*) from public.invoices) <> b.n_invoice then
    raise exception '0126 postcondition: an invoices row''s dispatch_id / load_id / count changed.';
  end if;

  -- IMMUTABILITY: settlement_line_items.dispatch_id / load_id unchanged
  if exists (
    select 1 from public.settlement_line_items sli
    join _mig0126_sli_snap s on s.id = sli.id
    where sli.dispatch_id is distinct from s.dispatch_id or sli.load_id is distinct from s.load_id
  ) or (select count(*) from public.settlement_line_items) <> b.n_sli then
    raise exception '0126 postcondition: a settlement_line_items row''s dispatch_id / load_id / count changed.';
  end if;

  -- IMMUTABILITY: settlements amounts/status unchanged
  if exists (
    select 1 from public.settlements st
    join _mig0126_settle_snap s on s.id = st.id
    where st.status <> s.status
       or st.gross_amount is distinct from s.gross_amount
       or st.adjustments_amount is distinct from s.adjustments_amount
       or st.deductions_amount is distinct from s.deductions_amount
       or st.advances_amount is distinct from s.advances_amount
       or st.quick_pay_fee_amount is distinct from s.quick_pay_fee_amount
       or st.net_amount is distinct from s.net_amount
       or st.amount_paid is distinct from s.amount_paid
       or st.balance_due is distinct from s.balance_due
  ) or (select count(*) from public.settlements) <> b.n_settlement then
    raise exception '0126 postcondition: a settlements row''s amount / status / count changed.';
  end if;

  -- No dispatch classified; Model A still off
  execute 'select count(*) from public.dispatches where proceeds_model is not null' into v_n;
  if v_n <> 0 then raise exception '0126 postcondition: % dispatch(es) have a non-NULL proceeds_model -- 0126 must not classify.', v_n; end if;
  if (select model_a_enabled from public.platform_settings where id = true) is not false then
    raise exception '0126 postcondition: platform_settings.model_a_enabled is not FALSE.';
  end if;

  -- Counts preserved
  if (select count(*) from public.organizations)              <> b.n_org             then raise exception '0126 postcondition: organizations count changed.'; end if;
  if (select count(*) from public.carriers)                   <> b.n_carrier         then raise exception '0126 postcondition: carriers count changed.'; end if;
  if (select count(*) from public.dispatches)                 <> b.n_dispatch        then raise exception '0126 postcondition: dispatches count changed.'; end if;
  if (select count(*) from public.loads)                      <> b.n_load            then raise exception '0126 postcondition: loads count changed.'; end if;
  if (select count(*) from public.invoice_line_items)         <> b.n_invoice_li      then raise exception '0126 postcondition: invoice_line_items count changed.'; end if;
  if (select count(*) from public.payments)                   <> b.n_payment         then raise exception '0126 postcondition: payments count changed.'; end if;
  if (select count(*) from public.carrier_settlement_payments) <> b.n_csp            then raise exception '0126 postcondition: carrier_settlement_payments count changed.'; end if;
  if (select count(*) from public.billing_records)            <> b.n_billing_records then raise exception '0126 postcondition: billing_records count changed.'; end if;
  if (select count(*) from public.organization_subscriptions) <> b.n_orgsub          then raise exception '0126 postcondition: organization_subscriptions count changed.'; end if;
  if (select count(*) from public.subscription_plans)         <> b.n_plan            then raise exception '0126 postcondition: subscription_plans count changed.'; end if;

  -- 0124 landmark + auto-invoice trigger untouched
  if not exists (select 1 from information_schema.columns
    where table_schema='public' and table_name='organization_subscriptions' and column_name='stripe_checkout_attempt_id') then
    raise exception '0126 postcondition: 0124 landmark disappeared.';
  end if;
  if (select pg_get_functiondef(to_regprocedure('public.auto_generate_invoice_from_delivered_load()'))) ilike '%financial_dispatch_id%' then
    raise exception '0126 postcondition: auto_generate_invoice_from_delivered_load() was changed to read financial_dispatch_id -- not this migration''s job.';
  end if;

  -- Set the "backfilled" comment marker (rerun guard for a SUCCESSFUL 0126).
  execute format(
    'comment on column public.loads.financial_dispatch_id is %L',
    'The dispatch that owns this load''s carrier-money accounting identity (Model A/B, carrier, fee %). '
    || 'Set for new loads by the dispatches AFTER INSERT trigger; legacy loads backfilled by migration 0126 on '
    || current_date::text || '. NULL = no dispatch / genuinely uncontrolled.'
  );

  raise notice '0126 complete: financial_dispatch_id assigned to % newly-backfilled load(s); total loads now controlled = %; % load(s) remain NULL (zero-dispatch / only-cancelled). No invoice/settlement/payment/dispatch data modified. Model A still disabled.',
    v_updated,
    (select count(*) from public.loads where financial_dispatch_id is not null),
    (select count(*) from public.loads where financial_dispatch_id is null);
end
$mig$;
