-- ============================================================================
-- TEST_ADVERSARIAL_TRAILER_AND_DISPATCH.sql -- disposable database only.
-- Run via TEST_0130_0133_run.sh.
--
-- Correction items #7 (trailer authorization flag spoofing) and #8 (direct
-- dispatch INSERT bypass). Every scenario here is run as an authenticated
-- app user (via `set_config('test.current_uid', ..., false)` -- session-
-- persistent, not transaction-local, so it survives across the separate
-- autocommitted statements a real client connection would also span) with
-- `SET ROLE authenticated` wherever the point is to prove the ORDINARY
-- client privilege boundary (not a superuser bypass) actually holds.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST ADVERSARIAL TRAILER AND DISPATCH  ################'

\i TEST_SUPPORT_0130_0133_schema.sql
\i migrations/0130_carrier_context_foundation.sql
\i migrations/0131_carrier_party_relationships.sql
\i migrations/0132_load_carrier_and_trailer_scope.sql

\echo '===== PART 1: trailer authorization -- adversarial spoof attempts (correction #7) ====='

\echo '----- 1.0 CATALOG PROOF: exact grant/revoke state, independent of any behavioral test (Phase 3A clarification round, item 3) -----'
do $t$
declare
  v_table_update boolean;
  v_col_carrier boolean;
  v_col_scope boolean;
  v_col_unit boolean;
  v_col_notes boolean;
  v_priv_rows int;
begin
  -- has_table_privilege: does `authenticated` hold a TABLE-LEVEL (unqualified)
  -- UPDATE grant on trailers -- the kind that would cover every column,
  -- including future ones, with no per-column restriction? CONFIRMED
  -- EMPIRICALLY (not assumed from documentation) to be FALSE here, and this
  -- is the correct, useful signal: 0132 section F REVOKEd the table-level
  -- UPDATE entirely and re-GRANTed it only on an explicit column list, so
  -- `authenticated` genuinely holds NO table-level UPDATE privilege any
  -- more -- contrast with, e.g., has_table_privilege('authenticated',
  -- 'public.dispatches', 'UPDATE'), which is TRUE (dispatches never had its
  -- table-level grant revoked). If this ever flips back to TRUE for
  -- trailers, something re-granted the whole-table privilege -- a real
  -- regression signal for a future audit. The per-COLUMN answer (which
  -- specific columns are updatable) is has_column_privilege, checked next.
  select has_table_privilege('authenticated', 'public.trailers', 'UPDATE') into v_table_update;
  assert v_table_update = false, 'TEST FAIL: authenticated holds a TABLE-LEVEL UPDATE grant on trailers -- the column-scoped revoke/re-grant design (0132 section F) has regressed to a broader grant';

  select has_column_privilege('authenticated', 'public.trailers', 'carrier_id', 'UPDATE') into v_col_carrier;
  select has_column_privilege('authenticated', 'public.trailers', 'ownership_scope', 'UPDATE') into v_col_scope;
  select has_column_privilege('authenticated', 'public.trailers', 'unit_number', 'UPDATE') into v_col_unit;
  select has_column_privilege('authenticated', 'public.trailers', 'notes', 'UPDATE') into v_col_notes;

  raise notice 'CATALOG: has_table_privilege(authenticated, trailers, UPDATE) = % (must be false -- no table-level grant survives; contrast with dispatches, where it is still true)', v_table_update;
  raise notice 'CATALOG: has_column_privilege(authenticated, trailers, carrier_id, UPDATE) = % (must be false)', v_col_carrier;
  raise notice 'CATALOG: has_column_privilege(authenticated, trailers, ownership_scope, UPDATE) = % (must be false)', v_col_scope;
  raise notice 'CATALOG: has_column_privilege(authenticated, trailers, unit_number, UPDATE) = % (must be true)', v_col_unit;
  raise notice 'CATALOG: has_column_privilege(authenticated, trailers, notes, UPDATE) = % (must be true)', v_col_notes;

  assert v_col_carrier = false, 'TEST FAIL: has_column_privilege says authenticated CAN update carrier_id';
  assert v_col_scope = false, 'TEST FAIL: has_column_privilege says authenticated CAN update ownership_scope';
  assert v_col_unit = true, 'TEST FAIL: has_column_privilege says authenticated CANNOT update unit_number (should be able to)';
  assert v_col_notes = true, 'TEST FAIL: has_column_privilege says authenticated CANNOT update notes (should be able to)';

  -- information_schema.column_privileges: the SQL-standard, introspectable
  -- view of the exact same fact -- confirms carrier_id/ownership_scope have
  -- NO UPDATE row for authenticated, while an ordinary column does.
  select count(*) into v_priv_rows
  from information_schema.column_privileges
  where table_schema='public' and table_name='trailers' and grantee='authenticated'
    and privilege_type='UPDATE' and column_name in ('carrier_id','ownership_scope');
  assert v_priv_rows = 0, format('TEST FAIL: information_schema.column_privileges shows % UPDATE grant row(s) for authenticated on carrier_id/ownership_scope (expected 0)', v_priv_rows);

  select count(*) into v_priv_rows
  from information_schema.column_privileges
  where table_schema='public' and table_name='trailers' and grantee='authenticated'
    and privilege_type='UPDATE' and column_name = 'unit_number';
  assert v_priv_rows = 1, 'TEST FAIL: information_schema.column_privileges is missing the expected UPDATE grant row for authenticated on unit_number';

  raise notice 'OK: catalog-level proof confirms carrier_id/ownership_scope have ZERO UPDATE privilege for authenticated (both has_column_privilege and information_schema.column_privileges agree); ordinary columns remain fully updatable.';

  -- Explicit contrast: `dispatches` never had its table-level UPDATE grant
  -- touched (only trailers.carrier_id/ownership_scope were narrowed), so its
  -- has_table_privilege must still read TRUE -- proving the FALSE result
  -- above for trailers is a genuine, deliberate narrowing, not an artifact
  -- of some broader misconfiguration.
  assert has_table_privilege('authenticated', 'public.dispatches', 'UPDATE') = true,
    'TEST FAIL: authenticated unexpectedly lost its ordinary table-level UPDATE grant on dispatches -- unrelated regression';
  raise notice 'OK: contrast confirmed -- has_table_privilege(authenticated, dispatches, UPDATE) = true (untouched table-level grant), vs. false for trailers (deliberately narrowed) -- the difference is real, not a fluke.';
