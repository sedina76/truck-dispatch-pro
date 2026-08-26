-- =============================================================================
-- 0093_broker_management_foundation.sql
-- Phase 2M.1: professional broker profiles, contacts, archive, and safe delete.
-- =============================================================================

create type public.broker_operational_status as enum (
  'prospect', 'setup_pending', 'active', 'inactive', 'do_not_use'
);

create type public.broker_onboarding_status as enum (
  'not_started', 'collecting', 'ready', 'complete'
);

create type public.broker_credit_status as enum (
  'review', 'approved', 'hold', 'do_not_use'
);

create type public.broker_contact_type as enum (
  'general', 'dispatch', 'accounting', 'carrier_setup',
  'claims', 'after_hours', 'management'
);

alter table public.brokers
  add column legal_name text,
  add column dba_name text,
  add column dot_number text,
  add column website text,
  add column status public.broker_operational_status not null default 'prospect',
  add column onboarding_status public.broker_onboarding_status not null default 'not_started',
  add column archived_at timestamptz,
  add column archived_by uuid references public.profiles(id) on delete set null,
  add constraint brokers_archive_shape check (archived_at is not null or archived_by is null);

update public.brokers
set legal_name = company_name,
    status = case when is_blacklisted then 'do_not_use'::public.broker_operational_status
                  else 'active'::public.broker_operational_status end;

alter table public.brokers alter column legal_name set not null;

alter table public.broker_financials
  add column credit_status public.broker_credit_status not null default 'review',
  add column credit_limit numeric(12,2) check (credit_limit is null or credit_limit >= 0),
  add column payment_method public.payment_method,
  add column financial_notes text;

drop policy if exists broker_financials_update on public.broker_financials;
create policy broker_financials_update on public.broker_financials for update
  using (organization_id=public.current_org_id()
    and public.has_role(array['owner','admin','accountant']::public.org_role[]))
  with check (organization_id=public.current_org_id());

create or replace function public.guard_broker_archive_boundary()
returns trigger language plpgsql set search_path=public as $$
begin
  if (new.archived_at,new.archived_by) is distinct from (old.archived_at,old.archived_by)
    and current_user not in ('postgres','supabase_admin') then
    raise exception 'Broker archive state may only change through the trusted workflow.';
  end if;
  return new;
end;
$$;
create trigger brokers_archive_boundary_guard
  before update of archived_at,archived_by on public.brokers
  for each row execute function public.guard_broker_archive_boundary();

create table public.broker_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  broker_id uuid not null references public.brokers(id) on delete cascade,
  contact_type public.broker_contact_type not null default 'general',
  name text not null check (btrim(name) <> ''),
  title text,
  department text,
  email text,
  phone text,
  extension text,
  is_primary boolean not null default false,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index broker_contacts_one_primary_per_type_idx
  on public.broker_contacts(broker_id, contact_type) where is_primary;
create index broker_contacts_org_broker_idx
  on public.broker_contacts(organization_id, broker_id, contact_type);

create trigger set_updated_at before update on public.broker_contacts
  for each row execute function public.set_updated_at();

create or replace function public.guard_broker_contact_organization()
returns trigger language plpgsql set search_path = public as $$
declare v_broker_org uuid;
begin
  select organization_id into v_broker_org from public.brokers where id = new.broker_id;
  if v_broker_org is null or v_broker_org <> new.organization_id then
    raise exception 'Broker contact must belong to the broker organization.';
  end if;
  return new;
end;
$$;

create trigger broker_contacts_organization_guard
  before insert or update on public.broker_contacts
  for each row execute function public.guard_broker_contact_organization();

insert into public.broker_contacts (
  organization_id, broker_id, contact_type, name, email, phone, is_primary
)
select organization_id, id, 'general',
  coalesce(nullif(btrim(contact_name), ''), nullif(btrim(email), ''), nullif(btrim(phone), '')),
  email, phone, true
from public.brokers
where nullif(btrim(contact_name), '') is not null
   or nullif(btrim(email), '') is not null
   or nullif(btrim(phone), '') is not null;

alter table public.broker_contacts enable row level security;
create policy broker_contacts_select on public.broker_contacts for select
  using (organization_id = public.current_org_id());
