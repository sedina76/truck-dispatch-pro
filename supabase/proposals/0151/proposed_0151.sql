-- =============================================================================
-- proposed_0151.sql -- BLOCKER F1-R1: authorize BEFORE any idempotency replay in transition_dispatch_status()
-- PROPOSAL 0151 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 (enum repair) -> 0150 (zero-evidence loads) -> 0151 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion.
--
-- DEFECT (0134): the ledger was read after only `auth.uid() IS NOT NULL` and `current_org_id() IS NOT NULL`, keyed by
-- (dispatch_id, idempotency_key) with NO organization or role check. A caller from ANY organization (any role) who knew a
-- foreign dispatch UUID and its key received that dispatch's cached result, and a caller whose role had been downgraded still
-- received cached results. The same call with a different requested status silently returned the stale result.
--
-- FIX (function body only; no schema change, no data change, signature/SECURITY DEFINER/search_path/ACL/comment untouched):
--   1. authenticated + has an organization (unchanged)  2. dispatch belongs to the caller's organization, else the SAME TSDNF as
--   "not found"  3. caller CURRENTLY holds owner/admin/dispatcher (else TSROL)  4. ONLY THEN the ledger lookup, scoped by
--   organization_id + dispatch_id + key, bound to the original requested status (mismatch -> TSIDK), replays of a reactivation /
--   backward correction still require owner/admin  5. a second ledger check under the load+dispatch locks so a concurrent
--   duplicate replays the winner's result. All transition, cancellation, audit and rollback semantics are unchanged.
-- POLICY: a DIFFERENT authorized owner/admin/dispatcher of the same organization may replay a cached result (the ledger row is
-- organization data they can already read); actor is NOT bound. Cross-organization, unauthorized-role and mismatched-request
-- replays are all refused.
-- =============================================================================
begin;

-- ======================= PHASE 1 -- PRECONDITIONS ==============================
do $mig$
declare
  v_md5 text;
begin
  if to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') is null then raise exception '0151 precondition: transition_dispatch_status(...) missing -- apply 0134 first. STOP.'; end if;
  if to_regclass('public.dispatch_status_transitions') is null then raise exception '0151 precondition: the idempotency ledger is missing. STOP.'; end if;
  if to_regprocedure('public.dispatch_status_sequence_rank(public.dispatch_status)') is null
     or to_regprocedure('public.current_org_id()') is null or to_regprocedure('public.has_role(public.org_role[])') is null then
    raise exception '0151 precondition: a helper function is missing. STOP.';
  end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)');
  if v_md5 is distinct from 'ba881fa42b60a752fb17e26609428e6c' then
    raise exception '0151 precondition: the live transition_dispatch_status() is not the reviewed 0134 definition (md5 %) -- already repaired, or drifted. STOP.', v_md5;
  end if;
  if not (select p.prosecdef and p.proconfig::text = '{"search_path=pg_catalog, public"}' from pg_proc p where p.oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')) then
    raise exception '0151 precondition: transition_dispatch_status() is not SECURITY DEFINER with the pinned search_path. STOP.';
  end if;

  -- snapshots (dropped at commit) for the Phase 3 "nothing else changed" proofs
  create temp table _mig0151_funcs on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  create temp table _mig0151_misc on commit drop as
    select (select count(*) from public.dispatch_status_transitions) as n_ledger,
           (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_status_transitions t) as ledger_md5,
           has_function_privilege('authenticated', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute') as priv_auth, has_function_privilege('anon', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute') as priv_anon,
           has_function_privilege('service_role', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute') as priv_svc, (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')) as priv_pub;
  raise notice '0151 PHASE 1 passed.';
end
$mig$;