end
$t$;

\echo '----- 1.0b confirm service_role and migration/superuser context are NOT restricted by this column revoke (by design -- the revoke names `authenticated` only) -----'
do $t$
declare v_service_col boolean; v_postgres_col boolean;
begin
  -- service_role: this schema (matching real 0010_rls_policies.sql, which
  -- never GRANTs/REVOKEs anything for service_role -- it is a Supabase
  -- platform-managed role, pre-configured with BYPASSRLS and full table
  -- privileges outside any of this project''s migrations) never restricts
  -- service_role. Confirmed: no REVOKE anywhere in 0132 names service_role,
  -- and this project''s application code (grep-verified, read-only) never
  -- writes trailers.carrier_id/ownership_scope via a service-role client --
  -- only via display-only SELECTs. service_role''s continued full access is
  -- therefore intentional and not a gap this correction needs to close.
  select has_column_privilege('service_role', 'public.trailers', 'carrier_id', 'UPDATE') into v_service_col;
  raise notice 'CATALOG: has_column_privilege(service_role, trailers, carrier_id, UPDATE) = % (role may not exist with real grants in this disposable schema -- production service_role is platform-provisioned, not migration-provisioned; see note above)', v_service_col;

  -- the migration/superuser role (whoever is running this script, i.e.
  -- postgres here) is the OWNER of public.trailers and therefore always
  -- bypasses table/column privilege checks entirely (Postgres: object
  -- owners bypass their own object''s grants) -- this is what makes 0132''s
  -- own PHASE 2 backfill UPDATE (before any policy/grant/trigger existed)
  -- and any future migration''s direct fix-up UPDATE both unaffected by this
  -- correction, exactly as intended.
  select has_column_privilege(current_user, 'public.trailers', 'carrier_id', 'UPDATE') into v_postgres_col;
  assert v_postgres_col = true, 'sanity: the migration-running role must still be able to update carrier_id directly (table owner bypass)';
  raise notice 'OK: migration/superuser context (%) retains full column access via table ownership -- confirmed, not merely assumed.', current_user;
end
$t$;

