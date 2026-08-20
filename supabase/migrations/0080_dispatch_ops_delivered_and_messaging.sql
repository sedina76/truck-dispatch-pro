-- =============================================================================
-- 0080_dispatch_ops_delivered_and_messaging.sql
-- Phase 2I.1: Dispatch Board Operations Cleanup.
-- PROPOSED ONLY -- NOT APPLIED.
--
-- Two independent pieces, both minimal and additive:
--   A. A one-time historical repair of dispatches.delivered_at for rows
--      that reached a delivered-like status through a path that predates
--      this phase's application-code fix (see Part A2 below).
--   B. dispatch_messages -- the one new table this phase's audit found
--      genuinely justified (two-way driver messaging; activity_logs
--      cannot represent a driver-authored row and has no body/read_at/
--      conversation concept -- see the Phase 2I.1 pre-implementation
--      audit for the full reasoning).
--
-- No change to any 0071-0079 factoring file, no change to documents/
-- document_type, no change to dispatches' own schema (delivered_at
-- already exists, added 0057) -- this migration only WRITES into that
-- existing column for historical rows and adds one new table.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- PART A2 -- historical delivered_at repair.
--
-- Live inspection (read-only, performed before writing this migration,
-- against the one real live tenant this app currently has data for) found
-- exactly 3 dispatches with status in ('delivered','completed') and
-- delivered_at is null. Per the approved priority order, each was checked
-- individually:
--
--   Priority 1 (final delivery stop actual arrival/departure): NOT
--   available for any of the 3 -- two of the three affected loads have a
--   delivery stop with both arrived_at and departed_at still null (never
--   recorded through the geofence/manual-arrival workflow at all); the
--   third load has NO stops rows at all.
--
--   Priority 2 (an activity/status-history entry PROVING the moment this
--   dispatch entered delivered/completed): NOT available for any of the
--   3. Every activity_logs row found for these three dispatches has
--   action='updated' with changes=null -- this is updateDispatch()'s own
--   existing log_activity call (dispatch/actions.ts), which -- unlike
--   updateDispatchBoardStatus()'s board-move log -- has never captured
--   {field:'status', old_value, new_value}, so no existing log row can be
--   used to PROVE which edit was the status transition versus some other
--   field edit in the same form submission. (This is itself a real,
--   separate observability gap; Part A12 below fixes updateDispatch()'s
--   bookkeeping going forward but does not retroactively add proof to
--   historical log rows that were never written with it.)
--
--   Priority 3 (updated_at fallback): used for all 3, as the honest final
--   fallback the approved design explicitly allows. For two of the three
--   rows, the row's own most recent activity_logs timestamp lands within
--   ~1 second of dispatches.updated_at itself (the same UPDATE statement
--   and the immediately-following log_activity RPC call inside
--   updateDispatch()), confirming updated_at IS the actual save moment
--   for these rows, not a later, unrelated touch -- not blind reuse of a
--   column that could just as easily reflect a much later, unrelated
--   edit. This was verified per-row, not assumed structurally the way it
--   safely could be for an immutable terminal row elsewhere in this
--   schema (dispatches remain editable after delivery, unlike e.g.
--   factored_invoices in a terminal status).
--
-- This UPDATE is deliberately written as a general rule (status in
-- ('delivered','completed') and delivered_at is null), not hardcoded to
-- the 3 specific ids found live -- the RULE that was vetted (checked
-- stop timestamps, checked activity log provenance, fell back to
-- updated_at only when neither was available) is what's being applied,
-- not a guess specific to today's data. Going forward, Part A12's fix to
-- updateDispatch() means no NEW row can ever reach this state again --
-- this UPDATE only ever needs to run once.
-- ---------------------------------------------------------------------------
update public.dispatches
set delivered_at = updated_at
where status in ('delivered', 'completed')
  and delivered_at is null;

-- ---------------------------------------------------------------------------
-- PART B -- dispatch_messages: two-way internal driver/dispatcher
-- messaging, scoped to (organization, dispatch, load, driver).
--
-- dispatch_id/load_id/driver_id are all stored directly on each message
-- row (denormalized from the dispatch at insert time via the guard
-- trigger below), not derived through a live join to dispatches --
-- deliberate: a dispatch's driver_id could in principle be reassigned
-- after messages were already exchanged with the original driver, and a
-- live join would silently reattribute that history to the new driver.
-- Snapshotting at write time is the same discipline already used for
-- factored_invoices' own snapshot columns (0071) and is enforced here by
-- a guard trigger, not merely by convention, exactly like
-- guard_factoring_event_org() (0071) enforces factoring_events'
-- organization_id against its parent row.
--
-- sender_type + sender_profile_id is the actor model: sender_type='staff'
-- rows always carry the real auth.uid() in sender_profile_id (enforced by
-- both a CHECK and the INSERT policy below); sender_type='driver' rows
-- always leave sender_profile_id null and are attributed to this row's
-- own driver_id (the conversation's driver, sole possible driver
-- participant) -- there is no sender_driver_id column because it would
-- always be redundant with driver_id (drivers are never members of more
-- than one side of their own conversation).
--
-- read_at is a single column because every row is inherently one-
-- directional (staff->driver or driver->staff) -- it always means "when
-- did the OTHER party read this specific message." No separate
-- per-recipient read table is needed for a two-party conversation.
-- ---------------------------------------------------------------------------
create table public.dispatch_messages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  dispatch_id uuid not null references public.dispatches (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  sender_type text not null check (sender_type in ('staff', 'driver')),
  sender_profile_id uuid references public.profiles (id) on delete set null,
  body text not null check (length(btrim(body)) > 0 and length(body) <= 2000),
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint dispatch_messages_sender_shape check (
    (sender_type = 'staff' and sender_profile_id is not null)
    or (sender_type = 'driver' and sender_profile_id is null)
  )
);

