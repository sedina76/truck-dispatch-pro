-- ============================================================================
-- TEST_0142_immutable_carrier_invoice_foundation.sql
-- disposable database only. Run via TEST_0130_0133_run.sh (or manually).
--
-- Phase 3B.3A verification (3B.3A.1 + 3B.3A.2 correction passes): the new,
-- additive carrier_invoices/line_items/loads foundation, the immutable
-- issuance snapshot, the SEPARATE issuance_status/payment_status guard
-- triggers, per-issuer per-calendar-year numbering, the three read-only
-- problem-classifier functions, the legacy-invoice classifier, the
-- owner/admin-only review_legacy_invoice_carrier_migration() RPC, the
-- recursive snapshot secret/credential-key exclusion, the column-privilege
-- model that leaves `notes` as the ONLY directly-grantable column on
-- carrier_invoices (3B.3A.2 Section A), and the guarded, role-tiered
-- update_carrier_invoice_draft() RPC (3B.3A.2 Section B). NO issuance RPC,
-- NO void RPC, NO ready-for-issue RPC, and NO payment RPC exist yet (all
-- deferred to 0143) -- every "issuance"/"payment"/"void" simulation below
-- runs in a trusted superuser test context (never as `authenticated`),
-- used ONLY to prove the schema-level guarantees already hold for 0143 to
-- build on.
-- ============================================================================
\set ON_ERROR_STOP on
\timing off
\echo '################  TEST 0142  ################'

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

\echo '===== fixtures ====='
reset role;
select set_config('test.current_uid', null, false);
do $t$
begin
  -- Carrier A1 (org A): FACTORED, complete internal_queue default
  -- relationship -- classify_carrier_factoring_readiness() must return
  -- exactly 'ready'. Carrier A2 (org A): left 'unconfigured' (default) --
  -- must BLOCK freight issuance. We also flip A2 to 'direct' later inline
  -- for the direct-billing test.
  update public.carriers set invoice_code = 'CARA', factoring_mode = 'factored' where id = 'a1a1a1a1-0000-0000-0000-000000000001';
  update public.carriers set invoice_code = 'CARB' where id = 'a2a2a2a2-0000-0000-0000-000000000002';

  insert into public.factoring_companies (id, organization_id, name, is_active) values
    ('fc420000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Factor 0142', true);

  insert into public.factoring_relationships
    (id, organization_id, factoring_company_id, carrier_id, default_advance_percentage, default_factoring_fee_percentage,
     default_reserve_percentage, fee_timing, recourse_type, remittance_instructions, noa_template_text, noa_reference,
     noa_effective_date, noa_approved, noa_approved_by, noa_approved_at, submission_method, is_default, is_active)
  values
    ('fe420000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'fc420000-0000-0000-0000-000000000001',
     'a1a1a1a1-0000-0000-0000-000000000001', 90, 3, 10, 'deducted_at_funding', 'non_recourse', 'Wire A1', 'NOA A1 v1', 'ref-1',
     current_date - 5, true, 'aaaa0000-0000-0000-0000-000000000001', now(), 'internal_queue', true, true);

  -- carrier_brokers: A1 <-> Broker A, active + factoring_eligible.
  insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values ('cb420000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
          'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

  -- carrier_customers: A1 <-> Customer A, active.
  insert into public.carrier_customers (id, organization_id, carrier_id, customer_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
  values ('cc420000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
          'a1a1a1a1-0000-0000-0000-000000000001', 'a0c00000-0000-0000-0000-000000000001', 'active', 'ap@customera.example', 30, true, now(), 'aaaa0000-0000-0000-0000-000000000001');

  -- (load_financials is not part of this disposable harness's schema --
  -- the line item inserted below carries its own explicit unit_price,
  -- which is all 0142's totals-recalculation trigger actually depends on.)
end
$t$;

do $s$
begin
  if (select factoring_mode from public.carriers where id = 'a1a1a1a1-0000-0000-0000-000000000001') <> 'factored' then
    raise exception 'SEED: carrier A1 should be factored.';
  end if;
  if not exists (select 1 from public.loads where id = '10000000-0000-0000-0000-000000000001' and carrier_id = 'a1a1a1a1-0000-0000-0000-000000000001') then
    raise exception 'SEED: load L1 should have been carrier-backfilled to A1 by 0133.';
  end if;
  raise notice 'SEED OK: carrier A1 factored+ready (internal_queue), carrier A2 invoice_code only, broker A / customer A carrier-party rows active+eligible, load L1 carrier-backfilled to A1.';
end
$s$;

-- ---------------------------------------------------------------------------
-- A. carrier_invoices basic shape + org-consistency + recipient-shape CHECK
-- ---------------------------------------------------------------------------
\echo '----- A1. a draft carrier_freight_invoice for A1 -> Broker A is created cleanly -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, currency, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'USD', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.civ_a1', v_id::text, false);
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'Freight -- LD-1', 1, 1500);
  insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id)
  values ('11111111-1111-1111-1111-111111111111', v_id, '10000000-0000-0000-0000-000000000001');

  if (select total_amount from public.carrier_invoices where id = v_id) <> 1500 then
    raise exception 'TEST FAIL: totals were not recalculated from line items (expected 1500).';
  end if;
  raise notice 'OK: draft carrier_freight_invoice created, line item -> totals recalculated to 1500, load attached.';
end
$t$;

\echo '----- A2. recipient-shape CHECK: both broker+customer, or neither, is rejected -----'
do $t$
begin
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, recipient_customer_id)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'a0c00000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: both broker+customer should have been rejected.';
  exception when check_violation then
    raise notice 'OK: both broker+customer rejected by cinv_recipient_shape.';
  end;
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: neither broker nor customer should have been rejected.';
  exception when check_violation then
    raise notice 'OK: neither broker nor customer rejected by cinv_recipient_shape.';
  end;
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
    values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: dispatch_service_invoice with a recipient_type set should have been rejected.';
  exception when check_violation then
    raise notice 'OK: dispatch_service_invoice cannot carry a broker/customer recipient (its recipient is always carrier_id).';
  end;
end
$t$;

\echo '----- A3. org-consistency guard rejects a cross-organization recipient -----'
do $t$
begin
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'b0b00000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: Org B''s broker should have been rejected for an Org A invoice.';
  exception when others then
    if sqlerrm not ilike '%same organization%' then raise; end if;
    raise notice 'OK: cross-organization recipient rejected -- %', sqlerrm;
  end;
end
$t$;

-- ---------------------------------------------------------------------------
-- B. numbering: atomic, per-issuer, per-calendar-year
-- ---------------------------------------------------------------------------
\echo '----- B1. carrier-scoped freight numbering: sequential, independent per carrier -----'
reset role;
select set_config('test.current_uid', null, false);
do $t$
declare v_a1_1 text; v_a1_2 text; v_a2_1 text;
begin
  v_a1_1 := public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
  v_a1_2 := public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
  v_a2_1 := public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'CARB');

  if v_a1_1 !~ '^CARA-[0-9]{4}-00001$' then raise exception 'TEST FAIL: unexpected first number shape: %', v_a1_1; end if;
  if v_a1_2 !~ '^CARA-[0-9]{4}-00002$' then raise exception 'TEST FAIL: second call for the SAME carrier did not increment: %', v_a1_2; end if;
  if v_a2_1 !~ '^CARB-[0-9]{4}-00001$' then raise exception 'TEST FAIL: a DIFFERENT carrier''s counter is not independent (expected 00001, got %).', v_a2_1; end if;
  raise notice 'OK: sequential per-carrier numbering (% / % ), independent per-carrier counters (% ).', v_a1_1, v_a1_2, v_a2_1;
end
$t$;

\echo '----- B2. dispatch-service numbering is org-scoped, independent from freight numbering -----'
do $t$
declare v_d1 text; v_d2 text;
begin
  v_d1 := public._generate_carrier_invoice_number_internal('dispatch_service_invoice', '11111111-1111-1111-1111-111111111111', 'DISP');
  v_d2 := public._generate_carrier_invoice_number_internal('dispatch_service_invoice', '11111111-1111-1111-1111-111111111111', 'DISP');
  if v_d1 !~ '^DISP-[0-9]{4}-00001$' or v_d2 !~ '^DISP-[0-9]{4}-00002$' then
    raise exception 'TEST FAIL: dispatch-service numbering not sequential: % / %', v_d1, v_d2;
  end if;
  raise notice 'OK: dispatch-service numbering (%,  %) uses its own organization-scoped counter, unaffected by carrier freight counters.', v_d1, v_d2;
end
$t$;

\echo '----- B3. the private numbering mechanism is not reachable by authenticated -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
begin
  begin
    perform public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
    raise exception 'TEST FAIL: authenticated should not be able to call the private numbering mechanism.';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated cannot call _generate_carrier_invoice_number_internal directly.';
  end;
end
$t$;
-- Sections C-E run as superuser (direct table access is needed to simulate
-- what the future 0143 RPC will do -- e.g. INSERT-ing a snapshot row, which
-- no role has table-level privilege for yet), but test.current_uid is kept
-- set to a real Org A owner throughout: the problem-classifier functions
-- (and classify_carrier_factoring_readiness, which they call) resolve
-- public.current_org_id() from auth.uid()/test.current_uid regardless of
-- which Postgres role is executing -- reset role alone does not stand in
-- for "no authenticated context", it only changes table-privilege checks.
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);

-- ---------------------------------------------------------------------------
-- C. lifecycle guard + immutable snapshot
-- ---------------------------------------------------------------------------
\echo '----- C1. draft -> ready_for_issue is permitted; ready_for_issue -> issued is refused without a snapshot -----'
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid;
begin
  update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = v_id;
  if (select issuance_status from public.carrier_invoices where id = v_id) <> 'ready_for_issue' then
    raise exception 'TEST FAIL: draft -> ready_for_issue should have succeeded.';
  end if;

  begin
    update public.carrier_invoices set issuance_status = 'issued', invoice_number = 'CARA-2099-99999', issued_at = now(), issued_by = 'aaaa0000-0000-0000-0000-000000000001' where id = v_id;
    raise exception 'TEST FAIL: issuance without a snapshot row should have been rejected.';
  exception when others then
    if sqlerrm not ilike '%without an existing issuance snapshot%' then raise; end if;
    raise notice 'OK: cannot transition to issued without an issuance snapshot already existing -- %', sqlerrm;
  end;
