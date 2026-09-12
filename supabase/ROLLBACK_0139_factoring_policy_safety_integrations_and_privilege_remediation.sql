-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0139_factoring_policy_safety_             ##
-- ##  integrations_and_privilege_remediation.sql                            ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0139.            ##
-- ##  APPLY AS ONE TRANSACTION. Run ONLY if no later migration depends on    ##
-- ##  0139's objects (none exist yet as of this writing).                   ##
-- ##                                                                        ##
-- ##  0139 is purely ADDITIVE (new table, new columns, new functions,       ##
-- ##  REVOKEs, one NOT VALID constraint) -- it never rewrote or deleted an   ##
-- ##  existing row. This rollback reverses every one of those additions and ##
-- ##  restores 0138's own function bodies/comments/grants EXACTLY (by       ##
-- ##  re-running the relevant CREATE OR REPLACE statements from 0138        ##
-- ##  itself, not by guessing) so the database is left in precisely the     ##
-- ##  state it was in immediately after 0138, before 0139 ever ran.         ##
-- ##                                                                        ##
-- ##  DATA LOSS: any row written to carrier_factoring_integrations,         ##
-- ##  factoring_policy_idempotency, or the new carrier_brokers/             ##
-- ##  carrier_customers direct-billing-exception columns, or any            ##
-- ##  noa_document_snapshot_* value populated by 0139's version of          ##
-- ##  approve_factoring_relationship_noa(), is destroyed by this script.    ##
-- ##  Confirm nothing depends on that data before running.                  ##
-- ##                                                                        ##
-- ##  NOTE ON THE NOT VALID CONSTRAINT: dropping                            ##
-- ##  factoring_relationships_new_writes_need_carrier reopens the ability   ##
-- ##  to write a null-carrier_id row again (0138's own posture, before      ##
-- ##  0139). It does NOT retroactively touch any row that was resolved      ##
-- ##  while the constraint was live -- those rows keep their resolved       ##
-- ##  carrier_id; this is a pure re-widening of what is possible, not a     ##
-- ##  historical rewrite of what already happened.                         ##
-- ############################################################################

begin;

-- --- Guard 0: this exact 0139 migration was applied -----------------------
do $rb$
begin
  if to_regclass('public.carrier_factoring_integrations') is null then
    raise exception 'ROLLBACK 0139: public.carrier_factoring_integrations is missing -- 0139 does not appear to be applied. STOP.';
  end if;
  if to_regprocedure('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)') is null then
    raise exception 'ROLLBACK 0139: set_carrier_factoring_policy(...) is missing -- 0139 does not appear to be fully applied. STOP.';
  end if;
  if to_regclass('public.carrier_factoring_integrations') is not null and exists (select 1 from public.carrier_factoring_integrations) then
    raise warning 'ROLLBACK 0139: carrier_factoring_integrations has % row(s) that will be DESTROYED.', (select count(*) from public.carrier_factoring_integrations);
  end if;
  if to_regclass('public.factoring_policy_idempotency') is not null and exists (select 1 from public.factoring_policy_idempotency) then
    raise warning 'ROLLBACK 0139: factoring_policy_idempotency has % row(s) that will be DESTROYED.', (select count(*) from public.factoring_policy_idempotency);
  end if;
  if exists (select 1 from public.carrier_brokers where factoring_ineligible_direct_billing_approved)
     or exists (select 1 from public.carrier_customers where factoring_ineligible_direct_billing_approved) then
    raise warning 'ROLLBACK 0139: at least one carrier_brokers/carrier_customers direct-billing exception approval will be DESTROYED.';
  end if;
  if exists (select 1 from public.factoring_relationships where noa_document_snapshot_file_path is not null) then
    raise warning 'ROLLBACK 0139: at least one factoring_relationships.noa_document_snapshot_* value will be DESTROYED.';
  end if;
end
$rb$;

