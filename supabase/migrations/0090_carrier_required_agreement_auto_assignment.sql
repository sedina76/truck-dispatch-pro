-- =============================================================================
-- 0090_carrier_required_agreement_auto_assignment.sql
-- Phase 2L.7: frozen per-application required agreement families.
-- =============================================================================

alter table public.carrier_onboarding_applications
  add column agreement_requirements_initialized_at timestamptz,
  add column agreement_requirements_initialized_by uuid
    references public.profiles(id) on delete set null,
  add constraint carrier_onboarding_applications_agreement_requirement_initialization_shape check (
    agreement_requirements_initialized_at is not null
    or agreement_requirements_initialized_by is null
  );

create or replace function public.guard_carrier_onboarding_agreement_requirement_initialization()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.agreement_requirements_initialized_at is not null then
    if new.agreement_requirements_initialized_at is distinct from old.agreement_requirements_initialized_at then
      raise exception 'Agreement requirement initialization cannot be changed or removed.';
    end if;
    if new.agreement_requirements_initialized_by is distinct from old.agreement_requirements_initialized_by
      and new.agreement_requirements_initialized_by is not null then
      raise exception 'Agreement requirement initialization attribution cannot be replaced.';
    end if;
  elsif new.agreement_requirements_initialized_at is not null then
    if current_user not in ('postgres', 'supabase_admin') then
      raise exception 'Agreement requirements may only be initialized through the trusted workflow.';
    end if;
    if new.agreement_requirements_initialized_by is null then
      raise exception 'Agreement requirement initialization requires an initiating staff profile.';
    end if;
  elsif new.agreement_requirements_initialized_by is not null then
    raise exception 'Agreement requirement initialization attribution requires an initialization timestamp.';
  end if;
  return new;
end;
$$;

create trigger carrier_onboarding_applications_agreement_requirement_initialization_guard
  before update of agreement_requirements_initialized_at, agreement_requirements_initialized_by
  on public.carrier_onboarding_applications
  for each row execute function public.guard_carrier_onboarding_agreement_requirement_initialization();

create table public.carrier_onboarding_agreement_requirements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  onboarding_application_id uuid not null references public.carrier_onboarding_applications(id) on delete restrict,
  template_key text not null check (btrim(template_key) <> ''),
  initial_template_id uuid not null references public.carrier_agreement_templates(id) on delete restrict,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  unique (onboarding_application_id, template_key)
);

create index carrier_onboarding_agreement_requirements_org_application_idx
  on public.carrier_onboarding_agreement_requirements (organization_id, onboarding_application_id);

create or replace function public.guard_carrier_onboarding_agreement_requirement_relationships()
returns trigger language plpgsql set search_path = public as $$
declare
  v_application_org uuid;
  v_template_org uuid;
  v_template_key text;
begin
  select organization_id into v_application_org
  from public.carrier_onboarding_applications where id = new.onboarding_application_id;
  select organization_id, template_key into v_template_org, v_template_key
  from public.carrier_agreement_templates where id = new.initial_template_id;
  if v_application_org is null or v_application_org <> new.organization_id then
    raise exception 'Agreement requirement organization must match its application.';
  end if;
  if v_template_org is null or v_template_org <> new.organization_id
    or v_template_key is distinct from new.template_key then
    raise exception 'Agreement requirement initial template must match its organization and logical key.';
  end if;
  return new;
end;
$$;

create trigger carrier_onboarding_agreement_requirements_relationship_guard
  before insert on public.carrier_onboarding_agreement_requirements
  for each row execute function public.guard_carrier_onboarding_agreement_requirement_relationships();

create or replace function public.guard_carrier_onboarding_agreement_requirement_immutability()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Frozen onboarding agreement requirements cannot be deleted.';
  end if;
  if new.id is distinct from old.id
    or new.organization_id is distinct from old.organization_id
    or new.onboarding_application_id is distinct from old.onboarding_application_id
    or new.template_key is distinct from old.template_key
    or new.initial_template_id is distinct from old.initial_template_id
    or new.created_at is distinct from old.created_at
    or (new.created_by is distinct from old.created_by and new.created_by is not null) then
    raise exception 'Frozen onboarding agreement requirements are immutable.';
  end if;
  return new;