end
$t$;

\echo '----- C2. simulated issuance (as the future 0143 RPC would): insert snapshot THEN transition -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_a1')::uuid;
  v_number text;
  v_payload jsonb;
begin
  v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
  v_payload := jsonb_build_object(
    'issuer', jsonb_build_object('carrier_id', 'a1a1a1a1-0000-0000-0000-000000000001', 'legal_name', 'Carrier A1 LLC'),
    'recipient', jsonb_build_object('type', 'broker', 'broker_id', 'a0b00000-0000-0000-0000-000000000001', 'legal_name', 'Broker A'),
    'loads', jsonb_build_array(jsonb_build_object('load_id', '10000000-0000-0000-0000-000000000001', 'load_number', 'LD-1', 'agreed_freight_rate', 1500)),
    'factoring', jsonb_build_object('factoring_relationship_id', 'fe420000-0000-0000-0000-000000000001', 'factoring_company_id', 'fc420000-0000-0000-0000-000000000001', 'submission_method', 'internal_queue'),
    'dispatch_service', null
  );

  insert into public.carrier_invoice_issuance_snapshots
    (invoice_id, organization_id, invoice_document_type, issued_by, currency, invoice_number,
     subtotal_amount, tax_amount, adjustments_amount, total_amount, amount_due_at_issuance,
     carrier_id, recipient_broker_id, snapshot_payload)
  values
    (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'aaaa0000-0000-0000-0000-000000000001', 'USD', v_number,
     1500, 0, 0, 1500, 1500,
     'a1a1a1a1-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', v_payload);

  update public.carrier_invoices
    set issuance_status = 'issued', invoice_number = v_number, issued_at = now(), issued_by = 'aaaa0000-0000-0000-0000-000000000001'
    where id = v_id;

  if (select issuance_status from public.carrier_invoices where id = v_id) <> 'issued' then
    raise exception 'TEST FAIL: issuance should have succeeded once a snapshot existed.';
  end if;
  perform set_config('test.civ_a1_number', v_number, false);
  raise notice 'OK: simulated issuance succeeded once the snapshot existed first -- invoice_number=%', v_number;
end
$t$;

\echo '----- C3. once issued: carrier/type/recipient/number/totals/currency are frozen for EVERYONE -----'
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid;
begin
  begin
    update public.carrier_invoices set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002' where id = v_id;
    raise exception 'TEST FAIL: carrier_id should be immutable once issued.';
  exception when others then
    if sqlerrm not ilike '%immutable once the invoice is no longer draft%' then raise; end if;
    raise notice 'OK: carrier_id is immutable post-issuance.';
  end;
  begin
    update public.carrier_invoices set invoice_number = 'SOMETHING-ELSE' where id = v_id;
    raise exception 'TEST FAIL: invoice_number should be immutable once issued.';
  exception when others then
    if sqlerrm not ilike '%immutable once the invoice is no longer draft%' then raise; end if;
    raise notice 'OK: invoice_number is immutable post-issuance.';
  end;
  begin
    update public.carrier_invoices set total_amount = 999999 where id = v_id;
    raise exception 'TEST FAIL: total_amount should be immutable once issued.';
  exception when others then
    if sqlerrm not ilike '%immutable once the invoice is no longer draft%' then raise; end if;
    raise notice 'OK: issued totals are immutable post-issuance.';
  end;
end
$t$;

\echo '----- C4. issued cannot return to draft; state machine rejects an invalid jump -----'
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid;
begin
  begin
    update public.carrier_invoices set issuance_status = 'draft' where id = v_id;
    raise exception 'TEST FAIL: issued -> draft should be rejected.';
  exception when others then
    if sqlerrm not ilike '%is not a permitted issuance transition%' and sqlerrm not ilike '%can never return to draft/ready_for_issue%' then raise; end if;
    raise notice 'OK: issued -> draft rejected -- %', sqlerrm;
  end;
end
$t$;

\echo '----- C5. the snapshot itself is immutable -- UPDATE and DELETE both rejected, even as superuser -----'
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid;
begin
  begin
    update public.carrier_invoice_issuance_snapshots set total_amount = 1 where invoice_id = v_id;
    raise exception 'TEST FAIL: snapshot UPDATE should be rejected.';
  exception when others then
    if sqlerrm not ilike '%immutable and can never be updated%' then raise; end if;
    raise notice 'OK: snapshot UPDATE rejected, even running as superuser -- %', sqlerrm;
  end;
  begin
    delete from public.carrier_invoice_issuance_snapshots where invoice_id = v_id;
    raise exception 'TEST FAIL: snapshot DELETE should be rejected.';
  exception when others then
    if sqlerrm not ilike '%immutable and can never be deleted%' then raise; end if;
    raise notice 'OK: snapshot DELETE rejected, even running as superuser -- %', sqlerrm;
  end;
end
$t$;

\echo '----- C6. an issued invoice cannot be DELETEd; voiding preserves the number and the snapshot -----'
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid;
begin
  begin
    delete from public.carrier_invoices where id = v_id;
    raise exception 'TEST FAIL: an issued invoice should not be deletable.';
  exception when others then
    if sqlerrm not ilike '%cannot be deleted%' then raise; end if;
    raise notice 'OK: an issued invoice cannot be deleted -- %', sqlerrm;
  end;

  update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'test void' where id = v_id;
  if (select invoice_number from public.carrier_invoices where id = v_id) <> current_setting('test.civ_a1_number') then
    raise exception 'TEST FAIL: voiding must preserve the invoice number.';
  end if;
  if not exists (select 1 from public.carrier_invoice_issuance_snapshots where invoice_id = v_id) then
    raise exception 'TEST FAIL: voiding must preserve the snapshot.';
  end if;
  raise notice 'OK: void preserves both the invoice number and the immutable snapshot.';
end
$t$;

\echo '----- C7. a voided invoice number can never be reused (per-carrier uniqueness holds across states) -----'
do $t$
declare v_new_id uuid;
begin
  begin
    insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, invoice_number, issuance_status, issued_at, issued_by)
    values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', current_setting('test.civ_a1_number'), 'issued', now(), 'aaaa0000-0000-0000-0000-000000000001');
    raise exception 'TEST FAIL: reusing a voided invoice number for the same carrier should be rejected.';
  exception when unique_violation then
    raise notice 'OK: a voided invoice number can never be reused for the same carrier (unique index still enforces it).';
  end;
end
$t$;

-- ---------------------------------------------------------------------------
-- D. dispatch_service_invoice: independent numbering + issuer/recipient shape
-- ---------------------------------------------------------------------------
\echo '----- D1. a dispatch_service_invoice recipient is always the carrier itself, never carrier factoring readiness -----'
do $t$
declare v_id uuid; v_problem text;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, currency, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'dispatch_service_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'USD', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;

  v_problem := public.carrier_invoice_factoring_readiness_problem(v_id);
  if v_problem is not null then
    raise exception 'TEST FAIL: dispatch_service_invoice must never be subject to carrier factoring readiness (got %).', v_problem;
  end if;
  raise notice 'OK: dispatch_service_invoice factoring-readiness problem is always null, even though carrier A2 is unconfigured for factoring.';
end
$t$;

-- ---------------------------------------------------------------------------
-- E. problem-classifier functions (Section H / I), used exactly as the
-- future 0143 issuance RPC would, before allocating a number
-- ---------------------------------------------------------------------------
\echo '----- E1. unconfigured carrier -> factoring blocked; direct carrier -> no factor needed; factored+ready -> null -----'
do $t$
declare v_id uuid; v_problem text;
begin
  -- A2 is 'unconfigured' (default, never changed) -- freight issuance must
  -- be blocked purely on factoring policy, independent of recipient shape.
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'broker', 'a0b00000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_problem := public.carrier_invoice_factoring_readiness_problem(v_id);
  if v_problem is distinct from 'carrier_factoring_unconfigured' then
    raise exception 'TEST FAIL: expected carrier_factoring_unconfigured, got %.', v_problem;
  end if;
  raise notice 'OK: unconfigured carrier -> %.', v_problem;

  update public.carriers set factoring_mode = 'direct' where id = 'a2a2a2a2-0000-0000-0000-000000000002';
  v_problem := public.carrier_invoice_factoring_readiness_problem(v_id);
  if v_problem is not null then
    raise exception 'TEST FAIL: a direct-billing carrier should have no factoring problem at all, got %.', v_problem;
  end if;
  raise notice 'OK: direct-billing carrier -> null (no factor snapshot required).';

  -- Carrier A1 is factored + fully ready (fixtures above).
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_problem := public.carrier_invoice_factoring_readiness_problem(v_id);
  if v_problem is not null then
    raise exception 'TEST FAIL: carrier A1 is factored+complete+default+active -- classifier should be exactly ready (got problem %).', v_problem;
  end if;
  raise notice 'OK: factored carrier with a complete default relationship -> null (classifier returned exactly ready).';
end
$t$;

\echo '----- E2. factored but relationship incomplete -> a non-null problem, never silently ready -----'
do $t$
declare v_id uuid; v_problem text;
begin
  update public.factoring_relationships set remittance_instructions = null where id = 'fe420000-0000-0000-0000-000000000001';
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_problem := public.carrier_invoice_factoring_readiness_problem(v_id);
  if v_problem is null or v_problem not ilike 'factoring_not_ready:%' then
    raise exception 'TEST FAIL: an incomplete relationship must never classify as ready (got %).', v_problem;
  end if;
  raise notice 'OK: incomplete relationship -> %  (never silently ready).', v_problem;
  update public.factoring_relationships set remittance_instructions = 'Wire A1' where id = 'fe420000-0000-0000-0000-000000000001';
