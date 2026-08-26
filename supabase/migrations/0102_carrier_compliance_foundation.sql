-- =============================================================================
-- 0102_carrier_compliance_foundation.sql
-- Phase 2P.2: the smallest safe database foundation capable of answering
-- "CAN THIS CARRIER BE DISPATCHED RIGHT NOW?" -- WITHOUT enforcing it
-- against dispatches yet. No trigger on public.dispatches is added by this
-- migration. No existing row is mutated. No organization's behavior
-- changes the moment this applies.
--
-- Built on the Phase 2P.1 audit's central finding: public.compliance_items
-- (0005) + public.operational_exceptions (0063, "Exception Center") already
-- form a working, production-proven expiring-credential tracker and
-- notification pipeline. This migration extends that existing layer
-- (adds columns, never replaces it) and adds exactly three new tables plus
-- one new organization-level setting on top of it:
--
--   compliance_requirement_definitions  -- WHAT must be true (system + org config)
--   compliance_items (extended)          -- the existing per-entity instance layer
--   carrier_suspensions                  -- explicit, manual, history-preserving
--   compliance_overrides                 -- owner/admin-only, reason-required
--   organizations.compliance_enforcement_mode -- audit_only (default) / warning / enforced
--   carrier_dispatch_readiness()         -- the one authoritative read function
--
-- Architectural decisions this migration implements exactly as authorized
-- (Phase 2P.2 instructions):
--   1. Agreements: NOT re-keyed to carrier_id. Resolved via
--      carriers.id -> carrier_onboarding_applications.converted_carrier_id
--      -> carrier_agreement_signings. A carrier with no backing application
--      resolves the agreement requirement as MISSING -- never invented.
--   2. compliance_items remains the ONE instance layer for generic/manual
--      requirements. No competing carrier_compliance_requirements table.
--   3. compliance_enforcement_mode defaults to 'audit_only' for every
--      organization, existing and future -- mirrors gps_automation_mode's
--      own proven "never default an existing org into stricter behavior"
--      precedent (0059).
--   4. Suspension is explicit and manual only. Nothing in this migration
--      (or the readiness function) ever inserts into carrier_suspensions
--      automatically. Missing/expired requirements produce NOT_READY/
--      WARNING, never SUSPENDED.
--   5. carriers.is_active is never read, written, or referenced by
--      anything in this migration. ACTIVE + NOT_READY is a valid,
--      unremarked-upon state by design.
-- =============================================================================

-- =============================================================================
-- PART 1 -- organizations: enforcement mode.
--
-- Truth (readiness) and policy (enforcement) are different concepts (2P.2
-- section 8) -- this column is the ONLY thing 0102 adds that represents
-- policy. carrier_dispatch_readiness() reports this value alongside the
-- honest computed status; it never lets this value change what status it
-- reports. No caller anywhere reads this column to change behavior yet --
-- that begins in a future dispatch-enforcement phase.
-- =============================================================================

create type public.compliance_enforcement_mode as enum ('audit_only', 'warning', 'enforced');

alter table public.organizations
  add column if not exists compliance_enforcement_mode public.compliance_enforcement_mode not null default 'audit_only';

comment on column public.organizations.compliance_enforcement_mode is
  'Carrier Compliance Readiness (Phase 2P) rollout mode. audit_only (default for every org, including every pre-existing one) = readiness is computed and queryable but nothing blocks or warns in the UI/dispatch flow. warning = surfaced to staff, still non-blocking. enforced = a future phase''s dispatch gate actually refuses a NOT_READY/SUSPENDED assignment. 0102 adds no enforcement of any kind regardless of this value -- see carrier_dispatch_readiness()''s own header comment.';

