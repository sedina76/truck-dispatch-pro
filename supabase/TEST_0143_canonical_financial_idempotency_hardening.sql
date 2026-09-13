-- ============================================================================
-- TEST_0143_canonical_financial_idempotency_hardening.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.3B verification (Section E, 20 items): the canonical SHA-256
-- request fingerprint (compute_financial_request_fingerprint), the
-- operation-scoped durable idempotency table (civ_idempotency_unique now
-- (organization_id, operation, idempotency_key)), the redefined
-- update_carrier_invoice_draft() built on both, and the existing-row
-- compatibility policy (Section C: refuse outright if the table is ever
-- non-empty at apply time -- proven here with a SIMULATED pre-existing
-- MD5 row against a database that has 0142, but not yet 0143, applied).
--
-- Section P below runs BEFORE 0143 is applied (0142 only) -- it is the
-- only way to test the refuse-if-nonempty policy at all, since 0143's own
-- Phase 1 precondition makes a genuinely non-empty table at apply time
-- otherwise unreachable in this same script. Section O runs AFTER 0143 is
-- applied for real (following the manufactured row's cleanup) and covers
-- the remaining 19 items functionally.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0143  ################'

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
-- 0143 is intentionally NOT applied yet -- see Section P below.

\echo '===== fixtures (base org/carrier/broker/customer rows come from the stub schema itself; no factoring seed is needed -- none of this file''s tests touch recipient swaps) ====='
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- P. Section C / Section E item 19: the existing-row compatibility policy.
-- Runs against a database with 0142 applied and 0143 NOT YET applied --
-- the only way to construct a genuinely non-empty
-- carrier_invoice_lifecycle_idempotency table for 0143 to encounter, since
-- once 0143 is live its own Phase 1 precondition (proven separately below)
-- makes that state otherwise unreachable in this same script.
-- ---------------------------------------------------------------------------
\echo '----- P0. fixture: one Org A draft invoice for the fake row''s invoice_id FK -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.civ_p', v_id::text, false);
  raise notice 'OK: fixture draft % created for the simulated-MD5-row test.', v_id;
end
$t$;

\echo '----- P1. inject a fake, 0142-shaped, 32-hex MD5 idempotency row directly (simulating a hypothetical pre-existing row -- the baseline states none should exist, so this is manufactured raw data, exactly like this project''s own established "structural abort" test convention) -----'
do $t$
begin
  insert into public.carrier_invoice_lifecycle_idempotency (organization_id, idempotency_key, invoice_id, action, request_fingerprint, result)
  values (
    '11111111-1111-1111-1111-111111111111',
    'legacy-simulated-key',
    current_setting('test.civ_p')::uuid,
    'update_draft',
    md5('legacy-simulated-payload'),
    jsonb_build_object('success', true, 'code', 'UPDATED', 'invoice_id', current_setting('test.civ_p')::uuid)
  );
  if (select request_fingerprint from public.carrier_invoice_lifecycle_idempotency where idempotency_key = 'legacy-simulated-key') !~ '^[0-9a-f]{32}$' then
    raise exception 'TEST SETUP FAIL: the simulated row''s fingerprint is not 32-hex-MD5-shaped.';
  end if;
  raise notice 'OK: simulated legacy MD5-shaped row injected directly (0142''s own action/request_fingerprint columns).';
end
$t$;

