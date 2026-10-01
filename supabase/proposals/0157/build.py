#!/usr/bin/env python3
"""Generator for the verification/rollback files of proposal 0157 (F-08, carrier-invoice factoring). proposed_0157.sql is hand-maintained; the other files are generated.
`python3 build.py` writes; `--check` verifies (and that proposed_0157.sql exists)."""
import hashlib
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("b0154", HERE.parent / "0154" / "build.py")
b0154 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b0154)
VERDICT = b0154.VERDICT
PUB = ["public.preview_carrier_invoice_factoring(uuid)", "public.submit_carrier_invoice_to_factor(uuid,text)", "public.withdraw_carrier_invoice_factoring_submission(uuid,text,text)", "public.set_carrier_factoring_submitter(uuid,uuid,boolean,text,text)",
       "public.preview_carrier_invoice_issuance(uuid,uuid[],text,uuid)", "public.create_carrier_invoice_draft_from_loads(uuid,uuid[],text,uuid,text)", "public.mark_carrier_invoice_ready_for_issue(uuid,timestamptz,text)", "public.discard_carrier_invoice_draft(uuid,timestamptz,text,text)",
       "public.issue_prepared_carrier_invoice(uuid,timestamptz,text,text)", "public.preview_carrier_invoice_reissue(uuid)", "public.reissue_carrier_invoice(uuid,timestamptz,text,text)"]
INT = ["public._cif_refuse_0157(uuid,uuid,text,uuid,uuid,text,text,jsonb,boolean)", "public._cif_authorize_0157(uuid,uuid,uuid)", "public._cif_evaluate_0157(uuid,uuid,uuid)", "public.verify_carrier_invoice_factoring_audit_chain_0157()",
       "public._cif_freeze_0157(uuid)", "public._cif_diff_frozen_0157(jsonb,jsonb)", "public._cif_selection_0157(uuid,uuid,uuid,uuid[],text,uuid,uuid)", "public._cif_create_draft_0157(uuid,uuid,uuid,uuid[],text,uuid,text)",
       "public._cif_dispatch_fee_0157(uuid,uuid,uuid,uuid,uuid[],uuid)", "public._cif_reissue_eval_0157(uuid,uuid,uuid)", "public._cif_issuance_guard_0157()",
       "public._cif_audit_chain_0157()", "public._cif_immutable_0157()", "public._cif_submission_guard_0157()", "public._cif_snapshot_guard_0157()", "public._cif_gate_guard_0157()", "public._cif_gate_audit_0157()"]
TABLES = ["carrier_invoice_factoring_gate_0157", "carrier_factoring_submitter_grants_0157", "carrier_invoice_factoring_submissions_0157", "carrier_invoice_factoring_snapshots_0157", "carrier_invoice_factoring_audit_0157",
          "carrier_invoice_issuance_terms_0157", "carrier_invoice_workflow_ops_0157", "carrier_invoice_billable_ledger_0157", "carrier_invoice_reissues_0157", "carrier_invoice_dispatch_fee_links_0157"]
NAMES = ", ".join(f"'{p.split('(')[0].split('.')[1]}'" for p in PUB) + ", 'verify_carrier_invoice_factoring_audit_chain_0157'"
HELPERS = ", ".join(f"'{p.split('(')[0].split('.')[1]}'" for p in INT if "guard" not in p and "immutable" not in p and "audit_chain" not in p and "gate_" not in p and "verify" not in p and "diff" not in p)
HEAD = """-- {name}
-- PROPOSAL 0157 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 -> 0155 -> (0156 optional, superseded) -> 0157 (this); unrelated 0148 -> 0153 or 0158+. Finding F-08 (carrier invoices).
"""
VER = HEAD + """-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "{tag} FAIL ...") whose text is the complete report.
"""


def vals(lst, extra=""):
    return ", ".join(f"({i + 1}, '{s}'{extra})" for i, s in enumerate(lst))


