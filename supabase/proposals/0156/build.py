#!/usr/bin/env python3
"""Generator for proposal 0156 (F-08: factoring submission restored ONLY under strict carrier-specific conditions, DISABLED BY DEFAULT). Standard library only.
The reviewed baseline (the 0140 universal-rejection function) is EXTRACTED from supabase/migrations/0140_factoring_authorization_and_submission_safety.sql. `python3 build.py` writes; `--check` verifies."""
import hashlib
import importlib.util
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
spec = importlib.util.spec_from_file_location("b0154", HERE.parent / "0154" / "build.py")
b0154 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b0154)
SIG = "public.submit_invoice_to_factor(uuid,uuid)"
HEAD = """-- {name}
-- PROPOSAL 0156 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 -> 0155 -> 0156 (this). The unrelated proposal 0148 MUST be renumbered to 0153 (unused) or to 0157 or higher, never 0154-0156. Finding F-08.
-- *** SUPERSEDED FOR PRODUCTION USE by proposal 0157 (carrier invoices). NOT PROMOTABLE FOR LEGACY INVOICES: Owner decisions D-08a/D-08b (0156/OWNER_DECISIONS.md) exclude legacy `invoices` from automatic
-- *** factoring. This file is kept, with its tests, as history; its gate stays DISABLED and must never be enabled. ***
"""


def baseline():
    s = (SUPA / "migrations" / "0140_factoring_authorization_and_submission_safety.sql").read_text()
    m = re.search(r"(create function public\.submit_invoice_to_factor\(.*?\n\$\$;)", s, re.S)
    block = m.group(1)
    body = re.search(r"\bas \$\$(.*?)\$\$;", block, re.S).group(1)
    return block, body


def facts():
    block, body = baseline()
    return {"base_block": block, "base_md5": b0154.norm_md5(body)}


