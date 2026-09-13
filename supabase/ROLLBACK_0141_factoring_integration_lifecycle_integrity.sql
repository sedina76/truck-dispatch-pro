-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0141_factoring_integration_lifecycle_    ##
-- ##  integrity.sql                                                        ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0141.           ##
-- ##  APPLY AS ONE TRANSACTION.                                             ##
-- ##                                                                        ##
-- ##  Restores the EXACT pre-0141 (0140-boundary) state: carrier_factoring_ ##
-- ##  integrations.configuration_status back to its original enum type and ##
-- ##  default; drops every function/trigger/table 0141 introduced; restores##
-- ##  authenticated's INSERT/UPDATE table + column grants and RLS policies;##
-- ##  restores classify_carrier_factoring_readiness() to its exact 0139    ##
-- ##  body; restores factoring_relationships_submission_integration_       ##
-- ##  present. No row is ever deleted by this script.                      ##
-- ##                                                                        ##
-- ##  DATA-PRESERVING REFUSAL, NOT FORCED CONVERSION: 0141's six lifecycle  ##
-- ##  states are almost entirely disjoint from the pre-0141 enum's five    ##
-- ##  (only 'draft' is shared). If ANY carrier_factoring_integrations row   ##
-- ##  has ever moved to pending_verification/ready/suspended/revoked/      ##
-- ##  failed, converting the column back to the old enum type cannot       ##
-- ##  represent that value at all -- there is no safe, lossless mapping.   ##
-- ##  This script REFUSES outright (raises, whole transaction rolls back)  ##
-- ##  rather than guessing a mapping or silently discarding history. If    ##
-- ##  that happens, the correct next step is a NEW, explicitly reviewed    ##
-- ##  forward migration that decides deliberately how to represent that    ##
-- ##  history under whatever comes next -- never an undocumented partial   ##
-- ##  rollback.                                                            ##
-- ############################################################################

begin;

-- --- Guard 0: this exact 0141 migration was applied -------------------------
do $rb$
begin
  if not exists (select 1 from pg_constraint where conname = 'cfi_ready_iff_active') then
    raise exception 'ROLLBACK 0141: cfi_ready_iff_active constraint not found -- 0141 does not appear to be applied. STOP.';
  end if;
end
$rb$;

-- --- Guard 1: refuse if a later (invoice-issuance, 0142+) migration is live -
do $rb$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'invoices' and column_name like 'carrier_factoring_snapshot%'
  ) then
    raise exception 'ROLLBACK 0141: invoices already carries a carrier/financial snapshot column -- a later (invoice-issuance) migration appears to depend on 0141''s integration-lifecycle contract. Refusing to roll back 0141 underneath it. STOP -- write a forward migration instead.';
  end if;
  if to_regclass('public.factoring_lifecycle_events') is not null then
    raise exception 'ROLLBACK 0141: an unrecognized factoring_lifecycle_events table exists -- a later migration may depend on it. STOP.';
  end if;
end
$rb$;

-- --- Guard 2: refuse if any row holds a state the old enum cannot express --
do $rb$
declare v_nondraft int;
begin
  select count(*) into v_nondraft from public.carrier_factoring_integrations where configuration_status <> 'draft';
  if v_nondraft > 0 then
    raise exception 'ROLLBACK 0141: % carrier_factoring_integrations row(s) hold a lifecycle state (pending_verification/ready/suspended/revoked/failed) the pre-0141 enum cannot represent. Refusing to convert the column back and lose that history. STOP -- see this script''s own header.', v_nondraft;
  end if;
end
$rb$;

-- --- Guard 3: refuse if restoring the legacy API-integration constraint would
-- immediately reject existing data (an api-method relationship created
-- under 0141 with no submission_integration_id, which 0141 explicitly permits)
do $rb$
declare v_violating int;
begin
  select count(*) into v_violating from public.factoring_relationships
  where submission_method = 'api'::public.factoring_submission_method and submission_integration_id is null;
  if v_violating > 0 then
    raise exception 'ROLLBACK 0141: % factoring_relationships row(s) use submission_method=api with no submission_integration_id (permitted under 0141, not under the pre-0141 constraint). Refusing to restore factoring_relationships_submission_integration_present and immediately violate existing data. STOP.', v_violating;
  end if;
end
$rb$;

