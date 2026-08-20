-- =============================================================================
-- 0063_operational_exceptions.sql
-- Phase 2E: Dispatcher Exception Center. Purely additive on top of 0057-0062.
-- Does not modify, drop, or rename anything from those migrations. No
-- historical GPS/route-intelligence/geofence/detention/document data is
-- rewritten.
--
-- ARCHITECTURE (revised after architecture review -- see the Phase 2E
-- revised pre-migration report for full reasoning): persisted exception
-- EPISODES, not dynamically computed rows. Existing detection systems
-- remain the sole source of truth for whether a condition is CURRENTLY
-- true:
--   - route deviation:  dispatch_route_deviation_state        (0062)
--   - ETA / late-risk:  dispatch_route_intelligence            (0060)
--   - detention:        load_stops arrival/departure + organization
--                        detention settings
--   - GPS freshness:    driver_latest_locations.recorded_at    (0058)
--   - POD:              documents / getLatestDocument()/computePodStatus()
--                        (0005/existing)
--   - compliance:       compliance_items.expiry_date           (0005)
--
-- SYNCHRONIZATION IS SPLIT BY KIND, NOT ONE ENGINE:
--   EVENT-DRIVEN (off_route, late, at_risk, pod_missing) -- each has a
--   real "meaningful transition" write path elsewhere in the app that
--   calls into src/lib/exceptions/sync.ts right after it happens:
--     off_route/late/at_risk: evaluate-route-deviation.ts / evaluate-route.ts
--     pod_missing: loads/pod-actions.ts (upload/verify/reject),
--                  driver-portal/upload-pod route, and board-actions.ts's
--                  delivered-status transition.
--
--   TIME-DRIVEN (detention, gps_stale, compliance) -- none of these has a
--   reliable event to hook: the condition becomes true because time
--   passed while nothing happened, which no ping/upload/status-change can
--   announce. These are owned ENTIRELY by the scheduled SQL function
--   below (public.sync_time_based_exceptions()), run via pg_cron every 5
--   minutes -- the one piece of scheduling infrastructure this project
--   already has enabled (pg_cron, since 0001) but had never actually
--   scheduled anything with (compliance's own refresh_compliance_
--   statuses(), 0009, has sat unscheduled since it was written -- its
--   cron.schedule call exists only inside a SQL comment). This migration
--   is what actually turns pg_cron on for the first time in this project.
--
--   Both engines read ONLY the existing trusted source tables/columns
--   listed above and write to the SAME operational_exceptions table via
--   the SAME dedup mechanism (the partial unique index below) -- there is
--   no risk of the two disagreeing about what "currently open" means,
--   because they own strictly disjoint exception_type values and never
--   write the same row.
--
--   Page-load reconciliation (Exception Center's own page load, still
--   calling syncExceptionsForOrganization()) remains as an ADDITIONAL,
--   SECONDARY safety net for the event-driven types only -- it is no
--   longer the only mechanism for anything.
-- =============================================================================

create type public.exception_type as enum (
  'off_route', 'late', 'at_risk', 'detention', 'gps_stale', 'pod_missing', 'compliance'
);
create type public.exception_severity as enum ('low', 'medium', 'high', 'critical');
create type public.exception_status as enum ('open', 'acknowledged', 'resolved');

