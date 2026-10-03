-- proposed_0155.sql -- F-01: strict carrier evidence + review of the 0137 relationship-to-carrier inference (forward correction; historical 0137 is NOT modified)
-- PROPOSAL 0155 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 -> 0155 (this) -> 0156. The unrelated proposal 0148 MUST be renumbered to 0153 (unused) or to 0157 or higher, never 0154-0156.
--
-- WHY. 0137 assigned factoring_relationships.carrier_id by rule R1 (an organization with ONE carrier row, ANY status) or R2 (2+ carriers, but the factored invoices that CAN be resolved all point to one
-- carrier -- even when other invoices of the same relationship resolve to no carrier). Both accept weaker evidence than its own header promises ("every factored_invoices row ... resolves to exactly one").
--
-- EVIDENCE HIERARCHY (the only sources; nothing else is ever consulted -- no recency, no majority, no first/newest row):
--   Invoice level  carrier_evidence_for_invoice(): candidates come ONLY from (S1) invoices.dispatch_id -> that dispatch's carrier and (S2) invoices.load_id -> that load's carrier.
--       A source counts only if it exists, is in the invoice's organization, is not a cancelled dispatch, agrees with the invoice's load, and names a carrier (a load marked 'unresolved' names none).
--       status 'proven' <=> exactly ONE distinct candidate AND that carrier exists, is in the same organization and is_active AND no structural contradiction.
--       'no_evidence' (0 candidates) | 'conflict' (2+ candidates or a structural contradiction) | 'invalid_carrier' (one candidate that is missing/other-org/inactive) -- all UNRESOLVED.
--   Relationship level  carrier_evidence_for_relationship():
--       L1  >= 1 factored invoice, EVERY one 'proven', all naming the SAME carrier            -> proven (all-or-nothing: one unproven invoice defeats L1)
--       L2  (no L1) the organization has EXACTLY ONE carrier row AND it is_active AND no factored invoice contradicts it -> proven (structural: no other value is possible)
--       otherwise unresolved: 'partial' (some invoices prove one carrier, others prove nothing -- the 0137 R2 defect), 'conflict', 'invalid_carrier' (e.g. sole carrier inactive), 'no_evidence'.
--   No single weaker source is sufficient; where no level applies the record stays unresolved. Payments and recipients are never evidence of a carrier.
--
-- WHAT THIS MIGRATION DOES: creates the evidence functions (owner-only), the review table, the run ledger and the owner/admin decision RPC, then runs an idempotent evaluation that
--   * NEVER changes any carrier_id, invoice, payment, factored invoice, load or dispatch;
--   * records, per relationship, a review row (assignable_proven | ambiguous_unresolved | unsafe_assigned | refused_structural) with the evidence needed for a human decision;
--   * opens exception records (via the 0154 owner-only writer) for ambiguous / unsafe / refused rows; existing open records are reused, never duplicated, never closed here;
--   * writes a run row with counts AND digests for candidate, supported (unchanged), assignable, ambiguous, unsafe, refused, decided-unchanged and resolved (0 at apply).
--   A carrier is assigned ONLY later, by an owner/admin decision (decide_carrier_inference_review: assign_proven re-verifies the strict evidence; assign_owner needs an explicit carrier + evidence reference) that is recorded; a non-null carrier is never overwritten or cleared (a wrong assignment is retired: deactivate + new relationship, per 0138).
-- Concurrency: SHARE locks on factored_invoices/invoices/dispatches/loads (writers wait, readers proceed), relationships FOR UPDATE, carriers FOR SHARE, 15 s lock_timeout, run inside the freeze.
begin;
set local lock_timeout = '15s';

do $mig$
begin
  if to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)') is null then raise exception '0155 precondition: proposal 0154 (owner-only exception writer) is not applied. STOP.'; end if;
  if to_regclass('public.carrier_backfill_0137_provenance') is null then raise exception '0155 precondition: 0137 provenance missing. STOP.'; end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'factoring_relationships' and column_name = 'carrier_id') then raise exception '0155 precondition: factoring_relationships.carrier_id missing. STOP.'; end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'carriers' and column_name = 'is_active') then raise exception '0155 precondition: carriers.is_active missing. STOP.'; end if;
  if to_regclass('public.carrier_inference_review_0155') is not null or to_regclass('public.carrier_inference_run_0155') is not null
     or to_regprocedure('public.carrier_evidence_for_invoice(uuid)') is not null or to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is not null
     or to_regprocedure('public._carrier_inference_apply_0155(text)') is not null or to_regprocedure('public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)') is not null then
    raise exception '0155 precondition: a 0155 object already exists -- already applied? STOP.';
  end if;
  raise notice '0155 PHASE 1 preconditions passed.';