NEW_FUNCTION = r"""create or replace function public.submit_invoice_to_factor(
  p_invoice_id uuid,
  p_relationship_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_org_id uuid;
  v_gate record;
  v_invoice record;
  v_existing record;
  v_ev jsonb;
  v_carrier uuid;
  v_rel record;
  v_company_active boolean;
  v_mode text;
  v_readiness jsonb;
  v_face_value numeric(10, 2);
  v_advance_amount numeric(10, 2);
  v_fee_amount numeric(10, 2);
  v_reserve_amount numeric(10, 2);
  v_other_fees numeric(10, 2);
  v_funding_amount numeric(10, 2);
  v_new_id uuid;
begin
  -- 1. identity, organization, role (raise exactly as 0140 does; the application maps these messages)
  if v_uid is null then raise exception 'No organization on this account.'; end if;
  v_org_id := public.current_org_id();
  if v_org_id is null then raise exception 'No organization on this account.'; end if;
  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to submit invoices for factoring.';
  end if;

  -- 2. serialise every attempt for this invoice (as 0075/0140)
  perform pg_advisory_xact_lock(pg_catalog.hashtext('factoring_submission:' || p_invoice_id::text));

  select inv.id, inv.organization_id, inv.status, inv.amount_paid, inv.total_amount, inv.broker_id, inv.customer_id
    into v_invoice from public.invoices inv where inv.id = p_invoice_id;
  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then raise exception 'Invoice not found.'; end if;
  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then raise exception 'This invoice is not eligible for factoring.'; end if;

  -- 3. idempotency: an invoice with a live (non-terminal) submission is never submitted twice; the answer names the existing row, nothing is written
  select fi.id, fi.status into v_existing from public.factored_invoices fi where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled') limit 1;
  if v_existing.id is not null then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'ALREADY_SUBMITTED', 'factored_invoice_id', v_existing.id, 'status', v_existing.status,
      'message', 'This invoice has already been submitted to a factor.');
  end if;

  -- 4. THE GATE. Disabled by default: the answer is then byte-for-byte the 0140 rejection. Enabled only by the Owner's recorded decision (see OWNER_DECISIONS.md).
  select g.enabled, g.decision_ref into v_gate from public.factoring_submission_gate g where g.singleton;
  if not found or not v_gate.enabled then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'CARRIER_INVOICE_SNAPSHOT_REQUIRED', 'snapshot_required', true,
      'message', 'This invoice was created before carrier-specific financial snapshots were enabled. Review and reissue it through the new invoice workflow.');
  end if;

  -- 5. recipient routing must be unambiguous: exactly one of broker / customer
  if (v_invoice.broker_id is null) = (v_invoice.customer_id is null) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'RECIPIENT_AMBIGUOUS', 'message', 'This invoice must have exactly one recipient (a broker or a customer) before it can be factored.');
  end if;

  -- 6. the invoice must belong to EXACTLY ONE valid carrier, proven by strict evidence (0155); anything else is refused, never repaired
  v_ev := public.carrier_evidence_for_invoice(p_invoice_id);
  if v_ev ->> 'status' <> 'proven' then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'CARRIER_EVIDENCE_NOT_PROVEN', 'evidence_status', v_ev ->> 'status',
      'message', 'The carrier for this invoice is not proven by strict evidence, so it cannot be factored. An owner or admin must resolve it first.');
  end if;
  v_carrier := (v_ev ->> 'carrier_id')::uuid;

  -- 7. the relationship: same organization, THIS carrier's own active default (no generic/global factor is ever selected), effective today, company active
  select rel.id, rel.organization_id, rel.carrier_id, rel.factoring_company_id, rel.is_active, rel.is_default, rel.default_advance_percentage, rel.default_factoring_fee_percentage,
         rel.default_reserve_percentage, rel.fee_timing, rel.other_fee_default, rel.effective_from, rel.effective_to
    into v_rel from public.factoring_relationships rel where rel.id = p_relationship_id for update;
  if v_rel.id is null or v_rel.organization_id <> v_org_id then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'RELATIONSHIP_NOT_AVAILABLE', 'message', 'This factoring relationship is not available.');
  end if;
  if v_rel.carrier_id is null or v_rel.carrier_id <> v_carrier then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'RELATIONSHIP_CARRIER_MISMATCH', 'message', 'This factoring relationship does not belong to the carrier of this invoice.');
  end if;
  if not v_rel.is_active or not v_rel.is_default then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_CARRIER_DEFAULT', 'message', 'Only the carrier''s own active default factoring relationship can be used.');
  end if;
  if v_rel.effective_from > current_date or (v_rel.effective_to is not null and v_rel.effective_to < current_date) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'RELATIONSHIP_NOT_EFFECTIVE', 'message', 'The selected factoring relationship is not currently effective.');
  end if;
  select comp.is_active into v_company_active from public.factoring_companies comp where comp.id = v_rel.factoring_company_id and comp.organization_id = v_org_id;
  if not coalesce(v_company_active, false) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'COMPANY_INACTIVE', 'message', 'The selected factoring company is inactive.');
  end if;

  -- 8. the carrier's own policy and the authoritative readiness classifier (recipient party eligibility, NOA, remittance, integration, exceptions)
  select c.factoring_mode::text into v_mode from public.carriers c where c.id = v_carrier and c.organization_id = v_org_id and c.is_active;
  if v_mode is distinct from 'factored' then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'POLICY_NOT_FACTORED', 'message', 'This carrier is not configured for factoring.');
  end if;
  v_readiness := public.classify_carrier_factoring_readiness(v_carrier, v_invoice.broker_id, v_invoice.customer_id);
  if v_readiness ->> 'classification' is distinct from 'ready' or (v_readiness ->> 'relationship_id')::uuid is distinct from p_relationship_id then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_READY', 'classification', v_readiness ->> 'classification', 'message', 'This carrier is not ready to factor this invoice.');
  end if;

  -- 9. no open exception on the relationship or the invoice; no pending 0155 review of the relationship
  if exists (select 1 from public.unresolved_carrier_records u where u.status = 'unresolved' and u.organization_id = v_org_id
              and ((u.record_type = 'factoring_relationship' and u.record_id = p_relationship_id) or (u.record_type = 'invoice' and u.record_id = p_invoice_id)))
     or exists (select 1 from public.carrier_inference_review_0155 v where v.relationship_id = p_relationship_id and v.decision_status = 'pending' and v.classification <> 'supported') then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'UNRESOLVED_LEGACY_RECORD', 'message', 'An unresolved legacy carrier record exists for this invoice or relationship; an owner or admin must resolve it first.');
  end if;

  -- 10. amounts: FACE VALUE IS THE INVOICE TOTAL ONLY. Dispatch-service fees are a separate receivable (carrier -> dispatcher) and are never netted from, added to or read by factor proceeds here.
  v_face_value := v_invoice.total_amount;
  v_advance_amount := round(v_face_value * v_rel.default_advance_percentage / 100, 2);
  v_fee_amount := round(v_face_value * v_rel.default_factoring_fee_percentage / 100, 2);
  v_reserve_amount := round(v_face_value * v_rel.default_reserve_percentage / 100, 2);
  v_other_fees := coalesce(v_rel.other_fee_default, 0);
  v_funding_amount := v_advance_amount - v_other_fees - (case when v_rel.fee_timing = 'deducted_at_funding' then v_fee_amount else 0 end);
  if v_funding_amount < 0 then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'NEGATIVE_FUNDING', 'message', 'Estimated funding amount for this invoice would be negative under the selected relationship''s terms.');
  end if;

  insert into public.factored_invoices (
    organization_id, invoice_id, factoring_company_id, factoring_relationship_id, status, submitted_at, submitted_by,
    invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount,
    reserve_percentage, reserve_amount, other_fees, fee_timing, expected_funding_amount
  ) values (
    v_org_id, p_invoice_id, v_rel.factoring_company_id, p_relationship_id, 'submitted', now(), v_uid,
    v_face_value, v_rel.default_advance_percentage, v_advance_amount, v_rel.default_factoring_fee_percentage, v_fee_amount,
    v_rel.default_reserve_percentage, v_reserve_amount, v_other_fees, v_rel.fee_timing, v_funding_amount
  ) returning id into v_new_id;

  insert into public.factoring_events (organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by)
  values (v_org_id, v_new_id, 'submitted', null, 'submitted', v_uid);

  -- the immutable, database-issued snapshot of what was PROVEN and APPROVED at the moment of submission
  insert into public.factored_invoice_carrier_snapshot_0156 (factored_invoice_id, invoice_id, organization_id, carrier_id, relationship_id, factoring_company_id, broker_id, customer_id, readiness, evidence, gate_decision_ref, submitted_by)
  values (v_new_id, p_invoice_id, v_org_id, v_carrier, p_relationship_id, v_rel.factoring_company_id, v_invoice.broker_id, v_invoice.customer_id, v_readiness, v_ev, v_gate.decision_ref, v_uid);

  return pg_catalog.jsonb_build_object('success', true, 'factored_invoice_id', v_new_id, 'status', 'submitted', 'carrier_id', v_carrier);
end;
$$;"""