-- --- A. drop everything 0141 introduced (functions, triggers, table) ------
drop trigger if exists a0141_lifecycle_transition on public.carrier_factoring_integrations;
drop trigger if exists z0141_lifecycle_dependencies on public.carriers;
drop trigger if exists z0141_lifecycle_dependencies on public.factoring_companies;
drop trigger if exists z0141_lifecycle_dependencies on public.factoring_relationships;
drop trigger if exists z0141_lifecycle_dependencies on public.carrier_factoring_integrations;
drop trigger if exists z0141_lifecycle_dependencies on public.documents;
drop trigger if exists z0141_lifecycle_dependencies on public.integration_settings;

drop function if exists public.configure_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text);
drop function if exists public.rotate_carrier_factoring_integration(uuid, text, text, public.integration_provider, text, text, timestamptz, text);
drop function if exists public.activate_carrier_factoring_integration(uuid, text, timestamptz, text);
drop function if exists public.deactivate_carrier_factoring_integration(uuid, text, timestamptz, text);
drop function if exists public.verify_carrier_factoring_integration(uuid, text, timestamptz, text);
drop function if exists public.fail_carrier_factoring_integration(uuid, text, timestamptz, text);
drop function if exists public.revoke_carrier_factoring_integration(uuid, text, timestamptz, text);
drop function if exists public.deactivate_factoring_relationship(uuid, text, timestamptz, text, boolean);
drop function if exists public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text);
drop function if exists public.factoring_integration_lifecycle_precheck(text, timestamptz, text);
drop function if exists public.guard_factoring_lifecycle_dependencies();
drop function if exists public.guard_factoring_integration_lifecycle_transition();
drop function if exists public.factoring_integration_lifecycle_problem(uuid);
drop function if exists public.factoring_relationship_lifecycle_problem(uuid);

drop table if exists public.factoring_integration_lifecycle_idempotency;

drop index if exists public.cfi_active_by_org;

-- --- B. restore the lifecycle-state column to its exact pre-0141 shape ----
alter table public.carrier_factoring_integrations drop constraint if exists cfi_lifecycle_states;
alter table public.carrier_factoring_integrations drop constraint if exists cfi_ready_iff_active;
alter table public.carrier_factoring_integrations drop constraint if exists cfi_opaque_reference_shape;
alter table public.carrier_factoring_integrations alter column configuration_status drop default;
alter table public.carrier_factoring_integrations alter column configuration_status type public.integration_configuration_status using configuration_status::public.integration_configuration_status;
alter table public.carrier_factoring_integrations alter column configuration_status set default 'draft';
comment on column public.carrier_factoring_integrations.configuration_status is null;

-- --- C. restore direct-write grants + RLS policies (0139's originals) -----
grant insert, update on public.carrier_factoring_integrations to authenticated;
do $regrant_cols$
declare c record;
begin
  for c in
    select attname from pg_attribute
    where attrelid = 'public.carrier_factoring_integrations'::regclass and attnum > 0 and not attisdropped
  loop
    execute format('grant insert (%I), update (%I) on public.carrier_factoring_integrations to authenticated', c.attname, c.attname);
  end loop;
end
$regrant_cols$;

create policy carrier_factoring_integrations_insert on public.carrier_factoring_integrations
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
create policy carrier_factoring_integrations_update on public.carrier_factoring_integrations
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]))
  with check (organization_id = public.current_org_id());