\echo '----- P2. snapshot the row and the table shape BEFORE attempting 0143, for a byte-for-byte post-abort comparison -----'
create temp table _pre_0143_row as select * from public.carrier_invoice_lifecycle_idempotency order by id;
create temp table _pre_0143_shape as select
  (select count(*) from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='action') as has_action,
  (select count(*) from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation') as has_operation;

\echo '----- P3. applying 0143 against a NON-EMPTY idempotency table -- MUST ABORT (whole transaction rolled back), per the chosen refuse-if-nonempty compatibility policy -----'
\set ON_ERROR_STOP off
\i migrations/0143_canonical_financial_idempotency_hardening.sql
\set ON_ERROR_STOP on

\echo '----- P4. confirming 0143 actually aborted -- its own new objects were never created, and the simulated row is completely untouched -----'
do $t$
declare v_post_row record; v_pre_row record;
begin
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is not null then
    raise exception 'TEST FAIL (item 19): compute_financial_request_fingerprint(jsonb) exists -- 0143 did NOT abort despite the non-empty table.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='action') then
    raise exception 'TEST FAIL (item 19): the action column is gone -- 0143 partially committed despite the refusal.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation') then
    raise exception 'TEST FAIL (item 19): the operation column exists -- 0143 partially committed despite the refusal.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%md5(%' then
    raise exception 'TEST FAIL (item 19): update_carrier_invoice_draft() no longer uses md5() -- 0143 partially committed despite the refusal.';
  end if;
  -- the fake row itself: byte-for-byte unchanged, never deleted, never
  -- reinterpreted as SHA-256, never rewritten.
  select * into v_pre_row from _pre_0143_row where idempotency_key = 'legacy-simulated-key';
  select * into v_post_row from public.carrier_invoice_lifecycle_idempotency where idempotency_key = 'legacy-simulated-key';
  if v_post_row.request_fingerprint is distinct from v_pre_row.request_fingerprint
     or v_post_row.action is distinct from v_pre_row.action
     or v_post_row.result is distinct from v_pre_row.result then
    raise exception 'TEST FAIL (item 19): the simulated row was altered by the aborted migration attempt.';
  end if;
  if v_post_row.request_fingerprint !~ '^[0-9a-f]{32}$' then
    raise exception 'TEST FAIL (item 19): the simulated row''s fingerprint is no longer 32-hex-MD5-shaped -- it must never be silently reinterpreted as SHA-256.';
  end if;
  if (select count(*) from public.carrier_invoice_lifecycle_idempotency) <> (select count(*) from _pre_0143_row) then
    raise exception 'TEST FAIL (item 19): row count changed -- nothing should be deleted or inserted by an aborted migration.';
  end if;
  raise notice 'OK (item 19): 0143 refused outright against a non-empty carrier_invoice_lifecycle_idempotency table -- zero schema change, zero data change, the simulated legacy MD5-shaped row left completely untouched (never deleted, never reinterpreted as SHA-256).';
end
$t$;

\echo '----- P5. removing the manufactured row (it was injected purely to exercise the refusal path above; the baseline guarantees no such row should ever genuinely exist, and 0143 requires the table empty to apply for real) -----'
delete from public.carrier_invoice_lifecycle_idempotency where idempotency_key = 'legacy-simulated-key';
do $t$
begin
  if (select count(*) from public.carrier_invoice_lifecycle_idempotency) <> 0 then
    raise exception 'TEST SETUP FAIL: table is not empty after removing the simulated row -- cannot proceed to apply 0143 for real.';
  end if;
  raise notice 'OK: simulated row removed, table confirmed empty again -- proceeding to apply 0143 for real.';
end
$t$;

\echo '----- P6. applying 0143 for real -- MUST succeed now that the table is genuinely empty -----'
\i migrations/0143_canonical_financial_idempotency_hardening.sql

do $t$
begin
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is null then
    raise exception 'TEST FAIL: 0143 did not actually apply -- compute_financial_request_fingerprint(jsonb) missing.';
  end if;
  raise notice 'OK: 0143 applied cleanly against the now-empty table.';
end
$t$;

-- ---------------------------------------------------------------------------
-- O. Section E items 1-18, 20: the canonical fingerprint's own properties
-- (direct calls to compute_financial_request_fingerprint), then the
-- redefined update_carrier_invoice_draft()'s behavior end-to-end.
-- ---------------------------------------------------------------------------
\echo '----- O0. fixtures: two fresh Org A drafts + one Org B draft for the RPC-level tests -----'
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_o1 uuid; v_o2 uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_o1;
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_o2;
  perform set_config('test.civ_o1', v_o1::text, false);
  perform set_config('test.civ_o2', v_o2::text, false);
  raise notice 'OK: fixtures civ_o1=%, civ_o2=% created.', v_o1, v_o2;
end
$t$;
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
do $t$
declare v_ob uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('22222222-2222-2222-2222-222222222222', 'carrier_freight_invoice', 'b1b1b1b1-0000-0000-0000-000000000001', 'broker', 'b0b00000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001')
  returning id into v_ob;
  perform set_config('test.civ_ob', v_ob::text, false);
  raise notice 'OK: Org B fixture civ_ob=% created.', v_ob;
end
$t$;

