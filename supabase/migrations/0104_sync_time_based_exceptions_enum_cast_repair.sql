-- =============================================================================
-- 0104_sync_time_based_exceptions_enum_cast_repair.sql
-- Phase 2P.4D -- repairs a live defect in public.sync_time_based_exceptions()
-- (0063, applied in Phase 2P.4B/C). Byte-for-byte identical to 0063's
-- function body EXCEPT for exactly two casts, both on the same line, in the
-- COMPLIANCE loop. No table/column/enum/index/RLS/grant/cron change.
--
-- DEFECT (found live in 2P.4C verification): compliance_items.item_type is
-- public.compliance_item_type, an ENUM. PostgreSQL enums have no implicit
-- cast to text for function-argument resolution, so
--   replace(r.item_type, '_', ' ')
-- fails with 42883 "function replace(compliance_item_type, unknown,
-- unknown) does not exist" the moment the COMPLIANCE loop actually reaches
-- a qualifying row (PL/pgSQL does not type-check this expression at CREATE
-- FUNCTION time, only at first execution of that code path -- which is why
-- 0063 could be authored, reviewed, and even preflighted-for-shape without
-- this ever surfacing until the function was actually invoked against real
-- data). Because a single top-level call to this function is one atomic
-- statement with no internal savepoints, hitting this error rolled back
-- EVERYTHING the function had already done in that same invocation --
-- including the GPS_STALE and DETENTION loops, which run before COMPLIANCE
-- in the body. Confirmed live: operational_exceptions had zero rows despite
-- pg_cron invoking this function every 5 minutes since 0063 was applied.
--
-- FIX: cast the enum to text before passing it to replace() --
-- replace(r.item_type::text, '_', ' ') -- at both occurrences (the expired
-- and expiring-soon message branches, the same case expression). A repo-
-- wide re-audit of this function (2P.4D step 1) confirmed these are the
-- ONLY two occurrences of replace() in the entire function, and confirmed
-- no other enum-typed value is passed to a text-only function anywhere
-- else in this body -- every other enum usage (r.stop_type, r.item_type in
-- jsonb_build_object, r.stale_minutes/r.minutes_over/r.days_remaining in
-- format()) already goes through a path that accepts any type (format()'s
-- %s uses the type's own output function; jsonb_build_object is variadic
-- "any") and needed no change.
--
-- Everything below is 0063's function body, UNCHANGED, except those two
-- casts.
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
      -- 2P.4D repair: r.item_type is public.compliance_item_type (an enum)
      -- -- explicit ::text cast required for replace(), which has no
      -- overload accepting an enum directly.
      case when r.days_remaining < 0 then replace(r.item_type::text, '_', ' ') || ' Expired' else replace(r.item_type::text, '_', ' ') || ' Expiring Soon' end,
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
  'Phase 2E scheduled evaluator for the three time-driven exception types (gps_stale, detention, compliance) -- see 0063''s migration header. Scheduled via pg_cron, every 5 minutes. Phase 2P.4D repaired a live enum-to-text cast defect in the COMPLIANCE loop''s replace() calls -- no other change from 0063.';

-- No cron.schedule() call here -- 0104 only replaces the function body the
-- already-registered 'sync-time-based-exceptions' job calls; the job
-- registration itself (name, schedule, command text `select public.
-- sync_time_based_exceptions();`) is untouched and does not need
-- re-creating for a CREATE OR REPLACE FUNCTION to take effect.