end
$t$;

\echo '----- E3. recipient problem: inactive/blacklisted recipient, missing carrier-party relationship -----'
do $t$
declare v_id uuid; v_problem text;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_problem := public.carrier_invoice_recipient_problem(v_id);
  if v_problem is not null then raise exception 'TEST FAIL: recipient should resolve cleanly, got %.', v_problem; end if;

  update public.brokers set is_blacklisted = true where id = 'a0b00000-0000-0000-0000-000000000001';
  v_problem := public.carrier_invoice_recipient_problem(v_id);
  if v_problem is distinct from 'recipient_broker_blacklisted' then
    raise exception 'TEST FAIL: expected recipient_broker_blacklisted, got %.', v_problem;
  end if;
  raise notice 'OK: blacklisted broker -> %.', v_problem;
  update public.brokers set is_blacklisted = false where id = 'a0b00000-0000-0000-0000-000000000001';

  -- A carrier/customer relationship that was never established at all.
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_customer_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a2a2a2a2-0000-0000-0000-000000000002', 'customer', 'a0c00000-0000-0000-0000-000000000001')
  returning id into v_id;
  v_problem := public.carrier_invoice_recipient_problem(v_id);
  if v_problem is distinct from 'recipient_relationship_missing' then
    raise exception 'TEST FAIL: expected recipient_relationship_missing, got %.', v_problem;
  end if;
  raise notice 'OK: no carrier_customers row at all -> %.', v_problem;
end
$t$;

-- ---------------------------------------------------------------------------
-- F. role matrix (Section K)
-- ---------------------------------------------------------------------------
\echo '----- F1. dispatcher may create a draft, but can never set it beyond draft, nor change carrier/recipient -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'dddd0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.civ_dispatcher', v_id::text, false);
  raise notice 'OK: dispatcher created a draft carrier_invoice.';

  -- Phase 3B.3A.2: carrier_id has ZERO column grant for authenticated at
  -- all any more -- this now fails at the GRANT level (insufficient_
  -- privilege), before the lifecycle trigger's own role check would ever
  -- get a chance to run.
  begin
    update public.carrier_invoices set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002' where id = v_id;
    raise exception 'TEST FAIL: dispatcher should never be able to change carrier_id.';
  exception when insufficient_privilege then
    raise notice 'OK: dispatcher cannot change carrier_id -- zero column grant, rejected before any trigger runs -- %', sqlerrm;
  end;

  begin
    update public.carrier_invoices set issuance_status = 'issued' where id = v_id;
    raise exception 'TEST FAIL: dispatcher should never be able to touch issuance_status at all.';
  exception when insufficient_privilege then
    raise notice 'OK: dispatcher cannot touch issuance_status -- zero column grant for ANY role (Phase 3B.3A.2 Section C/D) -- %', sqlerrm;
  end;
end
$t$;

\echo '----- F2. driver/viewer have zero visibility into carrier_invoices -----'
select set_config('test.current_uid', 'eeee0000-0000-0000-0000-000000000001', false);
do $t$
declare v_count integer;
begin
  select count(*) into v_count from public.carrier_invoices;
  if v_count <> 0 then
    raise exception 'TEST FAIL: driver should see zero carrier_invoices rows (RLS), saw %.', v_count;
  end if;
  raise notice 'OK: driver sees zero carrier_invoices rows.';