TABLES = """create table public.factoring_submission_gate (
  singleton    boolean primary key default true check (singleton),
  enabled      boolean not null default false,
  decision_ref text,
  changed_by   text,
  changed_at   timestamptz,
  constraint factoring_submission_gate_needs_decision check (not enabled or (decision_ref is not null and pg_catalog.btrim(decision_ref) <> ''))
);
insert into public.factoring_submission_gate (singleton, enabled) values (true, false);
alter table public.factoring_submission_gate enable row level security;
revoke all on public.factoring_submission_gate from anon, authenticated, service_role;
comment on table public.factoring_submission_gate is '0156: single-row switch. enabled=false (default) keeps the 0140 universal rejection. It is set true ONLY by the operator (SQL Editor) after the Owner answers OWNER_DECISIONS.md and records the decision reference; no client role has any privilege on it.';

create table public.factored_invoice_carrier_snapshot_0156 (
  factored_invoice_id   uuid primary key references public.factored_invoices (id) on delete restrict,
  invoice_id            uuid not null references public.invoices (id) on delete restrict,
  organization_id       uuid not null references public.organizations (id) on delete restrict,
  carrier_id            uuid not null references public.carriers (id) on delete restrict,
  relationship_id       uuid not null references public.factoring_relationships (id) on delete restrict,
  factoring_company_id  uuid not null references public.factoring_companies (id) on delete restrict,
  broker_id             uuid,
  customer_id           uuid,
  readiness             jsonb not null,
  evidence              jsonb not null,
  gate_decision_ref     text not null,
  submitted_by          uuid,
  submitted_at          timestamptz not null default now()
);
create function public.factored_invoice_carrier_snapshot_0156_immutable() returns trigger language plpgsql set search_path = pg_catalog, pg_temp as
$t$ begin raise exception 'factored_invoice_carrier_snapshot_0156 rows are immutable (historical record).' using errcode = '42501'; end $t$;
create trigger factored_invoice_carrier_snapshot_0156_immutable before update or delete on public.factored_invoice_carrier_snapshot_0156 for each row execute function public.factored_invoice_carrier_snapshot_0156_immutable();
alter table public.factored_invoice_carrier_snapshot_0156 enable row level security;
create policy factored_invoice_carrier_snapshot_0156_select on public.factored_invoice_carrier_snapshot_0156 for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
revoke all on public.factored_invoice_carrier_snapshot_0156 from anon, authenticated, service_role;
grant select on public.factored_invoice_carrier_snapshot_0156 to authenticated;
revoke all on function public.factored_invoice_carrier_snapshot_0156_immutable() from public, anon, authenticated, service_role;"""