-- --- D. restore classify_carrier_factoring_readiness() to its exact 0139 body
create or replace function public.classify_carrier_factoring_readiness(
  p_carrier_id uuid,
  p_broker_id uuid default null,
  p_customer_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_carrier record;
  v_party record;
  v_default_count int;
  v_default record;
  v_company_active boolean;
  v_integration record;
  v_missing text[] := '{}'::text[];
begin
  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'classification', 'error', 'message', 'No organization on this account.');
  end if;
  if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'classification', 'error', 'message', 'You do not have permission to view factoring configuration.');
  end if;

  select id, organization_id, factoring_mode into v_carrier
  from public.carriers where id = p_carrier_id;
  if v_carrier.id is null or v_carrier.organization_id <> v_org then
    return jsonb_build_object('success', false, 'classification', 'error', 'message', 'Carrier not found.');
  end if;

  -- Carrier-party gate: checked before mode-based classification,
  -- regardless of mode. factoring_eligible=false is now BLOCKING
  -- (carrier_party_ineligible) unless an EXPLICIT, owner/admin-approved
  -- direct-billing exception exists for this specific party (item 1, 7)
  -- -- never an automatic guess.
  if p_broker_id is not null then
    select status, factoring_eligible, factoring_ineligible_direct_billing_approved into v_party
    from public.carrier_brokers where carrier_id = p_carrier_id and broker_id = p_broker_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id);
    end if;
    if not v_party.factoring_eligible then
      if v_party.factoring_ineligible_direct_billing_approved then
        return jsonb_build_object('success', true, 'classification', 'carrier_party_direct_billing_exception', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id,
          'message', 'This broker relationship is billed directly under an explicitly approved exception.');
      end if;
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id,
        'message', 'This broker relationship is not factoring-eligible and has no approved direct-billing exception -- blocked, not automatically billed directly.');
    end if;
  end if;
  if p_customer_id is not null then
    select status, factoring_eligible, factoring_ineligible_direct_billing_approved into v_party
    from public.carrier_customers where carrier_id = p_carrier_id and customer_id = p_customer_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id);
    end if;
    if not v_party.factoring_eligible then
      if v_party.factoring_ineligible_direct_billing_approved then
        return jsonb_build_object('success', true, 'classification', 'carrier_party_direct_billing_exception', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id,
          'message', 'This customer relationship is billed directly under an explicitly approved exception.');
      end if;
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id,
        'message', 'This customer relationship is not factoring-eligible and has no approved direct-billing exception -- blocked, not automatically billed directly.');
    end if;
  end if;

  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', true, 'classification', 'factoring_policy_unconfigured', 'carrier_id', p_carrier_id);
  end if;
  if v_carrier.factoring_mode = 'direct' then
    return jsonb_build_object('success', true, 'classification', 'direct_billing', 'carrier_id', p_carrier_id);
  end if;

  -- factoring_mode = 'factored' from here.
  select count(*) into v_default_count
  from public.factoring_relationships where carrier_id = p_carrier_id and is_default and is_active;
  if v_default_count > 1 then
    return jsonb_build_object('success', true, 'classification', 'multiple_defaults', 'carrier_id', p_carrier_id, 'default_count', v_default_count);
  end if;

  if not exists (select 1 from public.factoring_relationships where carrier_id = p_carrier_id) then
    return jsonb_build_object('success', true, 'classification', 'no_factoring_configuration', 'carrier_id', p_carrier_id);
  end if;

  select id, factoring_company_id, is_active, effective_from, effective_to,
         remittance_instructions, noa_approved, submission_method
    into v_default
  from public.factoring_relationships
  where carrier_id = p_carrier_id and is_default
  order by is_active desc, effective_from desc
  limit 1;

  if v_default.id is null then
    return jsonb_build_object('success', true, 'classification', 'no_default', 'carrier_id', p_carrier_id);
  end if;
  if not v_default.is_active then
    return jsonb_build_object('success', true, 'classification', 'default_inactive', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
  end if;

  select is_active into v_company_active from public.factoring_companies where id = v_default.factoring_company_id;
  if not coalesce(v_company_active, false) then
    return jsonb_build_object('success', true, 'classification', 'factoring_company_inactive', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
  end if;

  if v_default.effective_from is not null and v_default.effective_from > current_date then
    return jsonb_build_object('success', true, 'classification', 'default_not_yet_effective', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'effective_from', v_default.effective_from);
  end if;
  if v_default.effective_to is not null and v_default.effective_to < current_date then
    return jsonb_build_object('success', true, 'classification', 'default_expired', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'effective_to', v_default.effective_to);
  end if;

  if v_default.remittance_instructions is null or btrim(v_default.remittance_instructions) = '' then
    v_missing := array_append(v_missing, 'remittance_instructions');
  end if;
  if not v_default.noa_approved then
    v_missing := array_append(v_missing, 'noa_approved');
  end if;
  if v_default.submission_method is null then
    v_missing := array_append(v_missing, 'submission_method');
  end if;
  if array_length(v_missing, 1) > 0 then
    return jsonb_build_object('success', true, 'classification', 'relationship_incomplete', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'missing', to_jsonb(v_missing));
  end if;

  -- Item 7: api-method readiness now depends on carrier_factoring_
  -- integrations, not merely factoring_relationships.submission_integration_id.
  if v_default.submission_method = 'api' then
    select configuration_status, is_active, effective_from, effective_to into v_integration
    from public.carrier_factoring_integrations
    where factoring_relationship_id = v_default.id and carrier_id = p_carrier_id
    order by is_active desc, created_at desc
    limit 1;

    if v_integration.configuration_status is null then
      return jsonb_build_object('success', true, 'classification', 'api_integration_missing', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
    end if;
    if not v_integration.is_active or v_integration.configuration_status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'api_integration_not_ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'configuration_status', v_integration.configuration_status);
    end if;
    if v_integration.effective_to is not null and v_integration.effective_to < current_date then
      return jsonb_build_object('success', true, 'classification', 'api_integration_not_ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id, 'configuration_status', 'expired');
    end if;
  end if;

  return jsonb_build_object('success', true, 'classification', 'ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
end;
$fn$;

revoke all on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) from public;
grant execute on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) to authenticated;

comment on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) is
  'Phase 3B.1/3B.1.1 read-only carrier-factor classifier and preview RPC. Never creates an invoice, submission, package, payment, or financial event; never returns a secret (secret_reference is never selected). Classifications: factoring_policy_unconfigured, direct_billing, no_factoring_configuration, no_default, default_inactive, default_expired, default_not_yet_effective, factoring_company_inactive, relationship_incomplete, multiple_defaults, api_integration_missing, api_integration_not_ready, carrier_party_inactive, carrier_party_ineligible, carrier_party_direct_billing_exception, ready, error.';

-- --- E. restore the legacy API-integration constraint (guarded above) -----
alter table public.factoring_relationships
  add constraint factoring_relationships_submission_integration_present check (
    submission_method is distinct from 'api'::public.factoring_submission_method
    or submission_integration_id is not null
  );
comment on column public.factoring_relationships.submission_integration_id is null;

-- --- Guard: postconditions -- prove the 0140 boundary, not just "no error" -
do $rb$
declare v_data_type text;
begin
  if (select data_type from information_schema.columns where table_schema='public' and table_name='carrier_factoring_integrations' and column_name='configuration_status') <> 'USER-DEFINED' then
    raise exception 'ROLLBACK 0141 postcondition: configuration_status is not back to the enum type.';
  end if;
  if exists (select 1 from pg_constraint where conname in ('cfi_lifecycle_states','cfi_ready_iff_active','cfi_opaque_reference_shape')) then
    raise exception 'ROLLBACK 0141 postcondition: a 0141 constraint is still present.';
  end if;
  if not has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'INSERT')
    or not has_table_privilege('authenticated', 'public.carrier_factoring_integrations', 'UPDATE')
  then
    raise exception 'ROLLBACK 0141 postcondition: authenticated does not have INSERT/UPDATE restored on carrier_factoring_integrations.';
  end if;
  if to_regprocedure('public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)') is not null
    or to_regprocedure('public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)') is not null
  then
    raise exception 'ROLLBACK 0141 postcondition: a 0141 function still exists.';
  end if;
  if exists (select 1 from pg_trigger where tgname in ('z0141_lifecycle_dependencies','a0141_lifecycle_transition')) then
    raise exception 'ROLLBACK 0141 postcondition: a 0141 trigger still exists.';
  end if;
  if to_regclass('public.factoring_integration_lifecycle_idempotency') is not null then
    raise exception 'ROLLBACK 0141 postcondition: factoring_integration_lifecycle_idempotency still exists.';
  end if;
  if to_regclass('public.cfi_active_by_org') is not null then
    raise exception 'ROLLBACK 0141 postcondition: cfi_active_by_org index still exists.';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'factoring_relationships_submission_integration_present') then
    raise exception 'ROLLBACK 0141 postcondition: factoring_relationships_submission_integration_present was not restored.';
  end if;
  if (select prosrc from pg_proc where proname = 'classify_carrier_factoring_readiness' and pronamespace = 'public'::regnamespace) ilike '%factoring_integration_lifecycle_problem%' then
    raise exception 'ROLLBACK 0141 postcondition: classify_carrier_factoring_readiness still references a 0141 function.';
  end if;
  raise notice 'ROLLBACK 0141 complete: carrier_factoring_integrations restored to its exact pre-0141 (0140-boundary) shape -- enum column, grants, RLS policies; every 0141 function/trigger/table removed; classify_carrier_factoring_readiness() and factoring_relationships_submission_integration_present restored to their exact 0139/0136 forms. No row was deleted by this script.';
end
$rb$;

commit;