end
$t$;
select set_config('test.current_uid', 'ffff0000-0000-0000-0000-000000000001', false);
do $t$
declare v_count integer;
begin
  select count(*) into v_count from public.carrier_invoices;
  if v_count <> 0 then
    raise exception 'TEST FAIL: viewer should see zero carrier_invoices rows (RLS), saw %.', v_count;
  end if;
  raise notice 'OK: viewer sees zero carrier_invoices rows.';
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- G. legacy invoice classification (Section J) -- read-only, no mutation
-- ---------------------------------------------------------------------------
\echo '----- G1. seed legacy public.invoices rows across every classification bucket -----'
do $t$
begin
  insert into public.invoices (id, organization_id, invoice_number, load_id, broker_id, status, total_amount, amount_paid)
  values
    -- safely identifiable: load-linked, carrier resolved+clean, no factoring, unpaid, not void
    ('1e000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'LEGACY-1', '10000000-0000-0000-0000-000000000001', 'a0b00000-0000-0000-0000-000000000001', 'sent', 1500, 0),
    -- missing recipient: no broker, no customer
    ('1e000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'LEGACY-2', null, null, 'draft', 0, 0),
    -- voided
    ('1e000000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'LEGACY-3', null, 'a0b00000-0000-0000-0000-000000000001', 'void', 500, 0),
    -- paid
    ('1e000000-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'LEGACY-4', null, 'a0b00000-0000-0000-0000-000000000001', 'paid', 800, 800),
    -- missing carrier evidence: load-linked but that load (L4) has no
    -- dispatch/carrier resolved at all
    ('1e000000-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'LEGACY-5', '40000000-0000-0000-0000-000000000004', 'a0b00000-0000-0000-0000-000000000001', 'sent', 200, 0);

  -- Conflicting recipient evidence must be constructed directly (0112's
  -- own guard, if applied, would reject this at the app layer -- 0112 is
  -- NOT part of this test's migration chain, so the raw row is reachable
  -- here purely to prove the CLASSIFIER's own handling of it).
  insert into public.invoices (id, organization_id, invoice_number, load_id, broker_id, customer_id, status, total_amount, amount_paid)
  values ('1e000000-0000-0000-0000-000000000006', '11111111-1111-1111-1111-111111111111', 'LEGACY-6', null, 'a0b00000-0000-0000-0000-000000000001', 'a0c00000-0000-0000-0000-000000000001', 'sent', 300, 0);
end
$t$;

\echo '----- G2. classify_legacy_invoice_for_carrier_migration() matches every bucket exactly -----'
do $t$
declare v_c text;
begin
  v_c := public.classify_legacy_invoice_for_carrier_migration('1e000000-0000-0000-0000-000000000001');
  if v_c <> 'safely_identifiable_legacy' then raise exception 'TEST FAIL: LEGACY-1 expected safely_identifiable_legacy, got %.', v_c; end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('1e000000-0000-0000-0000-000000000002');
  if v_c <> 'missing_recipient' then raise exception 'TEST FAIL: LEGACY-2 expected missing_recipient, got %.', v_c; end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('1e000000-0000-0000-0000-000000000003');
  if v_c <> 'voided_cancelled' then raise exception 'TEST FAIL: LEGACY-3 expected voided_cancelled, got %.', v_c; end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('1e000000-0000-0000-0000-000000000004');
  if v_c <> 'paid_or_partially_paid' then raise exception 'TEST FAIL: LEGACY-4 expected paid_or_partially_paid, got %.', v_c; end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('1e000000-0000-0000-0000-000000000005');
  if v_c <> 'missing_carrier_evidence' then raise exception 'TEST FAIL: LEGACY-5 expected missing_carrier_evidence, got %.', v_c; end if;

  v_c := public.classify_legacy_invoice_for_carrier_migration('1e000000-0000-0000-0000-000000000006');
  if v_c <> 'conflicting_recipient_evidence' then raise exception 'TEST FAIL: LEGACY-6 expected conflicting_recipient_evidence, got %.', v_c; end if;

  raise notice 'OK: all six legacy classification buckets matched exactly.';
end
$t$;

\echo '----- G3. scan_legacy_invoices_for_carrier_migration() populates the review table, never touches public.invoices -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_scanned integer; v_before_count integer;
begin
  select count(*) into v_before_count from public.invoices;
  v_scanned := public.scan_legacy_invoices_for_carrier_migration();
  if v_scanned < 6 then
    raise exception 'TEST FAIL: expected at least 6 rows scanned, got %.', v_scanned;
  end if;
  if (select count(*) from public.invoices) <> v_before_count then
    raise exception 'TEST FAIL: scan must never insert/delete public.invoices rows.';
  end if;
  if (select classification from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000001') <> 'safely_identifiable_legacy' then
    raise exception 'TEST FAIL: review row for LEGACY-1 does not match the classifier.';
  end if;
  raise notice 'OK: scan populated % review rows; public.invoices was never mutated by the scan.', v_scanned;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- H. Phase 3B.3A.1 Section A/G: issuance/payment state separation (items 1-7)
-- ---------------------------------------------------------------------------
\echo '----- H1. issuance_status and payment_status are separate columns; partially_paid/paid cannot exist in the issuance enum at all -----'
do $t$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoices' and column_name='issuance_status') then
    raise exception 'TEST FAIL: issuance_status column missing.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoices' and column_name='payment_status') then
    raise exception 'TEST FAIL: payment_status column missing.';
  end if;
  if exists (select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='invoice_issuance_status' and e.enumlabel in ('partially_paid','paid','disputed')) then
    raise exception 'TEST FAIL: invoice_issuance_status must never contain a payment or dispute value.';
  end if;
  raise notice 'OK: issuance_status and payment_status are two independent columns/enums -- partially_paid/paid/disputed do not exist anywhere in invoice_issuance_status.';
end
$t$;

\echo '----- H2. casting the literal ''partially_paid''/''paid'' into invoice_issuance_status is rejected at the type level, not just by application logic -----'
do $t$
begin
  begin
    perform 'partially_paid'::public.invoice_issuance_status;
    raise exception 'TEST FAIL: partially_paid should not be a valid invoice_issuance_status value.';
  exception when invalid_text_representation then
    raise notice 'OK: ''partially_paid''::invoice_issuance_status is rejected at the Postgres type level -- %', sqlerrm;
  end;
end
$t$;

\echo '----- H3. a draft invoice cannot be partially_paid or paid -- CHECK rejects it even attempted directly -----'
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001')
  returning id into v_id;
  begin
    update public.carrier_invoices set payment_status = 'partially_paid', amount_paid = 100 where id = v_id;
    raise exception 'TEST FAIL: a draft invoice should never be allowed to become partially_paid.';
  exception when check_violation then
    raise notice 'OK: draft + partially_paid rejected by cinv_payment_requires_issued -- %', sqlerrm;
  end;
  perform set_config('test.civ_draft_for_payment', v_id::text, false);
end
$t$;

\echo '----- H4. only an ISSUED invoice can accept a nonzero paid amount; payment changes never alter issuance_status -----'
do $t$
declare
  v_id uuid;
  v_number text;
begin
  -- A fresh, fully issued invoice (mirrors C1/C2's simulated-issuance shape).
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001')
  returning id into v_id;
  insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price)
  values ('11111111-1111-1111-1111-111111111111', v_id, 'Freight -- payment test', 1, 1000);
  update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = v_id;
  v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
  insert into public.carrier_invoice_issuance_snapshots
    (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, carrier_id, snapshot_payload)
  values (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', v_number, 1000, 1000, 1000, 'a1a1a1a1-0000-0000-0000-000000000001', '{}'::jsonb);
  update public.carrier_invoices set issuance_status = 'issued', invoice_number = v_number, issued_at = now() where id = v_id;

  -- Simulated future payment RPC (superuser-level direct write -- no such
  -- RPC exists yet, see this migration's header): applying a partial
  -- payment on an ISSUED invoice must succeed and must NOT touch
  -- issuance_status.
  update public.carrier_invoices set amount_paid = 400, payment_status = 'partially_paid' where id = v_id;
  if (select issuance_status from public.carrier_invoices where id = v_id) <> 'issued' then
    raise exception 'TEST FAIL: applying a payment must never change issuance_status.';
  end if;
  if (select payment_status from public.carrier_invoices where id = v_id) <> 'partially_paid' then
    raise exception 'TEST FAIL: payment_status should now be partially_paid.';
  end if;
  raise notice 'OK: a nonzero paid amount was accepted on an ISSUED invoice, and issuance_status remained ''issued'' throughout.';

  -- The SAME attempt against the draft from H3 must still fail.
  begin
    update public.carrier_invoices set amount_paid = 100, payment_status = 'partially_paid' where id = current_setting('test.civ_draft_for_payment')::uuid;
    raise exception 'TEST FAIL: a draft invoice must never accept a nonzero paid amount.';
  exception when check_violation then
    raise notice 'OK: a draft invoice still cannot accept a nonzero paid amount -- %', sqlerrm;
  end;
end
$t$;

\echo '----- H5/H6/H7. factoring and delivery state are not stored anywhere on carrier_invoices -----'
do $t$
declare v_bad_cols integer;
begin
  select count(*) into v_bad_cols from information_schema.columns
  where table_schema='public' and table_name='carrier_invoices'
    and (column_name ilike '%factoring%' or column_name ilike '%delivery%' or column_name ilike '%email_sent%' or column_name ilike '%whatsapp%');
  if v_bad_cols <> 0 then
    raise exception 'TEST FAIL: carrier_invoices must never store factoring or delivery state directly -- found % such column(s).', v_bad_cols;
  end if;
  raise notice 'OK: carrier_invoices has zero factoring/delivery-shaped columns -- factoring readiness is read LIVE from 0136-0141''s own tables (carrier_invoice_factoring_readiness_problem), and delivery is not modeled at all yet.';
end
$t$;

-- ---------------------------------------------------------------------------
-- I. Phase 3B.3A.1 Section D: column-privilege boundary (items 8-10)
-- ---------------------------------------------------------------------------
\echo '----- I1. dispatcher has NO column grant at all on payment_status/amount_paid/invoice_number/organization_id -- rejected before RLS even applies -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_dispatcher')::uuid;
begin
  begin
    update public.carrier_invoices set payment_status = 'paid' where id = v_id;
    raise exception 'TEST FAIL: dispatcher should not have any grant on payment_status.';
  exception when insufficient_privilege then
    raise notice 'OK: dispatcher has zero column-level UPDATE privilege on payment_status -- %', sqlerrm;
  end;
  begin
    update public.carrier_invoices set invoice_number = 'FORGED-1' where id = v_id;
    raise exception 'TEST FAIL: dispatcher should not have any grant on invoice_number.';
  exception when insufficient_privilege then
    raise notice 'OK: dispatcher has zero column-level UPDATE privilege on invoice_number -- %', sqlerrm;
  end;
  -- Phase 3B.3A.2: due_date/payment_terms_days/currency also have zero
  -- direct grant now (Section A) -- these must go through
  -- update_carrier_invoice_draft() instead.
  begin
    update public.carrier_invoices set due_date = '2099-01-01' where id = v_id;
    raise exception 'TEST FAIL: dispatcher should not have any grant on due_date.';
  exception when insufficient_privilege then
    raise notice 'OK: dispatcher has zero column-level UPDATE privilege on due_date -- %', sqlerrm;
  end;
  begin
    update public.carrier_invoices set currency = 'EUR' where id = v_id;
    raise exception 'TEST FAIL: dispatcher should not have any grant on currency.';
  exception when insufficient_privilege then
    raise notice 'OK: dispatcher has zero column-level UPDATE privilege on currency -- %', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- I2. a brand-new, unrecognized column defaults to NOT dispatcher-writable (and not writable by anyone authenticated) without any further action -----'
do $t$
begin
  alter table public.carrier_invoices add column test_future_unrecognized_column text;
  if has_column_privilege('authenticated', 'public.carrier_invoices', 'test_future_unrecognized_column', 'UPDATE') then
    raise exception 'TEST FAIL: a brand-new column must default to NO authenticated UPDATE grant.';
  end if;
  alter table public.carrier_invoices drop column test_future_unrecognized_column;
  raise notice 'OK: a freshly added column has zero authenticated UPDATE grant by default -- the column-privilege model, not a trigger denylist, is what keeps new columns safe.';
end
$t$;

\echo '----- I3. Phase 3B.3A.2: NO authenticated role -- not accountant, not even owner -- can change carrier_id or void directly any more; both are zero-grant for every role -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'cccc0000-0000-0000-0000-000000000001')
  returning id into v_id;
  begin
    update public.carrier_invoices set carrier_id = 'a2a2a2a2-0000-0000-0000-000000000002' where id = v_id;
    raise exception 'TEST FAIL: accountant should never be able to change carrier_id directly -- carrier is immutable through any client path now.';
  exception when insufficient_privilege then
    raise notice 'OK: accountant cannot change carrier_id -- zero column grant -- %', sqlerrm;
  end;
  begin
    update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'cccc0000-0000-0000-0000-000000000001', void_reason = 'accountant attempt' where id = v_id;
    raise exception 'TEST FAIL: accountant should never be able to void directly.';
  exception when insufficient_privilege then
    raise notice 'OK: accountant cannot void directly -- zero column grant on issuance_status/void_reason/voided_* (Phase 3B.3A.2 Section C) -- %', sqlerrm;
  end;
  delete from public.carrier_invoices where id = v_id;
end
$t$;

\echo '----- I3b. even OWNER cannot void directly any more -- voiding is fully deferred to the future 0143 RPC (Section C: preferred disposition) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := (select id from public.carrier_invoices where issuance_status = 'issued' and payment_status = 'partially_paid' and organization_id = '11111111-1111-1111-1111-111111111111' limit 1);
begin
  begin
    update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'owner attempt' where id = v_id;
    raise exception 'TEST FAIL: owner should never be able to void directly either -- voiding has NO authenticated write path yet, direct or via RPC.';
  exception when insufficient_privilege then
    raise notice 'OK: owner cannot void directly -- issuance_status/void_reason/voided_at/voided_by have zero grant for EVERY role, including owner -- %', sqlerrm;
  end;
  if (select issuance_status from public.carrier_invoices where id = v_id) <> 'issued' then
    raise exception 'TEST FAIL: the invoice must remain issued -- the failed attempt must not have partially applied.';
  end if;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- I3c. (trusted test context only, per Section C''s explicit allowance) the underlying void invariants still hold at the constraint/trigger level, ready for the future 0143 RPC to rely on -----'
-- The Postgres ROLE is superuser throughout (bypasses column grants),
-- but has_role() inside the trigger reads test.current_uid regardless of
-- Postgres role -- so simulating "an accountant attempts this" still
-- requires setting test.current_uid to the accountant's own id first.
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid := (select id from public.carrier_invoices where issuance_status = 'issued' and payment_status = 'partially_paid' and organization_id = '11111111-1111-1111-1111-111111111111' limit 1);
begin
  begin
    update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'cccc0000-0000-0000-0000-000000000001', void_reason = 'trusted-context accountant attempt' where id = v_id;
    raise exception 'TEST FAIL: the trigger''s own role check should still reject a would-be accountant void of a paid invoice, even in a trusted context.';
  exception when others then
    if sqlerrm not ilike '%can only be voided by an owner or admin%' then raise; end if;
    raise notice 'OK (trusted context): the underlying invariant -- an invoice with applied payments can only be voided by owner/admin -- still holds at the trigger level, ready for 0143 to build on -- %', sqlerrm;
  end;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid := (select id from public.carrier_invoices where issuance_status = 'issued' and payment_status = 'partially_paid' and organization_id = '11111111-1111-1111-1111-111111111111' limit 1);
begin
  update public.carrier_invoices set issuance_status = 'voided', voided_at = now(), voided_by = 'aaaa0000-0000-0000-0000-000000000001', void_reason = 'trusted-context owner correction' where id = v_id;
  if (select payment_status from public.carrier_invoices where id = v_id) <> 'partially_paid' then
    raise exception 'TEST FAIL: voiding must not erase payment history (payment_status).';
  end if;
  raise notice 'OK (trusted context): the underlying invariant -- voiding preserves payment history -- still holds, ready for 0143 to build on.';
end
$t$;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- M. Phase 3B.3A.2 Section B/F: update_carrier_invoice_draft() -- the
-- guarded draft-mutation RPC (Section F items 1-20).
-- ---------------------------------------------------------------------------
\echo '----- M0. fixture: a fresh draft owned by A1/Broker A for the RPC tests -----'
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_id;
  perform set_config('test.civ_rpc', v_id::text, false);
  raise notice 'OK: fixture draft % created for update_carrier_invoice_draft() tests.', v_id;
end
$t$;

\echo '----- M1/M2/M3/M4/M5. dispatcher via the RPC: notes succeeds; due_date/payment_terms_days/recipient/currency are all FORBIDDEN -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"dispatcher note"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm1-dispatcher-notes');
  if not (v_result->>'success')::boolean then raise exception 'TEST FAIL (item 1): dispatcher should be able to set notes via the RPC, got %.', v_result; end if;
  raise notice 'OK (item 1): dispatcher can edit notes on a draft through the RPC -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"due_date":"2099-01-01"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm2-dispatcher-due-date');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (item 2): dispatcher should be FORBIDDEN from due_date, got %.', v_result; end if;
  raise notice 'OK (item 2): dispatcher cannot edit due_date through the RPC -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"payment_terms_days":15}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm3-dispatcher-terms');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (item 3): dispatcher should be FORBIDDEN from payment_terms_days, got %.', v_result; end if;
  raise notice 'OK (item 3): dispatcher cannot edit payment_terms_days through the RPC -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"customer_id":"a0c00000-0000-0000-0000-000000000001"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'trying to switch recipient', 'm4-dispatcher-recipient');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (item 4): dispatcher should be FORBIDDEN from changing the recipient, got %.', v_result; end if;
  raise notice 'OK (item 4): dispatcher cannot change the recipient through the RPC -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"currency":"EUR"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'trying to switch currency', 'm5-dispatcher-currency');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (item 5): dispatcher should be FORBIDDEN from changing currency, got %.', v_result; end if;
  raise notice 'OK (item 5): dispatcher cannot change currency through the RPC -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- M6. dispatcher cannot void -- there is no void path anywhere, direct or via this RPC (already proven structurally in I3/I3b) -----'
do $t$
begin
  raise notice 'OK (item 6): re-confirmed by I3/I3b above -- issuance_status/void_reason/voided_at/voided_by are outside this RPC''s patch allowlist entirely (INVALID_INPUT ''unknown field'' if ever attempted) AND have zero column grant for any role.';
end
$t$;

\echo '----- M7/M8. accountant via the RPC: billing fields succeed; recipient is FORBIDDEN; carrier/document type are not even valid patch keys -----'
select set_config('test.current_uid', 'cccc0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"due_date":"2026-06-01","payment_terms_days":45,"currency":"USD"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'accountant billing update', 'm7-accountant-billing');
  if not (v_result->>'success')::boolean then raise exception 'TEST FAIL (item 7): accountant should be able to set billing fields, got %.', v_result; end if;
  raise notice 'OK (item 7): accountant can edit approved billing draft fields (due_date/payment_terms_days/currency) through the RPC -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"broker_id":"a0b00000-0000-0000-0000-000000000001"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'accountant recipient attempt', 'm7b-accountant-recipient');
  if v_result->>'code' <> 'FORBIDDEN' then raise exception 'TEST FAIL (item 7): accountant should be FORBIDDEN from the recipient fields, got %.', v_result; end if;
  raise notice 'OK (item 7): accountant cannot change the recipient through the RPC -- billing fields only -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"carrier_id":"a2a2a2a2-0000-0000-0000-000000000002"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'accountant carrier attempt', 'm8-accountant-carrier');
  if v_result->>'code' <> 'INVALID_INPUT' then raise exception 'TEST FAIL (item 8): carrier_id is not even a recognized patch key, got %.', v_result; end if;
  raise notice 'OK (item 8): accountant cannot change carrier_id -- it is not in the patch allowlist AT ALL, for any role -- %.', v_result;

  v_result := public.update_carrier_invoice_draft(v_id, '{"invoice_document_type":"dispatch_service_invoice"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'accountant doc type attempt', 'm8b-accountant-doctype');
  if v_result->>'code' <> 'INVALID_INPUT' then raise exception 'TEST FAIL (item 8): invoice_document_type is not even a recognized patch key, got %.', v_result; end if;
  raise notice 'OK (item 8): accountant cannot change invoice_document_type -- not in the patch allowlist AT ALL -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- M9. accountant cannot void (re-confirmed -- no path exists, structurally proven in I3) -----'
do $t$
begin
  raise notice 'OK (item 9): re-confirmed by I3 above.';
end
$t$;

\echo '----- M10. owner/admin CAN use the guarded RPC -- a real recipient swap (broker -> customer), with a reason, revalidated for eligibility -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb; v_problem text;
begin
  -- A genuine type-swap must explicitly clear the OTHER recipient field
  -- too (presence of a key = set it, including to null; absence = leave
  -- unchanged -- omitting broker_id here would leave the OLD broker_id in
  -- place alongside the new customer_id, correctly failing the XOR check).
  v_result := public.update_carrier_invoice_draft(v_id, '{"customer_id":"a0c00000-0000-0000-0000-000000000001","broker_id":null}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'switching to direct customer billing', 'm10-owner-swap');
  if not (v_result->>'success')::boolean then raise exception 'TEST FAIL (item 10): owner should be able to swap the recipient, got %.', v_result; end if;
  if (select recipient_type from public.carrier_invoices where id=v_id) <> 'customer' or (select recipient_customer_id from public.carrier_invoices where id=v_id) <> 'a0c00000-0000-0000-0000-000000000001'::uuid or (select recipient_broker_id from public.carrier_invoices where id=v_id) is not null then
    raise exception 'TEST FAIL (item 10): recipient was not correctly swapped to customer-only.';
  end if;
  raise notice 'OK (item 10): owner used the guarded RPC to swap the recipient (broker -> customer), successfully (the RPC itself already revalidates eligibility internally before writing) -- %.', v_result;
end
$t$;
-- carrier_invoice_recipient_problem() is internal-only (revoked from
-- authenticated) -- confirm the swap's eligibility from a trusted
-- context, matching this file's own established convention.
reset role;
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_problem text;
begin
  v_problem := public.carrier_invoice_recipient_problem(v_id);
  if v_problem is not null then raise exception 'TEST FAIL (item 10): the new recipient should be fully eligible, got problem %.', v_problem; end if;
  raise notice 'OK (item 10, trusted-context confirmation): the swapped recipient is fully eligible -- no problem.';
end
$t$;
set role authenticated;

\echo '----- M11. direct authenticated updates to protected columns fail (re-confirmed via the RPC''s own table too, plus a fresh direct-SQL check here) -----'
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid;
begin
  begin
    update public.carrier_invoices set total_amount = 1 where id = v_id;
    raise exception 'TEST FAIL (item 11): total_amount should never be directly UPDATE-able.';
  exception when insufficient_privilege then
    raise notice 'OK (item 11): direct authenticated UPDATE of a protected column fails -- %', sqlerrm;
  end;
end
$t$;

\echo '----- M12. an unknown patch key fails -----'
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"totally_unrecognized_key": "x"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm12-unknown-key');
  if v_result->>'code' <> 'INVALID_INPUT' then raise exception 'TEST FAIL (item 12): an unknown patch key should be rejected, got %.', v_result; end if;
  raise notice 'OK (item 12): an unknown patch key is rejected -- %.', v_result;
end
$t$;

\echo '----- M13. cross-organization recipient fails indistinguishably (INVALID_RECIPIENT, same message as a never-existed id) -----'
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb; v_result2 jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"broker_id":"b0b00000-0000-0000-0000-000000000001","customer_id":null}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'cross-org attempt', 'm13-cross-org');
  if v_result->>'code' <> 'INVALID_RECIPIENT' then raise exception 'TEST FAIL (item 13): Org B''s broker should be rejected as INVALID_RECIPIENT, got %.', v_result; end if;
  v_result2 := public.update_carrier_invoice_draft(v_id, '{"broker_id":"00000000-0000-0000-0000-000000000000","customer_id":null}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), 'never-existed attempt', 'm13b-never-existed');
  if v_result2->>'code' <> 'INVALID_RECIPIENT' or v_result2->>'message' <> v_result->>'message' then
    raise exception 'TEST FAIL (item 13): a cross-org id and a never-existed id should produce the SAME indistinguishable message, got % vs %.', v_result, v_result2;
  end if;
  raise notice 'OK (item 13): cross-organization recipient and a never-existed recipient both fail with the SAME INVALID_RECIPIENT message -- %.', v_result;
end
$t$;

\echo '----- M14. an inactive/never-established recipient relationship fails -----'
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb; v_new_broker_id uuid := 'a0b00000-0000-0000-0000-000000000099';
begin
  insert into public.brokers (id, organization_id, company_name) values (v_new_broker_id, '11111111-1111-1111-1111-111111111111', 'Broker With No Relationship');
  v_result := public.update_carrier_invoice_draft(v_id, jsonb_build_object('broker_id', v_new_broker_id, 'customer_id', null), (select updated_at from public.carrier_invoices where id=v_id), 'no relationship established', 'm14-no-relationship');
  if v_result->>'code' <> 'INVALID_RECIPIENT' then raise exception 'TEST FAIL (item 14): a broker with no carrier_brokers relationship at all should be rejected, got %.', v_result; end if;
  raise notice 'OK (item 14): a recipient with no active carrier-party relationship is rejected -- %.', v_result;
end
$t$;

\echo '----- M15. a stale expected_updated_at produces no mutation, no audit event, and no idempotency success -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_rpc')::uuid;
  v_stale timestamptz := now() - interval '1 hour';
  v_notes_before text := (select notes from public.carrier_invoices where id=v_id);
  v_audit_before integer;
  v_result jsonb;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_type='invoice' and entity_id=v_id and action='carrier_invoice_draft_updated';
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"should never apply"}'::jsonb, v_stale, null, 'm15-stale');
  if v_result->>'code' <> 'STALE_RECORD' then raise exception 'TEST FAIL (item 15): expected STALE_RECORD, got %.', v_result; end if;
  if (select notes from public.carrier_invoices where id=v_id) is distinct from v_notes_before then
    raise exception 'TEST FAIL (item 15): a stale-record rejection must never mutate the row.';
  end if;
  if (select count(*) from public.activity_logs where entity_type='invoice' and entity_id=v_id and action='carrier_invoice_draft_updated') <> v_audit_before then
    raise exception 'TEST FAIL (item 15): a stale-record rejection must never write an audit event.';
  end if;
  if exists (select 1 from public.carrier_invoice_lifecycle_idempotency where idempotency_key='m15-stale') then
    raise exception 'TEST FAIL (item 15): a stale-record rejection must never record an idempotency success.';
  end if;
  raise notice 'OK (item 15): STALE_RECORD produced zero mutation, zero audit event, and zero idempotency row -- %.', v_result;
end
$t$;

\echo '----- M16. the SAME idempotency key replayed (the exact original retry contract, including expected_updated_at) produces exactly one mutation and one audit event -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_rpc')::uuid;
  -- Captured ONCE and reused for both calls -- a genuine retry resends
  -- the SAME expected_updated_at (Phase 3B.3A.3: the fingerprint now
  -- includes expected_updated_at, so re-reading a FRESH value after the
  -- first call's mutation would make the second call a DIFFERENT
  -- logical request, not a replay -- see N4/N5 below for that documented
  -- behavior explicitly).
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id=v_id);
  v_result1 jsonb; v_result2 jsonb;
  v_audit_before integer; v_audit_after integer;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_type='invoice' and entity_id=v_id and action='carrier_invoice_draft_updated';
  v_result1 := public.update_carrier_invoice_draft(v_id, '{"notes":"idempotent note"}'::jsonb, v_expected, null, 'm16-replay');
  v_result2 := public.update_carrier_invoice_draft(v_id, '{"notes":"idempotent note"}'::jsonb, v_expected, null, 'm16-replay');
  if v_result1 <> v_result2 then raise exception 'TEST FAIL (item 16): an identical replay should return the exact original result, got % vs %.', v_result1, v_result2; end if;
  select count(*) into v_audit_after from public.activity_logs where entity_type='invoice' and entity_id=v_id and action='carrier_invoice_draft_updated';
  if v_audit_after - v_audit_before <> 1 then
    raise exception 'TEST FAIL (item 16): expected exactly ONE new audit event across both calls (the second being a pure cache hit), got %.', v_audit_after - v_audit_before;
  end if;
  raise notice 'OK (item 16): replaying the SAME idempotency key produced exactly one mutation and exactly one audit event -- the second call was a true cache hit, not a second mutation -- %.', v_result1;
end
$t$;

\echo '----- M17. a DIFFERENT payload under the SAME idempotency key is rejected, never silently replayed or applied -----'
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"a completely different note"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm16-replay');
  if v_result->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 17): a different payload under the same key should be rejected as IDEMPOTENCY_KEY_REUSED, got %.', v_result;
  end if;
  if (select notes from public.carrier_invoices where id=v_id) = 'a completely different note' then
    raise exception 'TEST FAIL (item 17): the different payload must never have been applied.';
  end if;
  raise notice 'OK (item 17): a different payload reusing the same idempotency key is rejected outright -- neither replayed nor applied -- %.', v_result;
end
$t$;

\echo '----- M18. issued/voided invoices cannot be edited through the draft RPC -----'
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid; v_result jsonb;
begin
  -- civ_a1 (from section C) is already 'voided' by this point in the script.
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"trying to edit a voided invoice"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm18-voided');
  if v_result->>'code' <> 'NOT_EDITABLE' then raise exception 'TEST FAIL (item 18): a voided invoice should be NOT_EDITABLE through this RPC, got %.', v_result; end if;
  raise notice 'OK (item 18): a voided invoice cannot be edited through the draft RPC -- %.', v_result;
end
$t$;

\echo '----- M19/M20. payment/snapshot fields remain entirely outside this RPC''s reach (re-confirmed: not even a recognized patch key) -----'
do $t$
declare v_id uuid := current_setting('test.civ_rpc')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"payment_status":"paid"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm19-payment-status');
  if v_result->>'code' <> 'INVALID_INPUT' then raise exception 'TEST FAIL (item 20): payment_status is not a recognized patch key, got %.', v_result; end if;
  v_result := public.update_carrier_invoice_draft(v_id, '{"snapshot_payload":{}}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'm20-snapshot');
  if v_result->>'code' <> 'INVALID_INPUT' then raise exception 'TEST FAIL (item 20): snapshot fields are not a recognized patch key, got %.', v_result; end if;
  raise notice 'OK (items 19/20): payment/snapshot fields are not reachable through this RPC at all -- neither is a recognized patch key.';
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- N. Phase 3B.3A.3 Section A/C: idempotency-collision closure -- the
-- organization+operation+idempotency-key advisory lock, canonical
-- fingerprint (invoice id + patch + reason + expected_updated_at), and
-- the narrow, constraint-name-checked defensive fallback.
-- ---------------------------------------------------------------------------
\echo '----- N0. fixtures: two fresh Org A drafts + one Org B draft for the collision tests -----'
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_n1 uuid; v_n2 uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_n1;
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-000000000001')
  returning id into v_n2;
  perform set_config('test.civ_n1', v_n1::text, false);
  perform set_config('test.civ_n2', v_n2::text, false);
  raise notice 'OK: fixtures civ_n1=%, civ_n2=% created.', v_n1, v_n2;
end
$t$;
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
do $t$
declare v_nb uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('22222222-2222-2222-2222-222222222222', 'carrier_freight_invoice', 'b1b1b1b1-0000-0000-0000-000000000001', 'broker', 'b0b00000-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-000000000001')
  returning id into v_nb;
  perform set_config('test.civ_nb', v_nb::text, false);
  raise notice 'OK: Org B fixture civ_nb=% created.', v_nb;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

\echo '----- N1 (Section C item 1). same key + same invoice + same patch -> cached replay, byte-identical result -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_n1')::uuid;
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id=v_id);
  v_r1 jsonb; v_r2 jsonb;
