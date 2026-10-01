#!/usr/bin/env python3
"""Generator for the verification/rollback files of proposal 0155 (F-01). proposed_0155.sql is hand-maintained (no external baseline to extract); the other files are generated so the
pinned facts (0154 body md5) come from proposals/0154/build.py. `python3 build.py` writes; `--check` verifies (including that proposed_0155.sql exists)."""
import hashlib
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("b0154", HERE.parent / "0154" / "build.py")
b0154 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b0154)
F = b0154.facts()
DEC = "public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)"
HEAD = """-- {name}
-- PROPOSAL 0155 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 -> 0155 (this) -> 0156; unrelated 0148 -> 0153 or 0157+ (never 0154-0156). Finding F-01.
"""
VER = HEAD + """-- READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no transaction control. RESULT: every row INFO or PASS and a final RESULT | PASS row;
-- otherwise the statement RAISES (invalid input syntax for type integer: "{tag} FAIL ...") whose text is the complete report.
"""
VERDICT = b0154.VERDICT


def preflight():
    return VER.format(name="preflight.sql", tag="PREFLIGHT 0155") + f"""with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'proposal 0154 is applied (owner-only exception writer present, fail-closed public function)', case when to_regprocedure('{b0154.TRUSTED_SIG}') is not null and (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('{b0154.SIG}')) = '{F['new_md5']}' then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'PRECONDITION', '0137 provenance table exists', case when to_regclass('public.carrier_backfill_0137_provenance') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'PRECONDITION', 'factoring_relationships.carrier_id and carriers.is_active exist', case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'factoring_relationships' and column_name = 'carrier_id') and exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'carriers' and column_name = 'is_active') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 113, 'PRECONDITION', 'no 0155 object exists yet', case when to_regclass('public.carrier_inference_review_0155') is null and to_regclass('public.carrier_inference_run_0155') is null and to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is null and to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is null and to_regprocedure('public._carrier_inference_apply_0155(text)') is null and to_regprocedure('{DEC}') is null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120, 'DATA (informational)', 'factoring_relationships total / with carrier_id / without carrier_id', 'INFO', (select count(*)::text || ' / ' || count(carrier_id)::text || ' / ' || (count(*) - count(carrier_id))::text from public.factoring_relationships)
  union all select 121, 'DATA (informational)', 'factored_invoices total', 'INFO', (select count(*)::text from public.factored_invoices)
  union all select 122, 'DATA (informational)', 'organizations whose ONLY carrier is inactive (0137 rule R1 would have assigned it; finding F-02)', 'INFO', (select count(*)::text from (select organization_id from public.carriers group by organization_id having count(*) = 1 and bool_and(not is_active)) x)
  union all select 123, 'DATA (informational)', 'open exception rows for factoring_relationship', 'INFO', (select count(*)::text from public.unresolved_carrier_records where record_type = 'factoring_relationship' and status = 'unresolved')
),
""" + VERDICT.format(tag="PREFLIGHT 0155", what="0154 is applied and no 0155 object exists")