-- --- G. classify_carrier_factoring_readiness / approve_factoring_relationship_noa:
-- restore 0138's exact bodies and comments (byte-for-byte re-run of 0138's
-- own CREATE OR REPLACE statements + comments, not a paraphrase) ----------
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

  if p_broker_id is not null then
    select status, factoring_eligible into v_party
    from public.carrier_brokers where carrier_id = p_carrier_id and broker_id = p_broker_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id);
    end if;
    if not v_party.factoring_eligible then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'broker_id', p_broker_id, 'message', 'This broker relationship is not factoring-eligible -- billed directly regardless of the carrier''s own factoring mode.');
    end if;
  end if;
  if p_customer_id is not null then
    select status, factoring_eligible into v_party
    from public.carrier_customers where carrier_id = p_carrier_id and customer_id = p_customer_id;
    if v_party.status is null or v_party.status <> 'active' then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_inactive', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id);
    end if;
    if not v_party.factoring_eligible then
      return jsonb_build_object('success', true, 'classification', 'carrier_party_ineligible', 'carrier_id', p_carrier_id, 'customer_id', p_customer_id, 'message', 'This customer relationship is not factoring-eligible -- billed directly regardless of the carrier''s own factoring mode.');
    end if;
  end if;

  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', true, 'classification', 'factoring_policy_unconfigured', 'carrier_id', p_carrier_id);
  end if;

  if v_carrier.factoring_mode = 'direct' then
    return jsonb_build_object('success', true, 'classification', 'direct_billing', 'carrier_id', p_carrier_id);
  end if;

  select count(*) into v_default_count
  from public.factoring_relationships
  where carrier_id = p_carrier_id and is_default and is_active;

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

  return jsonb_build_object('success', true, 'classification', 'ready', 'carrier_id', p_carrier_id, 'relationship_id', v_default.id);
end;
$fn$;

revoke all on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) from public;
grant execute on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) to authenticated;

comment on function public.classify_carrier_factoring_readiness(uuid,uuid,uuid) is
  'Phase 3B.1 read-only carrier-factor classifier and preview RPC (items 5, 11; Phase 3B.1.1 item 1 adds factoring_policy_unconfigured -- see 0139 for the further per-carrier-integration-aware corrections, item 7, which create-or-replaces this same function and its comment again). Never creates an invoice, submission, package, payment, or financial event. Classifications: factoring_policy_unconfigured, direct_billing, no_factoring_configuration, no_default, default_inactive, default_expired, default_not_yet_effective, factoring_company_inactive, relationship_incomplete, multiple_defaults, carrier_party_inactive, carrier_party_ineligible, ready, error. Callable by owner/admin/dispatcher/accountant; never driver/viewer.';

create or replace function public.approve_factoring_relationship_noa(
  p_relationship_id uuid,
  p_noa_reference text,
  p_noa_effective_date date,
  p_noa_template_text text default null,
  p_noa_document_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_relationship record;
begin
  if v_uid is null then
    raise exception 'approve_factoring_relationship_noa: authentication required.' using errcode = 'ANAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'approve_factoring_relationship_noa: caller has no organization.' using errcode = 'ANAUT';
  end if;
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'approve_factoring_relationship_noa: only an owner or admin may approve a Notice of Assignment.' using errcode = 'ANROL';
  end if;
  if p_noa_reference is null or btrim(p_noa_reference) = '' then
    raise exception 'approve_factoring_relationship_noa: a reference/version is required.' using errcode = 'ANVAL';
  end if;
  if p_noa_effective_date is null then
    raise exception 'approve_factoring_relationship_noa: an effective date is required.' using errcode = 'ANVAL';
  end if;
  if p_noa_template_text is null and p_noa_document_id is null then
    raise exception 'approve_factoring_relationship_noa: either approved template language or an approved document reference is required.' using errcode = 'ANVAL';
  end if;

  select id, organization_id, carrier_id into v_relationship
  from public.factoring_relationships where id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org then
    raise exception 'approve_factoring_relationship_noa: this factoring relationship is not available.' using errcode = 'ANDNF';
  end if;
  if v_relationship.carrier_id is null then
    raise exception 'approve_factoring_relationship_noa: this relationship has no resolved carrier -- its Notice of Assignment cannot be approved until one is. See unresolved_carrier_records.' using errcode = 'ANCAR';
  end if;
  if p_noa_document_id is not null then
    if not exists (select 1 from public.documents where id = p_noa_document_id and organization_id = v_org) then
      raise exception 'approve_factoring_relationship_noa: the referenced document does not belong to this organization.' using errcode = 'ANVAL';
    end if;
  end if;

  update public.factoring_relationships
  set noa_template_text = p_noa_template_text,
      noa_document_id = p_noa_document_id,
      noa_reference = p_noa_reference,
      noa_effective_date = p_noa_effective_date,
      noa_approved = true,
      noa_approved_by = v_uid,
      noa_approved_at = now()
  where id = p_relationship_id;

  perform public.log_activity(
    'carrier'::public.entity_type, v_relationship.carrier_id, 'factoring_noa_approved',
    jsonb_build_object('relationship_id', p_relationship_id, 'noa_reference', p_noa_reference, 'noa_effective_date', p_noa_effective_date),
    v_org);

  return jsonb_build_object('success', true, 'relationship_id', p_relationship_id, 'carrier_id', v_relationship.carrier_id);
end;
$fn$;

revoke all on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) from public;
grant execute on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) to authenticated;