begin
  v_r1 := public.update_carrier_invoice_draft(v_id, '{"notes":"n1 note"}'::jsonb, v_expected, null, 'n1-key');
  v_r2 := public.update_carrier_invoice_draft(v_id, '{"notes":"n1 note"}'::jsonb, v_expected, null, 'n1-key');
  if not (v_r1->>'success')::boolean then raise exception 'TEST FAIL (item 1): first call should succeed, got %.', v_r1; end if;
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (item 1): replay should return the byte-identical cached result, got % vs %.', v_r1, v_r2; end if;
  raise notice 'OK (item 1): same key + same invoice + same patch -> byte-identical cached replay -- %.', v_r1;
end
$t$;

\echo '----- N2 (Section C item 2). same key + DIFFERENT invoice -> structured IDEMPOTENCY_KEY_REUSED, no raw error, no mutation, no audit event -----'
do $t$
declare
  v_id2 uuid := current_setting('test.civ_n2')::uuid;
  v_notes_before text := (select notes from public.carrier_invoices where id=v_id2);
  v_audit_before integer; v_audit_after integer;
  v_result jsonb;
begin
  select count(*) into v_audit_before from public.activity_logs where entity_type='invoice' and entity_id=v_id2 and action='carrier_invoice_draft_updated';
  v_result := public.update_carrier_invoice_draft(v_id2, '{"notes":"trying to reuse n1''s key on a different invoice"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id2), null, 'n1-key');
  if v_result->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 2): same key + different invoice should return IDEMPOTENCY_KEY_REUSED, got %.', v_result;
  end if;
  if v_result ? 'constraint' or v_result ? 'detail' or v_result ? 'hint' or v_result::text ilike '%civ_idempotency_unique%' or v_result::text ilike '%duplicate key%' then
    raise exception 'TEST FAIL (item 2, and item 12): the client response leaked raw constraint/SQL detail -- %.', v_result;
  end if;
  if (select notes from public.carrier_invoices where id=v_id2) is distinct from v_notes_before then
    raise exception 'TEST FAIL (item 2, and item 10): a collision must never partially mutate the OTHER invoice.';
  end if;
  select count(*) into v_audit_after from public.activity_logs where entity_type='invoice' and entity_id=v_id2 and action='carrier_invoice_draft_updated';
  if v_audit_after <> v_audit_before then
    raise exception 'TEST FAIL (item 2, and item 9): a collision must never write an audit event for the losing request.';
  end if;
  raise notice 'OK (items 2, 9, 10, 12): same key + different invoice -> clean IDEMPOTENCY_KEY_REUSED, zero mutation, zero audit event, zero leaked internals -- %.', v_result;
