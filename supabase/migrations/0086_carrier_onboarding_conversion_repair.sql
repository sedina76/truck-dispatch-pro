-- =============================================================================
-- 0086_carrier_onboarding_conversion_repair.sql
-- Phase 2L.4D: narrow post-0085 carrier onboarding conversion repair.
--
-- Replaces only convert_carrier_onboarding_application(uuid). Operational
-- carrier fields remain on public.carriers; negotiated financial/factoring
-- fields are written to public.carrier_financials, preserving the post-0069
-- financial-isolation architecture. The legacy plaintext carriers.ein column
-- remains unset. No signing, invitation, document, or template behavior is
-- changed.
-- =============================================================================

create or replace function public.convert_carrier_onboarding_application(p_application_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_app public.carrier_onboarding_applications;
  v_carrier_id uuid;
  v_missing_required_agreement boolean;
  v_mc_number text;
  v_dot_number text;
  v_duplicate_carrier_id uuid;
begin
  -- Lock the application first so two conversion attempts for the same row
  -- cannot both pass the approved-state check.
  select * into v_app
  from public.carrier_onboarding_applications
  where id = p_application_id
  for update;

  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application to a carrier.';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only an approved application can be converted (current status=%).', v_app.status;
  end if;

  -- Preserve 0084/2L.4B exactly: every CURRENT published required logical
  -- template_key must have exactly one non-voided signing, and that signing
  -- must be completed. Its exact version may now be retired; zero required
  -- keys produces no rows here and therefore does not block conversion.
  select exists (
    select 1
    from (
      select distinct t.template_key
      from public.carrier_agreement_templates t
      where t.organization_id = v_app.organization_id
        and t.status = 'published'
        and t.is_required_for_onboarding
    ) required_keys
    where 1 <> (
      select count(*)
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t
        on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status <> 'voided'
        and t.template_key = required_keys.template_key
    )
    or not exists (
      select 1
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t
        on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status = 'completed'
        and t.template_key = required_keys.template_key
    )
  ) into v_missing_required_agreement;

  if v_missing_required_agreement then
    raise exception 'One or more required dispatch agreements have not been completed for this application.';
  end if;

  -- Prevent an obvious duplicate carrier for the same tenant. The existing
  -- find_potential_duplicate_carriers() helper is advisory/read-only; this
  -- mutation boundary must enforce the MC/DOT decision itself. Pair-scoped
  -- transaction advisory locks serialize different approved applications
  -- attempting the same nonblank MC or DOT value without a global lock.
  v_mc_number := nullif(btrim(v_app.mc_number), '');
  v_dot_number := nullif(btrim(v_app.dot_number), '');

  if v_mc_number is not null then
    perform pg_advisory_xact_lock(
      hashtext(v_app.organization_id::text),
      hashtext('carrier-mc:' || v_mc_number)
    );
  end if;
  if v_dot_number is not null then
    perform pg_advisory_xact_lock(
      hashtext(v_app.organization_id::text),
      hashtext('carrier-dot:' || v_dot_number)
    );
  end if;

  select c.id into v_duplicate_carrier_id
  from public.carriers c
  where c.organization_id = v_app.organization_id
    and (
      (v_mc_number is not null and btrim(c.mc_number) = v_mc_number)
      or (v_dot_number is not null and btrim(c.dot_number) = v_dot_number)
    )
  limit 1;

  if v_duplicate_carrier_id is not null then
    raise exception 'A carrier with the same MC or DOT number already exists in this organization.';
  end if;

  -- Operational identity/contact fields only. carriers.ein is intentionally
  -- omitted: onboarding EIN ciphertext is never decrypted into the legacy
  -- plaintext destination.
  insert into public.carriers (
    organization_id,
    legal_name,
    dba_name,
    mc_number,
    dot_number,
    contact_name,
    phone,
    email,
    address_line1,
    address_line2,
    city,
    state,
    postal_code,
    country
  ) values (
    v_app.organization_id,
    v_app.legal_name,
    v_app.dba_name,
    v_app.mc_number,
    v_app.dot_number,
    v_app.contact_name,
    v_app.phone,
    v_app.email,
    v_app.address_line1,
    v_app.address_line2,
    v_app.city,
    v_app.state,
    v_app.postal_code,
    coalesce(nullif(btrim(v_app.country), ''), 'US')
  )
  returning id into v_carrier_id;

  -- carrier_financials is one row per carrier (carrier_id primary key) and is
  -- the canonical post-0069 destination. When proposals are absent, retain
  -- its established schema defaults (10% and 7 days); never invent a new
  -- carrier column. has_factoring has no destination column and only controls
  -- whether the application-supplied factoring company name is carried over.
  insert into public.carrier_financials (
    carrier_id,
    organization_id,
    dispatch_fee_percentage,
    payment_terms_days,
    factoring_company_name
  ) values (
    v_carrier_id,
    v_app.organization_id,
    coalesce(v_app.proposed_dispatch_fee_percentage, 10.00),
    coalesce(v_app.proposed_payment_terms_days, 7),
    case
      when v_app.has_factoring then nullif(btrim(v_app.factoring_company_name), '')
      else null
    end
  );

  update public.carrier_onboarding_applications
  set status = 'converted',
    converted_at = now(),
    converted_by = auth.uid(),
    converted_carrier_id = v_carrier_id
  where id = p_application_id;

  return v_carrier_id;
end;
$$;

comment on function public.convert_carrier_onboarding_application(uuid) is
  'Atomically converts an approved onboarding application for the current organization into public.carriers plus its one-to-one public.carrier_financials row. Enforces owner/admin authorization, every current required logical agreement key, historical retired-version acceptance, and serialized same-org MC/DOT duplicate prevention. carriers.ein remains unset.';

grant execute on function public.convert_carrier_onboarding_application(uuid) to authenticated;

