-- =============================================================================
-- 0092_carrier_agreement_assignment_lock_order.sql
-- Phase 2L.7F: serialize manual agreement assignment behind the application.
-- =============================================================================

create or replace function public.assign_carrier_agreement_template(
  p_application_id uuid,
  p_template_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_application public.carrier_onboarding_applications;
  v_template public.carrier_agreement_templates;
  v_existing_signing_id uuid;
  v_signing_id uuid;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception using
      errcode = 'P2701',
      message = 'You do not have permission to assign carrier agreements.';
  end if;

  -- This row lock is the authoritative first lock for every staff assignment
  -- boundary. Initialization and reconciliation already take the same lock
  -- before inserting signings, eliminating the former inverse lock order.
  select * into v_application
  from public.carrier_onboarding_applications
  where id = p_application_id
  for update;

  if v_application.id is null
    or v_application.organization_id <> public.current_org_id() then
    raise exception using
      errcode = 'P2702',
      message = 'Application or agreement template not found in your organization.';
  end if;

  select * into v_template
  from public.carrier_agreement_templates
  where id = p_template_id;

  if v_template.id is null
    or v_template.organization_id <> v_application.organization_id then
    raise exception using
      errcode = 'P2702',
      message = 'Application or agreement template not found in your organization.';
  end if;
  if v_template.status <> 'published' then
    raise exception using
      errcode = 'P2703',
      message = 'Only a published template can be assigned.';
  end if;
  if v_template.content_hash is null
    or v_template.content_hash !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = 'P2704',
      message = 'This agreement template has not been published correctly and cannot be assigned.';
  end if;

  -- Match the uniqueness trigger's compound advisory lock, but only after
  -- the application row lock. Re-acquisition by the trigger is transaction-
  -- local and safe.
  perform pg_advisory_xact_lock(
    hashtext(v_application.id::text),
    hashtext(v_template.template_key)
  );

  select s.id into v_existing_signing_id
  from public.carrier_agreement_signings s
  join public.carrier_agreement_templates t on t.id = s.agreement_template_id
  where s.application_id = v_application.id
    and s.status <> 'voided'
    and t.template_key = v_template.template_key
  limit 1;

  if v_existing_signing_id is not null then
    return jsonb_build_object(
      'assignment_status', 'conflict',
      'signing_id', v_existing_signing_id
    );
  end if;

  -- content_hash is deliberately omitted. The 0085 snapshot trigger copies
  -- the immutable stored template hash into the new signing.
  insert into public.carrier_agreement_signings (
    organization_id,
    application_id,
    agreement_template_id,
    assigned_by
  ) values (
    v_application.organization_id,
    v_application.id,
    v_template.id,
    auth.uid()
  )
  returning id into v_signing_id;

  return jsonb_build_object(
    'assignment_status', 'assigned',
    'signing_id', v_signing_id
  );
end;
$$;

revoke execute on function public.assign_carrier_agreement_template(uuid,uuid)
  from public, anon;
grant execute on function public.assign_carrier_agreement_template(uuid,uuid)
  to authenticated;

-- All production staff assignment now goes through the locking RPC above.
-- Initialization and reconciliation are SECURITY DEFINER functions and are
-- unaffected by removing the authenticated direct-insert boundary.
revoke insert on public.carrier_agreement_signings from authenticated, anon;