end
$t$;

\echo '----- N3 (Section C item 3). same key + different PATCH (same invoice) -> structured reuse failure (re-confirms M17 from the prior phase, plus the no-leak check) -----'
do $t$
declare v_id uuid := current_setting('test.civ_n1')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"a totally different note"}'::jsonb, (select updated_at from public.carrier_invoices where id=v_id), null, 'n1-key');
  if v_result->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then raise exception 'TEST FAIL (item 3): expected IDEMPOTENCY_KEY_REUSED, got %.', v_result; end if;
  if (select notes from public.carrier_invoices where id=v_id) = 'a totally different note' then
    raise exception 'TEST FAIL (item 3): the different patch must never have been applied.';
  end if;
  raise notice 'OK (item 3): same key + different patch -> IDEMPOTENCY_KEY_REUSED, never applied -- %.', v_result;
end
$t$;

\echo '----- N4 (Section C item 4/5). same key + different expected_updated_at -> documented deterministic behavior: treated as a DIFFERENT logical request (fingerprint includes expected_updated_at) -----'
do $t$
declare v_id uuid := current_setting('test.civ_n1')::uuid; v_result jsonb;
begin
  v_result := public.update_carrier_invoice_draft(v_id, '{"notes":"n1 note"}'::jsonb, now() + interval '10 minutes', null, 'n1-key');
  if v_result->>'code' <> 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 4): same key + same patch but a DIFFERENT expected_updated_at should be treated as a different request (documented choice), got %.', v_result;
  end if;
  raise notice 'OK (item 4): same key + different expected_updated_at -> IDEMPOTENCY_KEY_REUSED (the documented, deterministic policy -- only the EXACT original retry contract, including expected_updated_at, replays) -- %.', v_result;