end
$mig$;

-- fingerprints of everything 0155 must NOT change (compared in the postcondition)
create temp table _mig0155_snap on commit drop as
select (select md5(coalesce(string_agg(r.id::text || ':' || coalesce(r.carrier_id::text, '-') || ':' || r.is_default::text || ':' || r.is_active::text, '|' order by r.id), '')) from public.factoring_relationships r) as rel_fp,
       (select md5(coalesce(string_agg(to_jsonb(i)::text, '|' order by i.id), '')) from public.invoices i) as inv_fp,
       (select md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by p.id), '')) from public.payments p) as pay_fp,
       (select md5(coalesce(string_agg(f.id::text || ':' || f.status::text || ':' || f.invoice_id::text || ':' || f.factoring_relationship_id::text, '|' order by f.id), '')) from public.factored_invoices f) as fi_fp,
       (select md5(coalesce(string_agg(l.id::text || ':' || coalesce(l.carrier_id::text, '-') || ':' || coalesce(l.carrier_resolution, '-'), '|' order by l.id), '')) from public.loads l) as load_fp,
       (select md5(coalesce(string_agg(d.id::text || ':' || coalesce(d.carrier_id::text, '-') || ':' || d.status::text, '|' order by d.id), '')) from public.dispatches d) as disp_fp;