\echo '----- O1 (item 1). the same logical request produces the SAME SHA-256 fingerprint -----'
do $t$
declare v_org uuid := '11111111-1111-1111-1111-111111111111'; v_inv uuid := gen_random_uuid();
declare fp1 text; fp2 text;
begin
  fp1 := public.compute_financial_request_fingerprint(jsonb_build_object('operation','op_x','schema_version',1,'organization_id',v_org,'invoice_id',v_inv,'patch','{"notes":"a"}'::jsonb,'reason','r','expected_updated_at','2026-01-01T00:00:00.000000Z'));
  fp2 := public.compute_financial_request_fingerprint(jsonb_build_object('operation','op_x','schema_version',1,'organization_id',v_org,'invoice_id',v_inv,'patch','{"notes":"a"}'::jsonb,'reason','r','expected_updated_at','2026-01-01T00:00:00.000000Z'));
  if fp1 <> fp2 then raise exception 'TEST FAIL (item 1): identical logical requests must fingerprint identically, got % vs %.', fp1, fp2; end if;
  raise notice 'OK (item 1): identical logical request -> identical fingerprint (%).', fp1;
end
$t$;

\echo '----- O2-O7 (items 2-7). varying EXACTLY ONE field (invoice, organization, operation, patch, reason, expected version) changes the fingerprint -----'
do $t$
declare
  v_base jsonb := jsonb_build_object('operation','op_x','schema_version',1,'organization_id','11111111-1111-1111-1111-111111111111'::uuid,'invoice_id','aaaaaaaa-0000-0000-0000-000000000001'::uuid,'patch','{"notes":"a"}'::jsonb,'reason','r','expected_updated_at','2026-01-01T00:00:00.000000Z');
  v_fp_base text := public.compute_financial_request_fingerprint(v_base);
  v_fp text;
begin
  v_fp := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('invoice_id','bbbbbbbb-0000-0000-0000-000000000002'::uuid));
  if v_fp = v_fp_base then raise exception 'TEST FAIL (item 2): a different invoice_id must change the fingerprint.'; end if;
  raise notice 'OK (item 2): different invoice_id -> different fingerprint.';

  v_fp := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('organization_id','22222222-2222-2222-2222-222222222222'::uuid));
  if v_fp = v_fp_base then raise exception 'TEST FAIL (item 3): a different organization_id must change the fingerprint.'; end if;
  raise notice 'OK (item 3): different organization_id -> different fingerprint.';

  v_fp := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('operation','op_y'));
  if v_fp = v_fp_base then raise exception 'TEST FAIL (item 4): a different operation must change the fingerprint.'; end if;
  raise notice 'OK (item 4): different operation -> different fingerprint.';

  v_fp := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('patch','{"notes":"different"}'::jsonb));
  if v_fp = v_fp_base then raise exception 'TEST FAIL (item 5): a different patch must change the fingerprint.'; end if;
  raise notice 'OK (item 5): different patch -> different fingerprint.';

  v_fp := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('reason','a different reason'));
  if v_fp = v_fp_base then raise exception 'TEST FAIL (item 6): a different reason must change the fingerprint.'; end if;
  raise notice 'OK (item 6): different reason -> different fingerprint.';

  v_fp := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('expected_updated_at','2026-01-01T00:00:00.000001Z'));
  if v_fp = v_fp_base then raise exception 'TEST FAIL (item 7): a different expected_updated_at (even by 1 microsecond) must change the fingerprint.'; end if;
  raise notice 'OK (item 7): different expected_updated_at -> different fingerprint.';
end
$t$;

\echo '----- O8 (item 8). nested JSON key ordering, at every level, does not affect the fingerprint -----'
do $t$
declare fp1 text; fp2 text;
begin
  fp1 := public.compute_financial_request_fingerprint(jsonb_build_object('operation','op_x','schema_version',1,'organization_id','11111111-1111-1111-1111-111111111111'::uuid,'invoice_id','aaaaaaaa-0000-0000-0000-000000000001'::uuid,'patch',jsonb_build_object('b',1,'a',jsonb_build_object('y',2,'z',1)),'reason','r','expected_updated_at','2026-01-01T00:00:00.000000Z'));
  fp2 := public.compute_financial_request_fingerprint(jsonb_build_object('expected_updated_at','2026-01-01T00:00:00.000000Z','reason','r','patch',jsonb_build_object('a',jsonb_build_object('z',1,'y',2),'b',1),'invoice_id','aaaaaaaa-0000-0000-0000-000000000001'::uuid,'organization_id','11111111-1111-1111-1111-111111111111'::uuid,'schema_version',1,'operation','op_x'));
  if fp1 <> fp2 then raise exception 'TEST FAIL (item 8): reordering keys at the outer AND inner level must not change the fingerprint, got % vs %.', fp1, fp2; end if;
  raise notice 'OK (item 8): outer- and inner-level JSON key reordering never affects the fingerprint (%).', fp1;
end
$t$;

