-- =============================================================================
-- 0084_carrier_onboarding_workflow_functions.sql
-- Phase 2L.4: Carrier Onboarding Workspace + Agreement Workflow.
-- PROPOSED ONLY -- NOT APPLIED.
--
-- 0081/0082 shipped schema/RLS/guard-triggers with ZERO working mutation
-- RPCs (by design -- see both files' own header comments). This migration
-- adds only the DB objects that genuinely cannot be plain RLS-scoped
-- client writes or plain service-role TS actions:
--
--   1. carrier_onboarding_sessions -- the ongoing portal credential (the
--      raw invitation token is consumed exactly once, at
--      /carrier-onboarding/[token], to bootstrap this; every later step
--      reads a cookie backed by THIS table, never the raw token again).
--   2. encrypt_carrier_onboarding_ein() -- a pure, stateless encryption
--      helper so EIN encryption stays inside the existing
--      pgp_sym_encrypt/carrier_pii_key mechanism (0081) rather than
--      duplicating crypto in TypeScript. EXECUTE is granted ONLY to
--      service_role -- explicitly NOT to authenticated/anon/public, so
--      this can never become a plaintext-to-ciphertext oracle reachable
--      from a browser (see its own comment below for the PUBLIC-grant
--      pitfall this closes).
--   3. complete_carrier_agreement_signing() -- the one place that
--      genuinely needs DB-level atomicity + row locking: validates every
--      completion requirement (required initials, consent, signer name/
--      title, typed signature, content-hash agreement) and, only if all
--      of it holds, atomically writes evidence + evidence_hash + signed_at
--      + status=completed + exactly one audit event, in a single
--      transaction. A concurrent/duplicate call safely returns the
--      already-completed result instead of raising or double-writing.
--   4. convert_carrier_onboarding_application() -- atomically creates the
--      real public.carriers row and marks the application converted,
--      enforcing the required-agreement gate at this boundary (not just
--      button visibility): conversion is blocked only when the org has a
--      PUBLISHED template with is_required_for_onboarding=true and no
--      COMPLETED signing against it exists for this application. An org
--      that has configured no required onboarding agreement is never
--      blocked. carriers.ein is deliberately left null/unchanged here --
--      see its own comment below.
--
-- Everything else this phase needs (invitation create/resend/revoke,
-- company-info/equipment save, document upload/verify/reject, agreement
-- assignment, initials record/correct, application submission, staff
-- approve/reject/request-correction) is a plain RLS-scoped client write or
-- a plain service-role TS action against tables 0081/0082 already
-- provide -- deliberately NOT duplicated here as DB objects.
--
-- No table modified. No column dropped. No prior migration edited. 0081
-- and 0082 are untouched.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PART 1 -- carrier_onboarding_sessions. RLS enabled, ZERO policies --
-- identical shape to driver_portal_sessions (0015) and
-- carrier_onboarding_invitations (0081) itself: accessed exclusively via
-- the service_role key from trusted server code. A session's expires_at
-- is capped at its parent invitation's own expires_at at bootstrap time
-- (in application code, not enforced here) -- a session can never outlive
-- the invitation staff intended to grant, only end sooner.
-- ---------------------------------------------------------------------------

create table public.carrier_onboarding_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.carrier_onboarding_applications (id) on delete cascade,
  invitation_id uuid not null references public.carrier_onboarding_invitations (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  user_agent text,
  revoked_at timestamptz
);

comment on table public.carrier_onboarding_sessions is
  'The ongoing carrier-portal credential, bootstrapped exactly once from a raw invitation token at /carrier-onboarding/[token]. RLS enabled with ZERO policies -- service-role-only, mirrors carrier_onboarding_invitations/driver_portal_sessions exactly. The raw session token lives only in an httpOnly cookie, never at rest here (token_hash only).';

alter table public.carrier_onboarding_sessions enable row level security;
-- No policies -- see table comment above.

create index carrier_onboarding_sessions_application_id_idx on public.carrier_onboarding_sessions (application_id);

-- Cross-org/cross-application consistency guard -- invitation_id and
-- application_id must both resolve to the SAME organization_id as the
-- session row itself, and the invitation must actually belong to the
-- same application. Same shape as guard_carrier_onboarding_invitation_org
-- (0081).
create or replace function public.guard_carrier_onboarding_session_org()
returns trigger
language plpgsql
as $$
declare
  v_application_org uuid;
  v_invitation_org uuid;
  v_invitation_application uuid;
begin
  select organization_id into v_application_org
  from public.carrier_onboarding_applications where id = new.application_id;

  select organization_id, application_id into v_invitation_org, v_invitation_application
  from public.carrier_onboarding_invitations where id = new.invitation_id;

  if v_application_org is null or v_application_org <> new.organization_id then
    raise exception 'Carrier onboarding session must reference an application in the same organization.';
  end if;
  if v_invitation_org is null or v_invitation_org <> new.organization_id then
    raise exception 'Carrier onboarding session must reference an invitation in the same organization.';
  end if;
  if v_invitation_application <> new.application_id then
    raise exception 'Carrier onboarding session''s invitation must belong to the same application.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_onboarding_sessions_guard_org on public.carrier_onboarding_sessions;
create trigger carrier_onboarding_sessions_guard_org
  before insert on public.carrier_onboarding_sessions
  for each row execute function public.guard_carrier_onboarding_session_org();

-- ---------------------------------------------------------------------------
-- PART 2 -- encrypt_carrier_onboarding_ein(): pure, stateless encryption
-- helper. Mirrors compute_carrier_agreement_content_hash()'s (0082) own
-- "safe to ship, no business-mutation logic" shape -- takes plaintext in,
-- returns ciphertext bytes out, touches no table.
--
-- SECURITY: CREATE FUNCTION grants EXECUTE to PUBLIC by default in
-- Postgres -- an easy, dangerous mistake for exactly this kind of
-- function (leaving it callable by anon/authenticated would make it an
-- unrestricted plaintext-to-ciphertext ENCRYPTION oracle, not a decryption
-- one, but still a real misuse surface: anyone could probe it to confirm
-- the encryption scheme/key behavior, or use it to pre-encrypt arbitrary
-- values). The explicit `revoke ... from public` below closes that,
-- leaving EXECUTE granted ONLY to service_role -- callable exclusively
-- from trusted server actions holding the service-role key (never shipped
-- to the browser), never directly from carrier-portal or staff browser
-- code.
-- ---------------------------------------------------------------------------

create or replace function public.encrypt_carrier_onboarding_ein(p_ein text)
returns bytea
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_key text;
begin
  if p_ein is null or btrim(p_ein) = '' then
    return null;
  end if;
  v_key := public.get_app_encryption_key('carrier_pii_key');
  return pgp_sym_encrypt(p_ein, v_key);
end;
$$;

comment on function public.encrypt_carrier_onboarding_ein(text) is
  'Pure encryption helper for carrier_onboarding_applications.ein_encrypted, using the same carrier_pii_key (0081) as reveal_carrier_onboarding_ein(). EXECUTE is restricted to service_role ONLY (see the revoke below) -- never callable from authenticated/anon browser sessions, since the carrier portal itself has no Supabase Auth session to gate this with RLS. Always called from a trusted server action, never directly from client code.';

revoke execute on function public.encrypt_carrier_onboarding_ein(text) from public;
revoke execute on function public.encrypt_carrier_onboarding_ein(text) from authenticated, anon;
grant execute on function public.encrypt_carrier_onboarding_ein(text) to service_role;

-- ---------------------------------------------------------------------------
-- PART 3 -- complete_carrier_agreement_signing(): the one true atomic
-- completion boundary (spec section 12). Also restricted to service_role
-- only -- the carrier portal has no Supabase Auth session, so this is
-- always invoked from a trusted server action that has ALREADY
-- independently verified the caller's carrier_onboarding_sessions cookie
-- and the signing_instance_id's ownership before ever reaching this
-- function.
-- ---------------------------------------------------------------------------

create or replace function public.complete_carrier_agreement_signing(
  p_signing_id uuid,
  p_signer_name text,
  p_signer_title text,
  p_typed_signature text,
  p_consent_text_version text,
  p_ip_address text,
  p_user_agent text
)
returns table (
  signing_id uuid,
  status public.carrier_agreement_signing_status,
  signed_at timestamptz,
  evidence_hash text,
  already_completed boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_signing public.carrier_agreement_signings;
  v_requires_title boolean;
  v_live_content_hash text;
  v_missing_initials integer;
  v_evidence_hash text;
  v_now timestamptz := now();
begin
  -- Lock the row FIRST (spec section 12/21) -- a concurrent second call
  -- for the same signing_id blocks here until the first transaction
  -- commits or rolls back, guaranteeing exactly one caller ever proceeds
  -- past this point while the row is still completable.
  select * into v_signing from public.carrier_agreement_signings where id = p_signing_id for update;
  if v_signing.id is null then
    raise exception 'Signing not found.';
  end if;

  -- Safe retry: a second call that arrives after the first already
  -- completed (whether truly concurrent-and-blocked, or a later retried
  -- request) returns the SAME already-written evidence, never raises,
  -- never re-writes anything, never inserts a second completion audit
  -- event.
  if v_signing.status = 'completed' then
    return query select v_signing.id, v_signing.status, v_signing.signed_at, v_signing.evidence_hash, true;
    return;
  end if;

  -- 'assigned' is accepted here too, not just 'in_progress': initials may
  -- legally be recorded while a signing is still 'assigned' (see
  -- guard_carrier_agreement_initial_consistency, 0082), so there is no
  -- separate "start signing" step/transition this function depends on --
  -- completion itself is the one place assigned-or-in_progress ->
  -- completed happens, atomically, alongside everything else below.
  if v_signing.status not in ('assigned', 'in_progress') then
    raise exception 'This agreement is not ready to be completed (status=%).', v_signing.status;
  end if;

  if p_signer_name is null or btrim(p_signer_name) = '' then
    raise exception 'Full legal name is required.';
  end if;
  if p_typed_signature is null or btrim(p_typed_signature) = '' then
    raise exception 'Typed signature is required.';
  end if;
  if p_consent_text_version is null or btrim(p_consent_text_version) = '' then
    raise exception 'Electronic records/signature consent must be accepted.';
  end if;

  select requires_signer_title, content_hash into v_requires_title, v_live_content_hash
  from public.carrier_agreement_templates where id = v_signing.agreement_template_id;

  if v_requires_title and (p_signer_title is null or btrim(p_signer_title) = '') then
    raise exception 'Signer title is required for this agreement.';
  end if;

  -- Recompute/verify: the signing's own content_hash snapshot (taken at
  -- assignment) must still agree with the template's own immutable,
  -- published content_hash. These should always match -- publishing
  -- freezes the template -- but this is re-verified rather than trusted
  -- blindly, matching this schema's own "guard triggers, not discipline
  -- alone" convention.
  if v_signing.content_hash is distinct from v_live_content_hash then
    raise exception 'This agreement''s content has changed since it was assigned -- it cannot be completed. Contact the office.';
  end if;

  -- Required-initial enforcement: every clause on this template that
  -- requires_initials must have a matching carrier_agreement_initials row
  -- for THIS signing instance.
  select count(*) into v_missing_initials
  from public.carrier_agreement_clauses c
  where c.agreement_template_id = v_signing.agreement_template_id
    and c.requires_initials
    and not exists (
      select 1 from public.carrier_agreement_initials i
      where i.signing_instance_id = v_signing.id and i.clause_id = c.id
    );
  if v_missing_initials > 0 then
    raise exception 'All clauses requiring initials must be initialed before signing (% remaining).', v_missing_initials;
  end if;

  v_evidence_hash := encode(digest(concat_ws('|',
    v_signing.id::text,
    v_signing.content_hash,
    p_signer_name,
    coalesce(p_signer_title, ''),
    p_typed_signature,
    p_consent_text_version,
    v_now::text
  ), 'sha256'), 'hex');

  update public.carrier_agreement_signings set
    signer_name = p_signer_name,
    signer_title = p_signer_title,
    signature_type = 'typed',
    typed_signature = p_typed_signature,
    consent_text_version = p_consent_text_version,
    consent_accepted_at = v_now,
    ip_address = p_ip_address,
    user_agent = p_user_agent,
    evidence_hash = v_evidence_hash,
    signed_at = v_now,
    completed_at = v_now,
    status = 'completed'
  where id = v_signing.id;

  insert into public.carrier_agreement_audit_events
    (organization_id, signing_instance_id, event_type, actor_type, occurred_at, ip_address, user_agent)
  values
    (v_signing.organization_id, v_signing.id, 'agreement_completed', 'carrier_signer', v_now, p_ip_address, p_user_agent);

  return query select v_signing.id, 'completed'::public.carrier_agreement_signing_status, v_now, v_evidence_hash, false;
end;
$$;

comment on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) is
  'The ONE atomic completion boundary for a carrier agreement signing (spec section 12). Locks the target row (select ... for update) before validating anything, so a concurrent duplicate call safely blocks then returns the already-completed result rather than double-completing or double-auditing. Validates required initials, consent, signer name/title, typed signature, and live content-hash agreement; on any failure, raises and writes NOTHING (no partial completion). EXECUTE restricted to service_role only -- see the revoke below.';

