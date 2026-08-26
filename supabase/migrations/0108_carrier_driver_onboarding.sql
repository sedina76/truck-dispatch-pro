-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Phase 2Q.2 -- Carrier-Assigned Driver Onboarding.
--
-- DO NOT APPLY WITHOUT APPROVAL. Authored for review only, mirroring the
-- exact "written but not yet applied" convention already used for 0099/etc.
-- elsewhere in this codebase.
--
-- WHY THIS IS NEEDED (audited first; see PHASE 2Q.2 report Section 29/30):
-- the existing public driver_applications table (0018) already has almost
-- everything a carrier-invited application needs (personal info, CDL,
-- medical card, uploaded_documents, review workflow, and a working
-- convert_driver_application_to_driver() RPC) -- reused as-is below, NOT
-- duplicated. What genuinely does not exist yet and cannot be built
-- without schema changes:
--   1. New lifecycle states (invited / in_progress / needs_correction /
--      expired / cancelled) that the current driver_application_status
--      enum has no values for.
--   2. A hashed-token invitation + session pair for the driver-onboarding
--      portal, mirroring carrier_onboarding_invitations/_sessions (0081/
--      0084) exactly -- there is no existing driver-facing equivalent (the
--      public flow is anonymous with no invitation at all; the driver
--      PORTAL (0015) is phone+PIN post-hire, not an onboarding intake).
--   3. Two small columns (invited_by, correction_reason) the new staff
--      workflow needs and the old anonymous-only table never had a reason
--      to carry.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. New driver_application_status values. Added individually and used
-- only in code below/after this migration file -- PostgreSQL 12+ allows a
-- newly added enum value to be used later in the SAME transaction, so this
-- is safe as a single migration file.
-- ---------------------------------------------------------------------------
alter type public.driver_application_status add value if not exists 'invited';
alter type public.driver_application_status add value if not exists 'in_progress';
alter type public.driver_application_status add value if not exists 'needs_correction';
alter type public.driver_application_status add value if not exists 'expired';
alter type public.driver_application_status add value if not exists 'cancelled';

-- ---------------------------------------------------------------------------
-- 2. driver_applications: two additive columns for the carrier-invited
-- workflow. Nothing here changes any existing column, row, or the public
-- /driver-application flow's behavior.
-- ---------------------------------------------------------------------------
alter table public.driver_applications
  add column if not exists invited_by uuid references public.profiles (id) on delete set null,
  add column if not exists correction_reason text check (correction_reason is null or char_length(correction_reason) <= 2000);

comment on column public.driver_applications.invited_by is
  'The staff profile who created this application via Invite Driver (2Q.2). NULL for applications submitted through the public /driver-application form -- that remains the distinguishing signal between the two origins, rather than a duplicated "source" column.';
comment on column public.driver_applications.correction_reason is
  'Staff-entered explanation shown to the driver when status = needs_correction. Bounded length; never contains document contents or PII beyond what staff choose to type.';

-- Additive grants -- the existing revoke-then-grant-columns pattern from
-- 0018 already locked this table down to an explicit column allow-list;
-- these GRANTs add to that list, they do not replace it.
grant select (invited_by, correction_reason) on public.driver_applications to authenticated;
grant update (correction_reason) on public.driver_applications to authenticated;

-- Staff (owner/admin only -- see 2Q.2 report Section 5 for why dispatcher
-- was deliberately NOT included) can create an application directly via
-- Invite Driver, distinct from submit_driver_application() (the anonymous
-- SECURITY DEFINER path used by the public form, unchanged). No such
-- INSERT policy existed before -- driver_applications previously had zero
-- authenticated-insert path at all, so 0018 never needed to touch the
-- table's INSERT grant either. It still carries Supabase's original
-- unrestricted table-level INSERT grant to authenticated/anon from when
-- the table was first created -- harmless while RLS had no INSERT policy
-- at all (RLS denies by default), but the moment a policy is added below,
-- that dormant blanket grant becomes live and would let an inserting
-- owner/admin set ANY column (not just the ones Invite Driver actually
-- fills in) subject only to the WITH CHECK predicate. Narrowed here the
-- same way 0018 already narrowed SELECT and UPDATE: revoke the blanket
-- grant, then grant INSERT on exactly the columns the new invite path
-- writes.
revoke insert on public.driver_applications from authenticated, anon;
grant insert (organization_id, status, first_name, middle_name, last_name, email, phone, signature_name, invited_by)
  on public.driver_applications to authenticated;

create policy driver_applications_insert_staff on public.driver_applications
  for insert
  with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
    and status = 'invited'
  );

-- ---------------------------------------------------------------------------
-- 3. driver_onboarding_invitations / driver_onboarding_sessions -- mirror
-- carrier_onboarding_invitations (0081) and carrier_onboarding_sessions
-- (0084) column-for-column and RLS-for-RLS (enabled, zero policies:
-- service-role-only access from trusted server code, exactly like those
-- two tables and driver_portal_sessions before them). Kept as their own
-- tables rather than widening the carrier-onboarding ones: a driver
-- invitation belongs to driver_applications, not
-- carrier_onboarding_applications, and the two should never be joinable
-- by accident.
-- ---------------------------------------------------------------------------
create table public.driver_onboarding_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.driver_applications (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid not null references public.profiles (id) on delete set null,
  first_viewed_at timestamptz,
  last_viewed_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references public.profiles (id) on delete set null,
  submitted_at timestamptz
);