def proposed(f):
    return HEAD.format(name="proposed_0156.sql -- F-08: strict, carrier-specific factoring submission behind a disabled-by-default gate") + f"""--
-- ROOT CAUSE (traced): 0140 replaced submit_invoice_to_factor() with an UNCONDITIONAL rejection on purpose (Phase 3B.1.5: a live join through dispatch/load is not a frozen financial record) and said a
-- future invoice-issuance migration would replace it. 0142-0147 built carrier_invoices (a real issuance snapshot) but 0144 states it adds NO bridge to factoring: factored_invoices.invoice_id still
-- references the LEGACY invoices table, and the application has NO call site for carrier_invoices at all (grep of src/: none). So: intentional temporary gate + missing follow-up migration + a
-- contradiction between the rejection message ("reissue through the new invoice workflow") and an application that has no such workflow.
-- WHAT THIS DOES: replaces submit_invoice_to_factor(uuid,uuid) (same signature and jsonb return) with a strict implementation that runs ONLY when public.factoring_submission_gate.enabled = true.
-- The gate is created DISABLED, so applying this migration changes no behaviour: the function then returns exactly the 0140 rejection. Enabling is an operator action after the Owner answers
-- OWNER_DECISIONS.md (decision reference recorded). When enabled, a submission succeeds ONLY if: authenticated owner/admin/dispatcher/accountant of the invoice's organization; invoice sent/viewed and unpaid;
-- not already submitted; exactly one recipient; the invoice's carrier is PROVEN by strict evidence (0155); the relationship is that carrier's OWN active default in the same organization, effective today,
-- company active; the carrier is factored and classify_carrier_factoring_readiness() says 'ready' for this carrier+recipient and names this relationship; no open exception/review on the relationship or invoice.
-- It writes a factored_invoices row, an event and an immutable carrier snapshot. It never reads or nets dispatch fees, never repairs an ambiguous row, never selects a factor.
-- Refuses (nothing changed) unless 0155 is applied, the live function is exactly the reviewed 0140 body, and the ACL/owner are as reviewed. One transaction.
begin;
set local lock_timeout = '15s';
do $mig$
declare v_md5 text;
begin
  if to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is null or to_regclass('public.carrier_inference_review_0155') is null then raise exception '0156 precondition: proposal 0155 (strict carrier evidence) is not applied. STOP.'; end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then raise exception '0156 precondition: classify_carrier_factoring_readiness missing. STOP.'; end if;
  if to_regclass('public.factoring_submission_gate') is not null or to_regclass('public.factored_invoice_carrier_snapshot_0156') is not null then raise exception '0156 precondition: a 0156 object already exists -- already applied? STOP.'; end if;
  if (select count(*) from pg_proc where proname = 'submit_invoice_to_factor') <> 1 then raise exception '0156 precondition: expected exactly one submit_invoice_to_factor (any schema); found an overload. STOP.'; end if;
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure('{SIG}');
  if v_md5 is distinct from '{f['base_md5']}' then raise exception '0156 precondition: live submit_invoice_to_factor (md5 %) is not the reviewed 0140 universal-rejection definition. STOP.', v_md5; end if;
  if (select pg_get_userbyid(p.proowner) in ('anon', 'authenticated', 'service_role', 'authenticator') or not pg_has_role(current_user, p.proowner, 'usage') from pg_proc p where p.oid = to_regprocedure('{SIG}')) then raise exception '0156 precondition: unexpected function owner. STOP.'; end if;
  if position('v_doc_snapshot_file_name' in (select prosrc from pg_proc where oid = to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)'))) = 0 then raise exception '0156 precondition: approve_factoring_relationship_noa is not the 0140 corrected version (finding F-07). STOP.'; end if;
  create temp table _mig0156_snap on commit drop as select (select count(*) from public.factored_invoices) as n_fi, (select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f) as fi_digest;
  raise notice '0156 PHASE 1 preconditions passed.';
end
$mig$;

{TABLES}

{NEW_FUNCTION}

revoke all on function {SIG} from public, anon, service_role;
grant execute on function {SIG} to authenticated;
comment on function {SIG} is '0156: strict carrier-specific factoring submission behind public.factoring_submission_gate (disabled by default: identical to the 0140 rejection). SECURITY DEFINER with its own organization/role checks; explicit ACL: authenticated only.';

do $mig$
declare s record;
begin
  select * into s from _mig0156_snap;
  if (select count(*) from public.factoring_submission_gate) <> 1 or (select enabled from public.factoring_submission_gate) then raise exception '0156 postcondition: the gate must exist once and be DISABLED at apply.'; end if;
  if (select count(*) from public.factored_invoices) <> s.n_fi or (select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f) <> s.fi_digest then raise exception '0156 postcondition: factored_invoices changed (0156 never writes historical rows).'; end if;
  if has_function_privilege('anon', '{SIG}', 'execute') or has_function_privilege('service_role', '{SIG}', 'execute') or not has_function_privilege('authenticated', '{SIG}', 'execute')
     or (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure('{SIG}')) then
    raise exception '0156 postcondition: submit_invoice_to_factor ACL is not authenticated-only.';
  end if;
  if has_table_privilege('anon', 'public.factoring_submission_gate', 'SELECT') or has_table_privilege('authenticated', 'public.factoring_submission_gate', 'SELECT') or has_table_privilege('service_role', 'public.factoring_submission_gate', 'UPDATE') then raise exception '0156 postcondition: the gate is reachable by a client role.'; end if;
  raise notice '0156 complete: submit_invoice_to_factor is strict; the gate is DISABLED (behaviour unchanged until the Owner decides).';
end
$mig$;
commit;
"""