\echo '----- O9 (item 9). delimiter/boundary ambiguity is structurally impossible -- content that would be dangerous under a naive concatenation scheme stays inert inside its own typed JSON field -----'
do $t$
declare v_base jsonb := jsonb_build_object('operation','op_x','schema_version',1,'organization_id','11111111-1111-1111-1111-111111111111'::uuid,'invoice_id','aaaaaaaa-0000-0000-0000-000000000001'::uuid,'expected_updated_at','2026-01-01T00:00:00.000000Z');
declare fp1 text; fp2 text;
begin
  -- Case 1: reason contains a literal '|' and JSON-structural characters
  -- (quotes/braces/colons) that would be dangerous in a bare
  -- concatenation scheme; patch is a small, unrelated object.
  fp1 := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('reason', 'a|b","x":"1', 'patch', jsonb_build_object('notes', 'c')));
  -- Case 2: a DIFFERENT logical assignment that a naive delimiter-based
  -- scheme could conceivably confuse with case 1 if the boundary between
  -- fields were ever ambiguous -- reason and patch content swapped/split
  -- differently. jsonb_build_object() (never hand-written JSON text)
  -- guarantees this string value is escaped correctly regardless of its
  -- raw content.
  fp2 := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('reason', 'a', 'patch', jsonb_build_object('notes', 'b"},"x":"1|c')));
  if fp1 = fp2 then
    raise exception 'TEST FAIL (item 9): two structurally different reason/patch assignments must never fingerprint identically.';
  end if;
  raise notice 'OK (item 9): reason/patch content containing raw delimiter-like and JSON-structural characters is hashed as an inert value inside its own typed jsonb field -- never reinterpreted as a field boundary, never a source of ambiguity (%  vs  %).', fp1, fp2;
end
$t$;

\echo '----- O10 (item 10). null differs from missing where semantics differ -- {"notes":null} in the patch is NOT the same fingerprint as an empty patch -----'
do $t$
declare v_base jsonb := jsonb_build_object('operation','op_x','schema_version',1,'organization_id','11111111-1111-1111-1111-111111111111'::uuid,'invoice_id','aaaaaaaa-0000-0000-0000-000000000001'::uuid,'reason','r','expected_updated_at','2026-01-01T00:00:00.000000Z');
declare fp_null text; fp_missing text;
begin
  fp_null := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('patch', '{"notes":null}'::jsonb));
  fp_missing := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('patch', '{}'::jsonb));
  if fp_null = fp_missing then
    raise exception 'TEST FAIL (item 10): an explicit JSON null (present key) must fingerprint differently from a key that is simply absent.';
  end if;
  raise notice 'OK (item 10): a patch with an explicit null value fingerprints differently from an empty patch -- null-present and key-missing are never conflated.';
end
$t$;