end;
$$;

create trigger carrier_onboarding_agreement_requirements_immutability_guard
  before update or delete on public.carrier_onboarding_agreement_requirements
  for each row execute function public.guard_carrier_onboarding_agreement_requirement_immutability();

alter table public.carrier_onboarding_agreement_requirements enable row level security;
create policy carrier_onboarding_agreement_requirements_select
  on public.carrier_onboarding_agreement_requirements for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner','admin','dispatcher','accountant','viewer']::public.org_role[])
  );

create or replace function public.initialize_carrier_required_agreements(p_application_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_app public.carrier_onboarding_applications;
  v_requirement record;
  v_template_id uuid;
  v_active_signing_id uuid;
  v_assigned_ids uuid[] := '{}'::uuid[];
  v_existing_ids uuid[] := '{}'::uuid[];
  v_keys text[] := '{}'::text[];
begin
  select * into v_app from public.carrier_onboarding_applications
  where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to initialize required agreements.';
  end if;
  if v_app.status not in ('draft','needs_correction','submitted','approved') then
    raise exception 'Agreement requirements cannot be initialized for this application status.';
  end if;
  if v_app.agreement_requirements_initialized_at is not null then
    raise exception 'Agreement requirements have already been initialized.';
  end if;

  for v_requirement in
    with current_required as (
      select t.template_key, t.id as template_id, 1 as source_order
      from public.carrier_agreement_templates t
      where t.organization_id = v_app.organization_id
        and t.status = 'published' and t.is_required_for_onboarding
    ), historical_required as (
      select distinct on (t.template_key)
        t.template_key, t.id as template_id, 0 as source_order
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t on t.id = s.agreement_template_id
      where s.application_id = v_app.id
        and t.organization_id = v_app.organization_id
        and t.is_required_for_onboarding
      order by t.template_key, s.assigned_at, s.id
    )
    select distinct on (template_key) template_key, template_id
    from (
      select * from current_required
      union all
      select * from historical_required
    ) requirements
    order by template_key, source_order
  loop
    v_keys := array_append(v_keys, v_requirement.template_key);
    insert into public.carrier_onboarding_agreement_requirements (
      organization_id, onboarding_application_id, template_key,
      initial_template_id, created_by
    ) values (
      v_app.organization_id, v_app.id, v_requirement.template_key,
      v_requirement.template_id, auth.uid()
    );

    select s.id into v_active_signing_id
    from public.carrier_agreement_signings s
    join public.carrier_agreement_templates t on t.id = s.agreement_template_id
    where s.application_id = v_app.id and s.status <> 'voided'
      and t.template_key = v_requirement.template_key
    limit 1;
    if v_active_signing_id is not null then
      v_existing_ids := array_append(v_existing_ids, v_active_signing_id);
      continue;
    end if;

    select t.id into v_template_id
    from public.carrier_agreement_templates t
    where t.organization_id = v_app.organization_id
      and t.template_key = v_requirement.template_key
      and t.status = 'published'
    limit 1;
    if v_template_id is null then
      raise exception 'No published version is currently available for a required agreement.';
    end if;
    begin
      insert into public.carrier_agreement_signings (
        organization_id, application_id, agreement_template_id, assigned_by
      ) values (v_app.organization_id, v_app.id, v_template_id, auth.uid())
      returning id into v_active_signing_id;
      v_assigned_ids := array_append(v_assigned_ids, v_active_signing_id);
    exception when others then
      select s.id into v_active_signing_id
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t on t.id = s.agreement_template_id
      where s.application_id = v_app.id and s.status <> 'voided'
        and t.template_key = v_requirement.template_key
      limit 1;
      if v_active_signing_id is null then raise; end if;
      v_existing_ids := array_append(v_existing_ids, v_active_signing_id);
    end;
  end loop;

  update public.carrier_onboarding_applications
  set agreement_requirements_initialized_at = now(),
      agreement_requirements_initialized_by = auth.uid()
  where id = v_app.id;

  return jsonb_build_object(
    'requirement_count', cardinality(v_keys),
    'assigned_count', cardinality(v_assigned_ids),
    'existing_count', cardinality(v_existing_ids),
    'template_keys', to_jsonb(v_keys)
  );
end;
$$;

create or replace function public.assign_missing_carrier_required_agreements(p_application_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_app public.carrier_onboarding_applications;
  v_requirement record;
  v_template_id uuid;
  v_signing_id uuid;
  v_assigned_ids uuid[] := '{}'::uuid[];
  v_existing_ids uuid[] := '{}'::uuid[];
  v_keys text[] := '{}'::text[];
begin
  select * into v_app from public.carrier_onboarding_applications
  where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to assign required agreements.';
  end if;
  if v_app.status not in ('draft','needs_correction','submitted','approved') then
    raise exception 'Required agreements cannot be assigned for this application status.';
  end if;
  if v_app.agreement_requirements_initialized_at is null then
    raise exception 'Agreement requirements have not been initialized.';
  end if;

  for v_requirement in
    select template_key
    from public.carrier_onboarding_agreement_requirements
    where onboarding_application_id = v_app.id
    order by template_key
  loop
    v_keys := array_append(v_keys, v_requirement.template_key);
    select s.id into v_signing_id
    from public.carrier_agreement_signings s
    join public.carrier_agreement_templates t on t.id = s.agreement_template_id
    where s.application_id = v_app.id and s.status <> 'voided'
      and t.template_key = v_requirement.template_key
    limit 1;
    if v_signing_id is not null then
      v_existing_ids := array_append(v_existing_ids, v_signing_id);
      continue;
    end if;
    select t.id into v_template_id
    from public.carrier_agreement_templates t
    where t.organization_id = v_app.organization_id
      and t.template_key = v_requirement.template_key
      and t.status = 'published'
    limit 1;
    if v_template_id is null then
      raise exception 'No published version is currently available for a required agreement.';
    end if;
    begin
      insert into public.carrier_agreement_signings (
        organization_id, application_id, agreement_template_id, assigned_by
      ) values (v_app.organization_id, v_app.id, v_template_id, auth.uid())
      returning id into v_signing_id;
      v_assigned_ids := array_append(v_assigned_ids, v_signing_id);
    exception when others then
      select s.id into v_signing_id
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t on t.id = s.agreement_template_id
      where s.application_id = v_app.id and s.status <> 'voided'
        and t.template_key = v_requirement.template_key
      limit 1;
      if v_signing_id is null then raise; end if;
      v_existing_ids := array_append(v_existing_ids, v_signing_id);
    end;
  end loop;
  return jsonb_build_object(
    'requirement_count', cardinality(v_keys),
    'assigned_count', cardinality(v_assigned_ids),
    'existing_count', cardinality(v_existing_ids),
    'template_keys', to_jsonb(v_keys)
  );
end;
$$;

revoke execute on function public.initialize_carrier_required_agreements(uuid) from public, anon;
revoke execute on function public.assign_missing_carrier_required_agreements(uuid) from public, anon;
grant execute on function public.initialize_carrier_required_agreements(uuid) to authenticated;
grant execute on function public.assign_missing_carrier_required_agreements(uuid) to authenticated;

create or replace function public.convert_carrier_onboarding_application(p_application_id uuid)
returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_app public.carrier_onboarding_applications;
  v_carrier_id uuid;
  v_missing_required_agreement boolean;
  v_mc_number text;
  v_dot_number text;
  v_duplicate_carrier_id uuid;
begin
  select * into v_app from public.carrier_onboarding_applications
  where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application to a carrier.';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only an approved application can be converted (current status=%).', v_app.status;
  end if;
  if v_app.agreement_requirements_initialized_at is null then
    raise exception 'Agreement requirements have not been initialized for this application.';
  end if;

  select exists (
    select 1
    from public.carrier_onboarding_agreement_requirements r
    where r.onboarding_application_id = p_application_id
      and (
        1 <> (
          select count(*) from public.carrier_agreement_signings s
          join public.carrier_agreement_templates t on t.id = s.agreement_template_id
          where s.application_id = p_application_id and s.status <> 'voided'
            and t.template_key = r.template_key
        )
        or not exists (
          select 1 from public.carrier_agreement_signings s
          join public.carrier_agreement_templates t on t.id = s.agreement_template_id
          where s.application_id = p_application_id and s.status = 'completed'
            and t.template_key = r.template_key
        )
      )
  ) into v_missing_required_agreement;
  if v_missing_required_agreement then
    raise exception 'One or more required dispatch agreements have not been completed for this application.';
  end if;

  v_mc_number := nullif(btrim(v_app.mc_number), '');
  v_dot_number := nullif(btrim(v_app.dot_number), '');
  if v_mc_number is not null then
    perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-mc:' || v_mc_number));
  end if;
  if v_dot_number is not null then
    perform pg_advisory_xact_lock(hashtext(v_app.organization_id::text), hashtext('carrier-dot:' || v_dot_number));
  end if;
  select c.id into v_duplicate_carrier_id
  from public.carriers c
  where c.organization_id = v_app.organization_id and (
    (v_mc_number is not null and btrim(c.mc_number) = v_mc_number)
    or (v_dot_number is not null and btrim(c.dot_number) = v_dot_number)
  ) limit 1;
  if v_duplicate_carrier_id is not null then
    raise exception 'A carrier with the same MC or DOT number already exists in this organization.';
  end if;

  insert into public.carriers (
    organization_id, legal_name, dba_name, mc_number, dot_number, contact_name,
    phone, email, address_line1, address_line2, city, state, postal_code, country
  ) values (
    v_app.organization_id, v_app.legal_name, v_app.dba_name, v_app.mc_number,
    v_app.dot_number, v_app.contact_name, v_app.phone, v_app.email,
    v_app.address_line1, v_app.address_line2, v_app.city, v_app.state,
    v_app.postal_code, coalesce(nullif(btrim(v_app.country), ''), 'US')
  ) returning id into v_carrier_id;

  insert into public.carrier_financials (
    carrier_id, organization_id, dispatch_fee_percentage,
    payment_terms_days, factoring_company_name
  ) values (
    v_carrier_id, v_app.organization_id,
    coalesce(v_app.proposed_dispatch_fee_percentage, 10.00),
    coalesce(v_app.proposed_payment_terms_days, 7),
    case when v_app.has_factoring then nullif(btrim(v_app.factoring_company_name), '') else null end
  );

  update public.carrier_onboarding_applications
  set status = 'converted', converted_at = now(), converted_by = auth.uid(),
      converted_carrier_id = v_carrier_id
  where id = p_application_id;
  return v_carrier_id;
end;
$$;

comment on table public.carrier_onboarding_agreement_requirements is
  'Immutable frozen logical agreement families required for one carrier onboarding application; initialized once before its first invitation.';
comment on function public.initialize_carrier_required_agreements(uuid) is
  'Atomically freezes current plus legacy historical required agreement keys and assigns every missing signing for an eligible same-organization application.';
comment on function public.assign_missing_carrier_required_agreements(uuid) is
  'Idempotently assigns current published versions only for missing keys already present in an application frozen agreement requirement set.';
comment on function public.convert_carrier_onboarding_application(uuid) is
  '0086 conversion behavior with agreement readiness sourced exclusively from the application immutable frozen requirement set.';

grant execute on function public.convert_carrier_onboarding_application(uuid) to authenticated;