VERIFY = """-- {name}
-- PROPOSAL 0156 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0154 -> 0155 -> 0156 (this); unrelated 0148 -> 0153 or 0157+. Finding F-08.
-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "{tag} FAIL ...") whose text is the complete report.
"""


def preflight(f):
    return VERIFY.format(name="preflight.sql", tag="PREFLIGHT 0156") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'proposal 0155 is applied', case when to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null and to_regclass('public.carrier_inference_review_0155') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'PRECONDITION', 'exactly one submit_invoice_to_factor exists (no overload)', case when (select count(*) from pg_proc where proname = 'submit_invoice_to_factor') = 1 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'PRECONDITION', 'live submit_invoice_to_factor is the reviewed 0140 universal-rejection definition', case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) = '{f['base_md5']}' then 'PASS' else 'FAIL' end, 'md5'
  union all select 113, 'PRECONDITION', 'approve_factoring_relationship_noa is the corrected 0140 version (finding F-07: the 0138/0139 versions are weaker or buggy)', case when position('v_doc_snapshot_file_name' in coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)')), '')) > 0 then 'PASS' else 'FAIL' end, 'source marker'
  union all select 114, 'PRECONDITION', 'no 0156 object exists yet', case when to_regclass('public.factoring_submission_gate') is null and to_regclass('public.factored_invoice_carrier_snapshot_0156') is null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 115, 'PRECONDITION', 'classify_carrier_factoring_readiness exists', case when to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'EXPOSURE (informational)', 'submit_invoice_to_factor EXECUTE: anon / authenticated / service_role / PUBLIC', 'INFO', has_function_privilege('anon', to_regprocedure('{SIG}'), 'execute')::text || ' / ' || has_function_privilege('authenticated', to_regprocedure('{SIG}'), 'execute')::text || ' / ' || has_function_privilege('service_role', to_regprocedure('{SIG}'), 'execute')::text || ' / ' || (select (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))::text from pg_proc p where p.oid = to_regprocedure('{SIG}'))
  union all select 121, 'DATA (informational)', 'factored_invoices rows (never modified by 0156)', 'INFO', (select count(*)::text from public.factored_invoices)
),
""" + b0154.VERDICT.format(tag="PREFLIGHT 0156", what="baseline is the reviewed 0140 definition and 0155 is applied")


def post_apply(f):
    return VERIFY.format(name="post_apply.sql", tag="POST-APPLY 0156") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'gate table has exactly one row', case when (select count(*) from public.factoring_submission_gate) = 1 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'STATE', 'gate is DISABLED as applied (INFO if the Owner has since enabled it with a decision reference)', case when (select enabled from public.factoring_submission_gate) then case when (select decision_ref from public.factoring_submission_gate) is not null then 'INFO' else 'FAIL' end else 'PASS' end, coalesce((select enabled::text || ' / ' || coalesce(decision_ref, '-') from public.factoring_submission_gate), 'no row')
  union all select 112, 'STATE', 'submit_invoice_to_factor is SECURITY DEFINER with search_path pg_catalog, pg_temp and returns jsonb', case when (select p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, pg_temp"}}' and p.prorettype = 'jsonb'::regtype from pg_proc p where p.oid = to_regprocedure('{SIG}')) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 113, 'STATE', 'exactly one submit_invoice_to_factor exists', case when (select count(*) from pg_proc where proname = 'submit_invoice_to_factor') = 1 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'ACL', 'submit_invoice_to_factor: EXECUTE for authenticated only (not anon, service_role, PUBLIC)', case when has_function_privilege('authenticated', to_regprocedure('{SIG}'), 'execute') and not has_function_privilege('anon', to_regprocedure('{SIG}'), 'execute') and not has_function_privilege('service_role', to_regprocedure('{SIG}'), 'execute')
                                                                                           and not (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure('{SIG}')) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 121, 'ACL', 'gate table: no privilege for anon, authenticated or service_role', case when not has_table_privilege('anon', 'public.factoring_submission_gate', 'SELECT') and not has_table_privilege('authenticated', 'public.factoring_submission_gate', 'SELECT') and not has_table_privilege('service_role', 'public.factoring_submission_gate', 'SELECT') and not has_table_privilege('authenticated', 'public.factoring_submission_gate', 'UPDATE') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 122, 'ACL', 'snapshot table: authenticated SELECT only (RLS); no write for any client role', case when has_table_privilege('authenticated', 'public.factored_invoice_carrier_snapshot_0156', 'SELECT') and not has_table_privilege('authenticated', 'public.factored_invoice_carrier_snapshot_0156', 'INSERT') and not has_table_privilege('authenticated', 'public.factored_invoice_carrier_snapshot_0156', 'UPDATE') and not has_table_privilege('service_role', 'public.factored_invoice_carrier_snapshot_0156', 'INSERT') and not has_table_privilege('anon', 'public.factored_invoice_carrier_snapshot_0156', 'SELECT') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 123, 'STATE', 'the snapshot table is immutable (update/delete trigger present)', case when exists (select 1 from pg_trigger where tgrelid = 'public.factored_invoice_carrier_snapshot_0156'::regclass and tgname = 'factored_invoice_carrier_snapshot_0156_immutable' and not tgisinternal) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 130, 'DATA (informational)', 'factored_invoices / snapshot rows', 'INFO', (select count(*)::text from public.factored_invoices) || ' / ' || (select count(*)::text from public.factored_invoice_carrier_snapshot_0156)
),
""" + b0154.VERDICT.format(tag="POST-APPLY 0156", what="F-08 candidate installed; gate state as recorded")