def post_apply():
    return VER.format(name="post_apply.sql", tag="POST-APPLY 0155") + f"""with run as (select * from public.carrier_inference_run_0155 order by applied_at desc limit 1),
rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'STATE', 'evidence functions, apply function, decision RPC, review table and run ledger exist', case when to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null and to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is not null and to_regprocedure('public._carrier_inference_apply_0155(text)') is not null and to_regprocedure('{DEC}') is not null and to_regclass('public.carrier_inference_review_0155') is not null and to_regclass('public.carrier_inference_run_0155') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 120 + g.n, 'ACL', g.sig || ' is NOT executable by ' || g.who, case when coalesce(has_function_privilege(g.who, to_regprocedure(g.sig), 'execute'), true) then 'FAIL' else 'PASS' end, 'explicit REVOKE'
  from (values (1, 'public.carrier_evidence_for_invoice(uuid)', 'anon'), (2, 'public.carrier_evidence_for_invoice(uuid)', 'authenticated'), (3, 'public.carrier_evidence_for_invoice(uuid)', 'service_role'),
               (4, 'public.carrier_evidence_for_relationship(uuid)', 'anon'), (5, 'public.carrier_evidence_for_relationship(uuid)', 'authenticated'), (6, 'public.carrier_evidence_for_relationship(uuid)', 'service_role'),
               (7, 'public._carrier_inference_apply_0155(text)', 'anon'), (8, 'public._carrier_inference_apply_0155(text)', 'authenticated'), (9, 'public._carrier_inference_apply_0155(text)', 'service_role'),
               (10, '{DEC}', 'anon'), (11, '{DEC}', 'service_role')) g(n, sig, who)
  union all select 140, 'ACL', 'decide_carrier_inference_review: EXECUTE for authenticated only (not PUBLIC)', case when has_function_privilege('authenticated', to_regprocedure('{DEC}'), 'execute') and not (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = to_regprocedure('{DEC}')) then 'PASS' else 'FAIL' end, 'catalog'
  union all select 141, 'ACL', 'review/run tables: authenticated has SELECT only; anon and service_role nothing', case when has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'SELECT') and not has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'INSERT') and not has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'UPDATE') and not has_table_privilege('authenticated', 'public.carrier_inference_review_0155', 'DELETE')
                                                                               and not has_table_privilege('anon', 'public.carrier_inference_review_0155', 'SELECT') and not has_table_privilege('service_role', 'public.carrier_inference_review_0155', 'SELECT') then 'PASS' else 'FAIL' end, 'catalog'
  union all select 150, 'RUN', 'the latest run: candidate count equals the current relationship count', case when (select (counts ->> 'candidate')::int from run) = (select count(*) from public.factoring_relationships) then 'PASS' else 'FAIL' end, coalesce((select counts::text from run), 'no run')
  union all select 151, 'RUN', 'the run counts are consistent (supported + assignable + ambiguous + unsafe + refused + decided = candidate; resolved = 0 at apply)', case when (select (counts ->> 'supported_unchanged')::int + (counts ->> 'assignable_proven_pending_owner')::int + (counts ->> 'ambiguous_unresolved')::int + (counts ->> 'unsafe_assigned')::int + (counts ->> 'refused_structural')::int + (counts ->> 'decided_unchanged')::int = (counts ->> 'candidate')::int from run) then 'PASS' else 'FAIL' end, 'counts'
  union all select 152, 'RUN', 'every category has a digest (md5 of the sorted relationship ids)', case when (select bool_and(v ~ '^[0-9a-f]{{32}}$') from run, jsonb_each_text(run.digests) e(k, v)) then 'PASS' else 'FAIL' end, 'digests'
  union all select 160, 'REVIEW', 'every unsafe / ambiguous / refused review row has an exception record (open, or resolved by a recorded decision)',
         case when not exists (select 1 from public.carrier_inference_review_0155 v where v.classification in ('ambiguous_unresolved', 'unsafe_assigned', 'refused_structural') and v.exception_record_id is null) then 'PASS' else 'FAIL' end, 'review rows'
  union all select 161, 'REVIEW', 'no review row is classified supported while still pending', case when not exists (select 1 from public.carrier_inference_review_0155 where classification = 'supported' and decision_status = 'pending') then 'PASS' else 'FAIL' end, 'review rows'
  union all select 162, 'REVIEW', 'no assignment is recorded without an owner/admin decision (decision_status assigned/confirmed/retired requires decided_by, key, reason and evidence reference)', case when not exists (select 1 from public.carrier_inference_review_0155 where decision_status in ('assigned', 'confirmed', 'retired') and (decision_key is null or decided_at is null or decision_reason is null or decision_evidence_ref is null)) then 'PASS' else 'FAIL' end, 'review rows'
  union all select 170, 'DATA (informational)', 'review classification counts', 'INFO', coalesce((select string_agg(classification || '=' || n, ', ' order by classification) from (select classification, count(*) n from public.carrier_inference_review_0155 group by 1) z), '(none)')
),
""" + VERDICT.format(tag="POST-APPLY 0155", what="strict evidence + review installed; no data changed by the migration")


def rollback():
    return HEAD.format(name="rollback.sql -- EMERGENCY removal of proposal 0155's objects") + f"""-- REFUSES (nothing changed) if ANY owner/admin decision has been recorded (assigned / confirmed / retired: those decisions changed carriers or closed exception records and cannot be silently undone) or if
-- proposal 0156 (which depends on the evidence functions) is applied. Otherwise drops only the 0155 objects. Exception records opened by 0155 are RETAINED (exception history is never deleted).
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regclass('public.carrier_inference_review_0155') is null then raise exception 'ROLLBACK 0155 REFUSED: review table missing (0155 not applied or already rolled back). Nothing changed.'; end if;
  if exists (select 1 from public.carrier_inference_review_0155 where decision_status in ('assigned', 'confirmed', 'retired')) then raise exception 'ROLLBACK 0155 REFUSED: owner/admin decisions have been recorded -- they changed carriers/exception records. Nothing changed.'; end if;
  if to_regclass('public.factoring_submission_gate') is not null then raise exception 'ROLLBACK 0155 REFUSED: proposal 0156 is applied and depends on the evidence functions -- roll back 0156 first. Nothing changed.'; end if;
end
$mig$;
drop function {DEC};
drop function public._carrier_inference_apply_0155(text);
drop function public.carrier_evidence_for_relationship(uuid);
drop function public.carrier_evidence_for_invoice(uuid);
drop table public.carrier_inference_review_0155;
drop table public.carrier_inference_run_0155;
do $mig$
begin
  if to_regclass('public.carrier_inference_review_0155') is not null or to_regclass('public.carrier_inference_run_0155') is not null or to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null then raise exception 'ROLLBACK 0155 postcondition: objects remain.'; end if;
  raise notice 'ROLLBACK 0155 complete: the 0155 objects are removed; no carrier assignment was ever changed by 0155 itself; exception records it opened are retained.';
end
$mig$;
commit;
"""


def all_files():
    return {"preflight.sql": preflight(), "post_apply.sql": post_apply(), "rollback.sql": rollback()}


if __name__ == "__main__":
    files = all_files()
    if "--check" in sys.argv:
        bad = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t] + ([] if (HERE / "proposed_0155.sql").exists() else ["proposed_0155.sql"])
        print("generated files are current" if not bad else "STALE: " + ", ".join(bad))
        sys.exit(1 if bad else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {hashlib.sha256(t.encode()).hexdigest()[:16]})")