-- ======================= EVIDENCE FUNCTIONS (read-only, owner-only) ======================================================
create or replace function public.carrier_evidence_for_invoice(p_invoice_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_inv record; v_d record; v_l record; v_c record;
  v_cands uuid[] := '{}'::uuid[];
  v_sources jsonb := '[]'::jsonb;
  v_reasons text[] := '{}'::text[];
  v_structural boolean := false;
  v_status text; v_carrier uuid; v_x uuid;
begin
  select i.id, i.organization_id, i.dispatch_id, i.load_id into v_inv from public.invoices i where i.id = p_invoice_id;
  if v_inv.id is null then
    return pg_catalog.jsonb_build_object('status', 'not_found', 'carrier_id', null, 'candidates', '[]'::jsonb, 'sources', '[]'::jsonb, 'reasons', pg_catalog.to_jsonb(array['invoice_not_found']));
  end if;

  if v_inv.dispatch_id is not null then
    select d.id, d.organization_id, d.load_id, d.carrier_id, d.status into v_d from public.dispatches d where d.id = v_inv.dispatch_id;
    if v_d.id is null then v_reasons := v_reasons || 'dispatch_missing'::text; v_structural := true;
    elsif v_d.organization_id <> v_inv.organization_id then v_reasons := v_reasons || 'dispatch_cross_organization'::text; v_structural := true;
    elsif v_inv.load_id is not null and v_d.load_id is distinct from v_inv.load_id then v_reasons := v_reasons || 'dispatch_load_mismatch'::text; v_structural := true;
    elsif v_d.status = 'cancelled' then v_reasons := v_reasons || 'dispatch_cancelled_is_not_evidence'::text;
    elsif v_d.carrier_id is null then v_reasons := v_reasons || 'dispatch_without_carrier'::text;
    else v_cands := v_cands || v_d.carrier_id; v_sources := v_sources || pg_catalog.jsonb_build_object('source', 'invoice.dispatch', 'carrier_id', v_d.carrier_id);
    end if;
  end if;

  if v_inv.load_id is not null then
    select l.id, l.organization_id, l.carrier_id, l.carrier_resolution into v_l from public.loads l where l.id = v_inv.load_id;
    if v_l.id is null then v_reasons := v_reasons || 'load_missing'::text; v_structural := true;
    elsif v_l.organization_id <> v_inv.organization_id then v_reasons := v_reasons || 'load_cross_organization'::text; v_structural := true;
    elsif v_l.carrier_resolution = 'unresolved' then v_reasons := v_reasons || 'load_marked_unresolved'::text;
    elsif v_l.carrier_id is null then v_reasons := v_reasons || 'load_without_carrier'::text;
    else v_cands := v_cands || v_l.carrier_id; v_sources := v_sources || pg_catalog.jsonb_build_object('source', 'invoice.load', 'carrier_id', v_l.carrier_id);
    end if;
  end if;

  select coalesce(pg_catalog.array_agg(distinct x), '{}'::uuid[]) into v_cands from pg_catalog.unnest(v_cands) x;

  if v_structural then v_status := 'conflict';
  elsif pg_catalog.cardinality(v_cands) = 0 then v_status := 'no_evidence';
  elsif pg_catalog.cardinality(v_cands) > 1 then v_status := 'conflict'; v_reasons := v_reasons || 'multiple_distinct_carriers'::text;
  else
    v_x := v_cands[1];
    select c.organization_id, c.is_active into v_c from public.carriers c where c.id = v_x;
    if not found then v_status := 'invalid_carrier'; v_reasons := v_reasons || 'carrier_missing'::text;
    elsif v_c.organization_id <> v_inv.organization_id then v_status := 'invalid_carrier'; v_reasons := v_reasons || 'carrier_cross_organization'::text;
    elsif not v_c.is_active then v_status := 'invalid_carrier'; v_reasons := v_reasons || 'carrier_inactive'::text;
    else v_status := 'proven'; v_carrier := v_x;
    end if;
  end if;

  return pg_catalog.jsonb_build_object('status', v_status, 'carrier_id', v_carrier, 'candidates', pg_catalog.to_jsonb(v_cands), 'sources', v_sources, 'reasons', pg_catalog.to_jsonb(v_reasons), 'organization_id', v_inv.organization_id);
end;
$fn$;

create or replace function public.carrier_evidence_for_relationship(p_relationship_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_rel record; v_fi record; v_ev jsonb; v_c record;
  v_n integer := 0; v_unproven integer := 0;
  v_proven uuid[] := '{}'::uuid[];
  v_unproven_statuses text[] := '{}'::text[];
  v_org_carriers integer; v_sole uuid;
  v_status text; v_level text; v_carrier uuid;
begin
  select r.id, r.organization_id, r.carrier_id into v_rel from public.factoring_relationships r where r.id = p_relationship_id;
  if v_rel.id is null then
    return pg_catalog.jsonb_build_object('status', 'not_found', 'level', null, 'carrier_id', null);
  end if;
  for v_fi in select f.id, f.invoice_id from public.factored_invoices f where f.factoring_relationship_id = p_relationship_id order by f.id loop
    v_n := v_n + 1;
    v_ev := public.carrier_evidence_for_invoice(v_fi.invoice_id);
    if v_ev ->> 'status' = 'proven' then v_proven := v_proven || (v_ev ->> 'carrier_id')::uuid;
    else v_unproven := v_unproven + 1; v_unproven_statuses := v_unproven_statuses || (v_ev ->> 'status');
    end if;
  end loop;
  select coalesce(pg_catalog.array_agg(distinct x), '{}'::uuid[]) into v_proven from pg_catalog.unnest(v_proven) x;
  select count(*), (pg_catalog.array_agg(c.id))[1] into v_org_carriers, v_sole from public.carriers c where c.organization_id = v_rel.organization_id;

  if pg_catalog.cardinality(v_proven) > 1 then
    v_status := 'conflict'; v_level := null;
  elsif v_n >= 1 and v_unproven = 0 and pg_catalog.cardinality(v_proven) = 1 then
    select c.organization_id, c.is_active into v_c from public.carriers c where c.id = v_proven[1];
    if found and v_c.organization_id = v_rel.organization_id and v_c.is_active then v_status := 'proven'; v_level := 'L1_all_factored_invoices_prove_one_carrier'; v_carrier := v_proven[1];
    else v_status := 'invalid_carrier'; v_level := null; end if;
  elsif v_org_carriers = 1 then
    select c.is_active into v_c from public.carriers c where c.id = v_sole;
    if v_c.is_active and (pg_catalog.cardinality(v_proven) = 0 or v_proven[1] = v_sole) then v_status := 'proven'; v_level := 'L2_sole_active_carrier_in_organization'; v_carrier := v_sole;
    elsif not v_c.is_active then v_status := 'invalid_carrier'; v_level := null;
    else v_status := 'conflict'; v_level := null; end if;
  elsif v_n >= 1 and pg_catalog.cardinality(v_proven) = 1 and v_unproven > 0 then
    v_status := 'partial'; v_level := null;
  else
    v_status := 'no_evidence'; v_level := null;
  end if;

  return pg_catalog.jsonb_build_object('status', v_status, 'level', v_level, 'carrier_id', v_carrier, 'factored_invoices', v_n, 'unproven_invoices', v_unproven,
    'unproven_statuses', pg_catalog.to_jsonb(v_unproven_statuses), 'proven_carriers', pg_catalog.to_jsonb(v_proven), 'organization_carriers', v_org_carriers);
end;
$fn$;

-- ======================= TABLES ===========================================================================================
create table public.carrier_inference_run_0155 (
  run_id      uuid primary key,
  applied_at  timestamptz not null default now(),
  applied_by  text not null default current_user,
  note        text,
  counts      jsonb not null,
  digests     jsonb not null
);
create table public.carrier_inference_review_0155 (
  id                    uuid primary key default gen_random_uuid(),
  relationship_id       uuid not null unique references public.factoring_relationships (id) on delete restrict,
  organization_id       uuid not null references public.organizations (id) on delete restrict,
  classification        text not null check (classification in ('assignable_proven', 'ambiguous_unresolved', 'unsafe_assigned', 'refused_structural', 'supported')),
  prior_carrier_id      uuid,
  strict_status         text not null,
  strict_level          text,
  strict_carrier_id     uuid,
  evidence              jsonb not null,
  decision_status       text not null default 'pending' check (decision_status in ('pending', 'not_required', 'confirmed', 'retired', 'assigned')),
  decision_key          text,
  decision_fingerprint  text,
  decision_result       jsonb,
  decided_by            uuid references public.profiles (id) on delete set null,
  decided_at            timestamptz,
  decision_reason       text,
  decision_evidence_ref text,
  exception_record_id   uuid references public.unresolved_carrier_records (id) on delete set null,
  first_run_id          uuid not null,
  last_run_id           uuid not null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create trigger carrier_inference_review_0155_updated_at before update on public.carrier_inference_review_0155 for each row execute function public.set_updated_at();
alter table public.carrier_inference_run_0155 enable row level security;
alter table public.carrier_inference_review_0155 enable row level security;
create policy carrier_inference_run_0155_select on public.carrier_inference_run_0155 for select using (public.has_role(array['owner','admin']::public.org_role[]));
create policy carrier_inference_review_0155_select on public.carrier_inference_review_0155 for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','accountant']::public.org_role[]));
revoke all on public.carrier_inference_run_0155 from anon, authenticated, service_role;
revoke all on public.carrier_inference_review_0155 from anon, authenticated, service_role;
grant select on public.carrier_inference_review_0155 to authenticated;
grant select on public.carrier_inference_run_0155 to authenticated;   -- RLS: owner/admin only (the run row holds counts and digests, no business identifiers)

-- ======================= IDEMPOTENT EVALUATION (owner-only) ================================================================
create or replace function public._carrier_inference_apply_0155(p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_run uuid := pg_catalog.gen_random_uuid();
  r record; v_ev jsonb; v_cls text; v_existing record; v_exc uuid; v_reason text;
  v_cand uuid[] := '{}'; v_supp uuid[] := '{}'; v_assign uuid[] := '{}'; v_amb uuid[] := '{}'; v_unsafe uuid[] := '{}'; v_ref uuid[] := '{}'; v_decided uuid[] := '{}';
  v_cur record;
begin
  lock table public.factored_invoices, public.invoices, public.dispatches, public.loads in share mode;   -- writers wait; the evaluation reads one consistent state
  perform 1 from public.factoring_relationships x order by x.id for update;
  perform 1 from public.carriers x order by x.id for share;

  for r in select fr.id, fr.organization_id, fr.carrier_id from public.factoring_relationships fr order by fr.id loop
    v_cand := v_cand || r.id;
    v_ev := public.carrier_evidence_for_relationship(r.id);
    v_cls := null;
    if r.carrier_id is not null then
      select c.organization_id, c.is_active into v_cur from public.carriers c where c.id = r.carrier_id;
      if not found or v_cur.organization_id <> r.organization_id then v_cls := 'refused_structural'; end if;
    end if;
    if v_cls is null then
      if r.carrier_id is null then
        v_cls := case when v_ev ->> 'status' = 'proven' then 'assignable_proven' else 'ambiguous_unresolved' end;
      elsif v_ev ->> 'status' = 'proven' and (v_ev ->> 'carrier_id')::uuid = r.carrier_id then v_cls := 'supported';
      else v_cls := 'unsafe_assigned';
      end if;
    end if;

    select * into v_existing from public.carrier_inference_review_0155 x where x.relationship_id = r.id;
    if found and v_existing.decision_status in ('confirmed', 'retired', 'assigned') then
      v_decided := v_decided || r.id;            -- an owner/admin decision stands; nothing is re-opened or overwritten
      update public.carrier_inference_review_0155 set last_run_id = v_run where id = v_existing.id;
      continue;
    end if;

    if v_cls = 'supported' then
      v_supp := v_supp || r.id;
      if found then
        update public.carrier_inference_review_0155 set classification = 'supported', decision_status = 'not_required', strict_status = v_ev ->> 'status', strict_level = v_ev ->> 'level',
               strict_carrier_id = nullif(v_ev ->> 'carrier_id', '')::uuid, evidence = v_ev, prior_carrier_id = r.carrier_id, last_run_id = v_run where id = v_existing.id;
      end if;
      continue;
    end if;

    if v_cls = 'assignable_proven' then v_assign := v_assign || r.id;
    elsif v_cls = 'ambiguous_unresolved' then v_amb := v_amb || r.id;
    elsif v_cls = 'unsafe_assigned' then v_unsafe := v_unsafe || r.id;
    else v_ref := v_ref || r.id;
    end if;

    v_exc := null;
    if v_cls = 'assignable_proven' then
      select u.id into v_exc from public.unresolved_carrier_records u where u.record_type = 'factoring_relationship' and u.record_id = r.id and u.status = 'unresolved';
    else
      v_reason := case v_cls
        when 'ambiguous_unresolved' then 'Factoring relationship carrier ownership is not proven by strict evidence (status: ' || (v_ev ->> 'status') || '); it stays unresolved until an owner/admin decides.'
        when 'unsafe_assigned' then 'The carrier assigned to this factoring relationship by migration 0137 is NOT supported by strict evidence (status: ' || (v_ev ->> 'status') || '); an owner/admin must confirm it or retire the relationship.'
        else 'Structural inconsistency: the carrier referenced by this factoring relationship is missing or belongs to another organization.'
      end;
      v_exc := public._record_unresolved_carrier_record_trusted(r.organization_id, 'factoring_relationship', r.id, v_reason,
                 pg_catalog.jsonb_build_object('proposal', '0155', 'classification', v_cls, 'prior_carrier_id', r.carrier_id, 'strict', v_ev));
    end if;

    insert into public.carrier_inference_review_0155 (relationship_id, organization_id, classification, prior_carrier_id, strict_status, strict_level, strict_carrier_id, evidence, exception_record_id, first_run_id, last_run_id)
    values (r.id, r.organization_id, v_cls, r.carrier_id, v_ev ->> 'status', v_ev ->> 'level', nullif(v_ev ->> 'carrier_id', '')::uuid, v_ev, v_exc, v_run, v_run)
    on conflict (relationship_id) do update
      set classification = excluded.classification, prior_carrier_id = excluded.prior_carrier_id, strict_status = excluded.strict_status, strict_level = excluded.strict_level,
          strict_carrier_id = excluded.strict_carrier_id, evidence = excluded.evidence, exception_record_id = coalesce(excluded.exception_record_id, public.carrier_inference_review_0155.exception_record_id),
          decision_status = 'pending', last_run_id = excluded.last_run_id;
  end loop;

  insert into public.carrier_inference_run_0155 (run_id, note, counts, digests)
  values (v_run, p_note,
    pg_catalog.jsonb_build_object('candidate', pg_catalog.cardinality(v_cand), 'supported_unchanged', pg_catalog.cardinality(v_supp), 'assignable_proven_pending_owner', pg_catalog.cardinality(v_assign),
      'ambiguous_unresolved', pg_catalog.cardinality(v_amb), 'unsafe_assigned', pg_catalog.cardinality(v_unsafe), 'refused_structural', pg_catalog.cardinality(v_ref), 'decided_unchanged', pg_catalog.cardinality(v_decided), 'resolved', 0),
    pg_catalog.jsonb_build_object('candidate', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_cand) x),
      'supported_unchanged', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_supp) x),
      'assignable_proven_pending_owner', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_assign) x),
      'ambiguous_unresolved', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_amb) x),
      'unsafe_assigned', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_unsafe) x),
      'refused_structural', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_ref) x),
      'decided_unchanged', (select pg_catalog.md5(coalesce(pg_catalog.string_agg(x::text, ',' order by x), '')) from pg_catalog.unnest(v_decided) x)));
  return (select pg_catalog.jsonb_build_object('run_id', run_id, 'counts', counts, 'digests', digests) from public.carrier_inference_run_0155 where run_id = v_run);