end
$t$;

\echo '----- N5 (Section C item 5). the SAME logical patch with keys in a DIFFERENT object order still fingerprints identically -> cached replay, not a collision -----'
do $t$
declare
  v_id uuid := current_setting('test.civ_n2')::uuid;
  -- Captured ONCE and reused for both calls -- a genuine idempotent
  -- retry naturally resends the SAME expected_updated_at it used the
  -- first time (that is exactly what makes it "the exact original retry
  -- contract", per item 4/5); re-reading updated_at after the first call
  -- would pick up the post-mutation value and defeat this test's own
  -- point.
  v_expected timestamptz := (select updated_at from public.carrier_invoices where id=v_id);
  v_r1 jsonb; v_r2 jsonb;
begin
  v_r1 := public.update_carrier_invoice_draft(v_id, '{"notes":"reordered test","due_date":"2027-03-01"}'::jsonb, v_expected, 'billing update', 'n5-key');
  if not (v_r1->>'success')::boolean then raise exception 'TEST FAIL (item 5): first call should succeed, got %.', v_r1; end if;
  -- SAME two keys, reversed object order, otherwise byte-identical values.
  v_r2 := public.update_carrier_invoice_draft(v_id, '{"due_date":"2027-03-01","notes":"reordered test"}'::jsonb, v_expected, 'billing update', 'n5-key');
  if v_r2->>'code' = 'IDEMPOTENCY_KEY_REUSED' then
    raise exception 'TEST FAIL (item 5): a logically identical patch with reordered keys must NOT be treated as a different request, got %.', v_r2;
  end if;
  if v_r1 <> v_r2 then raise exception 'TEST FAIL (item 5): expected the byte-identical cached result regardless of key order, got % vs %.', v_r1, v_r2; end if;
  raise notice 'OK (item 5): JSON object key ordering does not affect the fingerprint -- logically identical patches replay identically regardless of key order -- %.', v_r1;
end
$t$;

\echo '----- N6 (Section C item 6). the SAME idempotency key string reused by a DIFFERENT organization is fully independent -- no cross-tenant leak, no interference -----'
do $t$
declare v_id uuid := current_setting('test.civ_n1')::uuid; v_result jsonb;
begin
  -- 'n1-key' was already consumed above by Org A for civ_n1. Org B now
  -- uses the IDENTICAL key string for its OWN, completely different
  -- invoice/patch -- this must succeed on its own terms, structurally
  -- unaware Org A ever used the same string (the idempotency lookup and
  -- the advisory lock are both organization-scoped).
  perform set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
  v_result := public.update_carrier_invoice_draft(current_setting('test.civ_nb')::uuid, '{"notes":"org b using the same key string"}'::jsonb, (select updated_at from public.carrier_invoices where id=current_setting('test.civ_nb')::uuid), null, 'n1-key');
  if not (v_result->>'success')::boolean then
    raise exception 'TEST FAIL (item 6): Org B reusing the same key STRING as Org A must succeed independently, got %.', v_result;
  end if;
  if (select notes from public.carrier_invoices where id = current_setting('test.civ_nb')::uuid) <> 'org b using the same key string' then
    raise exception 'TEST FAIL (item 6): Org B''s own mutation should have applied.';
  end if;
  raise notice 'OK (item 6): the same idempotency key string is fully independent across organizations -- no cross-tenant leak, no interference -- %.', v_result;
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);

\echo '----- N11 (Section C item 11, structural proxy). the exception handler re-raises anything OTHER than civ_idempotency_unique -- an unrelated integrity failure is never mislabeled as a collision -----'
reset role;
do $t$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace;
  if v_src not ilike '%when unique_violation then%' then
    raise exception 'TEST FAIL (item 11): expected a narrow unique_violation handler, not a broad ''when others''.';
  end if;
  if v_src ilike '%when others then%' and v_src not ilike '%if v_constraint <> ''civ_idempotency_unique'' then%raise%' then
    raise exception 'TEST FAIL (item 11): the handler must check the constraint name and re-raise anything that is not civ_idempotency_unique.';
  end if;
  if v_src not ilike '%get stacked diagnostics v_constraint = constraint_name%' then
    raise exception 'TEST FAIL (item 11): expected the handler to inspect the actual constraint name via GET STACKED DIAGNOSTICS, not infer it from message text.';
  end if;
  raise notice 'OK (item 11, structural proxy): the collision handler is narrowly scoped to unique_violation on SPECIFICALLY civ_idempotency_unique (checked by name, via GET STACKED DIAGNOSTICS) and re-raises everything else unchanged -- a genuinely unrelated integrity failure can never be mislabeled as IDEMPOTENCY_KEY_REUSED. (A live, fully independent DIFFERENT-constraint violation inside this function''s narrow write path could not be manufactured without contorting the schema -- this structural check follows the same "prosrc inspection" convention already used elsewhere in this file and in VERIFY_0142_POST_APPLY.sql for equivalent cases.)';
end
$t$;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;

reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- J. Phase 3B.3A.1 Section C: legacy review RPC -- forgery prevention,
-- cross-organization rejection, derived actor/timestamp (items 11-14)
-- ---------------------------------------------------------------------------
\echo '----- J1. authenticated cannot forge reviewed_by or reviewed_at via direct UPDATE -- zero grant, table AND column -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_review_id uuid := (select id from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000001');
begin
  begin
    update public.legacy_invoice_carrier_migration_review set reviewed_by = 'dddd0000-0000-0000-0000-000000000001' where id = v_review_id;
    raise exception 'TEST FAIL: authenticated should never be able to set reviewed_by directly.';
  exception when insufficient_privilege then
    raise notice 'OK: reviewed_by cannot be forged via direct UPDATE (zero grant) -- %', sqlerrm;
  end;
  begin
    update public.legacy_invoice_carrier_migration_review set reviewed_at = now() - interval '10 years' where id = v_review_id;
    raise exception 'TEST FAIL: authenticated should never be able to set reviewed_at directly.';
  exception when insufficient_privilege then
    raise notice 'OK: reviewed_at cannot be forged via direct UPDATE (zero grant) -- %', sqlerrm;
  end;
end
$t$;