-- Authenticate as Dispatcher A (a real, valid, but non-owner/admin role) --
-- with FULL, realistic context: auth.uid() resolves through profiles to an
-- organization_id and org_role exactly as current_org_id()/current_role()/
-- has_role() do in production, and `SET ROLE authenticated` switches the
-- SESSION''s effective Postgres privileges to the real client role (current_
-- user becomes 'authenticated'; every privilege AND RLS check below runs
-- against that role, not a superuser bypass -- confirmed in this same round
-- by the fact that the SELECT-visibility and UPDATE-rejection checks below
-- actually depend on it).
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note_dispatcher_authenticated;

\echo '----- 1a. REALISTIC READ: dispatcher can SEE the exact trailer row through RLS (organization_id = current_org_id()), proving this is not an isolated privilege-only probe -----'
set role authenticated;
do $t$
declare v_seen record;
begin
  select id, unit_number, ownership_scope, carrier_id into v_seen
  from public.trailers where id = 'e9000000-0000-0000-0000-000000000009';
  assert v_seen.id is not null, 'TEST FAIL: dispatcher cannot SELECT a same-organization trailer through trailers_select RLS -- the realistic-user premise for the rest of this test would be false';
  raise notice 'OK: dispatcher sees the trailer row through RLS (trailers_select: organization_id = current_org_id()) -- current state: unit_number=%, ownership_scope=%, carrier_id=%', v_seen.unit_number, v_seen.ownership_scope, v_seen.carrier_id;
end
$t$;

\echo '----- 1b. REALISTIC ALLOWED EDIT: dispatcher successfully edits a permitted field (unit_number), through the FULL stack (RLS trailers_update + column grant), exactly as the real role model allows -----'
do $t$
declare v_after text;
begin
  update public.trailers set unit_number = 'TRL-SHARED-RENAMED' where id = 'e9000000-0000-0000-0000-000000000009';
  select unit_number into v_after from public.trailers where id = 'e9000000-0000-0000-0000-000000000009';
  assert v_after = 'TRL-SHARED-RENAMED', 'TEST FAIL: dispatcher''s permitted unit_number edit did not take effect';
  raise notice 'OK: dispatcher successfully edited an allowed field (unit_number) through RLS + column grant, matching the real operational_write role tier (owner/admin/dispatcher).';
end
$t$;

\echo '----- 1c. attempt to reproduce the internal GUC flag name/value, then a direct UPDATE -----'
do $t$
begin
  -- Even a caller who has somehow LEARNED the exact internal flag name and
  -- sets it themselves gains NOTHING: the column-level REVOKE (not the GUC)
  -- is the actual, unforgeable gate for an ordinary client role.
  perform set_config('app.trailer_ownership_rpc_reason', 'spoofed reason, attacker-supplied', true);
  begin
    update public.trailers set ownership_scope = 'organization_shared' where id = 'e9000000-0000-0000-0000-000000000009';
    raise exception 'TEST FAIL: GUC-spoofed direct UPDATE to ownership_scope SUCCEEDED -- the flag was not just a backstop, it was exploitable';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: GUC-spoofing does not help -- direct UPDATE still rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- 1d. plain direct UPDATE (no spoofing attempt) to the protected columns, as the SAME realistic dispatcher who just succeeded at 1b -----'
do $t$
declare v_scope_before public.trailer_ownership_scope; v_carrier_before uuid; v_scope_after public.trailer_ownership_scope; v_carrier_after uuid;
begin
  select ownership_scope, carrier_id into v_scope_before, v_carrier_before from public.trailers where id = 'e9000000-0000-0000-0000-000000000009';
  begin
    update public.trailers set ownership_scope = 'carrier', carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'
     where id = 'e9000000-0000-0000-0000-000000000009';
    raise exception 'TEST FAIL: direct UPDATE to ownership_scope/carrier_id succeeded as an ordinary authenticated dispatcher';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct UPDATE to protected columns rejected for dispatcher (%)', sqlerrm;
  end;
  select ownership_scope, carrier_id into v_scope_after, v_carrier_after from public.trailers where id = 'e9000000-0000-0000-0000-000000000009';
  assert v_scope_after = v_scope_before and v_carrier_after is not distinct from v_carrier_before,
    'TEST FAIL: ownership_scope/carrier_id changed despite the rejected UPDATE -- the statement must have had ZERO effect, not a partial one';

  -- an UNRELATED column stays updatable -- the revocation is column-scoped
  update public.trailers set status = 'in_maintenance' where id = 'e9000000-0000-0000-0000-000000000009';
  raise notice 'OK: an unrelated trailer column (status) remains updatable for an authenticated dispatcher';
