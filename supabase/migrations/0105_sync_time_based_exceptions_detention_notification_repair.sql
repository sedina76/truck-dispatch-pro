-- =============================================================================
-- 0105_sync_time_based_exceptions_detention_notification_repair.sql
-- Phase 2P.4E -- repairs TWO live defects found during 2P.4C acceptance
-- testing in public.sync_time_based_exceptions() (0063, cast-repaired by
-- 0104). Byte-for-byte identical to 0104's body except the two fixes
-- below. No table/column/enum/index/RLS/grant/cron change.
--
-- RE-AUDIT (2P.4E step 1) of the complete 0104 live-matching body, looking
-- for every log_activity(...) call, every notification insert, and the
-- "new exception" detection mechanism:
--   GPS_STALE open  -- log_activity('dispatch', r.dispatch_id, ...) -- safe:
--                       r.dispatch_id comes from an INNER JOIN to
--                       dispatches, never null.
--   GPS_STALE resolve -- same call, r.dispatch_id from oe.dispatch_id,
--                       which was set from that same INNER JOIN -- safe.
--   DETENTION open  -- log_activity('dispatch', r.dispatch_id, ...) --
--                       UNSAFE. r.dispatch_id comes from a LEFT JOIN to
--                       dispatches (deliberately, to still match a stop
--                       with no currently-active dispatch) and can be
--                       null. THE ORIGINALLY REPORTED DEFECT.
--   DETENTION resolve -- log_activity('dispatch', r.dispatch_id, ...) --
--                       ALSO UNSAFE, same-class, found during this
--                       re-audit and not previously reported: r.dispatch_id
--                       here comes from oe.dispatch_id, which the OPEN
--                       loop's own ON CONFLICT DO UPDATE explicitly keeps
--                       current ("keep current even if redispatched") --
--                       meaning it can just as easily be null if the
--                       exception was opened (or last updated) while no
--                       dispatch existed. Repaired identically, in the
--                       same migration, since it is the same defect class
--                       in the same loop this repair was already scoped to.
--   COMPLIANCE open -- log_activity(ci.entity_type, ci.entity_id, ...) --
--                       safe: compliance_items.entity_type/entity_id are
--                       both NOT NULL columns.
--   COMPLIANCE resolve -- no log_activity call exists at all -- nothing
--                       to repair.
--   Notification block -- single insertion site, single "new exception"
--                       heuristic (first_detected_at >= now() - 1 minute)
--                       -- THE SECOND REPORTED DEFECT. No other
--                       "new exception" detection mechanism exists
--                       anywhere else in the function.
-- No additional same-class defect beyond these two sites was found.
--
-- DEFECT 1 REPAIR (DETENTION null dispatch_id): per the authorized design
-- -- 'load' is a valid public.entity_type value (0001), and the DETENTION
-- loop's load_id (ls.load_id, later oe.load_id) is always non-null
-- (load_stops.load_id is NOT NULL) regardless of whether a dispatch
-- exists. Both the open and resolve loops now log against the dispatch
-- when one exists, and fall back to logging against the LOAD when it
-- doesn't -- the audit event is never silently dropped, no fake UUID or
-- synthetic dispatch is invented, and the LEFT JOIN itself is untouched
-- (the exception is still created for the over-time stop either way).
--
-- DEFECT 2 REPAIR (notification duplication): replaced the wall-clock
-- heuristic with invocation-specific truth (Step 3 pattern B) -- a new
-- v_newly_opened_ids uuid[] array, declared once per invocation, appended
-- to at the exact point each loop already knows v_was_insert is true (the
-- same (xmax = 0) signal each loop already computes for its own
-- log_activity calls -- reused, not re-derived). The notification block's
-- final filter is now "oe.id = any(v_newly_opened_ids)" instead of a time
-- window -- a notification fires if and only if THIS invocation genuinely
-- inserted that row, regardless of how soon another invocation runs
-- afterward. Every other notification filter (exception_type/status/
-- severity) and every other part of the block is unchanged.
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
  -- 2P.4E: invocation-scoped record of every exception genuinely inserted
  -- (not merely updated) by THIS call, across all three loops below --
  -- the notification block at the end reads this instead of guessing from
  -- first_detected_at's wall-clock proximity.
  v_newly_opened_ids uuid[] := '{}'::uuid[];
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
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
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
      -- 2P.4E repair: a load_stop can be over free time with no currently
      -- active dispatch for its load (the LEFT JOIN above deliberately
      -- still matches this case). log_activity's entity_id is NOT NULL --
      -- log against the dispatch when one exists, otherwise against the
      -- load (load_id is always present on a load_stop) rather than
      -- calling log_activity with a null entity_id at all.
      if r.dispatch_id is not null then
        perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'detention', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
      else
        perform public.log_activity('load'::public.entity_type, r.load_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'detention', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
      end if;
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
    end if;
  end loop;

  -- Resolve detention exceptions whose stop no longer qualifies (departed,
  -- arrival cleared, or back under free time).
  for r in
    select oe.id, oe.dispatch_id, oe.load_id, oe.organization_id
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
    -- 2P.4E repair: same null-dispatch fallback as the open loop above --
    -- oe.dispatch_id can be null here too (the open loop's own ON
    -- CONFLICT DO UPDATE keeps dispatch_id "current even if redispatched",
    -- which includes going from non-null back to null).
    if r.dispatch_id is not null then
      perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_resolved', jsonb_build_object('exception_id', r.id, 'exception_type', 'detention', 'auto', true, 'source', 'system:scheduler'), r.organization_id);
    else
      perform public.log_activity('load'::public.entity_type, r.load_id, 'exception_resolved', jsonb_build_object('exception_id', r.id, 'exception_type', 'detention', 'auto', true, 'source', 'system:scheduler'), r.organization_id);
    end if;
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
      -- 0104 repair (preserved): r.item_type is public.compliance_item_type
      -- (an enum) -- explicit ::text cast required for replace().
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
      -- entity_type/entity_id, so it uses them). Both columns are NOT
      -- NULL on compliance_items -- no null-entity risk here.
      perform public.log_activity(
        (select entity_type from public.compliance_items where id = r.item_id),
        (select entity_id from public.compliance_items where id = r.item_id),
        'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'compliance', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id
      );
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
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

  -- Best-effort notification for anything this pass genuinely just
  -- inserted (2P.4E: v_newly_opened_ids, populated above at each loop's
  -- own v_was_insert=true point -- replaces the old first_detected_at
  -- wall-clock heuristic, which could re-match an already-open exception
  -- on any invocation within the same minute as its original insert,
  -- double-sending). Every other filter (type/status/severity) and the
  -- one-query-not-per-row shape are unchanged. entity_type/entity_id must
  -- match the exception's OWN source, not be hardcoded to 'dispatch' --
  -- compliance exceptions have no dispatch_id at all.
  for r in
    select
      oe.id, oe.organization_id, oe.title, oe.summary,
      case when oe.exception_type = 'compliance' then ci.entity_type else 'dispatch'::public.entity_type end as notif_entity_type,
      case when oe.exception_type = 'compliance' then ci.entity_id else oe.dispatch_id end as notif_entity_id
    from public.operational_exceptions oe
    left join public.compliance_items ci on ci.id = oe.source_id and oe.exception_type = 'compliance'
    where oe.exception_type in ('gps_stale', 'detention', 'compliance')
      and oe.status = 'open' and oe.severity in ('high', 'critical')
      and oe.id = any (v_newly_opened_ids)
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
  'Phase 2E/2P.4 scheduled evaluator for the time-driven exception types (gps_stale, detention, compliance). Scheduled via pg_cron, every 5 minutes. 2P.4D repaired an enum-to-text cast crash in the COMPLIANCE loop; 2P.4E repaired a null-entity_id crash in the DETENTION loop (open and resolve) and replaced a wall-clock notification heuristic with invocation-specific new-exception tracking. See 0104/0105 migration headers.';