def preflight():
    return VER.format(name="preflight.sql", tag="PREFLIGHT 0157") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'proposal 0155 is applied (strict evidence + review table)', case when to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is not null and to_regclass('public.carrier_inference_review_0155') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'PRECONDITION', 'carrier invoice tables and the readiness classifier exist', case when to_regclass('public.carrier_invoices') is not null and to_regclass('public.carrier_invoice_issuance_snapshots') is not null and to_regclass('public.carrier_invoice_line_items') is not null and to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'PRECONDITION', 'no function with a 0157 name exists in ANY schema (no overload / twin)', case when not exists (select 1 from pg_proc p where p.proname in ({NAMES}) or p.proname like '\\_cif\\_%' escape '\\') then 'PASS' else 'FAIL' end, (select count(*)::text from pg_proc p where p.proname like '%carrier_invoice_to_factor%' or p.proname like '\\_cif\\_%' escape '\\') || ' matching'
  union all select 113, 'PRECONDITION', 'no 0157 table exists yet', case when {" and ".join(f"to_regclass('public.{t}') is null" for t in TABLES)} then 'PASS' else 'FAIL' end, 'catalog'
  union all select 114, 'PRECONDITION', 'the legacy 0156 gate (if installed) is DISABLED (D-08b)', case when to_regclass('public.factoring_submission_gate') is null then 'PASS' else case when (xpath('/row/e/text()', query_to_xml('select exists (select 1 from public.factoring_submission_gate where enabled) as e', false, true, '')))[1]::text = 'false' then 'PASS' else 'FAIL' end end, coalesce(to_regclass('public.factoring_submission_gate')::text, '0156 not installed')
  union all select 120, 'DATA (informational)', 'carrier_invoices total / issued / freight / dispatch-service', 'INFO', (select count(*)::text || ' / ' || count(*) filter (where issuance_status = 'issued')::text || ' / ' || count(*) filter (where invoice_document_type = 'carrier_freight_invoice')::text || ' / ' || count(*) filter (where invoice_document_type = 'dispatch_service_invoice')::text from public.carrier_invoices)
  union all select 121, 'DATA (informational)', 'factored carriers with 0 or 2+ active default relationships (their invoices would be refused: NO_ACTIVE_DEFAULT_RELATIONSHIP / MULTIPLE_DEFAULT_RELATIONSHIPS)', 'INFO', (select count(*)::text from public.carriers c where c.factoring_mode::text = 'factored' and (select count(*) from public.factoring_relationships r where r.carrier_id = c.id and r.is_default and r.is_active) <> 1)
  union all select 122, 'DATA (informational)', 'pending 0155 reviews / open factoring exception records (both must be 0 before the gate may be enabled: D-08i)', 'INFO', (select count(*)::text from public.carrier_inference_review_0155 where decision_status = 'pending' and classification <> 'supported') || ' / ' || (select count(*)::text from public.unresolved_carrier_records where status = 'unresolved' and record_type in ('factoring_relationship', 'factored_invoice'))
),
""" + VERDICT.format(tag="PREFLIGHT 0157", what="0155 applied, no 0157 object, legacy gate disabled")


def post_apply():
    fk = "select count(*) from pg_constraint k where k.contype = 'f' and k.confdeltype <> 'r' and k.conrelid in (" + ", ".join(f"'public.{t}'::regclass" for t in TABLES) + ")"
    return VER.format(name="post_apply.sql", tag="POST-APPLY 0157") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'all 0157 tables exist', case when {" and ".join(f"to_regclass('public.{t}') is not null" for t in TABLES)} then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'STATE', 'exactly the eleven public RPCs and the reviewed internal functions exist, once each (no overload)', case when (select count(*) from pg_proc p where p.proname in ({NAMES}) or p.proname like '\\_cif\\_%' escape '\\') = 28 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'STATE', 'every 0157 function is SECURITY DEFINER-or-trigger with a pinned search_path (pg_catalog, pg_temp)', case when not exists (select 1 from pg_proc p where (p.proname in ({NAMES}) or p.proname like '\\_cif\\_%' escape '\\') and p.proconfig::text is distinct from '{{"search_path=pg_catalog, pg_temp"}}') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 113, 'STATE', 'the eleven RPCs and the non-trigger helpers are SECURITY DEFINER', case when not exists (select 1 from pg_proc p where (p.proname in ({NAMES}, {HELPERS})) and not p.prosecdef) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120 + g.n, 'ACL', g.sig || ' EXECUTE: ' || g.who, case when coalesce(case g.who when 'PUBLIC' then (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure(g.sig)) else has_function_privilege(g.who, to_regprocedure(g.sig), 'execute') end, true) = g.want then 'PASS' else 'FAIL' end, 'want ' || g.want::text
  from (values {", ".join(f"({i * 4 + 1}, '{s}', 'anon', false), ({i * 4 + 2}, '{s}', 'service_role', false), ({i * 4 + 3}, '{s}', 'PUBLIC', false), ({i * 4 + 4}, '{s}', 'authenticated', true)" for i, s in enumerate(PUB))},
                {", ".join(f"({100 + i * 4 + 1}, '{s}', 'anon', false), ({100 + i * 4 + 2}, '{s}', 'service_role', false), ({100 + i * 4 + 3}, '{s}', 'PUBLIC', false), ({100 + i * 4 + 4}, '{s}', 'authenticated', false)" for i, s in enumerate(INT[:11]))}) g(n, sig, who, want)
  union all select 300, 'ACL', 'tables: anon and service_role have NO privilege; authenticated has SELECT only (RLS); the gate is unreachable by every client role',
         case when not exists (select 1 from information_schema.role_table_grants g where g.table_schema = 'public' and g.table_name in ({", ".join(f"'{t}'" for t in TABLES)}) and (g.grantee in ('anon', 'service_role', 'PUBLIC') or (g.grantee = 'authenticated' and g.privilege_type <> 'SELECT') or (g.grantee = 'authenticated' and g.table_name = 'carrier_invoice_factoring_gate_0157'))) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 301, 'INTEGRITY', 'RLS is enabled on every 0157 table', case when (select count(*) from pg_class c where c.oid in ({", ".join(f"'public.{t}'::regclass" for t in TABLES)}) and c.relrowsecurity) = {len(TABLES)} then 'PASS' else 'FAIL' end, 'catalog'
  union all select 302, 'INTEGRITY', 'NO foreign key of any 0157 table cascades, nulls or defaults on delete (all RESTRICT): no history can be silently deleted', case when ({fk}) = 0 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 303, 'INTEGRITY', 'immutability triggers exist: audit (update/delete/truncate), snapshots (update/delete/truncate), submissions (delete/truncate/guard), grants (delete), gate (insert/delete)', case when (select count(*) from pg_trigger t where not t.tgisinternal and t.tgrelid in ({", ".join(f"'public.{t}'::regclass" for t in TABLES)})) = 27 then 'PASS' else 'FAIL' end, (select count(*)::text from pg_trigger t where not t.tgisinternal and t.tgrelid in ({", ".join(f"'public.{t}'::regclass" for t in TABLES)})) || ' triggers'
  union all select 304, 'INTEGRITY', 'one live submission per carrier invoice is enforced by a partial unique index; the idempotency key is unique per organization', case when exists (select 1 from pg_indexes where indexname = 'carrier_invoice_factoring_submissions_0157_one_active' and indexdef ilike '%where%submitted%' and indexdef not ilike '%funded%') and exists (select 1 from pg_constraint where conname = 'carrier_invoice_factoring_submissions_0157_key' and contype = 'u') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 305, 'INTEGRITY', 'the audit hash chain verifies (0 broken links)', case when public.verify_carrier_invoice_factoring_audit_chain_0157() = 0 then 'PASS' else 'FAIL' end, public.verify_carrier_invoice_factoring_audit_chain_0157()::text || ' broken'
  union all select 306, 'STATE', 'the gate row exists once (INFO whether enabled; enabling requires a decision reference)', case when (select count(*) from public.carrier_invoice_factoring_gate_0157) = 1 and not (select enabled and (decision_ref is null or btrim(decision_ref) = '') from public.carrier_invoice_factoring_gate_0157) then 'PASS' else 'FAIL' end, coalesce((select enabled::text || ' / ' || coalesce(decision_ref, '-') from public.carrier_invoice_factoring_gate_0157), 'no row')
  union all select 307, 'STATE', 'submission statuses are exactly submitted / withdrawn (D-57e: no rejected / funded state exists)', case when exists (select 1 from pg_constraint where conrelid = 'public.carrier_invoice_factoring_submissions_0157'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%submitted%withdrawn%' and pg_get_constraintdef(oid) not ilike '%rejected%' and pg_get_constraintdef(oid) not ilike '%funded%') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 308, 'DATA (informational)', 'submissions / snapshots / audit rows / grants', 'INFO', (select count(*)::text from public.carrier_invoice_factoring_submissions_0157) || ' / ' || (select count(*)::text from public.carrier_invoice_factoring_snapshots_0157) || ' / ' || (select count(*)::text from public.carrier_invoice_factoring_audit_0157) || ' / ' || (select count(*)::text from public.carrier_factoring_submitter_grants_0157)
  union all select 310, 'INTEGRITY', 'a billable record (load) is on at most one LIVE invoice: the partial unique index on the ledger exists', case when exists (select 1 from pg_indexes where indexname = 'carrier_invoice_billable_ledger_0157_live' and indexdef ilike '%unique%' and indexdef ilike '%where%released_at is null%') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 311, 'INTEGRITY', 'every issuance-terms fingerprint verifies (sha-256 of the frozen facts)', case when not exists (select 1 from public.carrier_invoice_issuance_terms_0157 t where t.frozen_fingerprint <> encode(sha256(convert_to(t.frozen::text, 'UTF8')), 'hex')) then 'PASS' else 'FAIL' end, 'rows'
  union all select 312, 'INTEGRITY', 'no live ledger row belongs to a voided invoice; every reissue link joins a voided original to an issued replacement', case when not exists (select 1 from public.carrier_invoice_billable_ledger_0157 g join public.carrier_invoices c on c.id = g.invoice_id where g.released_at is null and c.issuance_status::text = 'voided')
         and not exists (select 1 from public.carrier_invoice_reissues_0157 r join public.carrier_invoices o on o.id = r.original_invoice_id join public.carrier_invoices n on n.id = r.replacement_invoice_id where o.issuance_status::text <> 'voided' or n.issuance_status::text <> 'issued') then 'PASS' else 'FAIL' end, 'rows'
  union all select 313, 'DATA (informational)', 'issuance-terms / ledger rows (live) / reissues / dispatch-fee links / workflow ops', 'INFO', (select count(*)::text from public.carrier_invoice_issuance_terms_0157) || ' / ' || (select count(*)::text from public.carrier_invoice_billable_ledger_0157 where released_at is null) || ' / ' || (select count(*)::text from public.carrier_invoice_reissues_0157) || ' / ' || (select count(*)::text from public.carrier_invoice_dispatch_fee_links_0157) || ' / ' || (select count(*)::text from public.carrier_invoice_workflow_ops_0157)
  union all select 309, 'INTEGRITY', 'every submission has exactly one snapshot', case when not exists (select 1 from public.carrier_invoice_factoring_submissions_0157 s where (select count(*) from public.carrier_invoice_factoring_snapshots_0157 x where x.submission_id = s.id) <> 1) then 'PASS' else 'FAIL' end, 'rows'
),
""" + VERDICT.format(tag="POST-APPLY 0157", what="carrier-invoice factoring installed; gate state as recorded")