comment on table public.dispatch_messages is 'Two-way internal dispatcher/driver messaging, scoped to one dispatch. Call logging uses activity_logs instead (see log_activity action=''call_logged'') -- this table is for message BODIES only.';

-- ---------------------------------------------------------------------------
-- Consistency guard -- mirrors guard_factoring_event_org() (0071) exactly:
-- a message's organization_id/load_id/driver_id must match its own
-- dispatch_id's real values at insert time. Prevents a caller (staff or,
-- structurally, the driver-portal service-role path) from writing a
-- message that claims to belong to one dispatch while actually
-- referencing a different load/driver/org.
-- ---------------------------------------------------------------------------
create or replace function public.guard_dispatch_message_consistency()
returns trigger
language plpgsql
as $$
declare
  v_dispatch record;
begin
  select organization_id, load_id, driver_id
    into v_dispatch
  from public.dispatches
  where id = new.dispatch_id;

  if v_dispatch.organization_id is null then
    raise exception 'dispatch_messages.dispatch_id must reference an existing dispatch.';
  end if;
  if v_dispatch.organization_id <> new.organization_id then
    raise exception 'dispatch_messages.organization_id must match the referenced dispatch''s organization.';
  end if;
  if v_dispatch.load_id <> new.load_id then
    raise exception 'dispatch_messages.load_id must match the referenced dispatch''s load.';
  end if;
  if v_dispatch.driver_id is distinct from new.driver_id then
    raise exception 'dispatch_messages.driver_id must match the referenced dispatch''s assigned driver.';
  end if;

  return new;
end;
$$;

drop trigger if exists dispatch_messages_guard_consistency on public.dispatch_messages;
create trigger dispatch_messages_guard_consistency
  before insert on public.dispatch_messages
  for each row execute function public.guard_dispatch_message_consistency();

-- ---------------------------------------------------------------------------
-- RLS -- STAFF SIDE ONLY. Driver Portal never authenticates as a Supabase
-- Auth user (drivers have no profiles row, no auth.uid()) -- every Driver
-- Portal read/write against this table goes through
-- createServiceRoleClient() (RLS bypassed entirely), with the actual
-- security boundary enforced in application code: every driver-portal
-- server action resolves getDriverPortalSession() FIRST, then explicitly
-- filters/checks .eq("driver_id", identity.driverId) before any read or
-- write, exactly like every existing driver-portal data path in this app
-- (trip document upload, location pings, status updates). These RLS
-- policies below are therefore never reached by Driver Portal traffic at
-- all -- they exist purely to protect the STAFF (Supabase-Auth) side.
--
-- select: matches dispatches_select exactly (organization_id =
-- current_org_id(), any org member) -- read access mirrors the existing
-- Dispatch Board read tier precisely (owner/admin/dispatcher/accountant/
-- viewer can all already see a dispatch; they can all already see its
-- communication history).
--
-- insert: matches dispatches_insert/update exactly
-- (owner/admin/dispatcher only -- accountant excluded, same as
-- dispatches' own write tier) -- plus sender_type/sender_profile_id must
-- be a genuine staff self-attribution (auth.uid()), never spoofable.
--
-- update: narrow, read-receipt only -- staff may mark a DRIVER-sent
-- message read (sender_type='driver' rows only); nothing else is
-- updatable via this policy (application code only ever issues a narrow
-- `update ... set read_at = now()` through it, matching the existing
-- verifyPod()/rejectPod() convention of trusting the action's own narrow
-- column list rather than a column-level RLS restriction, which
-- PostgreSQL RLS cannot express row-scoped anyway).
--
-- No delete policy -- append-only, matching activity_logs/
-- factoring_events precedent exactly.
-- ---------------------------------------------------------------------------
alter table public.dispatch_messages enable row level security;

create policy dispatch_messages_select on public.dispatch_messages
  for select using (organization_id = public.current_org_id());

create policy dispatch_messages_insert on public.dispatch_messages
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
    and sender_type = 'staff'
    and sender_profile_id = auth.uid()
  );

create policy dispatch_messages_update_read on public.dispatch_messages
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
    and sender_type = 'driver'
  )
  with check (
    organization_id = public.current_org_id()
    and sender_type = 'driver'
  );

-- ---------------------------------------------------------------------------
-- Index -- justified directly by the one query shape both the staff
-- drawer and Driver Portal actually issue: "most recent messages for this
-- dispatch, newest first, bounded page size." No other filter/sort shape
-- is needed by anything in this phase (org-wide or driver-wide message
-- search is explicitly out of scope), so no additional index is added on
-- theory.
-- ---------------------------------------------------------------------------
create index idx_dispatch_messages_dispatch_created on public.dispatch_messages (dispatch_id, created_at desc);

grant select, insert, update on public.dispatch_messages to authenticated;