def rollback(f):
    block = f["base_block"].replace("create function public.submit_invoice_to_factor(", "create or replace function public.submit_invoice_to_factor(", 1)
    return HEAD.format(name="rollback.sql -- EMERGENCY reversal of proposal 0156 (restores the 0140 universal rejection)") + f"""-- Restores the EXACT 0140 definition (extracted from the migration), its ACL and SECURITY INVOKER, and removes the gate. Historical rows are PRESERVED: submissions already made and their immutable
-- snapshots stay; the snapshot table is dropped ONLY if it is empty (otherwise it is kept and re-applying 0156 requires a reviewed manual step). REFUSES unless the live function is the reviewed 0156 definition.
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regclass('public.factoring_submission_gate') is null then raise exception 'ROLLBACK 0156 REFUSED: gate missing (0156 not applied or already rolled back). Nothing changed.'; end if;
  if position('factored_invoice_carrier_snapshot_0156' in (select prosrc from pg_proc where oid = to_regprocedure('{SIG}'))) = 0 then raise exception 'ROLLBACK 0156 REFUSED: live submit_invoice_to_factor is not the reviewed 0156 definition. Nothing changed.'; end if;
end
$mig$;
{block}
revoke all on function {SIG} from public, anon, service_role;
grant execute on function {SIG} to authenticated;
drop table public.factoring_submission_gate;
do $mig$
begin
  if not exists (select 1 from public.factored_invoice_carrier_snapshot_0156) then
    drop table public.factored_invoice_carrier_snapshot_0156;
    drop function public.factored_invoice_carrier_snapshot_0156_immutable();
  else
    raise notice 'ROLLBACK 0156: the snapshot table holds historical submissions and was KEPT.';
  end if;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{SIG}')) <> '{f['base_md5']}' then raise exception 'ROLLBACK 0156 postcondition: body is not the 0140 baseline.'; end if;
  raise notice 'ROLLBACK 0156 complete: the 0140 universal rejection is restored.';
end
$mig$;
commit;
"""


def all_files():
    f = facts()
    return {"proposed_0156.sql": proposed(f), "preflight.sql": preflight(f), "post_apply.sql": post_apply(f), "rollback.sql": rollback(f)}


if __name__ == "__main__":
    files = all_files()
    if "--check" in sys.argv:
        bad = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t]
        print("generated files are current" if not bad else "STALE: " + ", ".join(bad))
        sys.exit(1 if bad else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {hashlib.sha256(t.encode()).hexdigest()[:16]})")
