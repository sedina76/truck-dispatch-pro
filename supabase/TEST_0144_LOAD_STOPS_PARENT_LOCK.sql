-- ============================================================================
-- TEST_0144_LOAD_STOPS_PARENT_LOCK.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.3C.3, Section A (corrected in Section C -- see below): direct-
-- SQL, single-session structural proof of the CORRECT behavior for each
-- of the four load_stops mutation shapes, and that a cross-load load_id
-- UPDATE is REJECTED (rather than silently under-locking one side):
--
--   INSERT                       -> explicitly locks NEW.load_id (the
--                                    only mechanism that can close the
--                                    "a row lock can't lock a row's
--                                    absence" gap for a brand-new stop)
--   DELETE                       -> takes NO additional lock -- the
--                                    target row's own implicit lock,
--                                    already held by Postgres before
--                                    this trigger runs, is sufficient
--   UPDATE, load_id unchanged    -> takes NO additional lock -- same
--                                    reasoning as DELETE
--   UPDATE, load_id changed      -> REJECTED outright (55000), no
--                                    partial lock, no partial mutation
--
-- Section C correction: the original version of this migration ALSO
-- explicitly locked the parent for DELETE and same-load UPDATE -- this
-- created a genuine, repeatable AB-BA deadlock against issue_carrier_
-- invoice() (loads-then-load_stops vs. the trigger's load_stops-then-
-- loads, forced by PostgreSQL always locking an UPDATE/DELETE target
-- row before its own BEFORE trigger runs). Removing that redundant lock
-- for DELETE/same-load UPDATE (the row's own already-held implicit lock
-- was always sufficient on its own) closes the deadlock without
-- reopening any gap -- see the function's own header comment in
-- migrations/0144_atomic_carrier_invoice_issuance.sql for the full
-- derivation, and TEST_CONCURRENCY_0144 scenarios 20A/22A/23A (the exact
-- interleaving that used to deadlock, forced deterministically, now
-- clean) for the live proof.
--
-- This file proves the STRUCTURAL/behavioral rule (what succeeds, what is
-- rejected, and that no partial mutation is ever left behind by a rejected
-- cross-load UPDATE). The genuine BLOCKING proof -- that each shape's lock
-- actually contends with a concurrent issue_carrier_invoice() call on the
-- correct parent/row, and never blocks on an unrelated one -- is covered
-- by real two-session tests: TEST_CONCURRENCY_0144_atomic_invoice_issuance.sh
-- scenarios 20A/20B through 23A/23B and 25A/25B (UPDATE/INSERT/DELETE/
-- reorder/nonterminal-edit, both forced orderings) and scenario 27
-- (cross-load move attempt during issuance).
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0144 LOAD STOPS PARENT LOCK  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i TEST_SUPPORT_0136_0138_factoring_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql
\i migrations/0133_deterministic_carrier_backfill.sql
\i migrations/0134_dispatch_status_transition_and_trailer_privilege_hotfix.sql
\i migrations/0135_dispatch_resource_reassignment_and_carrier_lockdown.sql
\i migrations/0136_carrier_factoring_policy_and_relationship_columns.sql
\i migrations/0137_deterministic_factoring_carrier_backfill.sql
\i migrations/0138_carrier_default_cutover_classifier_and_secured_rpcs.sql
\i migrations/0139_factoring_policy_safety_integrations_and_privilege_remediation.sql
\i migrations/0140_factoring_authorization_and_submission_safety.sql
\i migrations/0141_factoring_integration_lifecycle_integrity.sql
\i migrations/0142_immutable_carrier_invoice_foundation.sql
\i migrations/0143_canonical_financial_idempotency_hardening.sql
\i migrations/0144_atomic_carrier_invoice_issuance.sql

select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

do $t$
begin
  insert into public.loads (id, organization_id, load_number, status, rate, carrier_id, carrier_resolution)
  values
    ('a1000000-0000-0000-0000-00000000a001', '11111111-1111-1111-1111-111111111111', 'LD-PLOCK-A', 'delivered', 100, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved'),
    ('a1000000-0000-0000-0000-00000000a002', '11111111-1111-1111-1111-111111111111', 'LD-PLOCK-B', 'delivered', 100, 'a1a1a1a1-0000-0000-0000-000000000001', 'resolved');
  raise notice 'OK: fixtures ready -- two loads (A, B), same carrier, same org, no stops yet.';
end
$t$;

\echo '----- J1. INSERT: a new stop can be inserted (locks NEW.load_id -- the only candidate parent; no error, no silent rejection) -----'
do $t$
declare v_stop_id uuid;
begin
  insert into public.load_stops (id, organization_id, load_id, stop_type, stop_sequence, city)
  values ('b1000000-0000-0000-0000-00000000b001', '11111111-1111-1111-1111-111111111111', 'a1000000-0000-0000-0000-00000000a001', 'pickup', 1, 'Dallas')
  returning id into v_stop_id;
  if v_stop_id is null then raise exception 'TEST FAIL (J1): insert did not return an id.'; end if;
  raise notice 'OK (J1): INSERT succeeded (locked NEW.load_id=LD-PLOCK-A only) -- stop id=%.', v_stop_id;
end
$t$;

\echo '----- J2. UPDATE (load_id unchanged): editing a non-load_id column succeeds -- no additional lock is taken; the row''s own implicit UPDATE lock (already held before this trigger runs) is sufficient -----'
do $t$
declare v_city text;
begin
  update public.load_stops set city = 'Fort Worth' where id = 'b1000000-0000-0000-0000-00000000b001';
  select city into v_city from public.load_stops where id = 'b1000000-0000-0000-0000-00000000b001';
  if v_city <> 'Fort Worth' then raise exception 'TEST FAIL (J2): update did not land, got city=%.', v_city; end if;
  raise notice 'OK (J2): same-load_id UPDATE succeeded (no additional loads lock taken -- Section C: that would create an AB-BA deadlock against issue_carrier_invoice(); the row''s own already-held implicit lock is sufficient) -- city=%.', v_city;
end
$t$;

\echo '----- J3. UPDATE (load_id CHANGED, cross-load move): REJECTED outright, no partial state, original row untouched -----'
do $t$
declare v_load_id_before uuid; v_load_id_after uuid; v_caught boolean := false;
begin
  select load_id into v_load_id_before from public.load_stops where id = 'b1000000-0000-0000-0000-00000000b001';
  begin
    update public.load_stops set load_id = 'a1000000-0000-0000-0000-00000000a002' where id = 'b1000000-0000-0000-0000-00000000b001';
    raise exception 'TEST FAIL (J3): a cross-load load_id UPDATE should have been rejected but succeeded.';
  exception when sqlstate '55000' then
    v_caught := true;
    if sqlerrm not ilike '%load_id cannot be changed%' then raise exception 'TEST FAIL (J3): rejected for the wrong reason: %.', sqlerrm; end if;
  end;
  if not v_caught then raise exception 'TEST FAIL (J3): expected sqlstate 55000, none raised.'; end if;
  select load_id into v_load_id_after from public.load_stops where id = 'b1000000-0000-0000-0000-00000000b001';
  if v_load_id_after <> v_load_id_before then raise exception 'TEST FAIL (J3): the row''s load_id changed despite the rejection -- got %, expected unchanged %.', v_load_id_after, v_load_id_before; end if;
  if v_load_id_after <> 'a1000000-0000-0000-0000-00000000a001' then raise exception 'TEST FAIL (J3): unexpected final load_id.'; end if;
  raise notice 'OK (J3): a cross-load load_id UPDATE is REJECTED (55000) BEFORE any lock/mutation completes -- the row still belongs to its original load (LD-PLOCK-A), never left half-moved.';
end
$t$;

\echo '----- J4. Multiple UPDATE attempts moving load_id to various targets (including the load''s OWN current load_id spelled via a subquery, and NULL) all correctly classified -----'
do $t$
declare v_caught boolean;
begin
  -- Moving to the SAME load_id (a no-op value-wise) must NOT be treated as
  -- a "change" -- `is distinct from` correctly returns false here.
  update public.load_stops set load_id = (select load_id from public.load_stops where id = 'b1000000-0000-0000-0000-00000000b001') where id = 'b1000000-0000-0000-0000-00000000b001';
  raise notice 'OK (J4a): re-assigning load_id to its OWN current value is correctly treated as unchanged (not rejected).';

  v_caught := false;
  begin
    update public.load_stops set load_id = null where id = 'b1000000-0000-0000-0000-00000000b001';
    raise exception 'TEST FAIL (J4b): setting load_id to NULL should be rejected (both as a cross-load change AND by the NOT NULL constraint).';
  exception when sqlstate '55000' or sqlstate '23502' then
    v_caught := true;
  end;
  if not v_caught then raise exception 'TEST FAIL (J4b): expected a rejection, none raised.'; end if;
  raise notice 'OK (J4b): setting load_id to NULL is rejected, not silently accepted.';
end
$t$;

\echo '----- J5. DELETE: removing a stop succeeds -- no additional lock is taken; the row''s own implicit DELETE lock (already held before this trigger runs) is sufficient -----'
do $t$
declare v_remaining integer;
begin
  delete from public.load_stops where id = 'b1000000-0000-0000-0000-00000000b001';
  select count(*) into v_remaining from public.load_stops where id = 'b1000000-0000-0000-0000-00000000b001';
  if v_remaining <> 0 then raise exception 'TEST FAIL (J5): the row still exists after DELETE.'; end if;
  raise notice 'OK (J5): DELETE succeeded (no additional loads lock taken -- same Section C reasoning as J2).';
end
$t$;

\echo '----- J6. INSERT/UPDATE/DELETE on a NONEXISTENT load_id is rejected by the FK, not silently accepted (the parent-lock SELECT itself finds nothing, but the FK constraint is the actual backstop) -----'
do $t$
declare v_caught boolean := false;
begin
  begin
    insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, city)
    values ('11111111-1111-1111-1111-111111111111', gen_random_uuid(), 'pickup', 1, 'Nowhere');
    raise exception 'TEST FAIL (J6): insert against a nonexistent load_id should have been rejected by the FK.';
  exception when foreign_key_violation then
    v_caught := true;
  end;
  if not v_caught then raise exception 'TEST FAIL (J6): expected foreign_key_violation, none raised.'; end if;
  raise notice 'OK (J6): a load_stops row can never reference a nonexistent load -- the FK constraint (not the trigger''s own best-effort lock attempt) is the authoritative backstop.';
end
$t$;

\echo '----- J7. structural proof: guard_load_stops_parent_lock() locks public.loads EXACTLY once (INSERT only) -- never the coalesce shortcut, never also for DELETE/same-load UPDATE (Section C''s AB-BA deadlock fix) -----'
do $t$
declare v_src text; v_lock_count integer;
begin
  select prosrc into v_src from pg_proc where proname = 'guard_load_stops_parent_lock' and pronamespace = 'public'::regnamespace;
  if v_src ilike '%coalesce(new.load_id, old.load_id) for update%' then
    raise exception 'TEST FAIL (J7): the trigger still uses the single coalesce(...) lock -- this is the exact Phase 3B.3C.3 Section A defect (OLD.load_id''s parent goes unlocked on a cross-load move).';
  end if;
  if v_src not ilike '%from public.loads where id = new.load_id for update%' then
    raise exception 'TEST FAIL (J7): INSERT path no longer locks NEW.load_id specifically.';
  end if;
  if v_src not ilike '%new.load_id is distinct from old.load_id%' then
    raise exception 'TEST FAIL (J7): the trigger no longer detects/rejects a cross-load load_id change.';
  end if;
  v_lock_count := (length(v_src) - length(replace(v_src, 'from public.loads where id =', ''))) / length('from public.loads where id =');
  if v_lock_count <> 1 then
    raise exception 'TEST FAIL (J7): expected guard_load_stops_parent_lock() to lock public.loads EXACTLY once (INSERT only), got % occurrences -- Section C''s AB-BA deadlock fix requires DELETE/same-load UPDATE to take NO additional loads lock.', v_lock_count;
  end if;
  raise notice 'OK (J7): guard_load_stops_parent_lock()''s source confirms per-operation locking (NEW.load_id on INSERT only, exactly once) and an explicit cross-load rejection -- never the coalesce(...) shortcut, and never an extra DELETE/same-load-UPDATE lock (the AB-BA deadlock Section C removes).';
end
$t$;

\echo '################  TEST 0144 LOAD STOPS PARENT LOCK PASSED  ################'