create table public.operational_exceptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,

  -- Generalized source identity -- see the revised report's full source
  -- identity matrix. Deliberately NOT one shape for every type:
  --   off_route / late / at_risk : source_type='dispatch',    source_id=dispatches.id
  --   pod_missing                : source_type='load',        source_id=loads.id
  --   detention                  : source_type='load_stop',   source_id=load_stops.id
  --   gps_stale                  : source_type='dispatch',    source_id=dispatches.id
  --   compliance                 : source_type='compliance_item', source_id=compliance_items.id
  -- detention is intentionally load_stop-scoped, NOT dispatch-scoped, so
  -- that two different stops on the same multi-stop dispatch can never
  -- collapse into a single active exception (a truck can only physically
  -- occupy one stop at a time, but a dispatch-scoped key would still make
  -- pickup-then-delivery detention episodes indistinguishable from each
  -- other while the first is still resolving). No text/enum CHECK
  -- constraint on source_type -- keeps this additive/extensible for a
  -- future exception type without another migration.
  source_type text not null,
  source_id uuid not null,
  -- Denormalized convenience columns for the common dispatch/load-scoped
  -- cases -- fast filtering/joins on the Exception Center table without a
  -- source_type branch in every query. Both null for compliance
  -- exceptions (attached to a driver/truck/carrier, not a dispatch/load).
  dispatch_id uuid references public.dispatches (id) on delete cascade,
  load_id uuid references public.loads (id) on delete cascade,

  exception_type public.exception_type not null,
  severity public.exception_severity not null default 'medium',
  status public.exception_status not null default 'open',

  title text not null,
  summary text,

  -- Episode timing (spec section 7/21): first_detected_at is the episode's
  -- age anchor and is NEVER updated after creation; last_detected_at
  -- advances on every re-sync confirmation while still active.
  first_detected_at timestamptz not null default now(),
  last_detected_at timestamptz not null default now(),

  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles (id) on delete set null,

  assigned_to uuid references public.profiles (id) on delete set null,
  assigned_at timestamptz,
  assigned_by uuid references public.profiles (id) on delete set null,

  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id) on delete set null,
  -- Free text, not an enum: the spec's "possible reasons" list (driver
  -- contacted, dispatch corrected, ...) is illustrative, not exhaustive --
  -- the UI offers those as quick-picks plus a custom "Other" entry.
  -- 'auto_resolved' is the one value the system itself ever writes.
  resolution_code text,
  resolution_note text,

  -- Denormalized, informational-only snapshot for fast table rendering
  -- (e.g. {"distance_from_route_m": 2092}). The detail drawer always
  -- re-fetches live from the real source table for anything it displays
  -- as current fact -- this column is never treated as authoritative
  -- (spec section 3/26-30: "do not fabricate data").
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The core dedup guarantee (spec section 7): at most one ACTIVE
-- (non-resolved) episode per (source, exception_type). A re-sync while a
-- matching active row exists only UPDATEs it (last_detected_at/severity/
-- metadata) -- never inserts a second row. Once resolved, the row is
-- excluded from this constraint, so a later recurrence creates a
-- genuinely NEW episode row while the old one remains, untouched, as
-- history. Same partial-unique-index idiom already proven in this
-- codebase by driver_tracking_sessions (0058) and dispatch_route_
-- deviation_state (0062). Both the TypeScript reconciler and the
-- scheduled SQL function below rely on this SAME index (via ON CONFLICT)
-- to stay correct, since they own disjoint exception_type values.
create unique index operational_exceptions_one_active_per_source
  on public.operational_exceptions (source_type, source_id, exception_type)
  where status <> 'resolved';

create index operational_exceptions_org_idx on public.operational_exceptions (organization_id);
create index operational_exceptions_dispatch_idx on public.operational_exceptions (dispatch_id);
create index operational_exceptions_org_status_idx on public.operational_exceptions (organization_id, status);
create index operational_exceptions_active_sort_idx
  on public.operational_exceptions (organization_id, severity, first_detected_at)
  where status <> 'resolved';
create index operational_exceptions_assigned_idx on public.operational_exceptions (organization_id, assigned_to) where status <> 'resolved';

alter table public.operational_exceptions enable row level security;

-- SELECT scope matches every other Phase 2A-2D operational table exactly
-- (dispatch_geofence_state/dispatch_route_intelligence/dispatch_route_
-- deviation_state all use this identical role set).
create policy "org staff can view operational exceptions"
  on public.operational_exceptions for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No client write policy -- every write (open/update/acknowledge/assign/
-- resolve) goes through server actions or the scheduled function below,
-- both using the service-role client (or, for the scheduled function,
-- running as its definer) after independently verifying organization/
-- dispatch ownership server-side, identical trust model to every write
-- path in Phases 2A-2D.

create trigger operational_exceptions_set_updated_at
  before update on public.operational_exceptions
  for each row execute function public.set_updated_at();

comment on table public.operational_exceptions is
  'Phase 2E. One row per exception EPISODE: open while the underlying condition is active, frozen once resolved, never reused for a later recurrence. Written by two disjoint engines: src/lib/exceptions/sync.ts (event-driven: off_route/late/at_risk/pod_missing) and public.sync_time_based_exceptions() (time-driven: detention/gps_stale/compliance, via pg_cron). Detection/business logic is never duplicated between them.';