end
$t$;

\echo '----- 1e. an unrelated trailer update does NOT accidentally clear or alter ownership fields (explicit requirement, Phase 3A clarification round item 3) -----'
do $t$
declare v_scope_before public.trailer_ownership_scope; v_carrier_before uuid; v_scope_after public.trailer_ownership_scope; v_carrier_after uuid;
begin
  select ownership_scope, carrier_id into v_scope_before, v_carrier_before from public.trailers where id = 'e9000000-0000-0000-0000-000000000009';
  update public.trailers
  set notes = 'routine inspection note', registration_expiry_date = current_date + interval '1 year', license_plate = 'TX-TEST-123'
  where id = 'e9000000-0000-0000-0000-000000000009';
  select ownership_scope, carrier_id into v_scope_after, v_carrier_after from public.trailers where id = 'e9000000-0000-0000-0000-000000000009';
  assert v_scope_after = v_scope_before and v_carrier_after is not distinct from v_carrier_before,
    format('TEST FAIL: an unrelated column UPDATE altered ownership_scope/carrier_id (before=%s/%s, after=%s/%s)', v_scope_before, v_carrier_before, v_scope_after, v_carrier_after);
  raise notice 'OK: an unrelated multi-column UPDATE (notes, registration_expiry_date, license_plate) left ownership_scope=% and carrier_id=% completely untouched.', v_scope_after, v_carrier_after;
end
$t$;
reset role;

\echo '----- 1f. owner ALSO cannot directly edit protected ownership columns (the column-level REVOKE is role-blind -- org_role lives only in profiles/has_role(), which the Postgres privilege system never consults; only the SECURITY DEFINER RPC, run as its OWNER, can bypass it) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false) as note_owner_authenticated;
set role authenticated;
do $t$
begin
  begin
    update public.trailers set ownership_scope = 'carrier', carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001'
     where id = 'e9000000-0000-0000-0000-000000000009';
    raise exception 'TEST FAIL: direct UPDATE to ownership_scope/carrier_id succeeded for an OWNER -- the column revoke must be unconditional, not role-gated';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct UPDATE to protected columns rejected even for an owner-role authenticated user (%) -- confirms the block is a Postgres-role privilege, not an org_role check that a privileged app role could route around.', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- 1g. the RPC still succeeds for owner, even while running AS authenticated (SECURITY DEFINER bypasses the column revocation; role/reason checks inside the RPC still apply) -----'
set role authenticated;
do $t$
declare v_res jsonb; v_audit_cnt_before int; v_audit_cnt_after int;
begin
  select count(*) into v_audit_cnt_before from public.trailer_ownership_scope_audit;
  v_res := public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'organization_shared', 'owner-approved, adversarial-test suite');
  assert v_res->>'success' = 'true', format('expected RPC success for owner, got %s', v_res);
  select count(*) into v_audit_cnt_after from public.trailer_ownership_scope_audit;
  assert v_audit_cnt_after = v_audit_cnt_before + 1, 'exactly one audit row must be written by the RPC call';
  raise notice 'OK: only the owner/admin RPC succeeds, even under SET ROLE authenticated; exactly one audit row written';
end
$t$;
reset role;

\echo '----- 1h. the audit record cannot be suppressed: dispatcher cannot call the RPC to skip it, cannot INSERT a forged row, and cannot alter/delete the real one -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note_dispatcher_again;
set role authenticated;
do $t$
declare
  v_audit_id uuid;
  v_reason_before text;