comment on function public.approve_factoring_relationship_noa(uuid,text,date,text,uuid) is
  'Phase 3B.1 (item 7): the ONE sanctioned path to set factoring_relationships.noa_approved = true. Owner/admin only. Requires a resolved carrier_id, a reference/version, an effective date, and either approved template language or an approved document reference. Writes one audit event via log_activity(entity_type=carrier).';

-- --- F. drop set_carrier_factoring_policy and its idempotency ledger ------
drop function if exists public.set_carrier_factoring_policy(uuid, public.carrier_factoring_mode, text, timestamptz, text);
drop table if exists public.factoring_policy_idempotency;

-- --- restore carriers' column-privilege grants to their pre-0139 shape
-- (0138/earlier never locked carriers down at all -- a blanket table-level
-- grant is what existed before 0139) ---------------------------------------
grant update on public.carriers to authenticated;

-- --- E. carrier_factoring_integrations + its status function -------------
-- Drop the TABLE first -- its own trigger depends on
-- guard_carrier_factoring_integration_org(), so dropping the table first
-- (which cascade-drops that trigger with it) lets the function drop cleanly
-- afterward with no CASCADE needed anywhere in this script.
drop function if exists public.get_carrier_factoring_integration_status(uuid);
drop table if exists public.carrier_factoring_integrations;
drop function if exists public.guard_carrier_factoring_integration_org();
drop type if exists public.integration_configuration_status;

-- --- C. carrier-party direct-billing exception columns/trigger -----------
drop trigger if exists carrier_brokers_guard_direct_billing_exception on public.carrier_brokers;
drop trigger if exists carrier_customers_guard_direct_billing_exception on public.carrier_customers;
drop function if exists public.guard_carrier_party_direct_billing_exception();

alter table public.carrier_brokers
  drop constraint if exists carrier_brokers_direct_billing_exception_complete,
  drop column if exists factoring_ineligible_direct_billing_approved,
  drop column if exists factoring_ineligible_direct_billing_approved_by,
  drop column if exists factoring_ineligible_direct_billing_approved_at;
alter table public.carrier_customers
  drop constraint if exists carrier_customers_direct_billing_exception_complete,
  drop column if exists factoring_ineligible_direct_billing_approved,
  drop column if exists factoring_ineligible_direct_billing_approved_by,
  drop column if exists factoring_ineligible_direct_billing_approved_at;

-- --- B. cutover-safety NOT VALID constraint --------------------------------
alter table public.factoring_relationships
  drop constraint if exists factoring_relationships_new_writes_need_carrier;

-- --- G (continued): NOA snapshot columns ----------------------------------
alter table public.factoring_relationships
  drop column if exists noa_document_snapshot_file_name,
  drop column if exists noa_document_snapshot_file_path;

-- --- A. privilege remediation: restore the exact (gap-having) grants that
-- existed immediately after 0130/0131/0133, so a rollback truly reverses
-- 0139 and nothing more -----------------------------------------------------
grant insert, delete on public.unresolved_carrier_records to authenticated;
grant insert, update, delete on public.financial_idempotency_keys to authenticated;
grant insert, update, delete on public.carrier_backfill_0133_provenance to authenticated;
grant delete on public.carrier_remittance_profiles to authenticated;
grant delete on public.carrier_brokers to authenticated;
grant delete on public.carrier_customers to authenticated;

-- --- Guard: postconditions -------------------------------------------------
do $rb$
begin
  if to_regclass('public.carrier_factoring_integrations') is not null then
    raise exception 'ROLLBACK 0139 postcondition: carrier_factoring_integrations still exists.';
  end if;
  if to_regprocedure('public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)') is not null then
    raise exception 'ROLLBACK 0139 postcondition: set_carrier_factoring_policy(...) still exists.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_brokers' and column_name='factoring_ineligible_direct_billing_approved') then
    raise exception 'ROLLBACK 0139 postcondition: carrier_brokers direct-billing exception column still exists.';
  end if;
  if exists (select 1 from pg_constraint where conname='factoring_relationships_new_writes_need_carrier') then
    raise exception 'ROLLBACK 0139 postcondition: factoring_relationships_new_writes_need_carrier constraint still exists.';
  end if;
  raise notice 'ROLLBACK 0139 complete: database restored to its exact post-0138 state.';
end
$rb$;

commit;
