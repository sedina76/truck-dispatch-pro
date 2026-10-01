-- =============================================================================
-- rollback.sql -- EMERGENCY reversal of proposal 0151
-- PROPOSAL 0151 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 (enum repair) -> 0150 (zero-evidence loads) -> 0151 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion.
--
-- Restores the EXACT 0134 function body (verbatim from migration 0134). WARNING: this re-introduces the replay-before-authorization
-- defect; use only if 0151 itself misbehaves. Refuses unless the live body is exactly the reviewed 0151 definition (anything else = drift).
-- The ledger and every other object are untouched. Single transaction.
-- =============================================================================
begin;

do $mig$
declare v_md5 text;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)');
  if v_md5 is distinct from '7d56b97529af95eece84b2f0dab2e83c' then
    raise exception 'ROLLBACK 0151 REFUSED: the live transition_dispatch_status() is not the reviewed 0151 definition (md5 %) -- nothing changed.', v_md5;
  end if;
  create temp table _rb0151_funcs on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config, p.prosecdef, p.proowner
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
end
$mig$;

create or replace function public.transition_dispatch_status(
  p_dispatch_id uuid,
  p_new_status public.dispatch_status,
  p_reason text default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
  v_dispatch_org uuid;
  v_load_id uuid;
  v_load_org uuid;
  v_load_carrier uuid;
  v_old_status public.dispatch_status;
  v_dispatch_carrier uuid;
  v_now timestamptz := now();
  v_ts_col text;
  v_result jsonb;
  v_cached jsonb;
  v_is_reactivation boolean;
  v_final_status public.dispatch_status;
  v_old_rank integer;
  v_new_rank integer;
begin
  -- Never allow browser-provided organization/carrier ownership to
  -- override database truth: this function takes NO organization_id or
  -- carrier_id parameter at all -- both are derived exclusively from the
  -- dispatch/load rows themselves and from auth.uid()/current_org_id().
  if v_uid is null then
    raise exception 'transition_dispatch_status: authentication required.' using errcode = 'TSAUT';
  end if;
  v_org := public.current_org_id();
  if v_org is null then
    raise exception 'transition_dispatch_status: caller has no organization.' using errcode = 'TSAUT';
  end if;

  -- Idempotency short-circuit -- BEFORE any lock, any validation, any
  -- write. A retried call with the SAME (dispatch_id, idempotency_key)
  -- pair replays the ORIGINAL cached result verbatim, never re-validates
  -- against however the row looks now.
  if p_idempotency_key is not null then
    select result into v_cached
    from public.dispatch_status_transitions
    where dispatch_id = p_dispatch_id and idempotency_key = p_idempotency_key;
    if found then
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  -- Resolve dispatch -> load_id WITHOUT locking yet -- load_id is needed
  -- to lock the LOAD before touching the dispatch row at all.
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    -- cross-tenant reported identically to "not found" -- never confirm
    -- existence of another organization's row.
    raise exception 'transition_dispatch_status: dispatch % not found.', p_dispatch_id using errcode = 'TSDNF';
  end if;

  -- ===== STEP 1: LOCK THE LOAD FIRST -- unconditional, for EVERY call,
  -- regardless of whether this specific transition strictly needs it. A
  -- BEFORE trigger (guard_dispatch_carrier_scope, 0132) cannot acquire a
  -- lock "before" Postgres has already locked the target row of the
  -- statement that fired it -- that is a structural constraint of the
  -- trigger mechanism, not a choice any trigger body can make. The ONLY
  -- way to guarantee load-then-dispatch order for every write this RPC
  -- performs is to take the load lock HERE, before the dispatch row is
  -- touched at all. This is what closes the deadlock class
  -- TEST_DEADLOCK_0132_lock_order.sh reproduced (Phase 3A clarification
  -- round, item 4) for every caller that routes through this RPC.
  select organization_id, carrier_id into v_load_org, v_load_carrier
  from public.loads where id = v_load_id for update;
  if v_load_org is null then
    raise exception 'transition_dispatch_status: load % missing.', v_load_id using errcode = 'TSDNF';
  end if;

  -- ===== STEP 2: LOCK THE DISPATCH SECOND, re-read current values under
  -- both locks. Never trust the pre-lock read above for anything but
  -- resolving load_id.
  select status, carrier_id into v_old_status, v_dispatch_carrier
  from public.dispatches where id = p_dispatch_id for update;

  if v_old_status = p_new_status then
    -- idempotent no-op, authoritative (post-lock) read
    v_result := jsonb_build_object(
      'success', true, 'dispatch_id', p_dispatch_id,
      'old_status', v_old_status, 'new_status', p_new_status,
      'no_op', true, 'reactivated', false);
  else
    v_is_reactivation := (v_old_status = 'cancelled');

    -- ===== STEP 3: VALIDATE (role, reason, carrier consistency) =====
    if v_is_reactivation then
      -- Recommended matrix: ordinary dispatchers cannot reactivate a
      -- cancelled dispatch directly. Owner/admin may, only with a reason,
      -- only onto the SAME carrier the load already has, and only when
      -- the transition matrix (below) agrees the shape is even permitted
      -- (cancelled -> assigned only -- never a silent mid-trip resume).
      if not public.has_role(array['owner','admin']::public.org_role[]) then
        raise exception 'transition_dispatch_status: reactivating a cancelled dispatch requires owner/admin authority. Create a new same-carrier dispatch instead, or ask an owner/admin to reactivate this one with a reason.' using errcode = 'TSROL';
      end if;
      if p_reason is null or btrim(p_reason) = '' then
        raise exception 'transition_dispatch_status: a reason is required to reactivate a cancelled dispatch.' using errcode = 'TSRSN';
      end if;
      if v_load_carrier is not null and v_dispatch_carrier is distinct from v_load_carrier then
        raise exception 'transition_dispatch_status: cannot reactivate -- this dispatch''s carrier (%) no longer matches the load''s carrier (%). Create a new same-carrier dispatch instead.', v_dispatch_carrier, v_load_carrier using errcode = 'TSCAR';
      end if;
    else
      if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
        raise exception 'transition_dispatch_status: only an owner, admin, or dispatcher may change dispatch status.' using errcode = 'TSROL';
      end if;

      -- Phase 3A.2, item 8: a BACKWARD move within the normal forward
      -- sequence (e.g. in_transit -> assigned, at_delivery -> dispatched,
      -- delivered -> an earlier active status) is a CORRECTION, not an
      -- ordinary dispatcher drag -- it requires owner/admin authority and a
      -- reason, exactly like reactivation does. Forward progress (and any
      -- move -> cancelled, handled entirely separately above) remains open
      -- to an ordinary dispatcher with no reason required -- "free
      -- movement" is preserved for FORWARD drags only. NULL ranks
      -- (p_new_status = 'completed', which is not a sequence-ranked status)
      -- never trigger this -- 'completed' is one-way from 'delivered' by
      -- the matrix already, and BOTH null out of the rank comparison
      -- safely (the `is not null and is not null and <` guard below).
      v_old_rank := public.dispatch_status_sequence_rank(v_old_status);
      v_new_rank := public.dispatch_status_sequence_rank(p_new_status);
      if v_old_rank is not null and v_new_rank is not null and v_new_rank < v_old_rank then
        if not public.has_role(array['owner','admin']::public.org_role[]) then
          raise exception 'transition_dispatch_status: moving % -> % is a BACKWARD correction and requires owner/admin authority.', v_old_status, p_new_status using errcode = 'TSROL';
        end if;
        if p_reason is null or btrim(p_reason) = '' then
          raise exception 'transition_dispatch_status: a reason is required to move % -> % (a backward correction).', v_old_status, p_new_status using errcode = 'TSRSN';
        end if;
      end if;
    end if;

    if not public.is_valid_dispatch_status_transition(v_old_status, p_new_status) then
      raise exception 'transition_dispatch_status: % -> % is not a permitted status transition.', v_old_status, p_new_status using errcode = 'TSINV';
    end if;

    -- ===== STEP 4: UPDATE =====
    if p_new_status = 'cancelled' then
      -- Delegate ENTIRELY to cancel_dispatch() (0129) -- never duplicate
      -- its terminal-status guard (delivered/completed cannot be
      -- cancelled), its notes/cancelled_at bookkeeping, or its "return
      -- load to booked" logic. The load+dispatch locks this function
      -- already holds are simply re-entrant when cancel_dispatch()
      -- re-acquires them internally (same transaction) -- instant, never
      -- a wait, never a second deadlock opportunity.
      perform public.cancel_dispatch(p_dispatch_id, p_reason);
    else
      -- Mirrors src/lib/dispatch/operational-timestamps.ts's
      -- computeOperationalTimestampUpdates() exactly: stamp the ONE
      -- dedicated timestamp column this status owns, only if not already
      -- set (idempotent -- bouncing back into a status already reached
      -- once never overwrites the original moment).
      v_ts_col := case p_new_status
        when 'en_route_to_pickup'  then 'en_route_pickup_at'
        when 'loaded'              then 'loaded_at'
        when 'en_route_to_delivery' then 'in_transit_at'
        when 'delivered'           then 'delivered_at'
        else null
      end;
      if v_ts_col = 'en_route_pickup_at' then
        update public.dispatches set status = p_new_status, en_route_pickup_at = coalesce(en_route_pickup_at, v_now) where id = p_dispatch_id;
      elsif v_ts_col = 'loaded_at' then
        update public.dispatches set status = p_new_status, loaded_at = coalesce(loaded_at, v_now) where id = p_dispatch_id;
      elsif v_ts_col = 'in_transit_at' then
        update public.dispatches set status = p_new_status, in_transit_at = coalesce(in_transit_at, v_now) where id = p_dispatch_id;
      elsif v_ts_col = 'delivered_at' then
        update public.dispatches set status = p_new_status, delivered_at = coalesce(delivered_at, v_now) where id = p_dispatch_id;
      else
        update public.dispatches set status = p_new_status where id = p_dispatch_id;
      end if;
      -- guard_dispatch_carrier_scope (0132) fires here on this UPDATE.
      -- The load lock from STEP 1 is already held by THIS transaction, so
      -- its own internal `for update` on loads is an instant re-lock, not
      -- a wait -- the structural fix this whole hotfix exists to prove.
    end if;

    select status into v_final_status from public.dispatches where id = p_dispatch_id;
    v_result := jsonb_build_object(
      'success', true, 'dispatch_id', p_dispatch_id,
      'old_status', v_old_status, 'new_status', v_final_status,
      'no_op', false, 'reactivated', v_is_reactivation);

    -- AUDIT (Phase 3A.2 clarification round, item 7 -- "cancellation audit
    -- duplication check"): cancel_dispatch() (0129, line ~644) ALREADY
    -- writes its own log_activity('dispatch', ..., 'cancelled',
    -- {reason}, ...) event -- confirmed by reading its body, not assumed.
    -- An earlier draft of this function wrote a SECOND, unconditional
    -- 'status_changed' event here regardless of path, producing TWO
    -- activity_logs rows for every cancellation. Fixed: this RPC writes
    -- its OWN audit event only for the non-cancellation branch;
    -- cancel_dispatch()'s event is the sole, authoritative audit record
    -- for a cancellation -- never duplicated, never weakened.
    -- TEST_0135_..., "cancellation audit duplication" asserts EXACTLY ONE
    -- activity_logs row per cancellation, by exact count.
    if p_new_status <> 'cancelled' then
      perform public.log_activity(
        'dispatch'::public.entity_type, p_dispatch_id, 'status_changed',
        jsonb_build_object('old_status', v_old_status, 'new_status', v_final_status, 'reason', p_reason, 'reactivated', v_is_reactivation),
        v_org);
    end if;
  end if;

  if p_idempotency_key is not null then
    insert into public.dispatch_status_transitions
      (dispatch_id, idempotency_key, organization_id, old_status, new_status, result, created_by)
    values (p_dispatch_id, p_idempotency_key, v_org, v_old_status, coalesce(v_final_status, v_old_status), v_result, v_uid)
    on conflict (dispatch_id, idempotency_key) do nothing;
  end if;

  return v_result;
end;
$fn$;

do $mig$
declare v_md5 text; v_bad integer;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)');
  if v_md5 is distinct from 'ba881fa42b60a752fb17e26609428e6c' then raise exception 'ROLLBACK 0151 postcondition: body md5 % is not the 0134 baseline.', v_md5; end if;
  select count(*) into v_bad from _rb0151_funcs o join pg_proc p on p.oid::regprocedure::text = o.sig
   where (o.acl, o.config, o.prosecdef, o.proowner) is distinct from (coalesce(p.proacl::text, ''), coalesce(p.proconfig::text, ''), p.prosecdef, p.proowner);
  if v_bad <> 0 then raise exception 'ROLLBACK 0151 postcondition: % function propert(ies) changed.', v_bad; end if;
  raise notice 'ROLLBACK 0151 complete: transition_dispatch_status() restored to the exact 0134 body (replay-before-authorization defect is back).';
end
$mig$;

commit;
