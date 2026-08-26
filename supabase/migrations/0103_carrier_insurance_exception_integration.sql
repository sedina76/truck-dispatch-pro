-- =============================================================================
-- 0103_carrier_insurance_exception_integration.sql
-- Phase 2P.4 -- wires public.insurance_policies (0014, extended by 0102's
-- carrier_dispatch_readiness() insurance adapter) into the EXISTING
-- Exception Center time-driven evaluator, public.sync_time_based_exceptions()
-- (0063, cast-repaired by 0104, detention/notification-repaired by 0105).
-- No new table, column, enum value, or index. exception_type 'compliance'
-- already exists; operational_exceptions.source_type is deliberately
-- unconstrained text (0063's own comment: "keeps this additive/extensible
-- for a future exception type without another migration") -- this
-- migration is exactly that extension, via a single CREATE OR REPLACE
-- FUNCTION.
--
-- STILL UNAPPLIED as of 2P.4E. This migration's baseline is now built on
-- top of 0105's live-matching body (which already includes 0104's enum
-- cast repair and 0105's detention-null-dispatch/notification-dedup
-- repairs) so that applying 0103 whenever it is eventually authorized can
-- never regress the live function back to either earlier bug.
--
-- WHY (insurance extension): 0063's compliance loop only ever read
-- compliance_items.expiry_date. insurance_policies (0014) and
-- compliance_requirement_definitions (0102) postdate 0063 and were never
-- wired into it -- a carrier's cargo/GL/workers-comp insurance could
-- silently expire post-conversion with no exception ever opening, unless
-- someone happened to also maintain a parallel legacy compliance_items
-- row for the same policy (not the general pattern since 0102).
--
-- INTEGRATION CONTRACT (2P.4 audit, user-authorized):
--   - Only 'blocking' and 'warning' classified insurance requirements ever
--     generate an exception -- 'optional'/'informational' (the seeded
--     physical_damage_insurance default) never does, and classification is
--     read fresh per (org-or-system) definition, exactly mirroring
--     carrier_dispatch_readiness()'s own system-vs-org precedence, so an
--     org that has customized a classification is honored automatically --
--     never hardcoded to specific policy_type values.
--   - carrier_id is not null (insurance_policies.carrier_id null = the
--     dispatch company's own policy, out of scope here).
--   - The "latest" policy per (carrier_id, policy_type) is selected with
--     the IDENTICAL ordering carrier_dispatch_readiness() uses (effective_date
--     desc, then created_at desc) -- the exception target is always exactly
--     the policy readiness is currently evaluating, never a stale one.
--   - warning_days defaults to 30, exactly like the RPC's own
--     coalesce(v_def.warning_days, 30).
--   - Severity: blocking+expired -> high (matches the existing
--     compliance_item loop's own expired->high convention); anything
--     warning-classified (even expired) is capped at medium, never treated
--     as blocking-critical; expiring-soon-but-not-yet-expired -> low.
--   - Overrides are never consulted -- an override neutralizes READINESS,
--     never the underlying insurance_policies.expiry_date fact, so an
--     expired policy keeps generating/holding its exception regardless of
--     any active compliance_overrides row, exactly matching 0102's own
--     "truth vs. policy" separation.
--   - Missing blocking W-9/agreement/MC-DOT, unverified compliance_items,
--     and carrier suspension deliberately do NOT generate a new exception
--     type here -- see the 2P.4 audit report for the full reasoning
--     (already visible via the Phase 2P.3 Carrier Compliance tab; adding
--     them here would be either alert noise with no time-based trigger, or
--     pure duplication of state already prominently displayed elsewhere).
--
-- Everything below this header is 0105's function body, UNCHANGED
-- (including its detention null-dispatch fallback and its
-- v_newly_opened_ids invocation-specific notification tracking), except:
--   (a) one new loop pair inserted after the existing COMPLIANCE
--       (compliance_items) loop's resolve pass: CARRIER INSURANCE
--       (insurance_policies), using the identical open/update + resolve
--       two-pass shape and the identical dedup index, and appending to
--       v_newly_opened_ids on genuine insert exactly like every other loop.
--   (b) the notification block's entity resolution, which previously
--       assumed exception_type='compliance' implied source_type=
--       'compliance_item' (true only because compliance_item was the only
--       source_type ever writing that exception_type before this
--       migration) -- now discriminates on source_type directly, adding an
--       insurance_policy branch (entity_type='carrier', entity_id=
--       carrier_id) alongside the preserved, byte-identical compliance_item
--       branch. This is a required correctness fix, not a redesign:
--       notifications.entity_type/entity_id are both nullable, so left as
--       the old exception_type-only discriminant this would not have
--       crashed the insert -- but every insurance-sourced high/critical
--       exception's notification would have silently carried a NULL
--       entity_type/entity_id (no deep link), because the old CASE's join
--       to compliance_items would simply fail to match an insurance_policy
--       source_id.
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
  -- (not merely updated) by THIS call, across every loop below -- the
  -- notification block at the end reads this instead of guessing from
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
      -- 2P.4E repair (preserved): a load_stop can be over free time with
      -- no currently active dispatch for its load. log_activity's
      -- entity_id is NOT NULL -- log against the dispatch when one
      -- exists, otherwise against the load (always present).
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
    -- 2P.4E repair (preserved): same null-dispatch fallback as the open
    -- loop above.
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
  -- Definition-agnostic: fires on ANY compliance_items row with a non-null
  -- expiry_date regardless of requirement_definition_id, so a 0102-era
  -- definition-linked item is already covered here, unchanged.
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
      -- (an enum) -- explicit ::text cast required for replace(), which
      -- has no overload accepting an enum directly.
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
    where oe.exception_type = 'compliance' and oe.source_type = 'compliance_item' and oe.status <> 'resolved'
      and not exists (
        select 1 from public.compliance_items ci
        where ci.id = oe.source_id and ci.expiry_date is not null and ci.status <> 'waived' and ci.expiry_date <= current_date + interval '30 days'
      )
  loop
    update public.operational_exceptions set status = 'resolved', resolved_at = now(), resolved_by = null, resolution_code = 'auto_resolved' where id = r.id and status <> 'resolved';
  end loop;

  -- =========================================================================
  -- CARRIER INSURANCE (Phase 2P.4, new) -- source_type='insurance_policy',
  -- source_id=insurance_policies.id. See migration header for the full
  -- integration contract. Reads the SAME facts carrier_dispatch_readiness()
  -- reads (latest policy per carrier+type, org-preferred classification,
  -- warning_days default) -- never duplicates its overall readiness
  -- algorithm, and never consults compliance_overrides (truth vs. policy).
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
      when r.days_remaining < 0 then 'medium' -- expired but only warning-classified -- never treated as blocking-critical
      else 'low' -- expiring soon, not yet expired
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

  -- Resolve insurance-policy exceptions whose (carrier, policy_type)
  -- current latest policy no longer qualifies (renewed to a later expiry,
  -- edited in place to a later expiry, reclassified optional/informational
  -- by an org override, or deleted). A renewal via a NEW row changes which
  -- row "latest" even selects at all -- the old row's id then matches
  -- nothing in the latest/def subquery below, so NOT EXISTS is true and
  -- the stale exception resolves, exactly like an in-place edit would.
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

  -- Best-effort notification for anything this pass genuinely just
  -- inserted (2P.4E: v_newly_opened_ids -- replaces the old
  -- first_detected_at wall-clock heuristic). Discriminates on source_type
  -- (not exception_type) to resolve entity_type/entity_id -- exception_type
  -- alone no longer uniquely implies a source table now that both
  -- compliance_item and insurance_policy write 'compliance'.
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
      insert into public.notifications (organization_id, profile_id, type, title, body, entity_type, entity_id)
      select r.organization_id, unnest(v_recipients), 'system', r.title, coalesce(r.summary, r.title), r.notif_entity_type, r.notif_entity_id;
    end if;
  end loop;
end;
$$;

comment on function public.sync_time_based_exceptions() is
  'Phase 2E/2P.4 scheduled evaluator for the time-driven exception types (gps_stale, detention, compliance -- the latter written by two disjoint source_types: compliance_item (0063) and insurance_policy (0103)). Scheduled via pg_cron, every 5 minutes. See 0104 (enum cast repair), 0105 (detention null-dispatch + notification dedup repair), and this migration''s own header for the carrier-insurance integration contract.';