end;
$fn$;

-- ======================= OWNER/ADMIN DECISION RPC =========================================================================
create or replace function public.decide_carrier_inference_review(
  p_review_id uuid, p_decision text, p_reason text, p_evidence_ref text, p_expected_updated_at timestamptz, p_idempotency_key text, p_carrier_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_org uuid; v_rv record; v_rel record; v_ev jsonb; v_fp text; v_result jsonb; v_status text;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may decide a carrier-inference review.');
  end if;
  if p_review_id is null or p_decision is null or p_decision not in ('confirm', 'retire', 'assign_proven', 'assign_owner') or p_reason is null or pg_catalog.btrim(p_reason) = ''
     or p_evidence_ref is null or pg_catalog.btrim(p_evidence_ref) = '' or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'INVALID_REQUEST', 'message', 'decision (confirm|retire|assign_proven|assign_owner), reason, evidence reference and idempotency key are all required.');
  end if;

  select * into v_rv from public.carrier_inference_review_0155 x where x.id = p_review_id and x.organization_id = v_org for update;   -- organization scoping BEFORE any ledger read
  if not found then return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Review not found.'); end if;
  v_fp := pg_catalog.md5(p_decision || '|' || pg_catalog.btrim(p_reason) || '|' || pg_catalog.btrim(p_evidence_ref) || '|' || coalesce(p_carrier_id::text, ''));

  if v_rv.decision_key is not null then
    if v_rv.decision_key = p_idempotency_key then
      if v_rv.decision_fingerprint = v_fp then return v_rv.decision_result || pg_catalog.jsonb_build_object('idempotent_replay', true); end if;
      return pg_catalog.jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return pg_catalog.jsonb_build_object('success', false, 'code', 'ALREADY_DECIDED', 'message', 'This review has already been decided.');
  end if;
  if v_rv.updated_at is distinct from p_expected_updated_at then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'current_updated_at', v_rv.updated_at, 'message', 'This review changed. Refresh and try again.');
  end if;

  select fr.id, fr.organization_id, fr.carrier_id, fr.is_default, fr.is_active into v_rel from public.factoring_relationships fr where fr.id = v_rv.relationship_id for update;
  if v_rel.id is null or v_rel.organization_id <> v_org then return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Review not found.'); end if;

  if p_decision = 'confirm' then
    if v_rv.classification <> 'unsafe_assigned' or v_rel.carrier_id is distinct from v_rv.prior_carrier_id or v_rel.carrier_id is null then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_APPLICABLE', 'message', 'Only an unsupported existing assignment that is unchanged can be confirmed.');
    end if;
    v_status := 'confirmed';
  elsif p_decision = 'retire' then
    -- a wrong assignment cannot be cleared to NULL (constraint factoring_relationships_new_writes_need_carrier, 0139) and is never repointed (0138): it is RETIRED --
    -- the owner/admin first deactivates it through the sanctioned deactivate_factoring_relationship() and creates a correct relationship; this only records that decision.
    if v_rv.classification <> 'unsafe_assigned' or v_rel.carrier_id is distinct from v_rv.prior_carrier_id or v_rel.carrier_id is null then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_APPLICABLE', 'message', 'Only an unsupported existing assignment that is unchanged can be retired.');
    end if;
    if v_rel.is_active then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'RELATIONSHIP_STILL_ACTIVE', 'message', 'Deactivate the relationship (deactivate_factoring_relationship) before recording the retirement.');
    end if;
    v_status := 'retired';
  elsif p_decision = 'assign_owner' then
    if v_rv.classification not in ('ambiguous_unresolved', 'assignable_proven') or v_rel.carrier_id is not null or p_carrier_id is null then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_APPLICABLE', 'message', 'An owner assignment needs an unassigned relationship and an explicit carrier.');
    end if;
    if not exists (select 1 from public.carriers c where c.id = p_carrier_id and c.organization_id = v_org and c.is_active) then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'INVALID_CARRIER', 'message', 'The carrier must exist, be active and belong to this organization.');
    end if;
    -- NEVER when strict evidence points at a DIFFERENT single carrier or is contradictory in a way that names another carrier
    v_ev := public.carrier_evidence_for_relationship(v_rel.id);
    if v_ev ->> 'status' = 'proven' and (v_ev ->> 'carrier_id')::uuid is distinct from p_carrier_id then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'CONTRADICTS_EVIDENCE', 'message', 'Strict evidence proves a different carrier.');
    end if;
    if v_ev ->> 'status' = 'conflict' and not (coalesce(v_ev -> 'proven_carriers', '[]'::jsonb) ? p_carrier_id::text) then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'CONTRADICTS_EVIDENCE', 'message', 'The chosen carrier is not among the carriers the evidence names.');
    end if;
    begin
      update public.factoring_relationships set carrier_id = p_carrier_id where id = v_rel.id;
    exception when unique_violation then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'DEFAULT_CONFLICT', 'message', 'That carrier already has an active default relationship.');
    end;
    v_status := 'assigned';
  else
    if v_rv.classification <> 'assignable_proven' or v_rel.carrier_id is not null then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'NOT_APPLICABLE', 'message', 'Only an unassigned relationship whose carrier is proven by strict evidence can be assigned.');
    end if;
    v_ev := public.carrier_evidence_for_relationship(v_rel.id);   -- re-verified NOW, under the relationship lock
    if v_ev ->> 'status' <> 'proven' or (v_ev ->> 'carrier_id')::uuid is distinct from v_rv.strict_carrier_id then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'EVIDENCE_CHANGED', 'message', 'The evidence no longer proves the same single carrier. Re-run the evaluation.');
    end if;
    begin
      update public.factoring_relationships set carrier_id = v_rv.strict_carrier_id where id = v_rel.id;
    exception when unique_violation then
      return pg_catalog.jsonb_build_object('success', false, 'code', 'DEFAULT_CONFLICT', 'message', 'That carrier already has an active default relationship.');
    end;
    v_status := 'assigned';
  end if;

  if v_status in ('confirmed', 'assigned') and v_rv.exception_record_id is not null then
    update public.unresolved_carrier_records set status = 'manually_resolved', resolved_by = v_uid, resolved_at = pg_catalog.now(),
           resolution_note = 'Carrier-inference review 0155: ' || v_status || ' by owner/admin. Evidence reference: ' || pg_catalog.btrim(p_evidence_ref)
     where id = v_rv.exception_record_id and status = 'unresolved' and organization_id = v_org;
  end if;
  v_result := pg_catalog.jsonb_build_object('success', true, 'review_id', v_rv.id, 'relationship_id', v_rel.id, 'decision', v_status, 'carrier_id', (select fr.carrier_id from public.factoring_relationships fr where fr.id = v_rel.id));
  update public.carrier_inference_review_0155 set decision_status = v_status, decision_key = p_idempotency_key, decision_fingerprint = v_fp, decision_result = v_result, decided_by = v_uid, decided_at = pg_catalog.now(),
         decision_reason = pg_catalog.btrim(p_reason), decision_evidence_ref = pg_catalog.btrim(p_evidence_ref) where id = v_rv.id;
  if (select fr.carrier_id from public.factoring_relationships fr where fr.id = v_rel.id) is not null or v_rv.prior_carrier_id is not null then
    perform public.log_activity('carrier'::public.entity_type, coalesce((select fr.carrier_id from public.factoring_relationships fr where fr.id = v_rel.id), v_rv.prior_carrier_id), 'factoring_relationship_carrier_inference_' || v_status,
             pg_catalog.jsonb_build_object('review_id', v_rv.id, 'relationship_id', v_rel.id, 'evidence_ref', pg_catalog.btrim(p_evidence_ref)), v_org);
  end if;
  return v_result;