\echo '----- O11 (item 11). empty string behavior is documented and consistent: p_reason = NULL and p_reason = '''' (or whitespace-only) are DEFINED as equivalent for fingerprint purposes -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare
  v_id uuid := current_setting('test.civ_o1')::uuid;
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id=v_id);
  v_r1 jsonb; v_r2 jsonb;
begin
  v_r1 := public.update_carrier_invoice_draft(v_id, '{"notes":"reason equivalence test"}'::jsonb, v_expected, null, 'o11-key');
  if not (v_r1->>'success')::boolean then raise exception 'TEST FAIL (item 11): first call (reason=NULL) should succeed, got %.', v_r1; end if;
  -- SAME key, SAME patch, SAME expected version, but reason is now an
  -- empty/whitespace string instead of NULL -- must be treated as the
  -- SAME logical request (a cache hit), never as a different one.
  v_r2 := public.update_carrier_invoice_draft(v_id, '{"notes":"reason equivalence test"}'::jsonb, v_expected, '   ', 'o11-key');
  if v_r2->>'code' = 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 11): reason=NULL and reason=whitespace-only must be equivalent for fingerprint purposes, got IDEMPOTENCY_KEY_REUSED.';
  end if;
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (item 11): expected the byte-identical cached result, got % vs %.', v_r1, v_r2; end if;
  raise notice 'OK (item 11): p_reason = NULL and p_reason = whitespace-only normalize to the SAME canonical fingerprint value (both collapse to JSON null) -- documented, consistent empty-string semantics -- %.', v_r1;
end
$t$;

\echo '----- O12 (item 12). SHA-256 output is always exactly 64 lowercase hex characters -----'
-- compute_financial_request_fingerprint() is called DIRECTLY here (not
-- through the RPC) -- must run as the owning/superuser role (Section B
-- revokes EXECUTE from authenticated -- proven directly by Q1 below).
reset role;
do $t$
declare v_fp text;
begin
  v_fp := public.compute_financial_request_fingerprint(jsonb_build_object('a', 1));
  if v_fp !~ '^[0-9a-f]{64}$' then raise exception 'TEST FAIL (item 12): expected 64 lowercase hex chars, got % (length %).', v_fp, length(v_fp); end if;
  v_fp := public.compute_financial_request_fingerprint('{}'::jsonb);
  if v_fp !~ '^[0-9a-f]{64}$' then raise exception 'TEST FAIL (item 12): expected 64 lowercase hex chars for an empty object, got %.', v_fp; end if;
  raise notice 'OK (item 12): compute_financial_request_fingerprint always produces 64 lowercase hex characters.';
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- O13/O14 (items 13/14). same-key exact replay -> cached success; same-key/different-request -> the EXACT structured collision object -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_o1')::uuid;
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id=v_id);
  v_r1 jsonb; v_r2 jsonb; v_r3 jsonb;
  v_expected_collision jsonb := jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
begin
  v_r1 := public.update_carrier_invoice_draft(v_id, '{"notes":"o13 note"}'::jsonb, v_expected, null, 'o13-key');
  if not (v_r1->>'success')::boolean then raise exception 'TEST FAIL (item 13): first call should succeed, got %.', v_r1; end if;
  v_r2 := public.update_carrier_invoice_draft(v_id, '{"notes":"o13 note"}'::jsonb, v_expected, null, 'o13-key');
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (item 13): exact replay should return the byte-identical cached result, got % vs %.', v_r1, v_r2; end if;
  raise notice 'OK (item 13): same-key exact replay returns the cached success result unchanged -- %.', v_r2;

  v_r3 := public.update_carrier_invoice_draft(v_id, '{"notes":"o14 a DIFFERENT note"}'::jsonb, v_expected, null, 'o13-key');
  if v_r3 <> v_expected_collision then
    raise exception 'TEST FAIL (item 14): a same-key/different-request collision must return EXACTLY %, got %.', v_expected_collision, v_r3;
  end if;
  raise notice 'OK (item 14): same-key/different-request returns the exact required structured collision object -- %.', v_r3;
end
$t$;

\echo '----- O15 (item 15). the SAME idempotency key string used by TWO DIFFERENT organizations remains fully independent -----'
do $t$
declare v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(current_setting('test.civ_o2')::uuid, '{"notes":"org a using o15-key"}'::jsonb, (select updated_at from public.carrier_invoices where id=current_setting('test.civ_o2')::uuid), null, 'o15-key');
  if not (v_result->>'success')::boolean then raise exception 'TEST FAIL (item 15): Org A''s own use of o15-key should succeed, got %.', v_result; end if;
end
$t$;
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
do $t$
declare v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(current_setting('test.civ_ob')::uuid, '{"notes":"org b using the SAME key string o15-key"}'::jsonb, (select updated_at from public.carrier_invoices where id=current_setting('test.civ_ob')::uuid), null, 'o15-key');
  if not (v_result->>'success')::boolean then
    raise exception 'TEST FAIL (item 15): Org B reusing the identical key string as Org A must succeed independently, got %.', v_result;
  end if;
  if (select notes from public.carrier_invoices where id = current_setting('test.civ_ob')::uuid) <> 'org b using the SAME key string o15-key' then
    raise exception 'TEST FAIL (item 15): Org B''s own mutation should have applied.';
  end if;
  raise notice 'OK (item 15): the same idempotency key string used by two different organizations is fully independent -- %.', v_result;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);

\echo '----- O16 (item 16). the SAME (organization, idempotency_key) used by TWO DIFFERENT operations remains fully independent (structural: the widened constraint permits both rows to coexist) -----'
reset role;
do $t$
declare v_count integer;
begin
  insert into public.carrier_invoice_lifecycle_idempotency (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state)
  values
    ('11111111-1111-1111-1111-111111111111', 'o16-shared-key', current_setting('test.civ_o1')::uuid, 'update_carrier_invoice_draft', encode(digest('op-a','sha256'),'hex'), 1, '{"success":true,"synthetic":"a"}'::jsonb, 'completed'),
    ('11111111-1111-1111-1111-111111111111', 'o16-shared-key', current_setting('test.civ_o1')::uuid, 'some_future_financial_operation', encode(digest('op-b','sha256'),'hex'), 1, '{"success":true,"synthetic":"b"}'::jsonb, 'completed');
  select count(*) into v_count from public.carrier_invoice_lifecycle_idempotency where idempotency_key = 'o16-shared-key';
  if v_count <> 2 then raise exception 'TEST FAIL (item 16): both rows should coexist under the widened (organization_id, operation, idempotency_key) constraint, found %.', v_count; end if;
  if (select result from public.carrier_invoice_lifecycle_idempotency where idempotency_key='o16-shared-key' and operation='update_carrier_invoice_draft') = (select result from public.carrier_invoice_lifecycle_idempotency where idempotency_key='o16-shared-key' and operation='some_future_financial_operation') then
    raise exception 'TEST FAIL (item 16): the two operations'' rows should carry their own distinct results.';
  end if;
  raise notice 'OK (item 16): the same (organization, idempotency_key) pair used by two DIFFERENT operations coexists cleanly -- a key reused for a different operation is structurally a different row, never a collision, never a cross-operation cache hit.';
  delete from public.carrier_invoice_lifecycle_idempotency where idempotency_key = 'o16-shared-key';
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- O17 (item 17, structural proxy). the collision handler remains narrowly scoped to civ_idempotency_unique and re-raises anything else -- see TEST_CONCURRENCY_0143 for the genuine two-session proof that a raw error never reaches the client -----'
reset role;
do $t$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace;
  if v_src not ilike '%when unique_violation then%' then
    raise exception 'TEST FAIL (item 17): expected a narrow unique_violation handler, not a broad ''when others''.';
  end if;
  if v_src ilike '%when others then%' and v_src not ilike '%if v_constraint <> ''civ_idempotency_unique'' then%raise%' then
    raise exception 'TEST FAIL (item 17): the handler must check the constraint name and re-raise anything that is not civ_idempotency_unique.';
  end if;
  if v_src not ilike '%get stacked diagnostics v_constraint = constraint_name%' then
    raise exception 'TEST FAIL (item 17): expected the handler to inspect the actual constraint name via GET STACKED DIAGNOSTICS.';
  end if;
  raise notice 'OK (item 17, structural proxy): the 0143 collision handler is still narrowly scoped to unique_violation on SPECIFICALLY civ_idempotency_unique and re-raises everything else unchanged -- carried forward unmodified from 0142/Phase 3B.3A.3.';
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- O18/O20 (items 18/20). the losing request in a same-key/different-invoice collision produces no mutation, no audit event, and no leaked internals -----'
do $t$
declare
  v_id2 uuid := current_setting('test.civ_o2')::uuid;
  v_notes_before text := (select notes from public.carrier_invoices where id=v_id2);
  v_audit_before integer; v_audit_after integer;
  v_result jsonb;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_type='invoice' and entity_id=v_id2 and action='carrier_invoice_draft_updated';
  v_result := public.update_carrier_invoice_draft(v_id2, '{"notes":"trying to reuse o13''s key on a different invoice"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id2), null, 'o13-key');
  if v_result->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 18): same key + different invoice should return IDEMPOTENCY_KEY_REUSED, got %.', v_result;
  end if;
  if v_result ? 'constraint' or v_result ? 'detail' or v_result ? 'hint' or v_result::text ilike '%civ_idempotency_unique%' or v_result::text ilike '%duplicate key%' or v_result::text ilike '%sqlstate%' then
    raise exception 'TEST FAIL (item 20): the client response leaked raw constraint/SQL/internal detail -- %.', v_result;
  end if;
  if (select notes from public.carrier_invoices where id=v_id2) is distinct from v_notes_before then
    raise exception 'TEST FAIL (item 18): a collision must never mutate the losing request''s invoice.';
  end if;
  select count(*) into v_audit_after from public.activity_logs where entity_type='invoice' and entity_id=v_id2 and action='carrier_invoice_draft_updated';
  if v_audit_after <> v_audit_before then
    raise exception 'TEST FAIL (item 18): a collision must never write an audit event for the losing request.';
  end if;
  raise notice 'OK (items 18, 20): the losing request produced zero mutation, zero audit event, and zero leaked internals -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- Q. Phase 3B.3B.1: fingerprint-helper privilege lockdown (Section B) and
-- fingerprinting the NORMALIZED mutation, not the raw request (Section C).
-- ---------------------------------------------------------------------------
\echo '----- Q1 (D.1). direct authenticated execution of the fingerprint helper is rejected -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public.compute_financial_request_fingerprint('{"a":1}'::jsonb);
    raise exception 'TEST FAIL (item 1): authenticated should NOT be able to call compute_financial_request_fingerprint() directly.';
  exception when insufficient_privilege then
    raise notice 'OK (item 1): direct authenticated execution of compute_financial_request_fingerprint() is rejected -- %', sqlerrm;
  end;
end
$t$;
reset role;
set role anon;
do $t$
begin
  begin
    perform public.compute_financial_request_fingerprint('{"a":1}'::jsonb);
    raise exception 'TEST FAIL (item 1): anon should NOT be able to call compute_financial_request_fingerprint() directly.';
  exception when insufficient_privilege then
    raise notice 'OK (item 1): direct anon execution of compute_financial_request_fingerprint() is also rejected -- %', sqlerrm;
  end;
end
$t$;
reset role;

\echo '----- Q2 (D.2). the secured draft RPC still works end-to-end despite the fingerprint helper''s own EXECUTE revoke -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_o1')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"q2 still works"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'q2-still-works');
  if not (v_result->>'success')::boolean then
    raise exception 'TEST FAIL (item 2): the secured RPC should still succeed despite compute_financial_request_fingerprint()''s own privilege lockdown, got %.', v_result;
  end if;
  raise notice 'OK (item 2): update_carrier_invoice_draft() still reaches compute_financial_request_fingerprint() internally (ownership + SECURITY DEFINER carry the call through) -- %.', v_result;
end
$t$;

\echo '----- Q3 (D.4). currency is NOT silently normalized -- a non-canonical (lowercase) value is rejected outright, never upper-cased and never treated as equivalent to its canonical form -----'
do $t$
declare v_id uuid := current_setting('test.civ_o1')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"currency":"eur"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'currency case test', 'q3-lowercase-currency');
  if v_result->>'code' <> 'INVALID_INPUT' then
    raise exception 'TEST FAIL (item 4): a lowercase currency value should be rejected outright (never silently normalized), got %.', v_result;
  end if;
  raise notice 'OK (item 4): a non-canonical-case currency value is rejected as INVALID_INPUT, never silently upper-cased -- the documented policy is validate-only, not normalize -- %.', v_result;
end
$t$;

\echo '----- Q4 (D.5). due_date empty-string and explicit null are DEFINED as the same stored value (both -> NULL) and now fingerprint identically -- a same-key replay with one, then the other, is a cache hit, not a collision -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_o2')::uuid;
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id=v_id);
  v_r1 jsonb; v_r2 jsonb;
begin
  v_r1 := public.update_carrier_invoice_draft(v_id, '{"due_date":""}'::jsonb, v_expected, null, 'q4-due-date-empty-null');
  if not (v_r1->>'success')::boolean then raise exception 'TEST FAIL (item 5): first call (due_date="") should succeed, got %.', v_r1; end if;
  v_r2 := public.update_carrier_invoice_draft(v_id, '{"due_date":null}'::jsonb, v_expected, null, 'q4-due-date-empty-null');
  if v_r2->>'code' = 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 5): due_date="" and due_date=null both normalize to NULL and must fingerprint identically, got IDEMPOTENCY_KEY_REUSED.';
  end if;
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (item 5): expected the byte-identical cached result, got % vs %.', v_r1, v_r2; end if;
  raise notice 'OK (item 5): due_date="" and due_date=null normalize to the identical stored value (NULL) and fingerprint identically -- a same-key replay is a cache hit -- %.', v_r1;
end
$t$;

\echo '----- Q5 (D.6). notes is stored byte-for-byte, including whitespace -- proven (not assumed) by two otherwise-identical requests differing ONLY in notes whitespace fingerprinting DIFFERENTLY -----'
-- compute_financial_request_fingerprint() is called DIRECTLY here (not
-- through the RPC) -- must run as the owning/superuser role, since
-- Section B revokes EXECUTE from authenticated (proven by Q1 above).
reset role;
do $t$
declare fp1 text; fp2 text;
declare v_base jsonb := jsonb_build_object('operation','update_carrier_invoice_draft','schema_version',1,'organization_id','11111111-1111-1111-1111-111111111111'::uuid,'invoice_id','aaaaaaaa-0000-0000-0000-000000000001'::uuid,'reason','r','expected_updated_at','2026-01-01T00:00:00.000000Z');
begin
  fp1 := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('patch', jsonb_build_object('notes', 'hello')));
  fp2 := public.compute_financial_request_fingerprint(v_base || jsonb_build_object('patch', jsonb_build_object('notes', '  hello  ')));
  if fp1 = fp2 then
    raise exception 'TEST FAIL (item 6): notes is never trimmed -- "hello" and "  hello  " are DIFFERENT stored values and must fingerprint differently.';
  end if;
  raise notice 'OK (item 6): notes whitespace is preserved byte-for-byte in both the fingerprint and the stored mutation -- "hello" and "  hello  " fingerprint differently, proving no hidden trim step exists anywhere between fingerprinting and storage.';
end
$t$;

-- fixture for Q6: an active carrier_brokers relationship (A1 <-> Broker
-- A) so the recipient-eligibility re-check the RPC always performs on a
-- recipient-touching patch actually passes.
do $t$
begin
  if not exists (select 1 from public.carrier_brokers where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and broker_id='a0b00000-0000-0000-0000-000000000001') then
    insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
    values ('cb430000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');
  end if;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- Q6 (D.10, recipient UUID normalization). the SAME broker uuid submitted in a different letter case normalizes to the identical stored value and now fingerprints identically -- a same-key replay is a cache hit -----'
do $t$
declare
  v_id uuid;
  v_expected timestamptz;
  v_r1 jsonb; v_r2 jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_expected := (select updated_at from public.carrier_invoices where id=v_id);

  v_r1 := public.update_carrier_invoice_draft(v_id, '{"broker_id":"a0b00000-0000-0000-0000-000000000001","customer_id":null}'::jsonb, v_expected, 'uuid case test', 'q6-uuid-case');
  if not (v_r1->>'success')::boolean then raise exception 'TEST FAIL (item 10): first call (lowercase uuid) should succeed, got %.', v_r1; end if;
  -- SAME uuid VALUE, submitted in upper case -- must normalize to the
  -- identical stored value and therefore fingerprint identically.
  v_r2 := public.update_carrier_invoice_draft(v_id, '{"broker_id":"A0B00000-0000-0000-0000-000000000001","customer_id":null}'::jsonb, v_expected, 'uuid case test', 'q6-uuid-case');
  if v_r2->>'code' = 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 10): the same uuid value in a different letter case must fingerprint identically (uuid canonicalization), got IDEMPOTENCY_KEY_REUSED.';
  end if;
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (item 10): expected the byte-identical cached result regardless of uuid casing, got % vs %.', v_r1, v_r2; end if;
  raise notice 'OK (item 10): the same broker uuid submitted in a different letter case normalizes to Postgres''s own canonical lowercase uuid text and fingerprints identically -- a same-key replay is a cache hit, not a collision -- %.', v_r1;
end
$t$;

\echo '----- Q7 (D.8). an unknown patch key is rejected BEFORE the invoice is even looked up -- proven against a NONEXISTENT invoice id, which would otherwise return NOT_FOUND -----'
do $t$
declare v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft('00000000-0000-0000-0000-000000000000'::uuid, '{"totally_unrecognized_key":"x"}'::jsonb, now(), null, 'q7-unknown-key-nonexistent-invoice');
  if v_result->>'code' <> 'INVALID_INPUT' then
    raise exception 'TEST FAIL (item 8): an unknown patch key must be rejected BEFORE the invoice lookup (expected INVALID_INPUT even for a nonexistent invoice id), got %.', v_result;
  end if;
  raise notice 'OK (item 8): an unknown patch key is rejected before fingerprinting, locking, or looking up the invoice at all -- a nonexistent invoice id still yields INVALID_INPUT, not NOT_FOUND -- %.', v_result;
end
$t$;

\echo '----- Q8 (D.9). the fingerprint / canonical payload is never returned to the browser, in either a success or a collision response -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_o1')::uuid;
  v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"q8 no leak"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'q8-no-leak-key');
  if v_result ? 'request_fingerprint' or v_result ? 'fingerprint' or v_result ? 'canonical_payload' or v_result ? 'schema_version' or v_result::text ilike '%sha256%' then
    raise exception 'TEST FAIL (item 9): a success response must never include a fingerprint or canonical payload, got %.', v_result;
  end if;
  -- and again on the collision path
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"a different note"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'q8-no-leak-key');
  if v_result ? 'request_fingerprint' or v_result ? 'fingerprint' or v_result ? 'canonical_payload' or v_result::text ilike '%sha256%' then
    raise exception 'TEST FAIL (item 9): a collision response must never include a fingerprint or canonical payload either, got %.', v_result;
  end if;
  raise notice 'OK (item 9): neither a success nor a collision response ever includes a request_fingerprint, fingerprint, canonical_payload, or schema_version field -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '################  TEST 0143 PASSED  ################'