revoke execute on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) from public;
revoke execute on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) from authenticated, anon;
grant execute on function public.complete_carrier_agreement_signing(uuid, text, text, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- PART 3A -- Phase 2L.4B: exactly one CURRENT published version per
-- logical agreement family. The row-per-version schema keeps
-- (organization_id, template_key) on this table, so a partial unique
-- index expresses the rule directly and safely under concurrency. A
-- second version cannot be published until staff explicitly retires the
-- current one; existing signings remain attached to their exact template
-- row and content hash.
-- ---------------------------------------------------------------------------

create unique index carrier_agreement_templates_one_published_per_key_idx
  on public.carrier_agreement_templates (organization_id, template_key)
  where status = 'published';

-- ---------------------------------------------------------------------------
-- PART 3B -- Phase 2L.4A: active-signing uniqueness per (application,
-- logical agreement family). "Logical agreement family" = template_key,
-- NOT agreement_template_id -- different version rows of the same
-- agreement share one template_key (0082's own row-per-version design),
-- so this must join through carrier_agreement_templates rather than
-- compare agreement_template_id directly. A plain partial unique index
-- cannot express a cross-table rule like this, so it's a guard trigger,
-- matching every other cross-table invariant already enforced this way in
-- 0081/0082 (guard_carrier_agreement_signing_org, etc.).
--
-- Business rule: for one application, at most ONE non-voided signing may
-- exist per template_key. Voiding a signing frees its template_key up for
-- a fresh assignment (including a different version of the same key).
-- Different template_keys may always coexist.
--
-- Concurrency: two simultaneous INSERTs for the same (application_id,
-- template_key) both pass a naive "does a conflicting row exist yet?"
-- SELECT before either has committed. Serialized with a transaction-scoped
-- advisory lock keyed on exactly that pair (not a global lock) --
-- pg_advisory_xact_lock's two-int4-argument form takes hashtext(app id)
-- and hashtext(template_key) as a compound key, released automatically at
-- transaction end (commit or rollback), so a losing concurrent inserter
-- blocks here until the winner's transaction resolves, then sees its row
-- and correctly raises instead of racing past the check.
-- ---------------------------------------------------------------------------

create or replace function public.guard_carrier_agreement_signing_active_uniqueness()
returns trigger
language plpgsql
as $$
declare
  v_template_key text;
  v_conflict_id uuid;
begin
  select template_key into v_template_key
  from public.carrier_agreement_templates
  where id = new.agreement_template_id;

  if v_template_key is null then
    raise exception 'Agreement template not found.';
  end if;

  -- Voided signings never conflict -- a fresh assignment (same or
  -- different version of this key) is always legal once the prior one is
  -- voided, per spec.
  if new.status = 'voided' then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtext(new.application_id::text), hashtext(v_template_key));

  select s.id into v_conflict_id
  from public.carrier_agreement_signings s
  join public.carrier_agreement_templates t on t.id = s.agreement_template_id
  where s.application_id = new.application_id
    and t.template_key = v_template_key
    and s.status <> 'voided'
    and s.id is distinct from new.id
  limit 1;

  if v_conflict_id is not null then
    raise exception 'An active version of this agreement is already assigned to this application. Void the existing agreement before assigning another version.';
  end if;

  return new;
end;
$$;

drop trigger if exists carrier_agreement_signings_active_uniqueness_guard on public.carrier_agreement_signings;
create trigger carrier_agreement_signings_active_uniqueness_guard
  before insert or update on public.carrier_agreement_signings
  for each row execute function public.guard_carrier_agreement_signing_active_uniqueness();

-- ---------------------------------------------------------------------------
-- PART 4 -- convert_carrier_onboarding_application(): atomic
-- approved -> converted, called directly by an authenticated owner/admin
-- staff session (mirrors convert_driver_application_to_driver's own
-- `grant ... to authenticated` precedent, 0018) -- NOT service-role-only,
-- since this always runs on behalf of a real logged-in staff member, not
-- an anonymous carrier-portal session.
-- ---------------------------------------------------------------------------

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
begin
  select * into v_app from public.carrier_onboarding_applications where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application to a carrier.';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only an approved application can be converted (current status=%).', v_app.status;
  end if;

  -- Required-agreement conversion gate (Phase 2L.4B): the unique partial
  -- index above makes each published row the one CURRENT version for its
  -- (organization_id, template_key). Every current published row marked
  -- required contributes one logical template_key to this gate.
  --
  -- A signing counts toward satisfying its key regardless of whether that
  -- SPECIFIC template row is still 'published' at conversion time --
  -- retiring a template after a carrier already legitimately completed it
  -- must never retroactively un-satisfy a requirement they already met
  -- (only the denominator -- which keys currently require a signing at
  -- all -- is scoped to status='published', so an org that retires every
  -- version of a key without publishing a replacement is treated the same
  -- as never having required it).
  --
  -- Exactly one non-voided signing for that key must exist and it must be
  -- completed. The signing template itself need not still be published or
  -- marked required: a legitimately assigned older version remains valid
  -- after retirement. The active-signing guard above makes the count=1
  -- invariant authoritative for new writes; spelling it out here also
  -- prevents legacy duplicate rows from accidentally passing conversion.
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
      join public.carrier_agreement_templates t on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status <> 'voided'
        and t.template_key = required_keys.template_key
    )
    or not exists (
      select 1
      from public.carrier_agreement_signings s
      join public.carrier_agreement_templates t on t.id = s.agreement_template_id
      where s.application_id = p_application_id
        and s.status = 'completed'
        and t.template_key = required_keys.template_key
    )
  ) into v_missing_required_agreement;

  if v_missing_required_agreement then
    raise exception 'One or more required dispatch agreements have not been completed for this application.';
  end if;

  -- ein is deliberately NOT copied to carriers.ein (spec section 3):
  -- carriers.ein is a plain, unencrypted column with no column-level
  -- access restriction today -- a pre-existing condition this phase does
  -- not change. Writing the applicant's encrypted EIN into it in
  -- plaintext here would silently defeat the protection 0081 just built.
  -- Left null/unchanged; flagged for a future carrier-level PII
  -- encryption phase (see the Phase 2L.4 implementation report).
  insert into public.carriers (
    organization_id, legal_name, dba_name, mc_number, dot_number,
    contact_name, phone, email,
    address_line1, address_line2, city, state, postal_code, country,
    factoring_company_name
  ) values (
    v_app.organization_id, v_app.legal_name, v_app.dba_name, v_app.mc_number, v_app.dot_number,
    v_app.contact_name, v_app.phone, v_app.email,
    v_app.address_line1, v_app.address_line2, v_app.city, v_app.state, v_app.postal_code, coalesce(v_app.country, 'US'),
    v_app.factoring_company_name
  )
  returning id into v_carrier_id;

  update public.carrier_onboarding_applications set
    status = 'converted',
    converted_at = now(),
    converted_by = auth.uid(),
    converted_carrier_id = v_carrier_id
  where id = p_application_id;

  return v_carrier_id;
end;
$$;

comment on function public.convert_carrier_onboarding_application(uuid) is
  'Atomically creates the real public.carriers row and marks the application converted. Enforces the required-agreement gate at this DB boundary (spec section 4), not merely staff-UI button visibility. carriers.ein is deliberately left null -- see this function''s own inline comment. owner/admin only.';

grant execute on function public.convert_carrier_onboarding_application(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- PART 5 -- indexes for the new session table's own lookup path
-- (token_hash's `unique` constraint already backs the primary lookup;
-- application_id index added in Part 1 above).
-- ---------------------------------------------------------------------------
-- (No further indexes needed.)