begin
  select id, reason into v_audit_id, v_reason_before from public.trailer_ownership_scope_audit order by created_at desc limit 1;

  -- dispatcher cannot call the RPC at all (role gate), so cannot create an
  -- un-audited change via it either
  begin
    perform public.approve_trailer_ownership_scope('e9000000-0000-0000-0000-000000000009', 'carrier', 'dispatcher trying to sneak past', 'a1a1a1a1-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: dispatcher was able to call approve_trailer_ownership_scope';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: dispatcher cannot call the RPC at all (%)', sqlerrm;
  end;

  -- dispatcher cannot INSERT a forged audit row, nor UPDATE/DELETE the real
  -- one, directly. 0132 explicitly REVOKEs table-level INSERT/UPDATE/DELETE
  -- on this table from `authenticated` (defense-in-depth correction found
  -- during this test pass -- see 0132 section E), so all three are now hard
  -- Postgres permission errors raised BEFORE RLS is even consulted -- not
  -- merely RLS's implicit default-deny (which, for UPDATE/DELETE, would
  -- otherwise silently affect 0 rows with no exception at all; verified
  -- empirically both before and after adding the explicit REVOKE).
  begin
    insert into public.trailer_ownership_scope_audit
      (trailer_id, organization_id, ownership_scope_before, ownership_scope_after, reason, approved_by)
    values ('e9000000-0000-0000-0000-000000000009', '11111111-1111-1111-1111-111111111111',
            'unresolved', 'organization_shared', 'forged, dispatcher-authored', 'dddd0000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: dispatcher was able to INSERT a forged audit row';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: forged direct INSERT into the audit table is rejected (%)', sqlerrm;
  end;

  begin
    delete from public.trailer_ownership_scope_audit where id = v_audit_id;
    raise exception 'TEST FAIL: dispatcher was able to delete an audit row';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: audit row cannot be deleted directly (%)', sqlerrm;
  end;

  begin
    update public.trailer_ownership_scope_audit set reason = 'tampered' where id = v_audit_id;
    raise exception 'TEST FAIL: dispatcher was able to alter an audit row';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: audit row cannot be altered directly (%)', sqlerrm;
  end;
end
$t$;
reset role;

-- Independently re-verify (as the table owner, bypassing RLS entirely) that
-- the audit row genuinely still exists, unchanged, and no forged row exists.
do $t$
declare v_cnt int; v_reason text;
begin
  select count(*) into v_cnt from public.trailer_ownership_scope_audit;
  assert v_cnt = 1, format('TEST FAIL: expected exactly 1 audit row after all adversarial attempts, found %s', v_cnt);
  select reason into v_reason from public.trailer_ownership_scope_audit limit 1;
  assert v_reason = 'owner-approved, adversarial-test suite',
    format('TEST FAIL: the sole audit row''s reason was altered (now "%s") -- tampering succeeded', v_reason);
  raise notice 'OK: exactly one audit row survives, byte-for-byte unchanged -- no suppression, no forgery, no tampering possible for an ordinary authenticated dispatcher';
end
$t$;
select set_config('test.current_uid', '', false) as note_reset;

\echo '===== PART 2: direct dispatch INSERT bypass (correction #8) ====='

\echo '----- 2a. cross-carrier direct insert rejected (already the core of TEST_0132, re-verified here explicitly as authenticated dispatcher) -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false) as note;
set role authenticated;
do $t$
begin
  -- L1 (from the standard seed) is carrier A1 once claimed; simulate that
  -- state directly here for a clean, isolated fixture.
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('ad000000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'LD-ADV-A', 'a0b00000-0000-0000-0000-000000000001', 'booked');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ad0d0000-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000a',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');

  begin
    insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('ad0d0000-0000-0000-0000-00000000000b', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000a',
            'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
    raise exception 'TEST FAIL: cross-carrier direct INSERT succeeded as authenticated dispatcher';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: cross-carrier direct dispatch INSERT rejected for an authenticated client (%)', sqlerrm;
  end;
end
$t$;

\echo '----- 2b. unresolved-load direct insert rejected -----'
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('ad000000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'LD-ADV-C', 'a0b00000-0000-0000-0000-000000000001', 'booked');
  update public.loads set carrier_resolution = 'unresolved' where id = 'ad000000-0000-0000-0000-00000000000c';
  begin
    insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('ad0d0000-0000-0000-0000-00000000000c', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000c',
            'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'assigned');
    raise exception 'TEST FAIL: direct INSERT onto an unresolved-carrier load succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: direct dispatch INSERT onto an unresolved-carrier load rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- 2c. NULL-resolution load (never yet touched) receives SAFE ATOMIC ownership on the first live dispatch -----'
do $t$
declare v_carrier uuid; v_resolution text;
begin
  -- fresh A1 equipment: 2a's dispatch (above) already holds the standard
  -- A1 driver/truck, and 0054's partial unique indexes (faithfully
  -- reproduced) forbid a second, simultaneously-active dispatch on them.
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-0000000000c1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-2c');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-0000000000c1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-2c');

  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('ad000000-0000-0000-0000-00000000000d', '11111111-1111-1111-1111-111111111111', 'LD-ADV-D', 'a0b00000-0000-0000-0000-000000000001', 'booked');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ad0d0000-0000-0000-0000-00000000000d', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000d',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000c1', 'd1000000-0000-0000-0000-0000000000c1', 'assigned');
  select carrier_id, carrier_resolution into v_carrier, v_resolution from public.loads where id = 'ad000000-0000-0000-0000-00000000000d';
  assert v_carrier = 'a1a1a1a1-0000-0000-0000-000000000001' and v_resolution = 'resolved',
    format('expected the first dispatch to atomically claim the load, got carrier=%s resolution=%s', v_carrier, v_resolution);
  raise notice 'OK: NULL-resolution load safely, atomically claimed by its first live dispatch (no window where financial controller exists while carrier_id is NULL)';
end
$t$;

\echo '----- 2d. same-carrier legitimate path works -----'
do $t$
begin
  -- another distinct A1 driver/truck (a real second dispatch on the same
  -- load needs its own equipment, matching 0054's own real-world
  -- constraint -- the same truck/driver cannot hold two active dispatches
  -- at once, on this load or any other).
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name)
  values ('d1000000-0000-0000-0000-0000000000d1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'Drv', 'A1-2d');
  insert into public.trucks (id, organization_id, carrier_id, unit_number)
  values ('c1000000-0000-0000-0000-0000000000d1', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'TRK-A1-2d');

  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ad0d0000-0000-0000-0000-00000000000e', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000d',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-0000000000d1', 'd1000000-0000-0000-0000-0000000000d1', 'accepted');
  raise notice 'OK: a second, SAME-carrier dispatch on an already-claimed load succeeds normally';
end
$t$;

\echo '----- 2e. a forged/manipulated financial_dispatch_id cannot bypass carrier validation -----'
do $t$
begin
  -- Redirect financial_dispatch_id to the LOAD''s OTHER dispatch (same load,
  -- allowed by 0125's guard_load_financial_dispatch_ref) -- an attempt to
  -- manipulate which dispatch "looks like" the controller.
  update public.loads set financial_dispatch_id = 'ad0d0000-0000-0000-0000-00000000000e'
   where id = 'ad000000-0000-0000-0000-00000000000d';

  -- guard_dispatch_carrier_scope does NOT consult financial_dispatch_id at
  -- all (by design, to avoid the cancel-redispatch regression) -- it derives
  -- the effective carrier from loads.carrier_id (already A1) and LIVE
  -- non-cancelled dispatches. The forged financial_dispatch_id has ZERO
  -- effect on the cross-carrier guard.
  begin
    insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id, status)
    values ('11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000d',
            'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
    raise exception 'TEST FAIL: a conflicting-carrier dispatch succeeded after financial_dispatch_id was redirected';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: a forged/redirected financial_dispatch_id has no effect on the cross-carrier guard -- still rejected (%)', sqlerrm;
  end;
end
$t$;

\echo '----- 2f. a status update cannot reactivate an old conflicting dispatch -----'
do $t$
begin
  insert into public.loads (id, organization_id, load_number, broker_id, status)
  values ('ad000000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'LD-ADV-F', 'a0b00000-0000-0000-0000-000000000001', 'booked');
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ad0d0000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000f',
          'a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'cancelled');
  -- a live, different-carrier dispatch now claims the load
  insert into public.dispatches (id, organization_id, load_id, carrier_id, truck_id, driver_id, status)
  values ('ad0d0000-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111', 'ad000000-0000-0000-0000-00000000000f',
          'a2a2a2a2-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'assigned');
  begin
    update public.dispatches set status = 'assigned' where id = 'ad0d0000-0000-0000-0000-00000000000f';  -- reactivate the OLD, conflicting one
    raise exception 'TEST FAIL: reactivating an old conflicting-carrier dispatch succeeded';
  exception when others then
    if sqlerrm like 'TEST FAIL:%' then raise; end if;
    raise notice 'OK: reactivating an old conflicting-carrier dispatch via status UPDATE is rejected (%)', sqlerrm;
  end;
end
$t$;

reset role;
select set_config('test.current_uid', '', false) as note_reset;

\echo '################  TEST ADVERSARIAL TRAILER AND DISPATCH PASSED  ################'
