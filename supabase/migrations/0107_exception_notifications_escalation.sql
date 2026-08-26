-- =============================================================================
-- 0107_exception_notifications_escalation.sql
-- Phase 2P.6 -- adds true database-level idempotency to exception
-- notifications and a minimal, opt-in, time-based escalation layer on top
-- of the EXISTING in-app notification architecture (public.notifications,
-- 0007; the notification bell, src/components/nav/notifications-menu.tsx;
-- and the existing best-effort notification block already written by
-- public.sync_time_based_exceptions() since 0063/0105). No new table, no
-- new notification system, no email in this migration (see the 2P.6
-- pre-apply report for why email is explicitly deferred).
--
-- AUDIT SUMMARY (2P.6 section A -- full detail in the pre-apply report):
--   - notifications (0007) + notifications-menu.tsx bell + getMyNotifications()/
--     markNotificationRead() (src/lib/actions/notifications.ts) is the one
--     existing in-app notification system. RLS is already strictly
--     per-recipient (profile_id = auth.uid()) with no authenticated INSERT
--     policy -- every write already goes through service-role/SECURITY
--     DEFINER code, exactly the boundary this migration's own new
--     notification writes continue to use.
--   - sync_time_based_exceptions() already sends a notification on a
--     genuinely NEW high/critical open (v_newly_opened_ids, 0105) -- this
--     migration only ADDS a tag (exception_id/notification_event) and a
--     DB-level uniqueness guard to that existing insert; it does not
--     change who gets notified or when for the "opened" event.
--   - src/lib/exceptions/sync.ts (the TypeScript-owned event-driven
--     engine for off_route/late/at_risk/pod_missing) already has its own
--     notifyOffice() open/escalate notification calls -- untouched here;
--     this migration's SQL-side changes are additive alongside it, not a
--     replacement.
--   - No existing organization-level exception-timing/SLA configuration
--     exists anywhere (pickup/delivery_detention_free_minutes, 0057, is
--     the closest analog but is a different concept -- free time before a
--     condition becomes true at all, not an escalation delay after it's
--     already open). This migration introduces the smallest new
--     configuration surface for that, opt-in (NULL = disabled), not a
--     rules engine.
--   - No assignment/reassignment notification exists at all today --
--     genuinely new, but application-only (actions.ts), not part of this
--     migration; it needs the exception_id/notification_event columns
--     this migration adds, so it can only be built AFTER 0107 is live.
--   - Email: audited src/lib/email/ (purposes.ts/authorization.ts/
--     send-pipeline.ts/sender-resolver.ts/domains.ts/resolve-entity.ts) --
--     a deliberate, purpose-gated system (EmailPurpose union, tenant-vs-
--     platform sender rules, email_send_log). No purpose value exists for
--     an operational exception alert today. Wiring a new purpose in
--     correctly is a real, separate scope decision (which sender, which
--     domain, retry/dedup semantics against email_send_log) -- explicitly
--     DEFERRED to a follow-up phase rather than rushed into this
--     migration. In-app notifications (already reaching the bell) are the
--     complete notification channel for 2P.6.
--
-- SCHEMA CHANGES (all additive, all nullable, zero behavior change until
-- explicitly configured):
--   1. notifications.exception_id -- links a notification to the specific
--      exception episode it's about. NULL for every non-exception
--      notification (dispatch_message, etc.) -- completely untouched.
--   2. notifications.notification_event -- which event this notification
--      represents for that exception ('opened' | 'escalated' | 'assigned'
--      | 'reassigned', enforced at the application layer, not a DB enum --
--      same "keep it plain text, additive" convention this codebase
--      already uses for email_send_log.entity_type and
--      operational_exceptions.source_type, both explicitly for the same
--      "avoid a future ALTER TYPE" reason).
--   3. A partial unique index on (exception_id, profile_id,
--      notification_event) where exception_id is not null -- THE
--      database-level idempotency guarantee (2P.6 section G): the same
--      exception episode can never generate more than one effective
--      notification of the same event to the same recipient, enforced by
--      Postgres itself via ON CONFLICT ... DO NOTHING, not by
--      application-side check-then-insert.
--   4. operational_exceptions.escalated_at -- nullable timestamp, same
--      "one flag stops repeat action" idiom already used by
--      acknowledged_at/resolved_at on this exact table. Set once an
--      escalation notification has been sent for this episode; the
--      escalation loop below never re-evaluates an episode that already
--      has one.
--   5. organizations.critical_exception_escalation_minutes /
--      organizations.high_exception_escalation_minutes -- nullable
--      integers, NULL = escalation disabled for that severity (opt-in,
--      matching compliance_enforcement_mode's own "default = no new
--      behavior" philosophy from 0102). No medium/low equivalent -- 2P.6
--      section D's own guidance is that medium/low should not carry
--      SLA-style escalation; this keeps the model minimal rather than a
--      general rules engine.
--
-- FUNCTION CHANGE: public.sync_time_based_exceptions() (0063, cast-
-- repaired 0104, detention/notification-repaired 0105, insurance-extended
-- 0103) gets exactly two changes, both additive:
--   (a) the existing "opened" notification insert now tags exception_id/
--       notification_event='opened' and adds ON CONFLICT ... DO NOTHING
--       against the new unique index -- belt-and-suspenders alongside the
--       already-correct v_newly_opened_ids gate, not a replacement for it.
--   (b) one new ESCALATION pass appended at the end: for every OPEN
--       (never acknowledged or resolved -- see below) exception whose age
--       exceeds its organization's configured threshold for its severity
--       and which has not already been escalated, notify owner/admin/
--       dispatcher and set escalated_at.
--
-- ACKNOWLEDGEMENT INTERACTION (2P.6 section H, explicit per the task's
-- own instruction not to leave this implicit): acknowledgement STOPS
-- escalation, it does not merely delay it. The escalation loop's WHERE
-- clause is `status = 'open'` -- an acknowledged exception (status=
-- 'acknowledged') is excluded entirely. This mirrors acknowledgeException()'s
-- own documented meaning exactly ("I have seen this and someone is
-- handling it. It does NOT mean the underlying problem is fixed.") --
-- escalating further after a human has already engaged would be pure
-- noise contradicting the point of acknowledgement. Acknowledgement is
-- never conflated with resolution: an acknowledged-but-still-invalid
-- exception is NOT auto-resolved by anything in this migration, exactly
-- as before.
--
-- REOPEN BEHAVIOR: a reopened exception is a genuinely NEW row (a fresh
-- INSERT after the prior episode resolved, per the existing dedup-index
-- design) with its own NULL escalated_at and NULL prior notification
-- history -- old episode notification/escalation state is never reused to
-- suppress a legitimate new episode, and the new episode's own age starts
-- from its own first_detected_at, not the old episode's.
--
-- SCHEDULING: no new scheduler. The escalation pass runs inside the
-- existing pg_cron job (sync-time-based-exceptions, 0063, every 5
-- minutes) -- reusing the one scheduler this project already has, not
-- introducing a second one.
-- =============================================================================

alter table public.notifications
  add column if not exists exception_id uuid references public.operational_exceptions (id) on delete cascade,
  add column if not exists notification_event text;

comment on column public.notifications.exception_id is
  'Phase 2P.6. Links this notification to the specific exception episode it is about. NULL for every non-exception notification (dispatch_message, etc.) -- completely unaffected by this column''s existence.';
comment on column public.notifications.notification_event is
  'Phase 2P.6. Which event this notification represents for exception_id (''opened'' | ''escalated'' | ''assigned'' | ''reassigned'' -- enforced at the application layer, plain text by the same convention as operational_exceptions.source_type, to avoid a future ALTER TYPE for a new event kind). NULL when exception_id is NULL.';

create unique index if not exists notifications_exception_event_recipient_unique
  on public.notifications (exception_id, profile_id, notification_event)
  where exception_id is not null;

comment on index public.notifications_exception_event_recipient_unique is
  'Phase 2P.6. The database-level idempotency guarantee (not application-side check-then-insert): the same exception episode can never generate more than one effective notification of the same event to the same recipient. Every exception-sourced notification insert must go through ON CONFLICT (exception_id, profile_id, notification_event) WHERE exception_id IS NOT NULL DO NOTHING.';

alter table public.operational_exceptions
  add column if not exists escalated_at timestamptz;

comment on column public.operational_exceptions.escalated_at is
  'Phase 2P.6. Set once a time-based escalation notification has been sent for this episode -- same "one flag stops repeat action" idiom as acknowledged_at/resolved_at on this table. NULL means never escalated. A reopened exception is a new row with its own NULL escalated_at -- old-episode state is never reused.';

alter table public.organizations
  add column if not exists critical_exception_escalation_minutes integer,
  add column if not exists high_exception_escalation_minutes integer;

comment on column public.organizations.critical_exception_escalation_minutes is
  'Phase 2P.6. Minutes an OPEN (not acknowledged/resolved) critical-severity exception may remain unaddressed before an escalation notification fires. NULL (the default for every organization, existing and new) = escalation disabled -- opt-in, no behavior change until explicitly configured.';
comment on column public.organizations.high_exception_escalation_minutes is
  'Phase 2P.6. Same as critical_exception_escalation_minutes, for high-severity exceptions. No medium/low equivalent by design -- see this migration''s header.';

-- =============================================================================
-- sync_time_based_exceptions() -- 0103's live body, unchanged except the
-- two additive changes described in this migration's header (opened-
-- notification tagging + ON CONFLICT guard; new escalation pass at the
-- end). Every loop above the notification block is byte-identical to
-- 0103 -- GPS_STALE, DETENTION (0105's null-dispatch fallback preserved
-- in both open and resolve branches), COMPLIANCE (0104's cast repair
-- preserved), and CARRIER INSURANCE, all unchanged.
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
  v_newly_opened_ids uuid[] := '{}'::uuid[];
begin
  -- =========================================================================
  -- GPS STALE -- source_type='dispatch', source_id=dispatches.id.
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
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'gps_stale', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
    end if;
  end loop;

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
  -- DETENTION -- source_type='load_stop', source_id=load_stops.id.
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
      dispatch_id = excluded.dispatch_id,
      severity = case when excluded.severity = 'high' and operational_exceptions.severity = 'medium' then 'high' else operational_exceptions.severity end
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      if r.dispatch_id is not null then
        perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'detention', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
      else
        perform public.log_activity('load'::public.entity_type, r.load_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'detention', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
      end if;
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
    end if;
  end loop;

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
    if r.dispatch_id is not null then
      perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_resolved', jsonb_build_object('exception_id', r.id, 'exception_type', 'detention', 'auto', true, 'source', 'system:scheduler'), r.organization_id);
    else
      perform public.log_activity('load'::public.entity_type, r.load_id, 'exception_resolved', jsonb_build_object('exception_id', r.id, 'exception_type', 'detention', 'auto', true, 'source', 'system:scheduler'), r.organization_id);
    end if;
  end loop;

  -- =========================================================================
  -- COMPLIANCE -- source_type='compliance_item', source_id=compliance_items.id.
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
      case when r.days_remaining < 0 then replace(r.item_type::text, '_', ' ') || ' Expired' else replace(r.item_type::text, '_', ' ') || ' Expiring Soon' end,
      case when r.days_remaining < 0 then format('Expired %sd ago.', -r.days_remaining) else format('Expires in %sd.', r.days_remaining) end,
      jsonb_build_object('item_type', r.item_type, 'days_remaining', r.days_remaining)
    )
    on conflict (source_type, source_id, exception_type) where status <> 'resolved'
    do update set last_detected_at = now(), summary = excluded.summary, title = excluded.title, metadata = excluded.metadata, severity = excluded.severity
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      perform public.log_activity(
        (select entity_type from public.compliance_items where id = r.item_id),
        (select entity_id from public.compliance_items where id = r.item_id),
        'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'compliance', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id
      );
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
    end if;
  end loop;

  for r in
    select oe.id, oe.organization_id, oe.source_id
    from public.operational_exceptions oe
    where oe.exception_type = 'compliance' and oe.source_type = 'compliance_item' and oe.status <> 'resolved'
      and not exists (
        select 1 from public.compliance_items ci
        where ci.id = oe.source_id and ci.expiry_date is not null and ci.status <> 'waived' and ci.expiry_date <= current_date + interval '30 days'
      )
  loop
    update public.operational_exceptions set status = 'resolved', resolved_at = now(), resolved_by = null, resolution_code = 'auto_resolved' where id = r.id and status <> 'resolved';
  end loop;

  -- =========================================================================
  -- CARRIER INSURANCE -- source_type='insurance_policy', source_id=insurance_policies.id.
  -- =========================================================================
  for r in
    select
      latest.id as policy_id, latest.carrier_id, latest.organization_id, latest.policy_type, latest.expiry_date,
      c.legal_name as carrier_name,
      def.classification,
      (latest.expiry_date - current_date)::int as days_remaining
    from (
      select distinct on (carrier_id, policy_type) *
      from public.insurance_policies
      where carrier_id is not null and expiry_date is not null
      order by carrier_id, policy_type, coalesce(effective_date, '0001-01-01'::date) desc, created_at desc
    ) latest
    join public.carriers c on c.id = latest.carrier_id
    join lateral (
      select crd.classification, crd.warning_days
      from public.compliance_requirement_definitions crd
      where crd.entity_type = 'carrier' and crd.is_active
        and crd.resolution_source = 'insurance' and crd.resolution_key = latest.policy_type::text
        and (crd.organization_id = latest.organization_id or crd.organization_id is null)
      order by (crd.organization_id is not null) desc
      limit 1
    ) def on true
    where def.classification in ('blocking', 'warning')
      and latest.expiry_date <= current_date + (coalesce(def.warning_days, 30) || ' days')::interval
  loop
    v_new_severity := case
      when r.days_remaining < 0 and r.classification = 'blocking' then 'high'
      when r.days_remaining < 0 then 'medium'
      else 'low'
    end;

    insert into public.operational_exceptions (organization_id, source_type, source_id, exception_type, severity, status, title, summary, metadata)
    values (
      r.organization_id, 'insurance_policy', r.policy_id, 'compliance', v_new_severity, 'open',
      case when r.days_remaining < 0 then replace(r.policy_type::text, '_', ' ') || ' Expired -- ' || r.carrier_name
           else replace(r.policy_type::text, '_', ' ') || ' Expiring Soon -- ' || r.carrier_name end,
      case when r.days_remaining < 0 then format('Expired %sd ago.', -r.days_remaining) else format('Expires in %sd.', r.days_remaining) end,
      jsonb_build_object('carrier_id', r.carrier_id, 'carrier_name', r.carrier_name, 'policy_type', r.policy_type, 'days_remaining', r.days_remaining, 'classification', r.classification)
    )
    on conflict (source_type, source_id, exception_type) where status <> 'resolved'
    do update set last_detected_at = now(), summary = excluded.summary, title = excluded.title, metadata = excluded.metadata, severity = excluded.severity
    returning id, (xmax = 0) into v_exception_id, v_was_insert;

    if v_was_insert then
      perform public.log_activity('carrier'::public.entity_type, r.carrier_id, 'exception_opened', jsonb_build_object('exception_id', v_exception_id, 'exception_type', 'compliance', 'source_type', 'insurance_policy', 'severity', v_new_severity, 'source', 'system:scheduler'), r.organization_id);
      v_newly_opened_ids := v_newly_opened_ids || v_exception_id;
    end if;
  end loop;

  for r in
    select oe.id, oe.organization_id, oe.source_id
    from public.operational_exceptions oe
    where oe.exception_type = 'compliance' and oe.source_type = 'insurance_policy' and oe.status <> 'resolved'
      and not exists (
        select 1
        from (
          select distinct on (carrier_id, policy_type) *
          from public.insurance_policies
          where carrier_id is not null and expiry_date is not null
          order by carrier_id, policy_type, coalesce(effective_date, '0001-01-01'::date) desc, created_at desc
        ) latest
        join lateral (
          select crd.classification, crd.warning_days
          from public.compliance_requirement_definitions crd
          where crd.entity_type = 'carrier' and crd.is_active
            and crd.resolution_source = 'insurance' and crd.resolution_key = latest.policy_type::text
            and (crd.organization_id = latest.organization_id or crd.organization_id is null)
          order by (crd.organization_id is not null) desc
          limit 1
        ) def on true
        where latest.id = oe.source_id
          and def.classification in ('blocking', 'warning')
          and latest.expiry_date <= current_date + (coalesce(def.warning_days, 30) || ' days')::interval
      )
  loop
    update public.operational_exceptions set status = 'resolved', resolved_at = now(), resolved_by = null, resolution_code = 'auto_resolved' where id = r.id and status <> 'resolved';
  end loop;

  -- =========================================================================
  -- NOTIFICATION (opened) -- for anything this pass genuinely just
  -- inserted (v_newly_opened_ids). Phase 2P.6: now tags exception_id/
  -- notification_event='opened' and adds ON CONFLICT ... DO NOTHING
  -- against the new unique index -- belt-and-suspenders alongside the
  -- already-correct v_newly_opened_ids gate (which alone was already
  -- sufficient to prevent duplicates in practice -- this adds a hard
  -- database guarantee on top, per 2P.6's explicit requirement not to
  -- rely solely on application/procedural-side check-then-insert).
  -- =========================================================================
  for r in
    select
      oe.id, oe.organization_id, oe.title, oe.summary,
      case
        when oe.source_type = 'compliance_item' then ci.entity_type
        when oe.source_type = 'insurance_policy' then 'carrier'::public.entity_type
        else 'dispatch'::public.entity_type
      end as notif_entity_type,
      case
        when oe.source_type = 'compliance_item' then ci.entity_id
        when oe.source_type = 'insurance_policy' then ip.carrier_id
        else oe.dispatch_id
      end as notif_entity_id
    from public.operational_exceptions oe
    left join public.compliance_items ci on ci.id = oe.source_id and oe.source_type = 'compliance_item'
    left join public.insurance_policies ip on ip.id = oe.source_id and oe.source_type = 'insurance_policy'
    where oe.exception_type in ('gps_stale', 'detention', 'compliance')
      and oe.status = 'open' and oe.severity in ('high', 'critical')
      and oe.id = any (v_newly_opened_ids)
  loop
    select array_agg(id) into v_recipients from public.profiles where organization_id = r.organization_id and role in ('owner', 'admin', 'dispatcher') and is_active = true;
    if v_recipients is not null then
      insert into public.notifications (organization_id, profile_id, type, title, body, entity_type, entity_id, exception_id, notification_event)
      select r.organization_id, unnest(v_recipients), 'system', r.title, coalesce(r.summary, r.title), r.notif_entity_type, r.notif_entity_id, r.id, 'opened'
      on conflict (exception_id, profile_id, notification_event) where exception_id is not null do nothing;
    end if;
  end loop;

  -- =========================================================================
  -- ESCALATION (Phase 2P.6, new) -- time-based, opt-in per organization.
  -- Only OPEN exceptions (never acknowledged or resolved -- see this
  -- migration's header for the explicit acknowledgement-stops-escalation
  -- decision) whose age exceeds their org's configured threshold for
  -- their own severity, and which have not already been escalated. No
  -- medium/low threshold exists (by design -- see header), so this loop
  -- structurally never fires for those severities regardless of age.
  -- =========================================================================
  for r in
    select
      oe.id, oe.organization_id, oe.dispatch_id, oe.title, oe.summary,
      case
        when oe.source_type = 'compliance_item' then ci.entity_type
        when oe.source_type = 'insurance_policy' then 'carrier'::public.entity_type
        else 'dispatch'::public.entity_type
      end as notif_entity_type,
      case
        when oe.source_type = 'compliance_item' then ci.entity_id
        when oe.source_type = 'insurance_policy' then ip.carrier_id
        else oe.dispatch_id
      end as notif_entity_id
    from public.operational_exceptions oe
    join public.organizations o on o.id = oe.organization_id
    left join public.compliance_items ci on ci.id = oe.source_id and oe.source_type = 'compliance_item'
    left join public.insurance_policies ip on ip.id = oe.source_id and oe.source_type = 'insurance_policy'
    where oe.status = 'open' and oe.escalated_at is null
      and (
        (oe.severity = 'critical' and o.critical_exception_escalation_minutes is not null and oe.first_detected_at <= now() - make_interval(mins => o.critical_exception_escalation_minutes))
        or
        (oe.severity = 'high' and o.high_exception_escalation_minutes is not null and oe.first_detected_at <= now() - make_interval(mins => o.high_exception_escalation_minutes))
      )
  loop
    -- Atomic claim, not a bare UPDATE after the fact (2P.6 final atomic
    -- claim correction): the SELECT above only reflects a snapshot taken
    -- when this FOR loop's query started -- by the time execution reaches
    -- this specific row, a concurrent transaction could have already
    -- resolved it, acknowledged it (status is the ONLY representation of
    -- acknowledgement on this table -- there is no separate
    -- acknowledged-but-still-open state, so status = 'open' alone already
    -- excludes it, no redundant acknowledged_at predicate needed),
    -- already escalated it, OR an owner/admin could have disabled or
    -- changed the organization's escalation threshold for this severity
    -- (0107's own new columns, editable starting the very next
    -- application round). Re-checking ALL FIVE conditions -- open,
    -- unescalated, threshold still configured, and age still meeting the
    -- CURRENT threshold -- inside the UPDATE's own WHERE clause (joined
    -- live against organizations, not the loop's captured `o` values)
    -- makes "claim the right to escalate this episode" one atomic,
    -- fully up-to-date operation. The notification/activity below only
    -- fire when a row actually comes back. This is the same
    -- RETURNING-gated pattern (v_was_insert) this function already uses
    -- everywhere else, applied to the escalation claim -- no severity
    -- policy is duplicated in application code; the organization's
    -- current threshold values are read fresh from organizations at
    -- claim-time, not carried over from the driving SELECT above.
    update public.operational_exceptions e
    set escalated_at = now()
    from public.organizations o
    where e.id = r.id
      and o.id = e.organization_id
      and e.status = 'open'
      and e.escalated_at is null
      and (
        (e.severity = 'critical' and o.critical_exception_escalation_minutes is not null
          and e.first_detected_at <= now() - make_interval(mins => o.critical_exception_escalation_minutes))
        or
        (e.severity = 'high' and o.high_exception_escalation_minutes is not null
          and e.first_detected_at <= now() - make_interval(mins => o.high_exception_escalation_minutes))
      )
    returning e.id into v_exception_id;

    if v_exception_id is not null then
      select array_agg(id) into v_recipients from public.profiles where organization_id = r.organization_id and role in ('owner', 'admin', 'dispatcher') and is_active = true;
      if v_recipients is not null then
        insert into public.notifications (organization_id, profile_id, type, title, body, entity_type, entity_id, exception_id, notification_event)
        select r.organization_id, unnest(v_recipients), 'system', 'ESCALATED: ' || r.title, coalesce(r.summary, r.title), r.notif_entity_type, r.notif_entity_id, r.id, 'escalated'
        on conflict (exception_id, profile_id, notification_event) where exception_id is not null do nothing;
      end if;

      if r.dispatch_id is not null then
        perform public.log_activity('dispatch'::public.entity_type, r.dispatch_id, 'exception_escalated', jsonb_build_object('exception_id', r.id, 'source', 'system:scheduler'), r.organization_id);
      elsif r.notif_entity_id is not null then
        perform public.log_activity(r.notif_entity_type, r.notif_entity_id, 'exception_escalated', jsonb_build_object('exception_id', r.id, 'source', 'system:scheduler'), r.organization_id);
      end if;
    end if;
  end loop;
end;
$$;

comment on function public.sync_time_based_exceptions() is
  'Phase 2E/2P.4/2P.6 scheduled evaluator for the time-driven exception types (gps_stale, detention, compliance -- written by three disjoint source_types: compliance_item (0063), insurance_policy (0103)) plus time-based escalation (2P.6, opt-in per organization). Scheduled via pg_cron, every 5 minutes. See 0104 (enum cast repair), 0105 (detention null-dispatch + notification dedup repair), 0103 (carrier-insurance integration), and 0107 (notification idempotency + escalation) for full history.';
