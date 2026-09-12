-- ============================================================================
-- ROLLBACK_0138_carrier_default_cutover_classifier_and_secured_rpcs.sql
--
-- Reverses 0138 ONLY: restores the organization-scoped default index and
-- 0072's original set_default_factoring_relationship()/guard_factoring_
-- company_deactivation() forms, drops classify_carrier_factoring_readiness
-- and approve_factoring_relationship_noa, and restores factoring_
-- relationships' original (0071) blanket UPDATE grant to authenticated.
--
-- IMPORTANT: restoring the org-scoped index means the SAME "one default per
-- organization" invariant 0071 originally enforced returns -- if, at
-- rollback time, two DIFFERENT carriers in the same organization each have
-- their own active default (entirely valid and expected after 0138 has
-- been live), creating the org-scoped index will FAIL with a unique-
-- violation. This script detects that up front and aborts with a clear
-- message rather than leaving the database in a half-migrated state; you
-- must first ensure at most one active default relationship exists
-- org-wide (e.g. by deactivating all but one) before this rollback can
-- succeed structurally -- this is disclosed, not silently handled.
--
-- IMPORTANT: restoring the original blanket UPDATE grant re-opens direct
-- authenticated UPDATE to carrier_id/is_default/NOA/remittance fields --
-- exactly the tampering surface 0138 exists to close. Only run this
-- rollback if 0138 itself must be reversed, and re-apply promptly.
--
-- STRUCTURE: explicit BEGIN/COMMIT.
-- ============================================================================

begin;

do $rb$
begin
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then
    raise exception 'ROLLBACK 0138 precondition: classify_carrier_factoring_readiness(...) does not exist -- 0138 was never applied, or already rolled back. STOP.';
  end if;
  if exists (
    select 1 from public.factoring_relationships
    where is_default and is_active and carrier_id is not null
    group by organization_id having count(distinct carrier_id) > 1
  ) then
    raise exception 'ROLLBACK 0138 ABORT: at least one organization currently has more than one carrier with its own active default relationship -- restoring the organization-scoped uniqueness index would fail with a unique-violation. Deactivate all but one active default org-wide before retrying this rollback. STOP.';
  end if;
end
$rb$;

-- Restore the org-scoped index BEFORE dropping the carrier-scoped one --
-- mirrors the forward migration's own "create new, then drop old" discipline
-- in reverse, so there is never a window with neither invariant enforced.
create unique index factoring_relationships_one_default_per_org
  on public.factoring_relationships (organization_id)
  where is_default and is_active;

drop index public.factoring_relationships_one_default_per_carrier;

drop function if exists public.approve_factoring_relationship_noa(uuid, text, date, text, uuid);
drop function if exists public.classify_carrier_factoring_readiness(uuid, uuid, uuid);

-- Restore set_default_factoring_relationship() to its exact 0072 form
-- (org-scoped lock, INVOKER, owner/admin/dispatcher/accountant, returns
-- void). 0138's version returns jsonb -- Postgres cannot CREATE OR REPLACE
-- a function into a different return type, so it is dropped first.
drop function if exists public.set_default_factoring_relationship(uuid);

create or replace function public.set_default_factoring_relationship(p_relationship_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_relationship record;
  v_company_active boolean;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to change factoring settings.';
  end if;

  perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || v_org_id::text));

  select id, organization_id, factoring_company_id, is_active
    into v_relationship
  from public.factoring_relationships
  where id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;

  if not v_relationship.is_active then
    raise exception 'This factoring relationship is inactive.';
  end if;

  select is_active into v_company_active from public.factoring_companies where id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'This factoring relationship''s factoring company is inactive.';
  end if;

  update public.factoring_relationships
  set is_default = false
  where organization_id = v_org_id and is_default = true and id <> p_relationship_id;

  update public.factoring_relationships
  set is_default = true
  where id = p_relationship_id;
end;
$$;

grant execute on function public.set_default_factoring_relationship(uuid) to authenticated;

-- Restore guard_factoring_company_deactivation() to its exact 0072 form
-- (org-scoped lock).
create or replace function public.guard_factoring_company_deactivation()
returns trigger
language plpgsql
as $$
declare
  v_has_active_default boolean;
begin
  if old.is_active and not new.is_active then
    perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || old.organization_id::text));

    select exists (
      select 1 from public.factoring_relationships
      where factoring_company_id = old.id and is_active = true and is_default = true
    ) into v_has_active_default;

    if v_has_active_default then
      raise exception 'This factoring company cannot be deactivated while one of its relationships is the default. Choose another default relationship first.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists factoring_companies_guard_deactivation on public.factoring_companies;
create trigger factoring_companies_guard_deactivation
  before update of is_active on public.factoring_companies
  for each row execute function public.guard_factoring_company_deactivation();

-- Restore 0071's original blanket UPDATE grant.
revoke update on public.factoring_relationships from authenticated;
grant update on public.factoring_relationships to authenticated;

do $rb$
begin
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then
    raise exception 'ROLLBACK 0138 postcondition: classify_carrier_factoring_readiness(...) still exists.';
  end if;
  if to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)') is not null then
    raise exception 'ROLLBACK 0138 postcondition: approve_factoring_relationship_noa(...) still exists.';
  end if;
  if not exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_org') then
    raise exception 'ROLLBACK 0138 postcondition: factoring_relationships_one_default_per_org index missing.';
  end if;
  if exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_carrier') then
    raise exception 'ROLLBACK 0138 postcondition: factoring_relationships_one_default_per_carrier index still exists.';
  end if;
  if not has_table_privilege('authenticated','public.factoring_relationships','UPDATE') then
    raise exception 'ROLLBACK 0138 postcondition: authenticated does not hold the restored table-level UPDATE grant.';
  end if;
  raise notice 'ROLLBACK 0138 complete: organization-scoped default index restored; classify_carrier_factoring_readiness/approve_factoring_relationship_noa removed; set_default_factoring_relationship()/guard_factoring_company_deactivation() restored to their 0072 (org-scoped) forms; factoring_relationships'' original blanket UPDATE grant restored. 0136''s columns/triggers and 0137''s carrier_id/provenance remain untouched -- roll those back separately if needed.';
end
$rb$;

commit;
