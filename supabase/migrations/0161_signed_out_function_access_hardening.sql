-- ============================================================================
-- 0161_signed_out_function_access_hardening.sql
--
-- Found by a production audit of which functions the signed-out role (anon)
-- can execute. PostgreSQL grants EXECUTE on every new function to PUBLIC,
-- and Supabase additionally grants it to anon / authenticated /
-- service_role. Several migrations assumed "not granted" meant "not
-- callable". Anyone holding the public anon key (it ships in the browser)
-- can call any such function through the REST API (/rest/v1/rpc/...).
--
-- 1. get_app_encryption_key(text) (0014) returned the master key that
--    encrypts driver SSNs, bank/routing numbers, TINs and QuickBooks
--    tokens -- to ANYONE. Every legitimate caller is another SECURITY
--    DEFINER function owned by the same owner, so revoking EXECUTE from
--    every client role breaks nothing.
-- 2. deduct_pending_advances_into_settlement / _into_invoice (0013) had no
--    caller check at all: any caller holding a settlement/invoice id could
--    add deduction lines to another organization's document. Now: same
--    organization only (a foreign id reads as "not found") and a role
--    that may change advances (owner/admin/accountant/dispatcher, the
--    dispatch_advances_update set). The rest of each body is unchanged.
-- 3. Server-only functions are no longer callable by signed-in or
--    signed-out users: verify_driver_portal_login and
--    submit_driver_application (the app calls both with the service role
--    only), refresh_compliance_statuses and sync_time_based_exceptions
--    (pg_cron runs them as the owner).
-- 4. Signed-out (anon) EXECUTE is removed from EVERY public SECURITY
--    DEFINER function, except the read-only identity helpers used inside
--    RLS policies (they return null/false for a signed-out caller).
--    Signed-in (authenticated) and service_role access is preserved
--    exactly as it was, except for the functions in 1 and 3.
--
-- Trigger functions are not touched (EXECUTE is not checked when a trigger
-- fires). Invoker functions are not touched (they run with the caller's
-- own table privileges and RLS).
--
-- Safe to re-run. One transaction: on any failed check nothing changes.
-- ============================================================================

begin;

-- 0 -- preconditions ---------------------------------------------------------
do $pre$
begin
  if to_regprocedure('public.get_app_encryption_key(text)') is null
     or to_regprocedure('public.deduct_pending_advances_into_settlement(uuid)') is null
     or to_regprocedure('public.deduct_pending_advances_into_invoice(uuid)') is null
     or to_regprocedure('public.verify_driver_portal_login(text,text)') is null
     or to_regprocedure('public.refresh_compliance_statuses()') is null
     or to_regprocedure('public.sync_time_based_exceptions()') is null
     or to_regprocedure('public.current_org_id()') is null
     or to_regprocedure('public.has_role(public.org_role[])') is null then
    raise exception '0161 precondition: an expected function is missing. STOP -- nothing was changed.';
  end if;
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'submit_driver_application') <> 1 then
    raise exception '0161 precondition: expected exactly one submit_driver_application. STOP -- nothing was changed.';
  end if;
end $pre$;

-- 2 -- caller checks on the advance-deduction functions -----------------------
create or replace function public.deduct_pending_advances_into_settlement(p_settlement_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_carrier_id uuid;
  v_count integer := 0;
  v_advance record;
  v_next_sort integer;
begin
  select organization_id, carrier_id into v_org_id, v_carrier_id
  from public.settlements where id = p_settlement_id;

  -- 0161: the target must belong to the caller's own organization (a foreign
  -- row is reported exactly like a missing one), and the caller must hold a
  -- role that may change advances (same set as dispatch_advances_update).
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    raise exception 'Settlement % not found', p_settlement_id;
  end if;
  if not public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to deduct advances.' using errcode = '42501';
  end if;

  select coalesce(max(sort_order), 0) + 1 into v_next_sort
  from public.settlement_line_items where settlement_id = p_settlement_id;

  for v_advance in
    select * from public.dispatch_advances
    where carrier_id = v_carrier_id
      and organization_id = v_org_id
      and status = 'pending'
    order by paid_date
  loop
    insert into public.settlement_line_items (organization_id, settlement_id, description, item_type, amount, sort_order)
    values (
      v_org_id,
      p_settlement_id,
      'Advance -- ' || replace(v_advance.expense_type::text, '_', ' ') ||
        case when v_advance.description is not null then ': ' || v_advance.description else '' end,
      'deduction',
      v_advance.amount,
      v_next_sort
    );

    update public.dispatch_advances
    set status = 'deducted', deducted_settlement_id = p_settlement_id
    where id = v_advance.id;

    v_count := v_count + 1;
    v_next_sort := v_next_sort + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.deduct_pending_advances_into_invoice(p_invoice_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_carrier_id uuid;
  v_count integer := 0;
  v_advance record;
  v_next_sort integer;
begin
  select i.organization_id, d.carrier_id into v_org_id, v_carrier_id
  from public.invoices i
  left join public.dispatches d on d.id = i.dispatch_id
  where i.id = p_invoice_id;

  -- 0161: the target must belong to the caller's own organization (a foreign
  -- row is reported exactly like a missing one), and the caller must hold a
  -- role that may change advances (same set as dispatch_advances_update).
  if v_org_id is null or v_org_id is distinct from public.current_org_id() then
    raise exception 'Invoice % not found', p_invoice_id;
  end if;
  if not public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to deduct advances.' using errcode = '42501';
  end if;

  if v_carrier_id is null then
    return 0;
  end if;

  select coalesce(max(sort_order), 0) + 1 into v_next_sort
  from public.invoice_line_items where invoice_id = p_invoice_id;

  for v_advance in
    select * from public.dispatch_advances
    where carrier_id = v_carrier_id
      and organization_id = v_org_id
      and status = 'pending'
    order by paid_date
  loop
    insert into public.invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, sort_order)
    values (
      v_org_id,
      p_invoice_id,
      'Advance deduction -- ' || replace(v_advance.expense_type::text, '_', ' ') ||
        case when v_advance.description is not null then ': ' || v_advance.description else '' end,
      1,
      -v_advance.amount,
      v_next_sort
    );

    update public.dispatch_advances
    set status = 'deducted', deducted_invoice_id = p_invoice_id
    where id = v_advance.id;

    v_count := v_count + 1;
    v_next_sort := v_next_sort + 1;
  end loop;

  return v_count;