def rollback():
    drops = "\n".join(f"drop function if exists {s};" for s in ["public.submit_carrier_invoice_to_factor(uuid,text)", "public.preview_carrier_invoice_factoring(uuid)", "public.withdraw_carrier_invoice_factoring_submission(uuid,text,text)", "public.set_carrier_factoring_submitter(uuid,uuid,boolean,text,text)",
                                                                       "public._cif_evaluate_0157(uuid,uuid,uuid)", "public._cif_authorize_0157(uuid,uuid,uuid)", "public._cif_refuse_0157(uuid,uuid,text,uuid,uuid,text,text,jsonb,boolean)"]
                                                                      + [p for p in PUB[4:]] + [p for p in INT[4:10]])
    return HEAD.format(name="rollback.sql -- EMERGENCY switch-off of proposal 0157 (history is PRESERVED)") + f"""-- Removes the RPCs, the helper functions and the gate: NEW submissions become impossible immediately. HISTORY IS PRESERVED: submissions, immutable snapshots, the audit ledger and submitter grants are KEPT (with their
-- immutability triggers and trigger functions) whenever any of them holds a row; they are dropped only if ALL are empty. Existing carrier invoices, relationships and legacy factored invoices are never touched.
-- REFUSES (nothing changed) unless the reviewed 0157 objects are present. A later re-application while the tables are kept requires a reviewed manual step. Single transaction; run once.
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regclass('public.carrier_invoice_factoring_gate_0157') is null or to_regprocedure('public.submit_carrier_invoice_to_factor(uuid,text)') is null then raise exception 'ROLLBACK 0157 REFUSED: the 0157 gate or RPC is missing (not applied or already rolled back). Nothing changed.'; end if;
end
$mig$;
{drops}
drop table public.carrier_invoice_factoring_gate_0157;
drop function if exists public._cif_gate_audit_0157();
drop function if exists public._cif_gate_guard_0157();
do $mig$
declare v_keep boolean;
begin
  v_keep := exists (select 1 from public.carrier_invoice_factoring_submissions_0157) or exists (select 1 from public.carrier_invoice_factoring_snapshots_0157) or exists (select 1 from public.carrier_invoice_factoring_audit_0157) or exists (select 1 from public.carrier_factoring_submitter_grants_0157)
    or exists (select 1 from public.carrier_invoice_issuance_terms_0157) or exists (select 1 from public.carrier_invoice_workflow_ops_0157) or exists (select 1 from public.carrier_invoice_billable_ledger_0157) or exists (select 1 from public.carrier_invoice_reissues_0157) or exists (select 1 from public.carrier_invoice_dispatch_fee_links_0157);
  if not v_keep then
    drop table public.carrier_invoice_dispatch_fee_links_0157;
    drop table public.carrier_invoice_reissues_0157;
    drop table public.carrier_invoice_billable_ledger_0157;
    drop table public.carrier_invoice_workflow_ops_0157;
    drop table public.carrier_invoice_issuance_terms_0157;
    drop table public.carrier_invoice_factoring_snapshots_0157;
    drop table public.carrier_invoice_factoring_submissions_0157;
    drop table public.carrier_factoring_submitter_grants_0157;
    drop table public.carrier_invoice_factoring_audit_0157;
    drop function public.verify_carrier_invoice_factoring_audit_chain_0157();
    drop function public._cif_issuance_guard_0157();
    drop function public._cif_snapshot_guard_0157();
    drop function public._cif_submission_guard_0157();
    drop function public._cif_immutable_0157();
    drop function public._cif_audit_chain_0157();
    raise notice 'ROLLBACK 0157 complete: all 0157 objects removed (no history existed).';
  else
    raise notice 'ROLLBACK 0157 complete: RPCs and gate removed; HISTORY KEPT (submissions, snapshots, audit ledger, grants, issuance terms, billable ledger, reissue and dispatch-fee links, workflow ops) with their immutability triggers.';
  end if;
end
$mig$;
commit;
"""


def all_files():
    return {"preflight.sql": preflight(), "post_apply.sql": post_apply(), "rollback.sql": rollback()}


if __name__ == "__main__":
    files = all_files()
    if "--check" in sys.argv:
        bad = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t] + ([] if (HERE / "proposed_0157.sql").exists() else ["proposed_0157.sql"])
        print("generated files are current" if not bad else "STALE: " + ", ".join(bad))
        sys.exit(1 if bad else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {hashlib.sha256(t.encode()).hexdigest()[:16]})")
