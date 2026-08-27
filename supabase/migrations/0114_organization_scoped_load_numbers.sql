-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Automatic Organization-Scoped Load-Number Generation.
--
-- DO NOT APPLY WITHOUT APPROVAL.
--
-- DISCOVERY (done first, not assumed -- see this phase's own report):
-- exactly ONE real, reachable load-creation path exists today --
-- create_load_with_stops() (0047/0061/0068), called from
-- src/app/(app)/loads/create-actions.ts's createLoadWithStops(), which is
-- the only action loads/new/page.tsx's form uses. It currently inserts
-- load_number verbatim from the client-submitted p_load->>'load_number'
-- JSON key, with the DB's existing unique(organization_id, load_number)
-- index (0004_operations.sql) as the only backstop against a duplicate.
-- A second function, createLoad() in src/app/(app)/loads/actions.ts, does
-- the same thing (plain INSERT, load_number straight from the form) but
-- is DEAD CODE -- confirmed by search, no page imports or calls it; only
-- that file's own updateLoad() (used by the edit page) is actually
-- referenced. Updated anyway, for defense-in-depth against it ever being
-- wired up again, not because it changes any current user-visible
-- behavior.
--
-- No CSV/bulk-import path for loads exists anywhere in this codebase
-- (confirmed by search). supabase/seed/seed.sql inserts its 3 demo loads
-- (LD-100001/100002/100003) via a raw literal INSERT, entirely outside any
-- application code path or this new allocator -- exactly the "isolated
-- test mechanism unavailable to production clients" the product decision
-- calls for; left untouched.
--
-- No dedicated load-level "customer reference" or "PO number" column
-- exists separate from rate_confirmation_number -- GAP, reported here
-- rather than silently addressed: the only load-level external-reference
-- field today is rate_confirmation_number (0002G.9, operational/safe), and
-- per-stop reference_number (load_stops, pickup/delivery "Number /
-- Reference" fields) is stop-scoped, not a general load-level customer or
-- broker reference. Both are preserved completely unchanged by this
-- migration; the internal load_number is never overloaded to carry either
-- purpose.
--
-- MECHANISM -- mirrors generate_invoice_number()/invoice_number_counters
-- (0065_billing_readiness.sql), this schema's own already-proven pattern
-- for exactly this problem (organization-scoped, race-proof, no
-- MAX()+1 scan, no shared global sequence): one counter row per
-- organization, advanced by a single INSERT ... ON CONFLICT ... DO UPDATE
-- ... RETURNING statement -- Postgres serializes concurrent conflicting
-- upserts against the same row internally, so two simultaneous callers
-- for the same organization can never receive the same number, and
-- different organizations proceed fully independently with no shared
-- contention point at all.
--
-- SECURITY (stricter than the invoice-number precedent, deliberately):
-- generate_invoice_number() accepts an explicit p_organization_id
-- parameter and only guards it with a role check, not an explicit
-- "belongs to the caller" assertion -- noted here as a pre-existing,
-- out-of-scope observation, not fixed by this migration (fixing an
-- unrelated already-live function is outside this phase's authorization).
-- allocate_load_number() below takes NO organization parameter at all --
-- it derives the organization exclusively from public.current_org_id()
-- (itself keyed off auth.uid() via profiles), so there is structurally no
-- argument a caller could forge to reach another organization's counter.
--
-- load_number_counters itself carries NO insert/update/delete grant to
-- authenticated at all (RLS has no policy for those commands, which
-- means "always denied" for a direct client write regardless of the
-- schema-wide default-privileges grant from 0010) -- the only way to
-- advance it is through allocate_load_number(), which is SECURITY
-- DEFINER and independently re-checks the caller's role. This exactly
-- mirrors invoice_number_counters' own "touched only via the function"
-- design (0065), just with an even narrower parameter surface.
--
-- CONCURRENCY-SAFE FAILURE BEHAVIOR: allocate_load_number() is called
-- from inside create_load_with_stops(), which runs its entire body -- the
-- counter advance, the loads insert, the load_financials insert, every
-- stop insert -- in the SAME database transaction as the caller's own
-- request. If anything later in that same call fails (a bad stop, a role
-- rejection, a concurrent unique-index race on the extremely unlikely
-- chance two callers' allocated numbers somehow collided), the ENTIRE
-- transaction rolls back, including the counter's own increment -- so a
-- failed load creation can never consume a number without a load actually
-- existing at it, and can never expose an allocated-but-unused number to
-- the client either (the RPC call itself fails before returning anything).
--
-- HARDENING PASS (post-initial-draft, pre-preflight):
--
-- 1. OLD RPC SIGNATURE AUDIT -- every migration that has ever defined
--    public.create_load_with_stops() was inspected directly (0047, 0061,
--    0068, this migration): all four use the IDENTICAL argument signature
--    `(p_load jsonb, p_stops jsonb)` and all four are `CREATE OR REPLACE`
--    against that same signature -- Postgres therefore only ever created
--    ONE function object for this name; there has never been a second
--    overload (e.g. a `p_load_number text` positional parameter) to leave
--    behind or drop. The load number was always carried as a key INSIDE
--    the p_load jsonb blob, never a separate argument -- so the fix for
--    "a client-supplied load number must not be honored" is necessarily a
--    body change (stop reading that key), not a signature change, and
--    there is no DROP FUNCTION needed, no signature to guess at, and no
--    risk of silently breaking a deployed client that calls the RPC with
--    the (unchanged) two-argument shape it has always used. Verified
--    structurally in VERIFY_0114_POST_APPLY.sql (exactly one overload
--    exists; its body never references p_load->>'load_number').
--
-- 2. ALLOCATOR PRIVILEGES -- allocate_load_number() now REVOKES execute
--    from public, anon, AND authenticated (previously granted to
--    authenticated, which would have let any ordinary user call it
--    directly, over and over, burning organization-scoped numbers with no
--    load ever created at them -- wasteful and confusing, even though not
--    a cross-tenant leak). Nothing is explicitly GRANTed in its place: no
--    function in this schema has ever set an explicit OWNER (current_
--    org_id(), has_role(), generate_invoice_number(), log_activity() are
--    all implicitly owned by whichever role applies these migrations, a
--    single consistent identity across this project's entire history) --
--    and a Postgres function's OWNER always has implicit EXECUTE on
--    anything they own, with no grant required. create_load_with_stops()
--    below is now SECURITY DEFINER for exactly this reason (see point 2
--    continued below): once it executes as that same owner, its internal
--    call to allocate_load_number() succeeds purely through ownership,
--    the same way log_activity() (already SECURITY DEFINER, 0046) has
--    always been callable from other functions with no explicit
--    cross-grant. A deliberate choice, not an oversight -- introducing a
--    hardcoded `ALTER FUNCTION ... OWNER TO <role>` here, guessing at a
--    role name never once used explicitly anywhere else in 114 prior
--    migrations, risks a preflight failure this author cannot test before
--    handing it over (zero SQL execution capability); the existing,
--    proven, uniform convention is followed instead, and
--    VERIFY_0114_PREFLIGHT.sql adds a check confirming allocate_load_
--    number(), create_load_with_stops(), current_org_id(), has_role(), and
--    generate_invoice_number() all already share one identical owner in
--    THIS database before this design is relied on.
--
--    create_load_with_stops() was audited for SECURITY DEFINER vs INVOKER
--    before deciding this, per instruction, rather than assuming nested
--    execution privileges: it was (and until this hardening pass
--    remained) a plain INVOKER function -- meaning a nested call to a
--    function with no grant to `authenticated` would fail for every
--    ordinary user, since Postgres evaluates EXECUTE privilege against
--    the CURRENT ROLE at each call site, and an INVOKER function's
--    "current role" stays the original caller throughout its entire body,
--    nested calls included. Flipping create_load_with_stops() to SECURITY
--    DEFINER changes that -- but SECURITY DEFINER also means every OTHER
--    statement in its body (the loads/load_financials/load_stops inserts)
--    now bypasses those tables' own RLS policies too, which is why an
--    explicit `has_role(['owner','admin','dispatcher'])` guard was added
--    at the top of its body below: those are exactly the roles the
--    pre-existing RLS insert policies on loads/load_stops already
--    required (0010_rls_policies.sql's standard_tables loop), and
--    load_financials_insert (0067) additionally allows 'accountant', but
--    since loads/load_stops never did, 'accountant' alone could never
--    reach this function's other inserts anyway -- so the net set of
--    roles able to use this function is unchanged by this hardening pass,
--    just now enforced explicitly in code instead of implicitly via RLS
--    (matching how allocate_load_number() itself already self-checks
--    rather than relying on RLS, since a SECURITY DEFINER function always
--    needs its own guard). auth.uid() and current_org_id() are unaffected
--    by SECURITY DEFINER -- both read session-level GUCs/auth state, not
--    "current role," so booked_by and every org-scoping check inside this
--    function continue to resolve the real original caller correctly,
--    exactly as current_org_id() (already SECURITY DEFINER, 0002) has
--    always done when called from anywhere else in this schema.
--
--    PRE-EXISTING, OUT-OF-SCOPE OBSERVATION (unchanged by this hardening
--    pass, not introduced by it): create_load_with_stops() has never
--    verified that p_load->>'broker_id'/'customer_id' actually belong to
--    the caller's own organization -- loads.broker_id/customer_id are
--    plain FKs to public.brokers/public.customers with no organization
--    match enforced at insert time, under INVOKER or DEFINER alike (RLS on
--    loads governs the loads ROW being written, not the visibility of a
--    foreign key it happens to reference). Flagged here for awareness,
--    not fixed -- outside this phase's authorization.
--
-- 3. NONTRANSACTIONAL FOOTGUN REMOVED -- createLoad() in loads/actions.ts
--    (dead code, confirmed zero references anywhere in this codebase)
--    performed allocation and insert as two separate PostgREST calls, so
--    a failed insert could strand an allocated number outside any
--    transaction. Removed entirely rather than refactored, since nothing
--    calls it and updateLoad() (the one live export in that file) shares
--    no code with the deleted function beyond loadValues()/
--    writeLoadFinancials(), both kept intact. No load-creation code path
--    remains that allocates a number outside the transaction that creates
--    the load.
--
-- REVISION 2 (controlled Owner/Admin override): the unconditional
-- immutability guard originally in this migration (guard_load_number_
-- immutable(), a flat "never allowed" BEFORE UPDATE trigger) has been
-- REPLACED, not merely relaxed, by guard_load_number_change() further
-- below -- a lifecycle-gated policy: Owner/Admin may rename a load's
-- number, with a required reason, until the load has a dispatch, an
-- invoice, a billing packet, or a generated/sent/superseded broker packet
-- that bundles one of this load's own documents -- at which point the
-- database rejects the change unconditionally, for any role, RPC or raw
-- SQL alike. See guard_load_number_change()'s own header comment for the
-- exact lock-point list and the full security reasoning (why it is
-- SECURITY DEFINER, why RLS's existing loads_update policy alone was
-- never enough, how the change reason reaches the trigger). The
-- application-facing entry point is the new change_load_number() RPC;
-- automatic allocation via allocate_load_number()/create_load_with_stops()
-- is completely unchanged by this revision.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- load_number_counters: one row per organization. last_number starts at 0
-- for a brand-new organization (no row at all until its first real
-- allocation, at which point the upsert below inserts starting at 1) --
-- backfilled below for organizations that already have loads using the
-- new 6-digit format, so a freshly-applied counter can never collide with
-- a real, already-existing load_number.
-- ---------------------------------------------------------------------------
create table public.load_number_counters (
  organization_id uuid primary key references public.organizations (id) on delete cascade,
  last_number integer not null default 0 check (last_number >= 0),
  updated_at timestamptz not null default now()
);

comment on table public.load_number_counters is
  'One row per organization. Advanced ONLY by allocate_load_number() (SECURITY DEFINER) -- no direct insert/update/delete policy exists for any client role, matching invoice_number_counters'' own established pattern (0065_billing_readiness.sql).';

alter table public.load_number_counters enable row level security;

-- SELECT-only, narrow, defense-in-depth (nothing in the application reads
-- this table directly today -- same belt-and-suspenders rationale as
-- invoice_number_counters_select, 0065).
create policy load_number_counters_select
  on public.load_number_counters for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No insert/update/delete policy of any kind -- a direct client write is
-- always denied by RLS regardless of the schema-wide default-privileges
-- grant (0010_rls_policies.sql) that would otherwise apply table-level
-- permission to this brand-new table automatically.

-- ---------------------------------------------------------------------------
-- One-time backfill (Section 6 -- "initialize each organization's next
-- counter safely"): for every organization with at least one EXISTING
-- load_number matching exactly ^LD-[0-9]{6}$, seed last_number at the
-- highest matching value so the very next allocation continues past it,
-- never colliding. An organization with no such load gets no row here at
-- all -- allocate_load_number()'s own upsert inserts one starting at 1 on
-- first use, producing LD-000001 exactly as specified.
--
-- This intentionally does NOT special-case "starts with LD-1" vs
-- "LD-0" -- ANY existing load_number matching the exact 6-digit shape
-- counts as valid and must be respected, per explicit instruction
-- ("start after the highest valid existing number... ignore nonstandard/
-- test numbers"). A load_number with a different digit count (5, 7, or
-- any non-numeric suffix) does not match this regex and is correctly
-- excluded from the calculation -- "nonstandard" is defined structurally
-- here, never by guessing at which specific numbers look like test data.
-- This INSERT only ever reads public.loads and writes the brand-new
-- load_number_counters table -- no existing loads row is read-then-
-- written, and none is ever modified, renamed, or overwritten.
-- ---------------------------------------------------------------------------
insert into public.load_number_counters (organization_id, last_number)
select l.organization_id, max(substring(l.load_number from 4)::integer)
from public.loads l
where l.load_number ~ '^LD-[0-9]{6}$'
group by l.organization_id
on conflict (organization_id) do nothing;

-- ---------------------------------------------------------------------------
-- allocate_load_number(): the sole writer of load_number_counters.
-- SECURITY DEFINER so it can write a table with no direct grant to
-- authenticated -- exactly mirrors generate_invoice_number()'s own
-- privilege model (0065), with a strictly narrower attack surface (no
-- organization parameter to forge at all; current_org_id() is the only
-- source of truth).
-- ---------------------------------------------------------------------------
create or replace function public.allocate_load_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid := public.current_org_id();
  v_number integer;
begin
  if v_org_id is null then
    raise exception 'Could not determine the current organization for this user.';
  end if;
  if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
    raise exception 'Only owners, admins, or dispatchers may create a load.';
  end if;

  insert into public.load_number_counters (organization_id, last_number)
  values (v_org_id, 1)
  on conflict (organization_id)
  do update set last_number = load_number_counters.last_number + 1, updated_at = now()
  returning last_number into v_number;

  return 'LD-' || lpad(v_number::text, 6, '0');
end;
$$;

comment on function public.allocate_load_number() is
  'Atomically allocates the next organization-scoped load number (LD-NNNNNN, 6 digits) for the CALLER''s own organization, derived exclusively from current_org_id() -- no organization can be specified or forged by a caller. Race-proof: a single INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING statement, same pattern as generate_invoice_number() (0065_billing_readiness.sql). Called from inside create_load_with_stops() (SECURITY DEFINER, same owner -- see this migration''s own header comment) in the same transaction as the actual load insert -- a failed load creation rolls back this allocation along with everything else, so a number can never be consumed without a load existing at it. NOT directly callable by ordinary users -- see the revoke below.';

-- No EXECUTE grant to authenticated (or anon/public): an ordinary user
-- calling this directly, outside create_load_with_stops(), could only
-- ever burn organization-scoped numbers with no load created at them --
-- never a cross-tenant read/write, since the organization is still
-- current_org_id()-derived either way, but wasteful and confusing enough
-- to close off entirely. create_load_with_stops() below is SECURITY
-- DEFINER and reaches this function purely through shared ownership (see
-- header comment) -- no grant is needed for that call to succeed.
revoke execute on function public.allocate_load_number() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- create_load_with_stops(): identical to the live 0068 version EXCEPT (a)
-- the load_number source -- now server-allocated, never read from the
-- client-submitted p_load JSON at all (structurally never referenced in
-- this function body, not merely ignored-if-present), and (b) SECURITY
-- DEFINER + an explicit role guard, added in this hardening pass so its
-- nested call to allocate_load_number() (which has no grant to
-- authenticated at all -- see above) succeeds via shared ownership. See
-- this migration's own header comment (point 2) for the full audit of why
-- this is safe: the explicit has_role() check below replicates exactly
-- what the loads/load_stops RLS insert policies already required, since
-- RLS on those tables is now bypassed for this function's own statements.
-- ---------------------------------------------------------------------------
create or replace function public.create_load_with_stops(
  p_load jsonb,
  p_stops jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org_id uuid;
  v_load_id uuid;
  v_load_number text;
  v_stop jsonb;
  v_stop_count integer;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'Could not determine the current organization for this user.';
  end if;
  if not public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[]) then
    raise exception 'Only owners, admins, or dispatchers may create a load.';
  end if;

  v_stop_count := coalesce(jsonb_array_length(p_stops), 0);
  if v_stop_count = 0 then
    raise exception 'At least a pickup and a delivery stop are required.';
  end if;

  -- Allocated INSIDE this same transaction, before the loads insert --
  -- if anything below this point fails, the whole transaction (this
  -- allocation included) rolls back, so no number is ever consumed
  -- without a real load existing at it.
  v_load_number := public.allocate_load_number();

  insert into public.loads (
    organization_id, load_number, broker_id, customer_id, status, commodity,
    weight_lbs, equipment_type, total_miles, rate_confirmation_number,
    special_instructions, booked_by
  )
  values (
    v_org_id,
    v_load_number,
    nullif(p_load ->> 'broker_id', '')::uuid,
    nullif(p_load ->> 'customer_id', '')::uuid,
    coalesce(nullif(p_load ->> 'status', ''), 'draft')::public.load_status,
    nullif(p_load ->> 'commodity', ''),
    nullif(p_load ->> 'weight_lbs', '')::integer,
    nullif(p_load ->> 'equipment_type', ''),
    nullif(p_load ->> 'total_miles', '')::numeric,
    nullif(p_load ->> 'rate_confirmation_number', ''),
    nullif(p_load ->> 'special_instructions', ''),
    auth.uid()
  )
  returning id into v_load_id;

  insert into public.load_financials (load_id, organization_id, rate)
  values (v_load_id, v_org_id, coalesce(nullif(p_load ->> 'rate', '')::numeric, 0));

  for v_stop in select * from jsonb_array_elements(p_stops)
  loop
    insert into public.load_stops (
      organization_id, load_id, stop_type, stop_sequence, facility_name,
      address_line1, address_line2, city, state, postal_code, country,
      contact_name, contact_phone, scheduled_at, scheduled_window_end,
      reference_number, notes, timezone, timezone_source
    )
    values (
      v_org_id,
      v_load_id,
      (v_stop ->> 'stop_type')::public.stop_type,
      (v_stop ->> 'stop_sequence')::integer,
      nullif(v_stop ->> 'facility_name', ''),
      nullif(v_stop ->> 'address_line1', ''),
      nullif(v_stop ->> 'address_line2', ''),
      v_stop ->> 'city',
      v_stop ->> 'state',
      nullif(v_stop ->> 'postal_code', ''),
      coalesce(nullif(v_stop ->> 'country', ''), 'US'),
      nullif(v_stop ->> 'contact_name', ''),
      nullif(v_stop ->> 'contact_phone', ''),
      nullif(v_stop ->> 'scheduled_at', '')::timestamptz,
      nullif(v_stop ->> 'scheduled_window_end', '')::timestamptz,
      nullif(v_stop ->> 'reference_number', ''),
      nullif(v_stop ->> 'notes', ''),
      nullif(v_stop ->> 'timezone', ''),
      nullif(v_stop ->> 'timezone_source', '')
    );
  end loop;

  perform public.log_activity('load'::public.entity_type, v_load_id, 'created', p_load, v_org_id);

  return v_load_id;
end;
$$;

comment on function public.create_load_with_stops(jsonb, jsonb) is
  'Atomically books a load and every stop in one call (0047/0061/0068). load_number is now allocated server-side by allocate_load_number() (0114) -- p_load''s own "load_number" key, if present, is never read. SECURITY DEFINER as of 0114 (was INVOKER through 0068) so its internal allocate_load_number() call succeeds via shared ownership despite that function having no grant to authenticated; explicitly re-checks owner/admin/dispatcher itself since RLS on loads/load_stops/load_financials no longer applies to this function''s own statements.';

-- ---------------------------------------------------------------------------
-- GUARDED LOAD-NUMBER CHANGE POLICY (revision -- replaces unconditional
-- immutability). Product decision: every load still gets an automatic
-- number by default, but Owner/Admin may change it under controlled
-- conditions; Dispatcher and every other role may not; the change is
-- rejected entirely once the load has dispatch, invoice, or a
-- finalized/generated external-document trail that would otherwise retain
-- the old number.
--
-- LOCK POINT, precisely: a load_number becomes locked the instant ANY of
-- the following exists for that load --
--   * a row in public.dispatches (dispatch created -- carrier/driver/truck
--     already assigned; the load number may already be on a rate
--     confirmation, BOL, or a carrier-facing document by this point)
--   * a row in public.invoices (auto-generated on delivery, 0022, or
--     created manually -- billing has begun) -- THIS is the primary,
--     independently-reachable billing lock.
--   * a row in public.billing_packets for that invoice -- checked as its
--     own explicit condition for clarity/auditability, but NOT an
--     independently reachable lock: billing_packets.invoice_id is NOT
--     NULL (0024_billing_packets.sql), so a billing_packets row can
--     structurally never exist unless its invoice already does too. This
--     branch is pure defense-in-depth (belt-and-suspenders against the
--     invoice check's own logic ever changing later) -- in the schema as
--     it stands today, it never fires on its own; the invoice check above
--     always fires first for the same load.
-- Before any of those exist, Owner/Admin may rename freely (with a
-- reason); the instant any exist, the DATABASE rejects the change
-- unconditionally, regardless of who asks or how (RPC or raw SQL).
--
-- "OTHER ESTABLISHED EXTERNAL DOCUMENT" -- audited, not assumed: this
-- schema's other generated-document system, public.broker_packets /
-- broker_packet_items (0095), was considered and DELIBERATELY excluded
-- here after reading its own guard_broker_packet_item() eligibility check
-- directly -- it only ever accepts a document whose entity_type is
-- 'broker', 'carrier', or 'organization', never 'load'. A broker packet
-- structurally cannot ever bundle a load-specific document (POD, rate
-- confirmation, etc.), so it can never "retain this load's old number" in
-- the first place -- there is nothing to gate on there, and a check
-- against it would be permanently-unreachable dead code, not
-- defense-in-depth. If a future migration ever introduces a real
-- generated, load-scoped document artifact beyond billing_packets, this
-- trigger is the place to add that condition.
--
-- ENFORCEMENT LAYERING (requirement 6 -- direct updates must still be
-- protected, independent of the UI): every rule below lives in the
-- TRIGGER itself, not merely in the change_load_number() RPC wrapper
-- further down. A raw `UPDATE public.loads SET load_number = ...` issued
-- directly by an authorized Owner/Admin (bypassing the RPC and the
-- reason-collecting UI entirely) still gets role-checked, lifecycle-
-- checked, counter-advanced, and logged (with a null reason, since none
-- was collected outside the UI) -- there is no code path to this column
-- that skips the trigger. The trigger is SECURITY DEFINER (with an
-- explicit has_role() self-check, same pattern as create_load_with_stops()
-- and allocate_load_number() above) specifically so it can write
-- load_number_counters and call log_activity() regardless of the calling
-- role's own RLS -- exactly the same reasoning already applied to
-- create_load_with_stops(). The role/org checks below are NOT redundant
-- busywork despite RLS's own loads_update policy already requiring
-- owner/admin/dispatcher: RLS is ROW-level, not COLUMN-level -- a
-- dispatcher legitimately passes RLS to update OTHER columns on a load,
-- so only this trigger's own explicit, narrower, load_number-specific
-- check keeps a dispatcher from slipping a load_number change through
-- inside a larger, otherwise-legitimate update.
--
-- REASON PLUMBING: change_load_number() (the RPC, further below) passes
-- the human-entered reason into this trigger via a transaction-local GUC
-- (set_config('app.load_number_change_reason', ..., true) -- is_local so
-- it can never outlive or leak into any later, unrelated transaction on
-- the same pooled connection). A direct SQL update that never sets this
-- GUC simply logs a null reason -- correctly reflecting that no reason
-- was collected, rather than fabricating one.
-- ---------------------------------------------------------------------------
create or replace function public.guard_load_number_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text;
  v_new_number integer;
begin
  -- No-op: any update that doesn't touch load_number at all is always
  -- allowed and never inspected further (matches the original
  -- immutability trigger's own "only fires on an actual change" rule).
  if new.load_number is not distinct from old.load_number then
    return new;
  end if;

  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners or admins may change a load number.';
  end if;

  -- Defense-in-depth: RLS's own loads_update policy already guarantees
  -- new.organization_id = current_org_id() for any row this UPDATE could
  -- ever reach, but this trigger runs SECURITY DEFINER (see header
  -- comment) specifically to bypass RLS for ITS OWN statements below --
  -- re-asserting the org match here costs nothing and keeps that
  -- guarantee explicit rather than implicit.
  if new.organization_id is distinct from public.current_org_id() then
    raise exception 'Load does not belong to the current organization.';
  end if;

  if new.load_number is null or btrim(new.load_number) = '' then
    raise exception 'Load number cannot be blank.';
  end if;

  -- CONFIRMED BLOCKER, FIXED: a reason is now required HERE, at the
  -- trigger, not merely at the change_load_number() RPC boundary -- a
  -- direct, otherwise-authorized UPDATE (bypassing the RPC and its own
  -- reason validation entirely) could previously slip through with no
  -- app.load_number_change_reason GUC set at all, or one set to
  -- whitespace, and would still have been logged with a null reason.
  -- Read + trimmed here, BEFORE the lifecycle-lock check and BEFORE
  -- log_activity() is ever reached, so a blank/missing reason can never
  -- result in a load-number-change activity log entry with a null or
  -- blank reason -- the function raises and rolls back first.
  v_reason := nullif(btrim(coalesce(current_setting('app.load_number_change_reason', true), '')), '');
  if v_reason is null then
    raise exception 'A reason is required to change a load number.';
  end if;

  -- Invoice existence is the PRIMARY, independently-reachable billing
  -- lock. The billing_packets branch is redundant defense-in-depth, not a
  -- separate reachable condition -- it can only ever match a load that
  -- the invoice branch has already matched, since billing_packets.
  -- invoice_id is NOT NULL (see this function's header comment).
  if exists (select 1 from public.dispatches d where d.load_id = new.id)
    or exists (select 1 from public.invoices i where i.load_id = new.id)
    or exists (
      select 1 from public.billing_packets bp
      join public.invoices i on i.id = bp.invoice_id
      where i.load_id = new.id
    )
  then
    raise exception 'Load number cannot be changed after dispatch or billing activity has begun.';
  end if;

  -- Counter advance (Section 7): if the new value happens to match the
  -- automatic format, make sure future automatic allocation for this
  -- organization continues past it -- never backward, never recycling.
  -- INSERT ... ON CONFLICT ... DO UPDATE ... WHERE is the same
  -- MAX-preserving upsert idiom as allocate_load_number() itself: if no
  -- counter row exists yet for this organization, one is created AT this
  -- value; if one exists, it only ever moves UP (the WHERE clause on the
  -- DO UPDATE makes the whole clause a no-op whenever the existing value
  -- is already >= the new one).
  if new.load_number ~ '^LD-[0-9]{6}$' then
    v_new_number := substring(new.load_number from 4)::integer;
    insert into public.load_number_counters (organization_id, last_number)
    values (new.organization_id, v_new_number)
    on conflict (organization_id) do update
      set last_number = excluded.last_number, updated_at = now()
      where load_number_counters.last_number < excluded.last_number;
  end if;

  -- Activity log (Section 4): old number, new number, reason (already
  -- read, trimmed, and confirmed non-blank above), actor (auth.uid(),
  -- captured by log_activity() itself), timestamp (activity_logs.
  -- created_at, defaulted by log_activity() itself).
  perform public.log_activity(
    'load'::public.entity_type,
    new.id,
    'load_number_changed',
    jsonb_build_object('old_load_number', old.load_number, 'new_load_number', new.load_number, 'reason', v_reason),
    new.organization_id
  );

  return new;
end;
$$;

comment on function public.guard_load_number_change() is
  'BEFORE UPDATE guard on public.loads (replaces the earlier unconditional guard_load_number_immutable()). Allows a load_number change ONLY for owner/admin, on the caller''s own organization''s load, with a required non-blank reason (read from the app.load_number_change_reason GUC -- enforced HERE, not merely by change_load_number(), so a direct UPDATE cannot skip it), before any dispatch/invoice exists for it (billing_packets is checked too but is redundant defense-in-depth, never independently reachable while it requires an invoice), to a non-blank value -- the org-scoped unique index remains the final concurrency backstop. broker_packets was audited and deliberately excluded (see this migration''s own header comment) -- it can never reference a load-scoped document. Advances load_number_counters (never backward) when the new value matches the automatic ^LD-[0-9]{6}$ shape, and always logs old/new/reason/actor/timestamp via log_activity() -- never with a null/blank reason, since the function raises before reaching that call otherwise. SECURITY DEFINER so it can write load_number_counters and activity_logs regardless of the calling role''s own RLS -- see this migration''s own inline comment for the full reasoning; auth.uid()/current_org_id()/has_role() are unaffected by SECURITY DEFINER (they read session-level GUC state, not the executing role), so every check here still evaluates the real calling user, never this function''s owner. Enforced here, at the trigger, specifically so a direct UPDATE (bypassing change_load_number() and its UI) cannot skip any of this.';

drop trigger if exists loads_guard_load_number_immutable on public.loads;
drop trigger if exists loads_guard_load_number_change on public.loads;
create trigger loads_guard_load_number_change
  before update on public.loads
  for each row execute function public.guard_load_number_change();

-- ---------------------------------------------------------------------------
-- change_load_number(): the application-facing entry point for an
-- Owner/Admin-initiated rename. Deliberately thin and plain INVOKER --
-- ALL of the actual security/lifecycle/logging logic lives in the trigger
-- above and fires regardless of how the UPDATE is issued (requirement 6);
-- this function exists only to (a) produce clean, specific error messages
-- for the common rejection cases instead of a raw trigger exception
-- reaching the client, (b) require a non-empty reason at the RPC boundary
-- too (not just in the UI form -- a direct RPC call, e.g. via curl,
-- cannot skip this), and (c) hand the reason to the trigger via the
-- transaction-local GUC described above. Runs under the CALLER's own
-- privileges: an owner/admin already has UPDATE rights on their own
-- organization's loads via the existing loads_update RLS policy
-- (0010_rls_policies.sql), so no elevated privilege is needed here at all.
-- ---------------------------------------------------------------------------
create or replace function public.change_load_number(
  p_load_id uuid,
  p_new_number text,
  p_reason text
)
returns public.loads
language plpgsql
set search_path = public
as $$
declare
  v_org_id uuid := public.current_org_id();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_new_number text := nullif(btrim(coalesce(p_new_number, '')), '');
  v_load public.loads;
begin
  if v_org_id is null then
    raise exception 'Could not determine the current organization for this user.';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners or admins may change a load number.';
  end if;
  if v_reason is null then
    raise exception 'A reason is required to change a load number.';
  end if;
  if v_new_number is null then
    raise exception 'Load number cannot be blank.';
  end if;

  -- Scoped to the caller's own organization -- never trusts a client-
  -- supplied organization_id, and never trusts a client-supplied
  -- "current number" either (there is no such parameter here at all; the
  -- trigger reads the row's REAL current value from OLD, not from
  -- anything the client claims it already is). A load in another
  -- organization, or one that doesn't exist, is reported identically as
  -- "not found" -- never distinguishing the two, so this can't be used to
  -- probe for another tenant's load ids.
  select * into v_load from public.loads where id = p_load_id and organization_id = v_org_id;
  if v_load.id is null then
    raise exception 'Load not found.';
  end if;

  perform set_config('app.load_number_change_reason', v_reason, true);

  begin
    update public.loads set load_number = v_new_number where id = p_load_id and organization_id = v_org_id returning * into v_load;
  exception
    when unique_violation then
      raise exception 'Load number "%" is already in use in this organization.', v_new_number;
  end;

  return v_load;
end;
$$;

comment on function public.change_load_number(uuid, text, text) is
  'Owner/Admin-only, reason-required load_number change. Thin INVOKER wrapper -- see guard_load_number_change() (the BEFORE UPDATE trigger) for the actual, unconditionally-enforced role/organization/lifecycle/uniqueness/logging/counter logic, which applies identically to a direct UPDATE. Never accepts a client-supplied organization_id or "current number" -- the target load is looked up fresh, scoped to current_org_id(), and the real current value is read from the row itself.';

revoke execute on function public.change_load_number(uuid, text, text) from public, anon;
grant execute on function public.change_load_number(uuid, text, text) to authenticated;