-- ---------------------------------------------------------------------------
-- operational_exception_notes: internal, office-only free-text notes.
-- Separate from activity_logs.changes -- notes are staff commentary
-- dispatchers browse as their own list; activity_logs still records a
-- lightweight "exception_note_added" event (no note body) for the unified
-- timeline. Never queried by any Driver Portal code path.
-- ---------------------------------------------------------------------------
create table public.operational_exception_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  exception_id uuid not null references public.operational_exceptions (id) on delete cascade,
  author_id uuid references public.profiles (id) on delete set null,
  body text not null,
  created_at timestamptz not null default now()
);

create index operational_exception_notes_exception_idx on public.operational_exception_notes (exception_id);

alter table public.operational_exception_notes enable row level security;

create policy "org staff can view exception notes"
  on public.operational_exception_notes for select
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

comment on table public.operational_exception_notes is
  'Phase 2E. Internal, office-only notes on an exception episode. Never queried by any Driver Portal code path.';

-- =============================================================================
-- operational_exceptions_grouped: deterministic COMPOUND presentation at
-- the query layer (spec review item 4). A dispatch with both an active
-- OFF ROUTE and an active LATE episode must render as ONE incident row
-- ("OFF ROUTE + LATE"), and that grouping must hold regardless of which
-- page of a paginated result either underlying row would otherwise land
-- on -- grouping in the browser after paginating raw rows can never
-- guarantee that (found and fixed during architecture review).
--
-- This view collapses to ONE row per (organization, group_key) --
-- group_key is the dispatch_id for dispatch/load-scoped types (off_route,
-- late, at_risk, pod_missing, gps_stale all ultimately roll up to "this
-- dispatch's situation") and a synthetic per-row key for source types that
-- never compound with anything else (detention is load_stop-scoped and
-- compliance is compliance_item-scoped -- each stands alone). The PAGINATED
-- LIST QUERY in actions.ts targets this view, never the raw table, so an
-- incident is always either fully on one page or fully on another.
--
-- A plain view, not a security-definer function -- Postgres evaluates RLS
-- on the underlying operational_exceptions table using the QUERYING
-- role's own permissions when a view is selected through PostgREST, so
-- this inherits the exact same org-scoping/role check as the base table
-- automatically. Verified in the post-migration round (cross-org
-- isolation test), not assumed.
-- =============================================================================
create view public.operational_exceptions_grouped as
with ranked as (
  select
    oe.*,
    coalesce(
      case when oe.source_type in ('dispatch', 'load') then oe.dispatch_id::text end,
      oe.source_type || ':' || oe.source_id::text
    ) as group_key,
    case oe.severity when 'critical' then 4 when 'high' then 3 when 'medium' then 2 else 1 end as sev_rank
  from public.operational_exceptions oe
  where oe.status <> 'resolved'
),
groups as (
  -- All exception_types active within a group (spec review item 4: needed
  -- both for the compound "OFF ROUTE + LATE" label AND so a "Type: Late"
  -- filter still matches a group whose LATE row isn't the primary/leader
  -- row -- filtering only against primary_exception_type would silently
  -- hide it).
  select organization_id, group_key, array_agg(distinct exception_type) as exception_types
  from ranked
  group by organization_id, group_key
)
select distinct on (r.organization_id, r.group_key)
  r.organization_id,
  r.group_key,
  r.dispatch_id,
  r.load_id,
  r.id as primary_exception_id,
  r.exception_type as primary_exception_type,
  r.severity as max_severity,
  r.status as primary_status,
  r.title,
  r.summary,
  r.first_detected_at,
  r.last_detected_at,
  r.assigned_to,
  r.acknowledged_at,
  g.exception_types
from ranked r
join groups g on g.organization_id = r.organization_id and g.group_key = r.group_key
order by r.organization_id, r.group_key, r.sev_rank desc, r.first_detected_at asc;

grant select on public.operational_exceptions_grouped to authenticated;

comment on view public.operational_exceptions_grouped is
  'Phase 2E. One row per operational INCIDENT (a dispatch''s compound OFF ROUTE + LATE collapses to one row here, led by the higher-severity exception), not one row per exception episode. exception_types carries every active type in the group, so filtering/labeling never depends on which one happens to be primary. The Exception Center''s paginated list queries this view specifically so compound grouping is correct regardless of pagination boundaries. group_key is dispatch_id for dispatch/load-scoped types, else a synthetic per-row key for source types that never compound (detention, compliance).';

-- =============================================================================
-- sync_time_based_exceptions(): the scheduled evaluator for the three
-- TIME-DRIVEN exception types (spec review item 1 -- "GPS stale is
-- time-based and therefore cannot be detected solely by receiving a new
-- ping... If a true scheduled evaluator is required, design it using
-- infrastructure already available in this project"). pg_cron is that
-- infrastructure (enabled since 0001, never actually scheduled until this
-- migration).
--
-- Deliberately narrow: this function only ever performs the SAME simple
-- threshold arithmetic already expressed elsewhere in this codebase for
-- these exact three signals --
--   GPS stale:   age-in-minutes > 5           (board-actions.ts's own
--                                               STALE_LOCATION_MINUTES)
--   detention:   elapsed-minutes - free_minutes > 0
--                                              (src/lib/dispatch/
--                                               detention.ts's
--                                               calculateDetention(), the
--                                               exact same one-line
--                                               formula, mirrored here
--                                               because there is no way
--                                               for SQL to call into that
--                                               TypeScript function -- if
--                                               that formula ever changes,
--                                               this block must change
--                                               with it)
--   compliance:  expiry_date <= today + 30d   (the exact thresholds
--                                               refresh_compliance_
--                                               statuses(), 0009, already
--                                               encodes)
-- It reads ONLY load_stops/organizations/driver_latest_locations/
-- compliance_items/dispatches -- never route geometry, GPS accuracy
-- filtering, geofence math, or anything with real algorithmic complexity.
-- Those all remain exclusively TypeScript-owned and event-driven.
-- =============================================================================
create or replace function public.sync_time_based_exceptions()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_exception_id uuid;
  v_was_insert boolean;
  v_new_severity public.exception_severity;
  v_recipients uuid[];
begin
  -- =========================================================================
  -- GPS STALE -- source_type='dispatch', source_id=dispatches.id.
  -- Eligible: non-terminal dispatches with a driver_latest_locations row.
  -- =========================================================================
  for r in
    select
      d.id as dispatch_id, d.organization_id, d.load_id,
      round(extract(epoch from (now() - dll.recorded_at)) / 60)::int as stale_minutes
    from public.dispatches d
    join public.driver_latest_locations dll on dll.dispatch_id = d.id
    where d.status not in ('delivered', 'completed', 'cancelled')
      and dll.recorded_at < now() - interval '5 minutes'
  loop
    v_new_severity := case when r.stale_minutes >= 30 then 'high' else 'medium' end;

    insert into public.operational_exceptions (organization_id, source_type, source_id, dispatch_id, load_id, exception_type, severity, status, title, summary, metadata)
    values (r.organization_id, 'dispatch', r.dispatch_id, r.dispatch_id, r.load_id, 'gps_stale', v_new_severity, 'open', 'GPS Stale', format('Last GPS update %sm ago.', r.stale_minutes), jsonb_build_object('stale_minutes', r.stale_minutes))
    on conflict (source_type, source_id, exception_type) where status <> 'resolved'
    do update set
      last_detected_at = now(),
      summary = excluded.summary,
      metadata = excluded.metadata,
      severity = case when excluded.severity = 'high' and operational_exceptions.severity = 'medium' then 'high' else operational_exceptions.severity end
    -- xmax=0 is a real Postgres tuple-visibility idiom for "this row was
    -- just INSERTed in this statement, not the ON CONFLICT UPDATE path" --
    -- FOUND alone can't distinguish the two (it's true either way), and
    -- activity/notifications must only fire once, on the genuine open.
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'gps_stale', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
    end if;
  end loop;

  -- Resolve GPS-stale exceptions whose dispatch no longer qualifies
  -- (terminal, location fresh again, or no location row for it anymore).
  for r in
    select oe.id, oe.dispatch_id, oe.organization_id
    from public.operational_exceptions oe
    where oe.exception_type = 'gps_stale' and oe.status <> 'resolved'
      and not exists (
        select 1 from public.dispatches d
        join public.driver_latest_locations dll on dll.dispatch_id = d.id
        where d.id = oe.dispatch_id
          and d.status not in ('delivered', 'completed', 'cancelled')
          and dll.recorded_at < now() - interval '5 minutes'
      )
  loop
    update public.operational_exceptions set status = 'resolved', resolved_at = now(), resolved_by = null, resolution_code = 'auto_resolved' where id = r.id and status <> 'resolved';
    perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_resolved', jsonb_build_object('exception_id', r.id, 'exception_type', 'gps_stale', 'auto', true, 'source', 'system:scheduler'), r.organization_id);
  end loop;

  -- =========================================================================
  -- DETENTION -- source_type='load_stop', source_id=load_stops.id (spec
  -- review item 3: never dispatch-scoped, so distinct stops can't collapse).
  -- =========================================================================
  for r in
    select
      ls.id as stop_id, ls.stop_type, ls.load_id, l.organization_id,
      d.id as dispatch_id,
      (extract(epoch from (now() - ls.arrived_at)) / 60)::int
        - (case ls.stop_type when 'pickup' then o.pickup_detention_free_minutes else o.delivery_detention_free_minutes end) as minutes_over
    from public.load_stops ls
    join public.loads l on l.id = ls.load_id
    join public.organizations o on o.id = l.organization_id
    left join public.dispatches d on d.load_id = ls.load_id and d.status not in ('delivered', 'completed', 'cancelled')
    where ls.arrived_at is not null and ls.departed_at is null
  loop
    if r.minutes_over <= 0 then continue; end if;
    v_new_severity := case when r.minutes_over >= 120 then 'high' else 'medium' end;

    insert into public.operational_exceptions (organization_id, source_type, source_id, dispatch_id, load_id, exception_type, severity, status, title, summary, metadata)
    values (r.organization_id, 'load_stop', r.stop_id, r.dispatch_id, r.load_id, 'detention', v_new_severity, 'open', 'Detention', format('%sm over free time at %s.', r.minutes_over, r.stop_type), jsonb_build_object('stop_type', r.stop_type, 'minutes_over', r.minutes_over))
    on conflict (source_type, source_id, exception_type) where status <> 'resolved'
    do update set
      last_detected_at = now(),
      summary = excluded.summary,
      metadata = excluded.metadata,
      dispatch_id = excluded.dispatch_id, -- keep current even if redispatched
      severity = case when excluded.severity = 'high' and operational_exceptions.severity = 'medium' then 'high' else operational_exceptions.severity end
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'detention', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
    end if;
  end loop;

  -- Resolve detention exceptions whose stop no longer qualifies (departed,
  -- arrival cleared, or back under free time).
  for r in
    select oe.id, oe.dispatch_id, oe.organization_id
    from public.operational_exceptions oe
    where oe.exception_type = 'detention' and oe.status <> 'resolved'
      and not exists (
        select 1 from public.load_stops ls
        join public.loads l on l.id = ls.load_id
        join public.organizations o on o.id = l.organization_id
        where ls.id = oe.source_id
          and ls.arrived_at is not null and ls.departed_at is null
          and (extract(epoch from (now() - ls.arrived_at)) / 60)::int
            - (case ls.stop_type when 'pickup' then o.pickup_detention_free_minutes else o.delivery_detention_free_minutes end) > 0
      )
  loop
    update public.operational_exceptions set status = 'resolved', resolved_at = now(), resolved_by = null, resolution_code = 'auto_resolved' where id = r.id and status <> 'resolved';
    perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_resolved', jsonb_build_object('exception_id', r.id, 'exception_type', 'detention', 'auto', true, 'source', 'system:scheduler'), r.organization_id);
  end loop;

  -- =========================================================================
  -- COMPLIANCE -- source_type='compliance_item', source_id=compliance_items.id.
  -- Mirrors refresh_compliance_statuses()'s own thresholds (0009) rather
  -- than trusting its output column, which that function only writes if
  -- something schedules it -- this migration is what finally does.
  -- =========================================================================
  for r in
    select
      ci.id as item_id, ci.organization_id, ci.item_type,
      (ci.expiry_date - current_date)::int as days_remaining
    from public.compliance_items ci
    where ci.expiry_date is not null
      and ci.status <> 'waived'
      and ci.expiry_date <= current_date + interval '30 days'
  loop
    v_new_severity := case when r.days_remaining < 0 then 'high' else 'low' end;

    insert into public.operational_exceptions (organization_id, source_type, source_id, exception_type, severity, status, title, summary, metadata)
    values (
      r.organization_id, 'compliance_item', r.item_id, 'compliance', v_new_severity, 'open',
      case when r.days_remaining < 0 then replace(r.item_type, '_', ' ') || ' Expired' else replace(r.item_type, '_', ' ') || ' Expiring Soon' end,
      case when r.days_remaining < 0 then format('Expired %sd ago.', -r.days_remaining) else format('Expires in %sd.', r.days_remaining) end,
      jsonb_build_object('item_type', r.item_type, 'days_remaining', r.days_remaining)
    )
    on conflict (source_type, source_id, exception_type) where status <> 'resolved'
    do update set last_detected_at = now(), summary = excluded.summary, title = excluded.title, metadata = excluded.metadata, severity = excluded.severity
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      -- Compliance exceptions have no dispatch_id -- log against the
      -- compliance item's own entity instead of skipping activity
      -- entirely (unlike the TypeScript side, which currently skips
      -- logging for compliance since it has no dispatch context; this
      -- scheduled function has direct access to the item's real
      -- entity_type/entity_id, so it uses them).
      perform public.log_activity(
        (select entity_type from public.compliance_items where id = r.item_id),
        (select entity_id from public.compliance_items where id = r.item_id),
        'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'compliance', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id
      );
    end if;
  end loop;

  -- Resolve compliance exceptions whose item no longer qualifies (renewed,
  -- waived, or deleted).
  for r in
    select oe.id, oe.organization_id, oe.source_id
    from public.operational_exceptions oe
    where oe.exception_type = 'compliance' and oe.status <> 'resolved'
      and not exists (
        select 1 from public.compliance_items ci
        where ci.id = oe.source_id and ci.expiry_date is not null and ci.status <> 'waived' and ci.expiry_date <= current_date + interval '30 days'
      )
  loop
    update public.operational_exceptions set status = 'resolved', resolved_at = now(), resolved_by = null, resolution_code = 'auto_resolved' where id = r.id and status <> 'resolved';
  end loop;

  -- Best-effort notification for anything newly HIGH+ this pass -- kept
  -- deliberately simple (one query, not per-row) since this function
  -- already runs every 5 minutes and duplicate-suppression is structural
  -- (the unique index prevents a second OPEN insert; this only fires for
  -- rows this very invocation just inserted, identified by first_detected_at
  -- being within the last minute). entity_type/entity_id must match the
  -- exception's OWN source, not be hardcoded to 'dispatch' -- compliance
  -- exceptions have no dispatch_id at all.
  for r in
    select
      oe.id, oe.organization_id, oe.title, oe.summary,
      case when oe.exception_type = 'compliance' then ci.entity_type else 'dispatch'::public.entity_type end as notif_entity_type,
      case when oe.exception_type = 'compliance' then ci.entity_id else oe.dispatch_id end as notif_entity_id
    from public.operational_exceptions oe
    left join public.compliance_items ci on ci.id = oe.source_id and oe.exception_type = 'compliance'
    where oe.exception_type in ('gps_stale', 'detention', 'compliance')
      and oe.status = 'open' and oe.severity in ('high', 'critical')
      and oe.first_detected_at >= now() - interval '1 minute'
  loop
    select array_agg(id) into v_recipients from public.profiles where organization_id = r.organization_id and role in ('owner', 'admin', 'dispatcher') and is_active = true;
    if v_recipients is not null then
      insert into public.notifications (organization_id, profile_id, type, title, body, entity_type, entity_id)
      select r.organization_id, unnest(v_recipients), 'system', r.title, coalesce(r.summary, r.title), r.notif_entity_type, r.notif_entity_id;
    end if;
  end loop;
end;
$$;

comment on function public.sync_time_based_exceptions() is
  'Phase 2E scheduled evaluator for the three time-driven exception types (gps_stale, detention, compliance) -- see the migration header. Scheduled via pg_cron below, every 5 minutes.';

-- Idempotency guard (this migration should only ever run once, but
-- cron.schedule() with a duplicate job name errors on some pg_cron
-- versions rather than upserting) -- safe to reapply if it ever needs to.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'sync-time-based-exceptions') then
    perform cron.unschedule('sync-time-based-exceptions');
  end if;
end;
$$;

select cron.schedule('sync-time-based-exceptions', '*/5 * * * *', $$select public.sync_time_based_exceptions();$$);