-- ======================= PHASE 2 -- THE ONE FUNCTION ===========================
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
  v_cached_old public.dispatch_status;
  v_cached_new public.dispatch_status;
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

  -- 0151: AUTHORIZATION BEFORE ANY LEDGER READ. Order: authenticated (above) -> caller has an organization (above)
  -- -> the target dispatch belongs to THAT organization (else exactly the same TSDNF a missing dispatch gets, so neither a
  -- foreign dispatch nor a foreign idempotency key is ever confirmed) -> the caller CURRENTLY holds an allowed role.
  -- Only then is the replay ledger consulted (org-scoped, key bound to the original requested status).
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    -- cross-tenant reported identically to "not found" -- never confirm
    -- existence of another organization's row.
    raise exception 'transition_dispatch_status: dispatch % not found.', p_dispatch_id using errcode = 'TSDNF';
  end if;
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'transition_dispatch_status: only an owner, admin, or dispatcher may change dispatch status.' using errcode = 'TSROL';
  end if;

  -- Idempotency short-circuit -- AFTER authorization, BEFORE any lock, validation or write. A retried call with the SAME
  -- (dispatch_id, idempotency_key) in the caller's organization replays the ORIGINAL cached result verbatim, never
  -- re-validating against however the row looks now.
  if p_idempotency_key is not null then
    select t.old_status, t.new_status, t.result into v_cached_old, v_cached_new, v_cached
    from public.dispatch_status_transitions t
    where t.dispatch_id = p_dispatch_id and t.idempotency_key = p_idempotency_key and t.organization_id = v_org;
    if found then
      -- (pre-lock) the key is bound to the ORIGINAL request: a different requested status is a client bug, never a silent stale result.
      if v_cached_new is distinct from p_new_status then
        raise exception 'transition_dispatch_status: this idempotency key was already used for a different request.' using errcode = 'TSIDK';
      end if;
      -- A replay never grants more than the original operation needed: replaying a reactivation or a backward correction
      -- requires CURRENT owner/admin authority, exactly as performing it does.
      if (v_cached_old = 'cancelled' and v_cached_new <> 'cancelled')
         or (public.dispatch_status_sequence_rank(v_cached_old) is not null and public.dispatch_status_sequence_rank(v_cached_new) is not null
             and public.dispatch_status_sequence_rank(v_cached_new) < public.dispatch_status_sequence_rank(v_cached_old)) then
        if not public.has_role(array['owner','admin']::public.org_role[]) then
          raise exception 'transition_dispatch_status: replaying a reactivation or a backward correction requires owner/admin authority.' using errcode = 'TSROL';
        end if;
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

  -- (the dispatch's organization and load_id were resolved and verified above, before any ledger read)

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

  -- 0151: re-check the ledger UNDER the locks. Two concurrent identical requests both miss the pre-lock lookup; the loser waits
  -- on the load/dispatch lock here and must then replay the winner's committed result (same authorization, same rules) rather
  -- than re-evaluating against the moved row.
  if p_idempotency_key is not null then
    select t.old_status, t.new_status, t.result into v_cached_old, v_cached_new, v_cached
    from public.dispatch_status_transitions t
    where t.dispatch_id = p_dispatch_id and t.idempotency_key = p_idempotency_key and t.organization_id = v_org;
    if found then
      -- (post-lock) the key is bound to the ORIGINAL request: a different requested status is a client bug, never a silent stale result.
      if v_cached_new is distinct from p_new_status then
        raise exception 'transition_dispatch_status: this idempotency key was already used for a different request.' using errcode = 'TSIDK';
      end if;
      -- A replay never grants more than the original operation needed: replaying a reactivation or a backward correction
      -- requires CURRENT owner/admin authority, exactly as performing it does.
      if (v_cached_old = 'cancelled' and v_cached_new <> 'cancelled')
         or (public.dispatch_status_sequence_rank(v_cached_old) is not null and public.dispatch_status_sequence_rank(v_cached_new) is not null
             and public.dispatch_status_sequence_rank(v_cached_new) < public.dispatch_status_sequence_rank(v_cached_old)) then
        if not public.has_role(array['owner','admin']::public.org_role[]) then
          raise exception 'transition_dispatch_status: replaying a reactivation or a backward correction requires owner/admin authority.' using errcode = 'TSROL';
        end if;
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;

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

-- ======================= PHASE 3 -- POSTCONDITIONS =============================
do $mig$
declare
  v_new text := '7d56b97529af95eece84b2f0dab2e83c';
  v_md5 text;
  v_bad integer;
  m record;
begin
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)');
  if v_md5 is distinct from v_new then raise exception '0151 postcondition: live body md5 % <> expected %.', v_md5, v_new; end if;

  -- exactly one public function body changed (this one); every property of every function (owner, ACL, config, args, return, volatility, comment, SECURITY DEFINER) identical
  create temp table _mig0151_after on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  select count(*) into v_bad from _mig0151_funcs o full join _mig0151_after n using (sig)
   where o.sig is null or n.sig is null
      or (o.acl, o.config, o.prosecdef, o.proowner, o.prorettype, o.provolatile, o.args, o.descr) is distinct from (n.acl, n.config, n.prosecdef, n.proowner, n.prorettype, n.provolatile, n.args, n.descr);
  if v_bad <> 0 then raise exception '0151 postcondition: % function(s) added/removed or with changed properties.', v_bad; end if;
  select count(*) into v_bad from _mig0151_funcs o join _mig0151_after n using (sig) where o.body_md5 is distinct from n.body_md5 and o.sig not like '%transition_dispatch_status(%';
  if v_bad <> 0 then raise exception '0151 postcondition: % OTHER function body(ies) changed.', v_bad; end if;
  select count(*) into v_bad from _mig0151_funcs o join _mig0151_after n using (sig) where o.body_md5 is distinct from n.body_md5;
  if v_bad <> 1 then raise exception '0151 postcondition: expected exactly ONE changed function body, found %.', v_bad; end if;
  if not exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)') and p.prosecdef and p.proconfig::text = '{"search_path=pg_catalog, public"}') then
    raise exception '0151 postcondition: SECURITY DEFINER / pinned search_path lost.';
  end if;
  select * into m from _mig0151_misc;
  if (has_function_privilege('authenticated', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute'), has_function_privilege('anon', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute'), has_function_privilege('service_role', 'public.transition_dispatch_status(uuid,public.dispatch_status,text,text)', 'execute'), (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')))
     is distinct from (m.priv_auth, m.priv_anon, m.priv_svc, m.priv_pub) or not m.priv_auth then
    raise exception '0151 postcondition: EXECUTE privileges changed (they must be exactly what they were before this migration).';
  end if;

  select * into m from _mig0151_misc;
  if (select count(*) from public.dispatch_status_transitions) <> m.n_ledger
     or (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_status_transitions t) <> m.ledger_md5 then
    raise exception '0151 postcondition: the idempotency ledger changed (0151 never writes it).';
  end if;
  raise notice '0151 complete: transition_dispatch_status() now authorizes (organization + current role) before any idempotency replay. Signature, SECURITY DEFINER, search_path, ACL, comment, ledger and every other function unchanged.';
end
$mig$;

commit;
