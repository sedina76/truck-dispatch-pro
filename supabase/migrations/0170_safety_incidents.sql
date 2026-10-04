-- ============================================================================
-- 0170_safety_incidents.sql
--
-- Safety: one simple record per incident -- driver, truck, date, place,
-- type (accident, citation, cargo claim, inspection violation), cost,
-- notes and photos -- so every driver and truck has a safety history.
--
--   * safety_incidents: the record itself. Driver, truck and load are
--     optional (a cargo claim may have no driver yet) but must belong to the
--     same organization (guard trigger).
--   * Photos / papers reuse the existing documents table + load-documents
--     bucket (entity_type 'safety_incident', document_type 'incident_photo').
--   * Who can do what: office staff read; owner/admin/dispatcher/accountant
--     add and edit; owner/admin delete. Drivers (driver-portal accounts)
--     cannot read other drivers' incidents.
--
-- Safe to re-run. The two enum values are added first, outside the main
-- transaction (Postgres needs a new enum value committed before use).
-- ============================================================================

alter type public.entity_type add value if not exists 'safety_incident';
alter type public.document_type add value if not exists 'incident_photo';

begin;

create table if not exists public.safety_incidents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  incident_type text not null,
  occurred_on date not null,
  location text,
  driver_id uuid references public.drivers (id) on delete set null,
  truck_id uuid references public.trucks (id) on delete set null,
  load_id uuid references public.loads (id) on delete set null,
  description text,
  cost numeric(12, 2) not null default 0,
  status text not null default 'open',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.safety_incidents drop constraint if exists safety_incidents_type_check;
alter table public.safety_incidents add constraint safety_incidents_type_check
  check (incident_type in ('accident', 'citation', 'cargo_claim', 'inspection_violation'));
alter table public.safety_incidents drop constraint if exists safety_incidents_status_check;
alter table public.safety_incidents add constraint safety_incidents_status_check
  check (status in ('open', 'closed'));
alter table public.safety_incidents drop constraint if exists safety_incidents_cost_check;
alter table public.safety_incidents add constraint safety_incidents_cost_check check (cost >= 0);
alter table public.safety_incidents drop constraint if exists safety_incidents_location_len;
alter table public.safety_incidents add constraint safety_incidents_location_len check (char_length(location) <= 300);
alter table public.safety_incidents drop constraint if exists safety_incidents_description_len;
alter table public.safety_incidents add constraint safety_incidents_description_len check (char_length(description) <= 5000);

create index if not exists idx_safety_incidents_org_date on public.safety_incidents (organization_id, occurred_on desc);
create index if not exists idx_safety_incidents_driver on public.safety_incidents (driver_id) where driver_id is not null;
create index if not exists idx_safety_incidents_truck on public.safety_incidents (truck_id) where truck_id is not null;
create index if not exists idx_safety_incidents_load on public.safety_incidents (load_id) where load_id is not null;

-- Driver, truck and load must be this organization's own; the organization
-- itself never changes after the record is made.
create or replace function public.guard_safety_incident()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
begin
  if tg_op = 'UPDATE' and new.organization_id is distinct from old.organization_id then
    raise exception 'An incident cannot move to another organization.' using errcode = '42501';
  end if;
  if new.driver_id is not null and not exists (select 1 from public.drivers where id = new.driver_id and organization_id = new.organization_id) then
    raise exception 'That driver does not belong to this organization.' using errcode = '23514';
  end if;
  if new.truck_id is not null and not exists (select 1 from public.trucks where id = new.truck_id and organization_id = new.organization_id) then
    raise exception 'That truck does not belong to this organization.' using errcode = '23514';
  end if;
  if new.load_id is not null and not exists (select 1 from public.loads where id = new.load_id and organization_id = new.organization_id) then
    raise exception 'That load does not belong to this organization.' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' then
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists safety_incidents_guard on public.safety_incidents;
create trigger safety_incidents_guard before insert or update on public.safety_incidents
  for each row execute function public.guard_safety_incident();

alter table public.safety_incidents enable row level security;

drop policy if exists safety_incidents_select on public.safety_incidents;
create policy safety_incidents_select on public.safety_incidents for select using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant', 'viewer']::public.org_role[])
);
drop policy if exists safety_incidents_insert on public.safety_incidents;
create policy safety_incidents_insert on public.safety_incidents for insert with check (
  organization_id = public.current_org_id()
  and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
);
drop policy if exists safety_incidents_update on public.safety_incidents;
create policy safety_incidents_update on public.safety_incidents for update using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
) with check (organization_id = public.current_org_id());
drop policy if exists safety_incidents_delete on public.safety_incidents;
create policy safety_incidents_delete on public.safety_incidents for delete using (
  organization_id = public.current_org_id()
  and public.has_role(array['owner', 'admin']::public.org_role[])
);

revoke all on function public.guard_safety_incident() from public, anon, authenticated;
revoke all on public.safety_incidents from anon, authenticated;
grant select, insert, update, delete on public.safety_incidents to authenticated;

commit;
