-- =============================================================================
-- 0072_factoring_default_relationship_rpc.sql
-- Phase 2H.3A: replaces the two-sequential-write "clear then set" pattern
-- setDefaultFactoringRelationship() previously used (the same shape as
-- settings/email/actions.ts's setDefaultEmailSender/setDefaultEmailDomain)
-- with a single, genuinely atomic database transaction for factoring
-- relationships specifically -- Phase 2H.4 will treat the organization's
-- default relationship as the authoritative source for financial
-- snapshots on every new factored invoice, so "briefly zero defaults" or
-- "briefly two defaults" between two application-level round trips is not
-- an acceptable window here the way it is for a cosmetic email sender
-- preference. PROPOSED ONLY -- NOT APPLIED.
--
-- Does not touch factored_invoices (Phase 2H.4 doesn't exist yet) and
-- does not add/change any table, column, or constraint -- 0071's own
-- factoring_relationships_one_default_per_org partial unique index
-- (is_default and is_active) and factoring_relationships_default_must_be
-- _active CHECK remain the final, unconditional invariant; this function
-- is what correctly and atomically satisfies them from application code,
-- it does not relax or bypass either one.
--
-- Phase 2H.3A final pass also adds one guard trigger on factoring_companies
-- (below, after the RPC): a company cannot be deactivated while it owns
-- the org's current active default relationship. Without this, 0071's own
-- invariants ("one default per org" + "a default relationship must be
-- active") say nothing at all about the DEFAULT RELATIONSHIP'S COMPANY's
-- own is_active -- a company could go inactive out from under an
-- untouched, still-flagged-default, still-active relationship, and
-- Phase 2H.4's default lookup would then have to guess whether that's
-- usable. This trigger makes that state simply unreachable, so
-- getDefaultFactoringRelationship() never has to reason about it.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- set_default_factoring_relationship(p_relationship_id uuid)
--
-- SECURITY INVOKER, not DEFINER: every statement inside this function runs
-- with the CALLING user's own privileges, so factoring_relationships' own
-- RLS policies (0071 -- FINANCIAL_ROLES, organization_id = current_org_id())
-- apply to the SELECT/UPDATE statements below exactly as if the caller had
-- issued them directly over PostgREST. This function does not need to (and
-- does not) re-implement authorization from scratch as a substitute for
-- RLS -- it adds the explicit checks below on top, purely so a caller gets
-- a specific, human-readable reason ("inactive", "not available", "no
-- permission") instead of a bare "0 rows updated"/RLS-silent-filter that
-- would be indistinguishable from "this relationship doesn't exist."
--
-- current_org_id()/has_role() are themselves the existing SECURITY DEFINER
-- helper functions (0001) every RLS policy in this app already calls --
-- reusing them here is not a new trust boundary, it's the same one.
--
-- Concurrency (spec section 4): a session-level advisory lock keyed by
-- this organization's id is acquired BEFORE reading the target
-- relationship, and held for the rest of the transaction
-- (pg_advisory_xact_lock -- auto-released on commit or rollback, never
-- needs a manual unlock). This serializes EVERY "set default" call for
-- the same organization against every other one, including two calls
-- that each target a DIFFERENT relationship -- a plain `select ... for
-- update` on the target row alone would not do this, since two
-- concurrent calls locking two DIFFERENT rows never conflict with each
-- other. With the advisory lock, the second of two concurrent callers
-- simply waits for the first to fully commit (or roll back) before its
-- own SELECT runs, so it always sees the true, post-commit state -- the
-- org can never observably pass through a zero-default or two-default
-- state, and neither caller can partially apply. The target row is also
-- selected `for update` as a second, narrower guard: it blocks a
-- concurrent setFactoringRelationshipActive() deactivation of this EXACT
-- row from interleaving mid-transaction.
-- ---------------------------------------------------------------------------
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

  -- Org-scoped mutual exclusion for the remainder of this transaction --
  -- see header comment. hashtext() on a stable per-org string keeps this
  -- to Postgres's single-bigint advisory lock key without needing a
  -- second numeric namespace.
  perform pg_advisory_xact_lock(hashtext('factoring_default_relationship:' || v_org_id::text));

  select id, organization_id, factoring_company_id, is_active
    into v_relationship
  from public.factoring_relationships
  where id = p_relationship_id
  for update;

  -- Covers both "no such row" and "row exists but belongs to another
  -- organization" with the same message -- never reveals which case it
  -- was, matching this app's existing cross-org convention (an
  -- unauthorized/cross-org id looks identical to a nonexistent one
  -- everywhere else in this codebase, e.g. requireExceptionOwnership()).
  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;

  if not v_relationship.is_active then
    raise exception 'This factoring relationship is inactive.';
  end if;

  -- Spec section 8's adopted rule: an inactive factoring company's
  -- relationship cannot be (re)selected as the active default, even
  -- though 0071 places no such constraint at the schema layer -- this is
  -- a business rule, not a data-integrity one, so it's enforced here in
  -- the one place "set default" actually happens rather than as a new
  -- CHECK constraint. Never touches factored_invoices or rewrites any
  -- historical row -- see header comment.
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

-- ---------------------------------------------------------------------------
-- guard_factoring_company_deactivation() -- BEFORE UPDATE OF is_active,
-- column-specific (same shape as guard_factored_invoice_status_transition,
-- 0071): only fires when is_active is actually in the UPDATE's SET list,
-- so every other company edit (name, contact info, ...) never touches
-- this trigger or its lock at all.
--
-- Only the true -> false transition is checked (a reactivation, or a
-- same-value update, is always allowed and never acquires the lock
-- below) -- deliberately does NOT silently clear the relationship's
-- is_default, and does NOT auto-deactivate the relationship itself: the
-- user must explicitly choose a replacement default first (spec: "make
-- the user choose the replacement deliberately"), exactly the same
-- deliberate-choice posture 0072's original setFactoringRelationshipActive
-- block on deactivating the current default already established for
-- relationships -- this is the same rule one level up, for companies.
--
-- Race safety: acquires the EXACT SAME organization-scoped advisory lock
-- key (hashtext('factoring_default_relationship:' || organization_id))
-- that set_default_factoring_relationship() takes, before running its own
-- check. Because both paths take one, and only one, lock each (neither
-- acquires a second/different lock while holding this one), the two can
-- never deadlock against each other -- the second of any concurrent pair
-- (a "Set Default" RPC call and a "Deactivate Company" update, on the
-- same org) simply blocks until the first commits or rolls back, then
-- re-evaluates against the now-true post-commit state:
--   * deactivate-first: sees its own default relationship, blocks itself;
--     the later set-default (to a still-active company) then proceeds normally.
--   * set-default-first: moves the org's default to a different
--     relationship/company, commits; the later deactivate then finds NO
--     active default on this company anymore and is allowed.
-- No interleaving can produce "default under an inactive company."
--
-- No explicit `security` clause -- matches every other guard trigger in
-- this app (guard_factoring_relationship_org, guard_factored_invoice_org,
-- guard_factoring_event_org, 0071): Postgres's default for an
-- unqualified function is invoker, i.e. runs as whichever role's
-- statement fired it. setFactoringCompanyActive() currently updates
-- through the service-role client -- RLS doesn't apply to that role, but
-- triggers are not RLS and are never bypassed by service-role, so this
-- guard fires unconditionally regardless of which client performs the
-- UPDATE.
-- ---------------------------------------------------------------------------
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