end;
$$;

-- 1 + 3 + 4 -- execute privileges -------------------------------------------
create temp table _mig0161_lockdown (oid oid primary key) on commit drop;
insert into _mig0161_lockdown
select oid from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('get_app_encryption_key', 'verify_driver_portal_login', 'submit_driver_application',
                  'refresh_compliance_statuses', 'sync_time_based_exceptions');

create temp table _mig0161_anon_keep (oid oid primary key) on commit drop;
insert into _mig0161_anon_keep
select oid from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('current_org_id', 'current_role', 'has_role', 'is_platform_admin',
                  'carrier_ids_authorized_for_current_user', 'carrier_ids_selectable_for_new_records');

do $acl$
declare
  r record;
  v_auth boolean;
  v_sr boolean;
  v_n integer := 0;
begin
  for r in
    select p.oid, p.oid::regprocedure::text as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
      and p.proowner = (select oid from pg_roles where rolname = current_user)
      and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
      and not exists (select 1 from _mig0161_anon_keep k where k.oid = p.oid)
      and (has_function_privilege('anon', p.oid, 'execute') or exists (select 1 from _mig0161_lockdown l where l.oid = p.oid))
  loop
    v_auth := has_function_privilege('authenticated', r.oid, 'execute');
    v_sr := has_function_privilege('service_role', r.oid, 'execute');
    execute format('revoke execute on function %s from public, anon', r.sig);
    if exists (select 1 from _mig0161_lockdown l where l.oid = r.oid) then
      execute format('revoke execute on function %s from authenticated', r.sig);
      if r.sig = 'get_app_encryption_key(text)' then
        execute format('revoke execute on function %s from service_role', r.sig);
      elsif v_sr then
        execute format('grant execute on function %s to service_role', r.sig);
      end if;
    else
      if v_auth then execute format('grant execute on function %s to authenticated', r.sig); end if;
      if v_sr then execute format('grant execute on function %s to service_role', r.sig); end if;
    end if;
    v_n := v_n + 1;
  end loop;
  raise notice '0161: execute privileges tightened on % function(s).', v_n;
end $acl$;

-- 5 -- postconditions --------------------------------------------------------
do $post$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v_bad
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prosecdef
    and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
    and p.proowner = (select oid from pg_roles where rolname = current_user)
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
    and not exists (select 1 from _mig0161_anon_keep k where k.oid = p.oid)
    and has_function_privilege('anon', p.oid, 'execute');
  if v_bad is not null then raise exception '0161 postcondition: still executable when signed out: %', v_bad; end if;

  select string_agg(l.oid::regprocedure::text, ', ') into v_bad
  from _mig0161_lockdown l
  where has_function_privilege('anon', l.oid, 'execute') or has_function_privilege('authenticated', l.oid, 'execute');
  if v_bad is not null then raise exception '0161 postcondition: server-only function still client-callable: %', v_bad; end if;

  if has_function_privilege('service_role', 'public.get_app_encryption_key(text)'::regprocedure, 'execute') then
    raise exception '0161 postcondition: get_app_encryption_key is still executable by service_role.';
  end if;

  if not has_function_privilege('authenticated', 'public.deduct_pending_advances_into_invoice(uuid)'::regprocedure, 'execute')
     or not has_function_privilege('authenticated', 'public.reveal_driver_pii(uuid,text,text)'::regprocedure, 'execute')
     or not has_function_privilege('authenticated', 'public.create_organization_with_owner(text,text)'::regprocedure, 'execute') then
    raise exception '0161 postcondition: a signed-in app function lost its access.';
  end if;

  if position('current_org_id' in (select prosrc from pg_proc where oid = 'public.deduct_pending_advances_into_invoice(uuid)'::regprocedure)) = 0
     or position('current_org_id' in (select prosrc from pg_proc where oid = 'public.deduct_pending_advances_into_settlement(uuid)'::regprocedure)) = 0 then
    raise exception '0161 postcondition: advance-deduction caller checks missing.';
  end if;
end $post$;

commit;

-- Rollback (only if ever needed): re-run the two deduct_* definitions from
-- 0013_*.sql, and `grant execute on function ... to anon` for any function
-- that turns out to need signed-out access (none is known). Never re-grant
-- get_app_encryption_key to any client role.
