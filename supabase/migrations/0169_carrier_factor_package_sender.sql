-- ============================================================================
-- 0169_carrier_factor_package_sender.sql
--
-- Owner decision (2026-10-02): for a carrier the broker pays directly, who
-- sends the paperwork (the carrier's invoice + rate confirmation, BOL, POD)
-- to the carrier's factoring company -- or to the broker when the carrier
-- doesn't factor -- is set per carrier:
--   'dispatcher' (default): we send it for the carrier;
--   'carrier'             : we send the package to the carrier, who submits it.
-- Changed only through set_carrier_factor_package_sender (owner/admin/accountant).
-- One transaction; safe to re-run.
-- ============================================================================

begin;

alter table public.carriers add column if not exists factor_package_sent_by text not null default 'dispatcher';
alter table public.carriers drop constraint if exists carriers_factor_package_sent_by_check;
alter table public.carriers add constraint carriers_factor_package_sent_by_check check (factor_package_sent_by in ('dispatcher', 'carrier'));

create or replace function public.guard_carrier_factor_package_sender_change()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.factor_package_sent_by is distinct from old.factor_package_sent_by
     and coalesce(current_setting('app.carrier_factor_sender_change', true), '') <> 'on' then
    raise exception 'Use the carrier''s "Who sends the paperwork?" setting to change this.' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists carriers_guard_factor_package_sender on public.carriers;
create trigger carriers_guard_factor_package_sender before update of factor_package_sent_by on public.carriers
  for each row execute function public.guard_carrier_factor_package_sender_change();

create or replace function public.set_carrier_factor_package_sender(p_carrier_id uuid, p_sender text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_org uuid := public.current_org_id(); v_old text;
begin
  if auth.uid() is null or v_org is null then raise exception 'You must be signed in.' using errcode = '42501'; end if;
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    raise exception 'Only an owner, admin or accountant can change who sends the paperwork.' using errcode = '42501';
  end if;
  if p_sender is null or p_sender not in ('dispatcher', 'carrier') then raise exception 'Choose who sends the paperwork.'; end if;
  select factor_package_sent_by into v_old from public.carriers where id = p_carrier_id and organization_id = v_org for update;
  if not found then raise exception 'Carrier not found.'; end if;
  if v_old = p_sender then return; end if;
  perform set_config('app.carrier_factor_sender_change', 'on', true);
  update public.carriers set factor_package_sent_by = p_sender where id = p_carrier_id;
  perform set_config('app.carrier_factor_sender_change', '', true);
  perform public.log_activity('carrier'::public.entity_type, p_carrier_id, 'factor_package_sender_changed',
    jsonb_build_object('from', v_old, 'to', p_sender), v_org);
end $$;
revoke all on function public.set_carrier_factor_package_sender(uuid, text) from public, anon;
grant execute on function public.set_carrier_factor_package_sender(uuid, text) to authenticated;

do $post$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'carriers' and column_name = 'factor_package_sent_by') then
    raise exception '0169 postcondition: column missing.';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'carriers_guard_factor_package_sender' and not tgisinternal) then
    raise exception '0169 postcondition: guard missing.';
  end if;
end $post$;

commit;
