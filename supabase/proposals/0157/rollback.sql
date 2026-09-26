-- rollback.sql -- EMERGENCY switch-off of proposal 0157 (history is PRESERVED)
-- PROPOSAL 0157 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION. Sequencing: ... -> 0152 -> 0154 -> 0155 -> (0156 optional, superseded) -> 0157 (this); unrelated 0148 -> 0153 or 0158+. Finding F-08 (carrier invoices).
-- Removes the RPCs, the helper functions and the gate: NEW submissions become impossible immediately. HISTORY IS PRESERVED: submissions, immutable snapshots, the audit ledger and submitter grants are KEPT (with their
-- immutability triggers and trigger functions) whenever any of them holds a row; they are dropped only if ALL are empty. Existing carrier invoices, relationships and legacy factored invoices are never touched.
-- REFUSES (nothing changed) unless the reviewed 0157 objects are present. A later re-application while the tables are kept requires a reviewed manual step. Single transaction; run once.
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regclass('public.carrier_invoice_factoring_gate_0157') is null or to_regprocedure('public.submit_carrier_invoice_to_factor(uuid,text)') is null then raise exception 'ROLLBACK 0157 REFUSED: the 0157 gate or RPC is missing (not applied or already rolled back). Nothing changed.'; end if;
end
$mig$;
drop function if exists public.submit_carrier_invoice_to_factor(uuid,text);
drop function if exists public.preview_carrier_invoice_factoring(uuid);
drop function if exists public.withdraw_carrier_invoice_factoring_submission(uuid,text,text);
drop function if exists public.set_carrier_factoring_submitter(uuid,uuid,boolean,text,text);
drop function if exists public._cif_evaluate_0157(uuid,uuid,uuid);
drop function if exists public._cif_authorize_0157(uuid,uuid,uuid);
drop function if exists public._cif_refuse_0157(uuid,uuid,text,uuid,uuid,text,text,jsonb,boolean);
drop function if exists public.preview_carrier_invoice_issuance(uuid,uuid[],text,uuid);
drop function if exists public.create_carrier_invoice_draft_from_loads(uuid,uuid[],text,uuid,text);
drop function if exists public.mark_carrier_invoice_ready_for_issue(uuid,timestamptz,text);
drop function if exists public.discard_carrier_invoice_draft(uuid,timestamptz,text,text);
drop function if exists public.issue_prepared_carrier_invoice(uuid,timestamptz,text,text);
drop function if exists public.preview_carrier_invoice_reissue(uuid);
drop function if exists public.reissue_carrier_invoice(uuid,timestamptz,text,text);
drop function if exists public._cif_freeze_0157(uuid);
drop function if exists public._cif_diff_frozen_0157(jsonb,jsonb);
drop function if exists public._cif_selection_0157(uuid,uuid,uuid,uuid[],text,uuid,uuid);
drop function if exists public._cif_create_draft_0157(uuid,uuid,uuid,uuid[],text,uuid,text);
drop function if exists public._cif_dispatch_fee_0157(uuid,uuid,uuid,uuid,uuid[],uuid);
drop function if exists public._cif_reissue_eval_0157(uuid,uuid,uuid);
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