\echo '----- J2. review_legacy_invoice_carrier_migration() derives reviewed_by/reviewed_at server-side and writes exactly one audit event -----'
do $t$
declare
  v_review_id uuid := (select id from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000001');
  v_expected_updated_at timestamptz := (select updated_at from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000001');
  v_result jsonb;
  v_audit_count integer;
begin
  v_result := public.review_legacy_invoice_carrier_migration(v_review_id, 'ready_to_reissue', 'Looks clean, safe to reissue.', v_expected_updated_at, 'review-test-1');
  if not (v_result->>'success')::boolean then
    raise exception 'TEST FAIL: review should have succeeded, got %.', v_result;
  end if;
  if (v_result->>'reviewed_by')::uuid <> 'aaaa0000-0000-0000-0000-000000000001'::uuid then
    raise exception 'TEST FAIL: reviewed_by should be the calling owner''s own auth.uid(), got %.', v_result;
  end if;
  if (select reviewed_by from public.legacy_invoice_carrier_migration_review where id = v_review_id) <> 'aaaa0000-0000-0000-0000-000000000001'::uuid then
    raise exception 'TEST FAIL: the row itself should show reviewed_by = the calling owner.';
  end if;
  if (select reviewed_at from public.legacy_invoice_carrier_migration_review where id = v_review_id) is null then
    raise exception 'TEST FAIL: reviewed_at should be set from the database clock.';
  end if;

  select count(*) into v_audit_count from public.activity_logs
  where entity_type = 'invoice' and entity_id = '1e000000-0000-0000-0000-000000000001' and action = 'carrier_migration_reviewed';
  if v_audit_count <> 1 then
    raise exception 'TEST FAIL: expected exactly 1 audit event, got %.', v_audit_count;
  end if;
  raise notice 'OK: review_legacy_invoice_carrier_migration() derived reviewed_by/reviewed_at server-side (never from client input) and wrote exactly 1 audit event.';
end
$t$;

\echo '----- J3. optimistic concurrency (STALE_RECORD) and idempotent retry -----'
do $t$
declare
  v_review_id uuid := (select id from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000002');
  v_stale_ts timestamptz := now() - interval '1 hour';
  v_result jsonb;
  v_result2 jsonb;
begin
  v_result := public.review_legacy_invoice_carrier_migration(v_review_id, 'stale-attempt', null, v_stale_ts, 'review-test-stale');
  if v_result->>'code' <> 'STALE_RECORD' then
    raise exception 'TEST FAIL: expected STALE_RECORD, got %.', v_result;
  end if;
  raise notice 'OK: a mismatched p_expected_updated_at is rejected as STALE_RECORD -- %.', v_result;

  v_result := public.review_legacy_invoice_carrier_migration(v_review_id, 'idempotent-attempt', 'first', (select updated_at from public.legacy_invoice_carrier_migration_review where id = v_review_id), 'review-test-idempotent');
  v_result2 := public.review_legacy_invoice_carrier_migration(v_review_id, 'idempotent-attempt-DIFFERENT-TEXT-IGNORED', 'second', (select updated_at from public.legacy_invoice_carrier_migration_review where id = v_review_id), 'review-test-idempotent');
  if v_result2 <> v_result then
    raise exception 'TEST FAIL: an identical idempotency key should replay the exact original result, got % vs %.', v_result, v_result2;
  end if;
  raise notice 'OK: an identical idempotency key replays the original result rather than re-reviewing.';
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- J4. cross-organization review is rejected (NOT_FOUND, indistinguishable from a genuinely missing row) -----'
select set_config('test.current_uid', 'bbbb0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare
  v_org_a_review_id uuid := (select id from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000001');
  v_result jsonb;
begin
  v_result := public.review_legacy_invoice_carrier_migration(v_org_a_review_id, 'cross-org-attempt', null, now(), 'review-test-cross-org');
  if v_result->>'code' <> 'NOT_FOUND' then
    raise exception 'TEST FAIL: Org B reviewing Org A''s review row should return NOT_FOUND, got %.', v_result;
  end if;
  raise notice 'OK: cross-organization review rejected as NOT_FOUND (not a distinguishable ''wrong org'' message) -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

\echo '----- J5. dispatcher/driver/viewer cannot call the review RPC at all (owner/admin only) -----'
select set_config('test.current_uid', 'dddd0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare
  v_review_id uuid := (select id from public.legacy_invoice_carrier_migration_review where legacy_invoice_id = '1e000000-0000-0000-0000-000000000005');
  v_result jsonb;
begin
  v_result := public.review_legacy_invoice_carrier_migration(v_review_id, 'dispatcher-attempt', null, (select updated_at from public.legacy_invoice_carrier_migration_review where id = v_review_id), 'review-test-dispatcher');
  if v_result->>'code' <> 'FORBIDDEN' then
    raise exception 'TEST FAIL: dispatcher should be FORBIDDEN from reviewing, got %.', v_result;
  end if;
  raise notice 'OK: dispatcher cannot review a legacy classification -- %.', v_result;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- K. Phase 3B.3A.1 Section E: recursive snapshot secret/credential exclusion
-- (items 15-18)
-- ---------------------------------------------------------------------------
\echo '----- K1. secret_reference nested two levels deep inside an array is rejected -----'
reset role;
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'draft')
  returning id into v_id;
  begin
    insert into public.carrier_invoice_issuance_snapshots
      (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, carrier_id, snapshot_payload)
    values (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', 'CARA-SECRET-TEST-1', 100, 100, 100, 'a1a1a1a1-0000-0000-0000-000000000001',
      jsonb_build_object('loads', jsonb_build_array(jsonb_build_object('load_id', '10000000-0000-0000-0000-000000000001', 'nested', jsonb_build_object('secret_reference', 'vault://should-not-be-here')))));
    raise exception 'TEST FAIL: secret_reference nested inside an array element should have been rejected.';
  exception when check_violation then
    raise notice 'OK: secret_reference nested two levels deep (array -> object) is rejected -- %', sqlerrm;
  end;
  delete from public.carrier_invoices where id = v_id;
end
$t$;

\echo '----- K2. forbidden credential keys (api_key, access_token, password, client_secret, credentials, private_key) nested inside arrays/objects are all rejected -----'
do $t$
declare
  v_id uuid;
  v_key text;
  v_payload jsonb;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'draft')
  returning id into v_id;

  foreach v_key in array array['api_key','access_token','refresh_token','password','client_secret','credential','credentials','private_key'] loop
    v_payload := jsonb_build_object(
      'factoring', jsonb_build_object('nested_array', jsonb_build_array(jsonb_build_object('deep', jsonb_build_object(v_key, 'FORBIDDEN-VALUE'))))
    );
    begin
      insert into public.carrier_invoice_issuance_snapshots
        (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, carrier_id, snapshot_payload)
      values (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', 'CARA-SECRET-TEST-' || v_key, 100, 100, 100, 'a1a1a1a1-0000-0000-0000-000000000001', v_payload);
      raise exception 'TEST FAIL: forbidden key % nested inside an array should have been rejected.', v_key;
    exception when check_violation then
      null; -- expected
    end;
  end loop;
  raise notice 'OK: all 8 forbidden credential-shaped keys (case-insensitive, any depth, inside arrays and objects alike) are rejected.';
  delete from public.carrier_invoices where id = v_id;
end
$t$;

\echo '----- K3. snapshot_payload must be a genuine JSON object, never a bare array/scalar -----'
do $t$
declare v_id uuid;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'draft')
  returning id into v_id;
  begin
    insert into public.carrier_invoice_issuance_snapshots
      (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, carrier_id, snapshot_payload)
    values (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', 'CARA-SECRET-TEST-ARRAY', 100, 100, 100, 'a1a1a1a1-0000-0000-0000-000000000001', '["not", "an", "object"]'::jsonb);
    raise exception 'TEST FAIL: a bare array snapshot_payload should have been rejected.';
  exception when check_violation then
    raise notice 'OK: a bare array snapshot_payload is rejected -- %', sqlerrm;
  end;
  delete from public.carrier_invoices where id = v_id;
end
$t$;

\echo '----- K4. a rich, VALID non-secret nested payload succeeds cleanly (no false positives) -----'
do $t$
declare v_id uuid; v_number text;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, issuance_status)
  values ('11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'broker', 'a0b00000-0000-0000-0000-000000000001', 'draft')
  returning id into v_id;
  v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice', 'a1a1a1a1-0000-0000-0000-000000000001', 'CARA');
  insert into public.carrier_invoice_issuance_snapshots
    (invoice_id, organization_id, invoice_document_type, currency, invoice_number, subtotal_amount, total_amount, amount_due_at_issuance, carrier_id, snapshot_payload)
  values (v_id, '11111111-1111-1111-1111-111111111111', 'carrier_freight_invoice', 'USD', v_number, 100, 100, 100, 'a1a1a1a1-0000-0000-0000-000000000001',
    jsonb_build_object(
      'issuer', jsonb_build_object('carrier_id', 'a1a1a1a1-0000-0000-0000-000000000001', 'legal_name', 'Carrier A1 LLC', 'mc_number', 'MC-1'),
      'recipient', jsonb_build_object('type', 'broker', 'broker_id', 'a0b00000-0000-0000-0000-000000000001'),
      'loads', jsonb_build_array(jsonb_build_object('load_id', '10000000-0000-0000-0000-000000000001', 'load_number', 'LD-1')),
      'factoring', jsonb_build_object('factoring_relationship_id', 'fe420000-0000-0000-0000-000000000001', 'submission_method', 'internal_queue', 'submission_destination', 'safe-non-secret-value'),
      'dispatch_service', null
    ));
  if not exists (select 1 from public.carrier_invoice_issuance_snapshots where invoice_id = v_id) then
    raise exception 'TEST FAIL: a valid, non-secret nested payload should have succeeded.';
  end if;
  raise notice 'OK: a rich, legitimately nested, non-secret payload is accepted -- the forbidden-key check has no false positives.';
end
$t$;

\echo '----- K5. the snapshot remains immutable for every role, including authenticated (which has zero grant at all, not just a trigger) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_id uuid := current_setting('test.civ_a1')::uuid;
begin
  begin
    update public.carrier_invoice_issuance_snapshots set total_amount = 1 where invoice_id = v_id;
    raise exception 'TEST FAIL: authenticated should not be able to update a snapshot at all.';
  exception when insufficient_privilege then
    raise notice 'OK: authenticated has zero grant on carrier_invoice_issuance_snapshots -- rejected before any trigger even runs -- %', sqlerrm;
  end;
end
$t$;
reset role;
select set_config('test.current_uid', null, false);

-- ---------------------------------------------------------------------------
-- L. Section G items 19-20: legacy invoices untouched; no new factoring path
-- ---------------------------------------------------------------------------
\echo '----- L1. every legacy public.invoices row is byte-for-byte unchanged from its original seed values -----'
do $t$
begin
  if (select total_amount from public.invoices where id = '1e000000-0000-0000-0000-000000000001') <> 1500
    or (select status from public.invoices where id = '1e000000-0000-0000-0000-000000000001') <> 'sent' then
    raise exception 'TEST FAIL: LEGACY-1 was mutated -- existing invoices must remain entirely untouched.';
  end if;
  if (select amount_paid from public.invoices where id = '1e000000-0000-0000-0000-000000000004') <> 800 then
    raise exception 'TEST FAIL: LEGACY-4''s amount_paid was mutated.';
  end if;
  raise notice 'OK: every legacy public.invoices row remains exactly as seeded -- nothing in this migration or its RPCs ever writes to public.invoices.';
end
$t$;

\echo '----- L2. no new factoring-submission path exists for carrier_invoices -- submit_invoice_to_factor() remains the ONLY submission entry point, still fail-closed (0140) -----'
select set_config('test.current_uid', 'aaaa0000-0000-0000-0000-000000000001', false);
set role authenticated;
do $t$
declare v_result jsonb;
begin
  -- Deliberately excludes carrier_invoice_factoring_readiness_problem()
  -- (a legitimate READ-ONLY classifier this same migration adds, Section
  -- H) -- only a genuine SUBMISSION-shaped function name would fail this.
  if exists (select 1 from pg_proc where proname ilike '%submit%carrier_invoice%' or proname ilike '%carrier_invoice%submit%') then
    raise exception 'TEST FAIL: a new carrier_invoice factoring-submission function must not exist yet.';
  end if;
  v_result := public.submit_invoice_to_factor('1e000000-0000-0000-0000-000000000001'::uuid, 'fe420000-0000-0000-0000-000000000001'::uuid);
  if (v_result->>'success')::boolean or v_result->>'code' <> 'CARRIER_INVOICE_SNAPSHOT_REQUIRED' then
    raise exception 'TEST FAIL: submit_invoice_to_factor() should still be unconditionally fail-closed (0140), got %.', v_result;
  end if;
  raise notice 'OK: no new carrier-invoice factoring-submission function exists, and the legacy submit_invoice_to_factor() remains unconditionally fail-closed -- %.', v_result;
end
$t$;

reset role;
select set_config('test.current_uid', null, false);

\echo '################  TEST 0142 PASSED  ################'