-- =============================================================================
-- PART 2 -- compliance_requirement_definitions: WHAT must be true.
--
-- Hybrid model per the 2P.1 recommendation: organization_id IS NULL rows
-- are CORE system definitions (seeded by this migration, PART 5), visible
-- to every organization but writable by none (see RLS below); organization_id
-- IS NOT NULL rows are an organization's own additions/overrides of the
-- same requirement_key, which the readiness function prefers when both
-- exist (PART 6, "distinct on" precedence). A system definition can never
-- be silently disabled by a tenant -- there is no UPDATE/DELETE path to a
-- null-organization_id row for anyone but a future migration.
--
-- Field design deliberately avoids storing two facts that would silently
-- drift out of sync (2P.2 instruction: "avoid redundant flags where one
-- clearly implies another"):
--   - `required` is NOT a stored column -- it is exactly
--     `classification in ('blocking', 'warning')`. Something "optional" or
--     "informational" is, by definition, not required; storing both would
--     let a future edit set required=true, classification='optional' and
--     leave no way to know which one is authoritative.
--   - `dispatch_blocking` is NOT a stored column -- it is exactly
--     `classification = 'blocking'`. The classification IS the dispatch-
--     relevant severity; a second boolean saying the same thing again
--     could disagree with it after an edit.
--   - `enabled` is NOT a separate column from `is_active` -- one boolean,
--     one meaning.
-- `resolution_source` + `resolution_key` are the "source adapter" contract
-- carrier_dispatch_readiness() (PART 6) switches on -- see that function's
-- header for the full adapter list. This is what keeps W-9/agreement/
-- insurance truth OUT of compliance_items (2P.2 instruction: "do not
-- duplicate truth into compliance_items merely to make the query easier").
-- =============================================================================

create table public.compliance_requirement_definitions (
  id uuid primary key default gen_random_uuid(),
  -- null = system-wide core definition. Non-null = this organization's own
  -- addition or override of the same (entity_type, requirement_key).
  organization_id uuid references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  requirement_key text not null check (btrim(requirement_key) <> ''),
  display_name text not null check (btrim(display_name) <> ''),
  description text,

  classification text not null check (classification in ('blocking', 'warning', 'optional', 'informational')),

  -- Which adapter carrier_dispatch_readiness() uses to find the truth for
  -- this requirement, and (for insurance/carrier_field) which specific
  -- value within that source it means.
  resolution_source text not null check (resolution_source in ('w9', 'agreement', 'insurance', 'carrier_field', 'compliance_item')),
  resolution_key text,

  expiration_required boolean not null default false,
  warning_days integer check (warning_days is null or warning_days > 0),
  verification_required boolean not null default false,
  overridable boolean not null default true,
  is_active boolean not null default true,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,

  -- Sane-combination guards (2P.2 section "Requirement Definitions").
  constraint compliance_requirement_definitions_informational_shape check (
    classification <> 'informational' or (verification_required = false and expiration_required = false)
  ),
  constraint compliance_requirement_definitions_insurance_needs_key check (
    resolution_source <> 'insurance' or resolution_key is not null
  ),
  constraint compliance_requirement_definitions_expiration_source check (
    not expiration_required or resolution_source in ('insurance', 'compliance_item')
  ),
  -- w9/agreement are one-time completion facts in this design, not
  -- dated credentials -- an expiry_date concept for them would have no
  -- real source column to read (carrier_w9s/carrier_agreement_signings
  -- have no "renewal date"). carrier_field (identifier presence) is a
  -- point-in-time fact, not a dated credential, so it is excluded too --
  -- see resolution_source='carrier_field' commentary in PART 6.
  constraint compliance_requirement_definitions_w9_agreement_no_key check (
    resolution_source not in ('w9', 'agreement') or resolution_key is null
  )
);

comment on table public.compliance_requirement_definitions is
  'WHAT must be true for an entity to be dispatch-ready (Phase 2P). System rows (organization_id null) are seeded here and immutable to every tenant; an organization may add its own rows for the same (entity_type, requirement_key) to override classification/thresholds -- carrier_dispatch_readiness() prefers the organization-specific row when both exist. Never referenced by any dispatch trigger in this migration.';

drop trigger if exists set_updated_at on public.compliance_requirement_definitions;
create trigger set_updated_at before update on public.compliance_requirement_definitions
  for each row execute function public.set_updated_at();

-- Two partial unique indexes, not one constraint spanning both, because
-- NULL organization_id values are never equal to each other under a plain
-- UNIQUE constraint (Postgres treats every NULL as distinct) -- a single
-- constraint would silently allow duplicate system rows for the same key.
create unique index compliance_requirement_definitions_system_key
  on public.compliance_requirement_definitions (entity_type, requirement_key)
  where organization_id is null;
create unique index compliance_requirement_definitions_org_key
  on public.compliance_requirement_definitions (organization_id, entity_type, requirement_key)
  where organization_id is not null;
create index compliance_requirement_definitions_org_lookup
  on public.compliance_requirement_definitions (organization_id, entity_type)
  where organization_id is not null and is_active;

alter table public.compliance_requirement_definitions enable row level security;

-- SELECT: any org member sees both their own org's rows AND every system
-- (organization_id is null) row -- a plain `organization_id =
-- current_org_id()` predicate would exclude system rows entirely (NULL
-- never equals a uuid), so this is written as an explicit OR.
create policy compliance_requirement_definitions_select on public.compliance_requirement_definitions
  for select using (organization_id = public.current_org_id() or organization_id is null);

-- WRITE: owner/admin only, and `with check (organization_id =
-- current_org_id())` structurally excludes ever writing a null-organization_id
-- (system) row or another organization's row -- a tenant has no predicate
-- under which that check can pass. This is the "no cross-org security
-- hole, no tenant can disable a system requirement" guarantee from a
-- single, ordinary RLS clause, with no special-casing needed.
create policy compliance_requirement_definitions_insert on public.compliance_requirement_definitions
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
create policy compliance_requirement_definitions_update on public.compliance_requirement_definitions
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());
-- No delete policy: an organization-level override, once created, is
-- deactivated via is_active = false (preserving history of what was once
-- configured), never deleted -- matches every other "soft-disable, never
-- hard-delete a configuration row" precedent in this schema.

-- =============================================================================
-- PART 3 -- compliance_items extension.
--
-- Additive only. Every existing row is valid with both new columns NULL --
-- no backfill, no requirement that a historical row ever acquire a
-- requirement_definition_id. Existing pages (src/app/(app)/compliance/*)
-- and refresh_compliance_statuses()/sync_time_based_exceptions() are
-- completely unaffected: neither new column is read by either of those
-- existing functions, and this migration does not modify them.
--
-- Verification: deliberately NOT duplicating documents.is_verified.
-- compliance_items.document_id already links to a documents row, which
-- already carries is_verified/verified_by/verified_at for "is this FILE
-- authentic/reviewed" -- that question is about the evidence artifact.
-- verified_by/verified_at added here answer a DIFFERENT question -- "has
-- this REQUIREMENT been confirmed satisfied" -- which can be true with no
-- document at all (a manually-attested requirement) or need re-confirming
-- even when the underlying document was already marked verified for an
-- unrelated reason. carrier_dispatch_readiness() (PART 6) resolves
-- verification for a compliance_item by checking THIS column first, and
-- only falls back to the linked document's is_verified when this column
-- is null and a document_id exists -- documented there, not duplicated
-- here as a second source of truth.
-- =============================================================================

alter table public.compliance_items
  add column if not exists requirement_definition_id uuid references public.compliance_requirement_definitions (id) on delete set null,
  add column if not exists verified_by uuid references public.profiles (id) on delete set null,
  add column if not exists verified_at timestamptz;

alter table public.compliance_items
  add constraint compliance_items_verification_shape check ((verified_by is null) = (verified_at is null));

comment on column public.compliance_items.requirement_definition_id is
  'Optional link to the compliance_requirement_definitions row this item instantiates (Phase 2P). NULL for every pre-2P.2 row and for any future manually-created item with no matching definition -- carrier_dispatch_readiness() only consults items that DO have this set, for the generic resolution_source=''compliance_item'' adapter. Existing Compliance dashboard pages that read compliance_items directly are unaffected either way.';
comment on column public.compliance_items.verified_by is
  'Requirement-level verification (Phase 2P), independent of documents.is_verified -- see this migration''s PART 3 header for why these are deliberately not the same fact. NULL means unverified; both this and verified_at are always set or unset together.';

-- =============================================================================
-- PART 4 -- carrier_suspensions: explicit, manual, history-preserving.
--
-- Deliberately NOT a single boolean on carriers (2P.2 instruction) --
-- "is this carrier suspended" must also answer why/by whom/when, and a
-- carrier suspended twice in its lifetime should keep both episodes, not
-- overwrite the first. Same "at most one ACTIVE episode, full history
-- retained" shape already proven by broker_packets' supersession chain and
-- operational_exceptions' own episode model (0063) -- a partial unique
-- index enforces "at most one currently-active suspension per carrier",
-- nothing more exotic than that.
--
-- Nothing in this migration ever inserts into this table automatically.
-- The only write paths are the two RPCs below, both owner/admin-only.
-- =============================================================================

create table public.carrier_suspensions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  reason text not null check (btrim(reason) <> ''),
  suspended_by uuid references public.profiles (id) on delete set null,
  suspended_at timestamptz not null default now(),
  lifted_at timestamptz,
  lifted_by uuid references public.profiles (id) on delete set null,
  lifted_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint carrier_suspensions_lift_shape check (lifted_at is not null or (lifted_by is null and lifted_reason is null))
);

comment on table public.carrier_suspensions is
  'Explicit, manual carrier suspension history (Phase 2P). "Currently suspended" = exists a row for this carrier with lifted_at is null (enforced unique below). Never written to automatically by any requirement/expiration/compliance logic -- see suspend_carrier()/lift_carrier_suspension() below, the only two write paths, both owner/admin-only.';

drop trigger if exists set_updated_at on public.carrier_suspensions;
create trigger set_updated_at before update on public.carrier_suspensions
  for each row execute function public.set_updated_at();

create unique index carrier_suspensions_one_active_per_carrier
  on public.carrier_suspensions (carrier_id) where lifted_at is null;
create index carrier_suspensions_carrier_lookup on public.carrier_suspensions (carrier_id);

alter table public.carrier_suspensions enable row level security;

create policy carrier_suspensions_select on public.carrier_suspensions
  for select using (organization_id = public.current_org_id());
-- No insert/update policy for authenticated at all: suspend_carrier()/
-- lift_carrier_suspension() are SECURITY DEFINER and are the only
-- sanctioned write path -- matches void_carrier_w9()/void_broker_packet()'s
-- own "RLS closed, RPC is SECURITY DEFINER and does its own role check"
-- precedent exactly. No delete policy: suspension history is never deleted.

create or replace function public.guard_carrier_suspension_relationships()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from public.carriers where id = new.carrier_id and organization_id = new.organization_id) then
    raise exception 'Suspension carrier must belong to the same organization.';
  end if;
  return new;
end;
$$;

create trigger carrier_suspensions_relationships_guard
  before insert on public.carrier_suspensions
  for each row execute function public.guard_carrier_suspension_relationships();

create or replace function public.suspend_carrier(p_carrier_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org_id uuid; v_id uuid;
begin
  select organization_id into v_org_id from public.carriers where id = p_carrier_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Carrier not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may suspend a carrier.';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'A suspension reason is required.';
  end if;
  if exists (select 1 from public.carrier_suspensions where carrier_id = p_carrier_id and lifted_at is null) then
    raise exception 'This carrier is already suspended.';
  end if;

  insert into public.carrier_suspensions (organization_id, carrier_id, reason, suspended_by)
  values (v_org_id, p_carrier_id, btrim(p_reason), auth.uid())
  returning id into v_id;

  perform public.log_activity('carrier'::public.entity_type, p_carrier_id, 'carrier_suspended', jsonb_build_object('suspension_id', v_id), v_org_id);
  return v_id;
end;
$$;

comment on function public.suspend_carrier(uuid, text) is
  'Owner/admin-only. Does NOT touch carriers.is_active -- suspension and roster-active status are deliberately independent (Phase 2P). Refuses if the carrier already has an active suspension (lift it first).';

revoke execute on function public.suspend_carrier(uuid, text) from public, anon;
grant execute on function public.suspend_carrier(uuid, text) to authenticated;

create or replace function public.lift_carrier_suspension(p_carrier_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_org_id uuid;
begin
  select organization_id into v_org_id from public.carriers where id = p_carrier_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Carrier not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may lift a carrier suspension.';
  end if;

  update public.carrier_suspensions
  set lifted_at = now(), lifted_by = auth.uid(), lifted_reason = nullif(btrim(coalesce(p_reason, '')), '')
  where carrier_id = p_carrier_id and lifted_at is null;
  if not found then raise exception 'This carrier has no active suspension.'; end if;

  perform public.log_activity('carrier'::public.entity_type, p_carrier_id, 'carrier_suspension_lifted', null, v_org_id);
end;
$$;

revoke execute on function public.lift_carrier_suspension(uuid, text) from public, anon;
grant execute on function public.lift_carrier_suspension(uuid, text) to authenticated;

-- =============================================================================
-- PART 5 -- compliance_overrides.
--
-- Recording only, in this migration -- no trigger anywhere consults this
-- table to actually permit/deny anything (2P.2 instruction: "no override
-- should actually permit/deny a dispatch in 0102", since no dispatch gate
-- exists yet). An override never changes the underlying fact: it does not
-- write to compliance_items, insurance_policies, carrier_w9s, or
-- carrier_agreement_signings -- expired insurance stays EXPIRED.
-- carrier_dispatch_readiness() (PART 6) reports an active override
-- alongside a requirement's true status, it does not hide the true status.
-- =============================================================================

create table public.compliance_overrides (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete cascade,
  -- Null = a blanket carrier-level override (all currently-blocking
  -- requirements); non-null = scoped to exactly one requirement.
  requirement_definition_id uuid references public.compliance_requirement_definitions (id) on delete restrict,
  -- Optional: scope the override to one specific load's dispatch rather
  -- than the carrier generally. Set null on delete -- an override remains
  -- valid history even if the load it was created for is later removed.
  load_id uuid references public.loads (id) on delete set null,
  reason text not null check (btrim(reason) <> ''),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid references public.profiles (id) on delete set null,

  constraint compliance_overrides_expiry_shape check (expires_at is null or expires_at > created_at)
);

comment on table public.compliance_overrides is
  'Owner/admin-only, reason-required record of a decision to disregard a specific (or all) currently-blocking compliance requirement(s) for a carrier, optionally scoped to one load and/or a future expiration. Recording only in 0102 -- no dispatch gate consults this table yet. Never mutates the underlying requirement truth.';

create index compliance_overrides_carrier_lookup on public.compliance_overrides (carrier_id) where revoked_at is null;

alter table public.compliance_overrides enable row level security;

create policy compliance_overrides_select on public.compliance_overrides
  for select using (organization_id = public.current_org_id());
-- No insert/update policy: create_compliance_override()/revoke_compliance_override()
-- are the only write path, matching carrier_suspensions above.

create or replace function public.guard_compliance_override_relationships()
returns trigger language plpgsql set search_path = public as $$
declare v_overridable boolean;
begin
  if not exists (select 1 from public.carriers where id = new.carrier_id and organization_id = new.organization_id) then
    raise exception 'Override carrier must belong to the same organization.';
  end if;
  if new.load_id is not null and not exists (select 1 from public.loads where id = new.load_id and organization_id = new.organization_id) then
    raise exception 'Override load must belong to the same organization.';
  end if;
  if new.requirement_definition_id is not null then
    select overridable into v_overridable from public.compliance_requirement_definitions
    where id = new.requirement_definition_id and (organization_id = new.organization_id or organization_id is null);
    if v_overridable is null then
      raise exception 'Override requirement must be visible to this organization.';
    end if;
    if not v_overridable then
      raise exception 'This requirement is not overridable.';
    end if;
  end if;
  return new;
end;
$$;

create trigger compliance_overrides_relationships_guard
  before insert on public.compliance_overrides
  for each row execute function public.guard_compliance_override_relationships();

create or replace function public.create_compliance_override(
  p_carrier_id uuid, p_reason text, p_requirement_definition_id uuid default null,
  p_load_id uuid default null, p_expires_at timestamptz default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_org_id uuid; v_id uuid;
begin
  select organization_id into v_org_id from public.carriers where id = p_carrier_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Carrier not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may override a compliance requirement.';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'An override reason is required.';
  end if;

  insert into public.compliance_overrides (organization_id, carrier_id, requirement_definition_id, load_id, reason, created_by, expires_at)
  values (v_org_id, p_carrier_id, p_requirement_definition_id, p_load_id, btrim(p_reason), auth.uid(), p_expires_at)
  returning id into v_id;

  perform public.log_activity('carrier'::public.entity_type, p_carrier_id, 'carrier_compliance_override_created', jsonb_build_object('override_id', v_id, 'requirement_definition_id', p_requirement_definition_id), v_org_id);
  return v_id;
end;
$$;

revoke execute on function public.create_compliance_override(uuid, text, uuid, uuid, timestamptz) from public, anon;
grant execute on function public.create_compliance_override(uuid, text, uuid, uuid, timestamptz) to authenticated;

create or replace function public.revoke_compliance_override(p_override_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_org_id uuid; v_carrier_id uuid;
begin
  select organization_id, carrier_id into v_org_id, v_carrier_id from public.compliance_overrides where id = p_override_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Override not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may revoke a compliance override.';
  end if;

  update public.compliance_overrides set revoked_at = now(), revoked_by = auth.uid()
  where id = p_override_id and revoked_at is null;
  if not found then raise exception 'This override is already revoked or does not exist.'; end if;

  perform public.log_activity('carrier'::public.entity_type, v_carrier_id, 'carrier_compliance_override_revoked', jsonb_build_object('override_id', p_override_id, 'reason', p_reason), v_org_id);
end;
$$;

revoke execute on function public.revoke_compliance_override(uuid, text) from public, anon;
grant execute on function public.revoke_compliance_override(uuid, text) to authenticated;

-- =============================================================================
-- PART 6 -- carrier_dispatch_readiness(): the one authoritative computation.
--
-- Read-only. Never writes to any table. Never creates a compliance_items
-- row, an operational_exceptions row, or a notification -- Exception
-- Center integration is a future phase's decision, not this migration's.
--
-- Returns ONLY status metadata -- never tin_encrypted, never a signed URL,
-- never PDF bytes, never SSN/bank/routing values:
--   - the W-9 adapter selects only carrier_w9s.status/version, exactly
--     mirroring the same non-sensitive column set the existing W-9 role
--     matrix already exposes to every org member.
--   - the insurance adapter selects only insurance_policies.expiry_date/
--     policy_type -- never premium_amount or anything else not needed for
--     a status computation (premium is a financial detail, not a
--     readiness fact).
--   - the agreement adapter selects only carrier_agreement_signings.status.
--
-- Statuses: READY, WARNING, NOT_READY, SUSPENDED (INCOMPLETE is
-- deliberately not a top-level state -- a missing requirement is a
-- blocking_reasons entry under NOT_READY, per 2P.2 section 7).
--
-- `allowed` is a plain derived fact -- true iff status not in
-- ('NOT_READY', 'SUSPENDED') -- computed the SAME way regardless of the
-- organization's enforcement_mode. `enforcement_mode` is returned
-- alongside it, unmodified, so a future caller decides what to DO with
-- the combination -- this function never lies by folding enforcement_mode
-- into status or allowed (2P.2 section 8's explicit instruction).
--
-- Source adapters, one per resolution_source (2P.1 section 6 -- "prefer
-- source adapters inside the authoritative readiness computation" over
-- duplicating truth into compliance_items):
--   w9            -> carrier_w9s: latest row with status='completed' for
--                    this carrier_id. None -> MISSING. Found -> VALID.
--                    No expiration modeled (see PART 2's CHECK).
--   agreement     -> carriers.id -> carrier_onboarding_applications.
--                    converted_carrier_id -> carrier_agreement_signings,
--                    requiring every published, is_required_for_onboarding
--                    template to have a completed, non-voided signing --
--                    the SAME logic convert_carrier_onboarding_application()
--                    already gates conversion on (0086/0099), reused here
--                    read-only, never re-implemented differently. A
--                    carrier with NO backing application resolves MISSING
--                    -- completion is never invented (2P.2 decision 1).
--   insurance     -> insurance_policies: latest row (by effective_date,
--                    then created_at) for this carrier_id + policy_type =
--                    resolution_key::insurance_policy_type. None ->
--                    MISSING. expiry_date null -> VALID (not tracked as
--                    dated). Otherwise compared against
--                    coalesce(definition.warning_days, 30) exactly like
--                    refresh_compliance_statuses()'s own existing
--                    threshold (0009).
--   carrier_field -> a literal, closed set of known-safe carrier column
--                    checks. Today only 'mc_or_dot_number' is implemented
--                    (carriers.mc_number is not null or dot_number is not
--                    null) -- an IDENTIFIER-PRESENT check only. This is
--                    NEVER reported as "authority active" or any FMCSA
--                    claim -- Truck Dispatch Pro has no such integration
--                    (2P.1 section 6, reconfirmed).
--   compliance_item -> the latest public.compliance_items row for this
--                    carrier + requirement_definition_id, mapping its
--                    existing compliance_status directly, with
--                    verification resolved as: item.verified_at if set,
--                    else the linked document's is_verified if
--                    document_id is set, else UNVERIFIED when
--                    verification_required.
-- =============================================================================

create or replace function public.carrier_dispatch_readiness(p_carrier_id uuid, p_load_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_enforcement_mode public.compliance_enforcement_mode;
  -- Deliberately a plain scalar, not a `record` -- a record-typed variable
  -- that has never been successfully assigned raises "record ... is not
  -- assigned yet" the moment any field on it is referenced, which is
  -- exactly what happens here on every zero-active-suspension call (the
  -- overwhelming common case) if this were `record`. A scalar column
  -- correctly comes back NULL on a zero-row SELECT INTO, no such trap.
  v_suspension_reason text;
  v_def record;
  v_req_status text;
  v_req_days integer;
  v_req_verified boolean;
  v_has_override boolean;
  v_requirements jsonb := '[]'::jsonb;
  v_blocking jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_overall text;
  v_any_blocking_open boolean := false;
  v_any_warning_open boolean := false;
begin
  select organization_id into v_org_id from public.carriers where id = p_carrier_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Carrier not found in your organization.';
  end if;
  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant', 'viewer']::public.org_role[]) then
    raise exception 'You do not have permission to view carrier compliance readiness.';
  end if;

  select compliance_enforcement_mode into v_enforcement_mode from public.organizations where id = v_org_id;

  select reason into v_suspension_reason from public.carrier_suspensions where carrier_id = p_carrier_id and lifted_at is null limit 1;

  -- One requirement row per (entity_type='carrier', requirement_key),
  -- preferring this organization's own definition over the system default
  -- for the same key -- the hybrid-model precedence (2P.1 section 16).
  for v_def in
    select distinct on (requirement_key) *
    from public.compliance_requirement_definitions
    where entity_type = 'carrier' and is_active
      and (organization_id = v_org_id or organization_id is null)
    order by requirement_key, (organization_id is not null) desc
  loop
    v_req_status := 'VALID';
    v_req_verified := true;
    v_has_override := false;

    if v_def.resolution_source = 'w9' then
      if not exists (select 1 from public.carrier_w9s where carrier_id = p_carrier_id and status = 'completed') then
        v_req_status := 'MISSING';
      end if;

    elsif v_def.resolution_source = 'agreement' then
      declare v_app_id uuid;
      begin
        select id into v_app_id from public.carrier_onboarding_applications where converted_carrier_id = p_carrier_id limit 1;
        if v_app_id is null then
          v_req_status := 'MISSING';
        elsif exists (
          select 1 from public.carrier_agreement_templates t
          where t.organization_id = v_org_id and t.status = 'published' and t.is_required_for_onboarding
            and not exists (
              select 1 from public.carrier_agreement_signings s
              where s.application_id = v_app_id and s.agreement_template_id = t.id and s.status = 'completed'
            )
        ) then
          v_req_status := 'MISSING';
        end if;
      end;

    elsif v_def.resolution_source = 'insurance' then
      -- %rowtype, not bare `record` -- a bare record with zero matching
      -- rows is left completely unassigned (touching any field raises
      -- "record ... is not assigned yet"), whereas a %rowtype variable
      -- has a fixed structure from declaration and correctly comes back
      -- all-NULL on a zero-row SELECT INTO. Same fix applied to v_item
      -- below and to v_suspension_reason above.
      declare v_policy public.insurance_policies%rowtype;
      begin
        select * into v_policy from public.insurance_policies
        where carrier_id = p_carrier_id and policy_type = v_def.resolution_key::public.insurance_policy_type
        order by coalesce(effective_date, '0001-01-01'::date) desc, created_at desc
        limit 1;
        if v_policy.id is null then
          v_req_status := 'MISSING';
        elsif v_policy.expiry_date is not null then
          v_req_days := coalesce(v_def.warning_days, 30);
          if v_policy.expiry_date < current_date then v_req_status := 'EXPIRED';
          elsif v_policy.expiry_date <= current_date + (v_req_days || ' days')::interval then v_req_status := 'EXPIRING_SOON';
          end if;
        end if;
      end;

    elsif v_def.resolution_source = 'carrier_field' then
      if v_def.resolution_key = 'mc_or_dot_number' then
        if not exists (select 1 from public.carriers where id = p_carrier_id and (mc_number is not null or dot_number is not null)) then
          v_req_status := 'MISSING';
        end if;
      else
        v_req_status := 'MISSING'; -- unknown key -- fail closed to MISSING, never silently VALID.
      end if;

    elsif v_def.resolution_source = 'compliance_item' then
      declare v_item public.compliance_items%rowtype;
      begin
        select * into v_item from public.compliance_items
        where entity_type = 'carrier' and entity_id = p_carrier_id and requirement_definition_id = v_def.id
        order by created_at desc limit 1;
        if v_item.id is null then
          v_req_status := 'MISSING';
        else
          v_req_status := case v_item.status
            when 'valid' then 'VALID' when 'expiring_soon' then 'EXPIRING_SOON'
            when 'expired' then 'EXPIRED' when 'missing' then 'MISSING' when 'waived' then 'VALID'
            else 'MISSING' end;
          if v_def.verification_required then
            if v_item.verified_at is not null then
              v_req_verified := true;
            elsif v_item.document_id is not null then
              select is_verified into v_req_verified from public.documents where id = v_item.document_id;
              v_req_verified := coalesce(v_req_verified, false);
            else
              v_req_verified := false;
            end if;
          end if;
        end if;
      end;
    end if;

    if v_def.verification_required and v_req_status <> 'MISSING' and not v_req_verified then
      v_req_status := 'UNVERIFIED';
    end if;

    if v_req_status in ('MISSING', 'EXPIRED', 'UNVERIFIED') and v_def.classification in ('blocking', 'warning') then
      -- Load scoping: a blanket override (load_id is null at creation)
      -- always applies. A load-scoped override applies ONLY when this
      -- call is itself asking about that same load (p_load_id matches) --
      -- without this second condition, a load-scoped override would
      -- neutralize the requirement for every future readiness check on
      -- this carrier, on any load, which is exactly the "accidentally
      -- carrier-global" failure this design must not have.
      select exists (
        select 1 from public.compliance_overrides
        where carrier_id = p_carrier_id and revoked_at is null
          and (expires_at is null or expires_at > now())
          and (requirement_definition_id = v_def.id or requirement_definition_id is null)
          and (load_id is null or load_id = p_load_id)
      ) into v_has_override;

      if v_def.classification = 'blocking' and not v_has_override then
        v_any_blocking_open := true;
        v_blocking := v_blocking || jsonb_build_object('requirement_key', v_def.requirement_key, 'display_name', v_def.display_name, 'reason', v_req_status);
      elsif v_def.classification = 'warning' and not v_has_override then
        v_any_warning_open := true;
        v_warnings := v_warnings || jsonb_build_object('requirement_key', v_def.requirement_key, 'display_name', v_def.display_name, 'reason', v_req_status);
      end if;
    elsif v_req_status = 'EXPIRING_SOON' and v_def.classification in ('blocking', 'warning') then
      -- EXPIRING_SOON never blocks (only EXPIRED does) -- it only ever
      -- contributes a warning, and only for requirements whose
      -- classification actually drives overall status. An 'optional'/
      -- 'informational' item (e.g. physical_damage_insurance's default
      -- classification) expiring soon is still visible in `requirements`
      -- below, but deliberately never flips overall status away from
      -- READY -- consistent with "optional" meaning "tracked, not required".
      v_any_warning_open := true;
      v_warnings := v_warnings || jsonb_build_object('requirement_key', v_def.requirement_key, 'display_name', v_def.display_name, 'reason', v_req_status);
    end if;

    v_requirements := v_requirements || jsonb_build_object(
      'requirement_key', v_def.requirement_key, 'display_name', v_def.display_name,
      'classification', v_def.classification, 'status', v_req_status,
      'overridable', v_def.overridable, 'verification_required', v_def.verification_required,
      'has_active_override', v_has_override
    );
  end loop;

  if v_suspension_reason is not null then
    v_overall := 'SUSPENDED';
    v_blocking := jsonb_build_array(jsonb_build_object('requirement_key', null, 'display_name', 'Carrier suspended', 'reason', v_suspension_reason));
  elsif v_any_blocking_open then
    v_overall := 'NOT_READY';
  elsif v_any_warning_open then
    v_overall := 'WARNING';
  else
    v_overall := 'READY';
  end if;

  return jsonb_build_object(
    'carrier_id', p_carrier_id,
    'status', v_overall,
    'allowed', v_overall not in ('NOT_READY', 'SUSPENDED'),
    'enforcement_mode', v_enforcement_mode,
    'blocking_reasons', v_blocking,
    'warnings', v_warnings,
    'requirements', v_requirements
  );
end;
$$;

comment on function public.carrier_dispatch_readiness(uuid, uuid) is
  'The one authoritative Carrier Compliance Readiness computation (Phase 2P). Read-only -- writes nothing, notifies nothing, gates nothing. Returns status metadata only: never tin_encrypted, never a signed URL, never PDF bytes, never SSN/bank/routing values. status is one of READY/WARNING/NOT_READY/SUSPENDED; enforcement_mode is the organization''s current rollout setting, reported honestly alongside status, never folded into it. p_load_id is optional -- pass it when checking readiness for a specific load so a load-scoped override (compliance_overrides.load_id) is honored only for that load, never carrier-wide; omit it for a general carrier-level readiness check, where only blanket (load_id is null) overrides apply.';

revoke execute on function public.carrier_dispatch_readiness(uuid, uuid) from public, anon;
grant execute on function public.carrier_dispatch_readiness(uuid, uuid) to authenticated;

-- =============================================================================
-- PART 7 -- initial (system-wide) requirement definitions.
--
-- Seeded only for requirements this repository's actual architecture
-- already supports a truthful source for (2P.2 section 5) -- no BOC-3,
-- UCR, or IRP tracking invented. operating_identifier is deliberately
-- named and described as presence-only, never authority-active.
-- =============================================================================

insert into public.compliance_requirement_definitions
  (organization_id, entity_type, requirement_key, display_name, description, classification, resolution_source, resolution_key, expiration_required, warning_days, verification_required, overridable)
values
  (null, 'carrier', 'w9', 'Form W-9 on File', 'A completed IRS Form W-9 exists for this carrier.', 'blocking', 'w9', null, false, null, false, true),
  (null, 'carrier', 'carrier_agreement', 'Carrier Agreement Signed', 'Every published, required-for-onboarding agreement template has a completed signing for this carrier''s onboarding application.', 'blocking', 'agreement', null, false, null, false, true),
  (null, 'carrier', 'cargo_insurance', 'Cargo Insurance', 'A cargo insurance policy is on file and not expired.', 'blocking', 'insurance', 'cargo', true, 30, false, true),
  (null, 'carrier', 'general_liability_insurance', 'General Liability Insurance', 'A general liability policy is on file and not expired.', 'blocking', 'insurance', 'general_liability', true, 30, false, true),
  (null, 'carrier', 'workers_compensation_insurance', 'Workers'' Compensation Insurance', 'A workers'' compensation policy is on file and not expired. Classified as a warning by default, not blocking -- organizations for whom this must be blocking can add their own override row with the same requirement_key.', 'warning', 'insurance', 'workers_compensation', true, 30, false, true),
  (null, 'carrier', 'physical_damage_insurance', 'Physical Damage Insurance', 'A physical damage policy is on file and not expired. Tracked as optional by default.', 'optional', 'insurance', 'physical_damage', true, 30, false, true),
  (null, 'carrier', 'operating_identifier', 'MC or DOT Number on File', 'Confirms an MC or DOT identifier is recorded for this carrier. This is an IDENTIFIER-PRESENCE check only -- Truck Dispatch Pro has no FMCSA/SAFER integration and this is never a claim that operating authority is verified active.', 'warning', 'carrier_field', 'mc_or_dot_number', false, null, false, true)
on conflict do nothing;