end;
$fn$;

-- ======================= PRIVILEGES (explicit; independent of default privileges) ==========================================
revoke all on function public.carrier_evidence_for_invoice(uuid) from public, anon, authenticated, service_role;
revoke all on function public.carrier_evidence_for_relationship(uuid) from public, anon, authenticated, service_role;
revoke all on function public._carrier_inference_apply_0155(text) from public, anon, authenticated, service_role;
revoke all on function public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid) from public, anon, service_role;
grant execute on function public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid) to authenticated;

-- ======================= RUN THE EVALUATION ================================================================================
do $mig$
declare v_res jsonb;
begin
  v_res := public._carrier_inference_apply_0155('initial run inside proposal 0155');
  raise notice '0155 evaluation: counts % digests %', v_res -> 'counts', v_res -> 'digests';
end
$mig$;

-- ======================= POSTCONDITIONS ====================================================================================
do $mig$
declare s record;
begin
  select * into s from _mig0155_snap;
  if (select md5(coalesce(string_agg(r.id::text || ':' || coalesce(r.carrier_id::text, '-') || ':' || r.is_default::text || ':' || r.is_active::text, '|' order by r.id), '')) from public.factoring_relationships r) <> s.rel_fp then raise exception '0155 postcondition: a factoring relationship changed (0155 never assigns or clears a carrier).'; end if;
  if (select md5(coalesce(string_agg(to_jsonb(i)::text, '|' order by i.id), '')) from public.invoices i) <> s.inv_fp then raise exception '0155 postcondition: invoices changed.'; end if;
  if (select md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by p.id), '')) from public.payments p) <> s.pay_fp then raise exception '0155 postcondition: payments changed.'; end if;
  if (select md5(coalesce(string_agg(f.id::text || ':' || f.status::text || ':' || f.invoice_id::text || ':' || f.factoring_relationship_id::text, '|' order by f.id), '')) from public.factored_invoices f) <> s.fi_fp then raise exception '0155 postcondition: factored invoices changed.'; end if;
  if (select md5(coalesce(string_agg(l.id::text || ':' || coalesce(l.carrier_id::text, '-') || ':' || coalesce(l.carrier_resolution, '-'), '|' order by l.id), '')) from public.loads l) <> s.load_fp then raise exception '0155 postcondition: loads changed.'; end if;
  if (select md5(coalesce(string_agg(d.id::text || ':' || coalesce(d.carrier_id::text, '-') || ':' || d.status::text, '|' order by d.id), '')) from public.dispatches d) <> s.disp_fp then raise exception '0155 postcondition: dispatches changed.'; end if;
  if (select count(*) from public.carrier_inference_run_0155) <> 1 then raise exception '0155 postcondition: expected exactly one run row.'; end if;
  if (select (counts ->> 'candidate')::int from public.carrier_inference_run_0155) <> (select count(*) from public.factoring_relationships) then raise exception '0155 postcondition: candidate count is not the relationship count.'; end if;
  if has_function_privilege('anon', 'public.carrier_evidence_for_invoice(uuid)', 'execute') or has_function_privilege('authenticated', 'public._carrier_inference_apply_0155(text)', 'execute')
     or has_function_privilege('service_role', 'public.carrier_evidence_for_relationship(uuid)', 'execute') or has_function_privilege('anon', 'public.decide_carrier_inference_review(uuid,text,text,text,timestamptz,text,uuid)', 'execute') then
    raise exception '0155 postcondition: an internal function is executable by a client role.';
  end if;
  raise notice '0155 complete: no carrier, invoice, payment, factored invoice, load or dispatch was changed; review rows and exception records were written for every unsupported relationship.';
end
$mig$;

commit;