comment on table public.driver_onboarding_invitations is
  'Secure, hashed-token driver onboarding invitations (2Q.2). RLS enabled with ZERO policies -- deliberately mirrors carrier_onboarding_invitations (0081): accessed exclusively via the service_role key from trusted server code (see src/lib/driver-onboarding/invitation.ts and the staff-side query helper in drivers/applications/actions.ts), never a client-side RLS-scoped query. The raw token is never stored, only its sha256 hash.';

alter table public.driver_onboarding_invitations enable row level security;
-- No policies -- see table comment above. The staff review page reads
-- this via a service-role helper after independently re-checking the
-- caller's own org/role first, the same pattern
-- src/app/(app)/carriers/onboarding/[id]/page.tsx SHOULD use for
-- carrier_onboarding_invitations but currently does not -- see 2Q.2
-- report Section 37 for that pre-existing, separate finding.

create index driver_onboarding_invitations_application_id_idx on public.driver_onboarding_invitations (application_id);

create table public.driver_onboarding_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  application_id uuid not null references public.driver_applications (id) on delete cascade,
  invitation_id uuid not null references public.driver_onboarding_invitations (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  user_agent text,
  revoked_at timestamptz
);

comment on table public.driver_onboarding_sessions is
  'The ongoing driver-onboarding-portal credential, bootstrapped exactly once from a raw invitation token at /driver-onboarding/[token]. RLS enabled with ZERO policies -- service-role-only, mirrors carrier_onboarding_sessions/driver_portal_sessions exactly. The raw session token lives only in an httpOnly cookie, never at rest here (token_hash only).';

alter table public.driver_onboarding_sessions enable row level security;
-- No policies -- see table comment above.

create index driver_onboarding_sessions_application_id_idx on public.driver_onboarding_sessions (application_id);

-- ---------------------------------------------------------------------------
-- 4. convert_driver_application_to_driver: tighten the existing function
-- to require status = 'approved' before conversion, closing a real gap
-- found during this phase's audit of existing conversion logic (2Q.2
-- report Section 18) -- the function previously only blocked converting
-- an ALREADY-converted application, not one that was never approved at
-- all. Backward compatible with the existing public-flow UI: it already
-- offers "Approved" as a selectable status before the Hire & Convert form
-- is used, this just makes that ordering a hard server-side requirement
-- instead of a UI convention. Everything else about the function --
-- ownership check, role check, encrypted-SSN copy, duplicate-conversion
-- guard -- is unchanged, EXCEPT the initial select now takes `for update`
-- (2Q.2 report Section 19/34 -- "simultaneous conversion"): two staff
-- members clicking Convert on the same application at the same instant
-- previously could both pass the "not already converted" check before
-- either UPDATE committed, creating two driver rows from one application.
-- `for update` locks the row for the rest of this transaction, so the
-- second concurrent call blocks until the first commits, then correctly
-- sees status = 'converted' and raises the existing exception instead of
-- creating a duplicate.
-- ---------------------------------------------------------------------------
create or replace function public.convert_driver_application_to_driver(p_application_id uuid, p_carrier_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app public.driver_applications;
  v_driver_id uuid;
begin
  select * into v_app from public.driver_applications where id = p_application_id for update;
  if v_app.id is null or v_app.organization_id <> public.current_org_id() then
    raise exception 'Application not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may convert an application';
  end if;
  if v_app.status = 'converted' then
    raise exception 'This application has already been converted';
  end if;
  if v_app.status <> 'approved' then
    raise exception 'Only approved applications can be converted to a driver. Set this application to Approved first.';
  end if;
  if not exists (select 1 from public.carriers where id = p_carrier_id and organization_id = v_app.organization_id) then
    raise exception 'Carrier not found in your organization';
  end if;

  insert into public.drivers (
    organization_id, carrier_id, first_name, middle_name, last_name, phone, email,
    date_of_birth, address_line1, city, state, postal_code,
    emergency_contact_name, emergency_contact_phone,
    cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
    medical_card_expiry_date, status, ssn_encrypted, ssn_last4
  ) values (
    v_app.organization_id, p_carrier_id, v_app.first_name, v_app.middle_name, v_app.last_name,
    v_app.phone, v_app.email, v_app.date_of_birth, v_app.address_line1, v_app.city, v_app.state, v_app.postal_code,
    v_app.emergency_contact_name, v_app.emergency_contact_phone,
    v_app.cdl_number, v_app.cdl_state, v_app.cdl_class, v_app.cdl_endorsements, v_app.cdl_expiry_date,
    v_app.medical_card_expiry_date, 'applicant', v_app.ssn_encrypted, v_app.ssn_last4
  )
  returning id into v_driver_id;

  update public.driver_applications
    set status = 'converted', converted_driver_id = v_driver_id, updated_at = now()
    where id = p_application_id;

  return v_driver_id;
end;
$$;
-- grant execute unchanged -- already granted to authenticated by 0018 and
-- not revoked since; CREATE OR REPLACE preserves existing grants.