create policy broker_contacts_insert on public.broker_contacts for insert
  with check (organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher']::public.org_role[]));
create policy broker_contacts_update on public.broker_contacts for update
  using (organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher']::public.org_role[]))
  with check (organization_id = public.current_org_id());
create policy broker_contacts_delete on public.broker_contacts for delete
  using (organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher']::public.org_role[]));

grant select on public.broker_contacts to authenticated;
grant insert, update, delete on public.broker_contacts to authenticated;

create or replace function public.save_broker_contact(
  p_broker_id uuid, p_contact_id uuid, p_contact_type public.broker_contact_type,
  p_name text, p_title text, p_department text, p_email text, p_phone text,
  p_extension text, p_is_primary boolean, p_notes text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_broker public.brokers; v_id uuid;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to manage broker contacts.';
  end if;
  select * into v_broker from public.brokers where id = p_broker_id for update;
  if v_broker.id is null or v_broker.organization_id <> public.current_org_id() then
    raise exception 'Broker not found in your organization.';
  end if;
  if nullif(btrim(p_name), '') is null then raise exception 'Contact name is required.'; end if;
  if p_is_primary then
    update public.broker_contacts set is_primary = false
    where broker_id = p_broker_id and contact_type = p_contact_type
      and (p_contact_id is null or id <> p_contact_id) and is_primary;
  end if;
  if p_contact_id is null then
    insert into public.broker_contacts (
      organization_id, broker_id, contact_type, name, title, department,
      email, phone, extension, is_primary, notes
    ) values (
      v_broker.organization_id, p_broker_id, p_contact_type, btrim(p_name),
      nullif(btrim(p_title),''), nullif(btrim(p_department),''), nullif(btrim(p_email),''),
      nullif(btrim(p_phone),''), nullif(btrim(p_extension),''), p_is_primary, nullif(btrim(p_notes),'')
    ) returning id into v_id;
  else
    update public.broker_contacts set
      contact_type=p_contact_type, name=btrim(p_name), title=nullif(btrim(p_title),''),
      department=nullif(btrim(p_department),''), email=nullif(btrim(p_email),''),
      phone=nullif(btrim(p_phone),''), extension=nullif(btrim(p_extension),''),
      is_primary=p_is_primary, notes=nullif(btrim(p_notes),'')
    where id=p_contact_id and broker_id=p_broker_id and organization_id=v_broker.organization_id
    returning id into v_id;
    if v_id is null then raise exception 'Broker contact not found.'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.delete_broker_contact(p_broker_id uuid, p_contact_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_broker public.brokers;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to manage broker contacts.';
  end if;
  select * into v_broker from public.brokers where id=p_broker_id for update;
  if v_broker.id is null or v_broker.organization_id <> public.current_org_id() then
    raise exception 'Broker not found in your organization.';
  end if;
  delete from public.broker_contacts where id=p_contact_id and broker_id=p_broker_id;
  if not found then raise exception 'Broker contact not found.'; end if;
end;
$$;

create or replace function public.archive_broker(p_broker_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'Only owners and admins may archive brokers.';
  end if;
  update public.brokers set archived_at=now(), archived_by=auth.uid()
  where id=p_broker_id and organization_id=public.current_org_id() and archived_at is null;
  if not found then raise exception 'Broker not found in your organization.'; end if;
  perform public.log_activity('broker'::public.entity_type,p_broker_id,'broker_archived',null);
end;
$$;

create or replace function public.restore_broker(p_broker_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'Only owners and admins may restore brokers.';
  end if;
  update public.brokers set archived_at=null, archived_by=null
  where id=p_broker_id and organization_id=public.current_org_id() and archived_at is not null;
  if not found then raise exception 'Broker not found in your organization.'; end if;
  perform public.log_activity('broker'::public.entity_type,p_broker_id,'broker_restored',null);
end;
$$;

create or replace function public.delete_broker_safely(p_broker_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_broker public.brokers; v_blocked boolean;
begin
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'You do not have permission to permanently delete brokers.';
  end if;
  select * into v_broker from public.brokers where id=p_broker_id for update;
  if v_broker.id is null or v_broker.organization_id <> public.current_org_id() then
    raise exception 'Broker not found in your organization.';
  end if;
  select exists(select 1 from public.loads where broker_id=p_broker_id)
    or exists(select 1 from public.invoices where broker_id=p_broker_id)
    or exists(select 1 from public.documents where entity_type='broker' and entity_id=p_broker_id)
    or exists(select 1 from public.statements where broker_id=p_broker_id)
    or exists(select 1 from public.carrier_setup_packages where broker_id=p_broker_id)
    or exists(select 1 from public.email_send_log where broker_id=p_broker_id)
  into v_blocked;
  if v_blocked then
    return jsonb_build_object('deletion_status','not_deletable','message',
      'This broker has operational or financial history and cannot be permanently deleted. Archive the broker instead.');
  end if;
  perform public.log_activity('broker'::public.entity_type,p_broker_id,'broker_deleted',jsonb_build_object('broker_id',p_broker_id));
  delete from public.brokers where id=p_broker_id;
  return jsonb_build_object('deletion_status','deleted');
end;
$$;

revoke execute on function public.save_broker_contact(uuid,uuid,public.broker_contact_type,text,text,text,text,text,text,boolean,text) from public,anon;
revoke execute on function public.delete_broker_contact(uuid,uuid) from public,anon;
revoke execute on function public.archive_broker(uuid) from public,anon;
revoke execute on function public.restore_broker(uuid) from public,anon;
revoke execute on function public.delete_broker_safely(uuid) from public,anon;
grant execute on function public.save_broker_contact(uuid,uuid,public.broker_contact_type,text,text,text,text,text,text,boolean,text) to authenticated;
grant execute on function public.delete_broker_contact(uuid,uuid) to authenticated;
grant execute on function public.archive_broker(uuid) to authenticated;
grant execute on function public.restore_broker(uuid) to authenticated;
grant execute on function public.delete_broker_safely(uuid) to authenticated;

comment on table public.broker_contacts is 'Organization-isolated operational contacts for a broker; one primary contact is allowed per contact type.';
comment on function public.delete_broker_safely(uuid) is 'Owner/admin-only UUID-scoped broker deletion that refuses to detach operational, financial, document, setup-package, or statement history.';

-- Read-only preflight: all queries should return zero rows before apply.
-- select id from public.brokers where company_name is null or btrim(company_name)='';
-- select b.id from public.brokers b left join public.organizations o on o.id=b.organization_id where o.id is null;
-- select broker_id,count(*) from public.broker_financials group by broker_id having count(*)>1;
