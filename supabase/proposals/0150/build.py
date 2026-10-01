#!/usr/bin/env python3
"""Proposal 0150 generator. NOT APPROVED FOR PRODUCTION.

Derives the five SQL files from ONE shared analysis fragment (so the migration, the read-only
preflight, the candidate review, the post-apply verifier and the rollback can never disagree about
what a "candidate" is) and from the authoritative 0132 text (guard fingerprints).

    python3 build.py           # (re)write the generated files
    python3 build.py --check   # exit 1 if any generated file is stale
"""
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]

# ---------------------------------------------------------------------------- constants
REASON = "No dispatch on this load; a responsible carrier cannot be determined."
RULE = "C4_zero_dispatch"
CLOSE_NOTE = ("Closed by migration 0150: this legacy load has no dispatch and no carrier evidence of any kind, so no carrier "
              "can be proven from data. It was returned to pending carrier assignment (loads.carrier_id NULL, "
              "loads.carrier_resolution NULL); its carrier is established atomically by guard_dispatch_carrier_scope() "
              "(0132) at the first dispatch, chosen and authorized by the dispatching user. No carrier was assigned by this migration.")
CLOSE_STATUS = "archived_legacy"

# (table, column): every place a carrier-linked / financial record can point at a load, through 0147.
# A table that does not exist (never deployed) simply contributes zero rows.
EVIDENCE = [
    ("public.invoices", "load_id", False),
    ("public.dispatch_advances", "load_id", False),
    ("public.settlement_line_items", "load_id", False),
    ("public.driver_settlement_items", "load_id", False),
    ("public.expenses", "load_id", False),
    ("public.compliance_overrides", "load_id", False),
    ("public.dispatch_resource_reassignments", "load_id", False),
    ("public.carrier_invoice_loads", "load_id", True),                 # 0142
    ("public.carrier_invoice_line_items", "source_load_id", True),     # 0144
    ("public.carrier_dispatch_service_billing_lines", "load_id", True),  # 0145
]
REQUIRED_EVIDENCE = [t for t, _, req in EVIDENCE if req]


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def norm(body):
    """Comment- and whitespace-insensitive, case-insensitive form of a function body (as preflight computes live)."""
    return re.sub(r"\s+", "", re.sub(r"--[^\n]*", "", body).lower())


def fn_body(text, header):
    i = text.index(header)
    a = text.index("$fn$", i) + 4
    b = text.index("$fn$", a)
    return text[a:b]


def fingerprints():
    t = (SUPA / "migrations/0132_load_carrier_and_trailer_scope.sql").read_text()
    out = {}
    for name in ("guard_dispatch_carrier_scope", "guard_load_carrier_change"):
        out[name] = hashlib.md5(norm(fn_body(t, f"create or replace function public.{name}()")).encode()).hexdigest()
    return out


def q(s):
    return "'" + s.replace("'", "''") + "'"


# ---------------------------------------------------------------------------- shared analysis fragment
def analysis(indent="  "):
    """CTE list (no leading WITH) that classifies every zero-dispatch 'unresolved' load. Ends with cls."""
    ev_values = ",\n".join(f"    ({q(t)}, {q(c)}, {str(r).lower()})" for t, c, r in EVIDENCE)
    text = f"""evtab(tbl, col, required) as (values
{ev_values}
),
evlive as (
  select e.tbl, e.col, e.required, to_regclass(e.tbl) as rel,
         exists (select 1 from pg_attribute a where a.attrelid = to_regclass(e.tbl) and a.attname = e.col and not a.attisdropped) as has_col
  from evtab e
),
pool as (   -- every load 0133 left 'unresolved' that has NO dispatch of ANY status (cancelled included)
  select l.id as load_id, l.organization_id, l.load_number::text as load_number, l.status::text as load_status,
         l.carrier_id, l.carrier_locked_at, l.financial_dispatch_id
  from public.loads l
  where l.carrier_resolution = 'unresolved'
    and not exists (select 1 from public.dispatches d where d.load_id = l.id)
),
evn as (    -- carrier/financial evidence rows per pool load and evidence table (count(*) via a catalog-validated, identifier-quoted query)
  select p.load_id, e.tbl,
         case when e.rel is null or not e.has_col then 0
              else ((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %s where %I = %L', e.rel, e.col, p.load_id), false, true, '')))[1])::text::integer
         end as n
  from pool p cross join evlive e
),
ex as (     -- the 0133 exception records for each pool load
  select p.load_id,
         (select count(*) from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id = p.load_id) as n_exc_all,
         (select count(*) from public.unresolved_carrier_records u
           where u.record_type = 'load' and u.record_id = p.load_id and u.status = 'unresolved'
             and u.organization_id = p.organization_id
             and u.reason = {q(REASON)}
             and u.detail = jsonb_build_object('rule', {q(RULE)}, 'dispatches', '[]'::jsonb)
             and u.resolved_by is null and u.resolved_at is null and u.resolution_note is null) as n_exc_exact,
         (select u.id from public.unresolved_carrier_records u
           where u.record_type = 'load' and u.record_id = p.load_id and u.status = 'unresolved'
             and u.organization_id = p.organization_id
             and u.reason = {q(REASON)}
             and u.detail = jsonb_build_object('rule', {q(RULE)}, 'dispatches', '[]'::jsonb)
             and u.resolved_by is null and u.resolved_at is null and u.resolution_note is null
           order by u.id limit 1) as exc_id
  from pool p
),
cls as (
  select p.*, x.n_exc_all, x.n_exc_exact, x.exc_id,
         (select count(*) from public.carrier_backfill_0133_provenance v where v.load_id = p.load_id) as n_pv,
         (select count(*) from public.carrier_backfill_0133_provenance v
           where v.load_id = p.load_id and v.organization_id = p.organization_id and v.carrier_id is null
             and v.carrier_resolution = 'unresolved' and v.carrier_locked_at is null
             and v.unresolved_carrier_record_id is not distinct from x.exc_id and x.exc_id is not null) as n_pv_exact,
         (select coalesce(sum(n.n), 0) from evn n where n.load_id = p.load_id)::integer as n_evidence,
         (select string_agg(n.tbl || '=' || n.n::text, ', ' order by n.tbl) from evn n where n.load_id = p.load_id and n.n > 0) as evidence_detail,
         exists (select 1 from public.organizations o where o.id = p.organization_id) as org_ok
  from pool p join ex x using (load_id)
),
verdict_rows as (
  select c.*,
         concat_ws('; ',
           case when c.carrier_id is not null then 'carrier_id is set' end,
           case when c.carrier_locked_at is not null then 'carrier_locked_at is set' end,
           case when c.financial_dispatch_id is not null then 'financial_dispatch_id is set' end,
           case when c.n_evidence > 0 then 'carrier/financial evidence: ' || coalesce(c.evidence_detail, '?') end,
           case when c.n_exc_all <> 1 then c.n_exc_all::text || ' exception record(s) for this load (expected exactly 1)' end,
           case when c.n_exc_all = 1 and c.n_exc_exact <> 1 then 'the exception record is not the exact open 0133 C4_zero_dispatch record' end,
           case when c.n_pv_exact <> 1 then '0133 provenance row missing or inconsistent (rows=' || c.n_pv::text || ')' end,
           case when not c.org_ok then 'organization missing' end) as problems
  from cls c
)"""
    return "\n".join(indent + l if l else l for l in text.splitlines())


DIGEST_EXPR = "md5(coalesce(string_agg(load_id::text, ',' order by load_id) filter (where problems = ''), ''))"

PLACEHOLDER_COUNT = "null::integer"
PLACEHOLDER_DIGEST = "null::text"

HEADER_NOT_APPROVED = """-- PROPOSAL 0150 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: applies AFTER 0130..0147 and 0149. Current proposal 0148 is unrelated and MUST be renumbered to 0153 or higher before promotion."""


# ---------------------------------------------------------------------------- proposed_0150.sql
def proposed():
    fp = fingerprints()
    return f"""-- =============================================================================
-- proposed_0150.sql -- BLOCKER A: normalize zero-evidence legacy 'unresolved' loads.
{HEADER_NOT_APPROVED}
--
-- WHY. Migration 0133 classified every legacy load with no dispatch as carrier_resolution='unresolved'
-- (rule C4_zero_dispatch) and opened an exception record. The 0132 guard then rejects ANY new dispatch
-- on an 'unresolved' load ("no exceptions"), so those loads can never be dispatched. For a load with NO
-- dispatch and NO carrier/financial evidence there is nothing to be "unresolved" about: no carrier was
-- ever attached. The correct pre-first-dispatch state is the one the 0132 guard already handles
-- atomically: carrier_id NULL + carrier_resolution NULL -> the first non-cancelled dispatch claims the
-- load for ITS carrier (chosen and authorized by the dispatching user, under the load row lock).
--
-- WHAT IT DOES (and nothing else):
--   * for each CANDIDATE load: loads.carrier_resolution 'unresolved' -> NULL. carrier_id stays NULL.
--   * closes exactly the matching open unresolved_carrier_records row (status 'archived_legacy', a
--     factual resolution_note; resolved_by stays NULL because no person resolved it).
--   * writes public.carrier_backfill_0150_provenance (one row per load; full prior state) so
--     ROLLBACK_0150 can restore exactly.
-- WHAT IT NEVER DOES: choose or assign a carrier; touch a load with any dispatch (cancelled included);
-- touch guard_dispatch_carrier_scope() / guard_load_carrier_change() (0132) or any other function;
-- touch any load or exception record that is not a candidate.
--
-- CANDIDATE (every condition, evaluated under row locks): carrier_resolution='unresolved'; carrier_id,
-- carrier_locked_at, financial_dispatch_id all NULL; ZERO dispatches of any status; ZERO rows in any
-- carrier/financial evidence table (see build.py EVIDENCE); exactly ONE exception record for the load
-- and it is the exact open 0133 record (organization, reason text, detail {{rule: C4_zero_dispatch,
-- dispatches: []}}, unresolved, no resolver); a matching 0133 provenance row; valid organization.
-- FAIL CLOSED: any zero-dispatch 'unresolved' load that fails a condition (contradictory evidence)
-- aborts the WHOLE migration -- nothing is skipped silently. The candidate count AND digest must equal
-- v_expected_count / v_expected_digest (printed by candidate_review.sql and approved by the owner); NULL aborts.
--
-- OWNER ACTION BEFORE RUNNING: replace  null  in the two marked lines with the approved count AND the approved digest
-- (both REQUIRED; there is no default and no example value). Run candidate_review.sql and preflight.sql first. Single transaction.
-- AS SHIPPED THIS FILE FAILS CLOSED: run unedited (or with a wrong/placeholder count or digest) it aborts in Phase 1 and changes nothing.
-- =============================================================================
begin;

-- ======================= PHASE 1 -- PRECONDITIONS + LOCKS + PLAN ===============
do $mig$
declare
  v_expected_count  constant integer := null;   -- <<< OWNER: REPLACE null WITH THE APPROVED CANDIDATE COUNT (integer)
  v_expected_digest constant text    := null;   -- <<< OWNER: REPLACE null WITH THE APPROVED CANDIDATE DIGEST (32 hex chars) printed by candidate_review.sql
  v_guard_md5 text;
  v_load_guard_md5 text;
  v_n_pool integer;
  v_n_cand integer;
  v_n_bad  integer;
  v_digest text;
  v_list   text;
begin
  if v_expected_count is null or v_expected_count < 0 then
    raise exception '0150 precondition: expected candidate count is not set. Run candidate_review.sql, approve the list, and set v_expected_count. STOP.';
  end if;

  if v_expected_digest is null or v_expected_digest !~ '^[0-9a-f]{{32}}$' then
    raise exception '0150 precondition: expected candidate digest is not set (or is not 32 lowercase hex characters). Run candidate_review.sql after 0133, approve the list, and set v_expected_digest. STOP.';
  end if;

  if to_regclass('public.carrier_backfill_0150_provenance') is not null then raise exception '0150 precondition: carrier_backfill_0150_provenance already exists -- already applied? STOP.'; end if;
  if to_regclass('public.carrier_backfill_0133_provenance') is null then raise exception '0150 precondition: 0133 not applied (carrier_backfill_0133_provenance missing). STOP.'; end if;
  if to_regclass('public.unresolved_carrier_records') is null then raise exception '0150 precondition: unresolved_carrier_records missing. STOP.'; end if;
  if to_regclass('public.loads') is null or to_regclass('public.dispatches') is null then raise exception '0150 precondition: loads/dispatches missing. STOP.'; end if;
  if to_regclass('public.carrier_invoice_loads') is null or to_regclass('public.carrier_invoice_line_items') is null
     or to_regclass('public.carrier_dispatch_service_billing_lines') is null then
    raise exception '0150 precondition: the 0142/0144/0145 carrier-evidence tables are missing -- apply 0130..0147 first. STOP.';
  end if;
  if not exists (select 1 from pg_enum e where e.enumtypid = to_regtype('public.unresolved_record_status') and e.enumlabel = {q(CLOSE_STATUS)}) then
    raise exception '0150 precondition: unresolved_record_status has no ''{CLOSE_STATUS}'' label. STOP.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.loads'::regclass and conname = 'loads_carrier_resolution_values'
                  and pg_get_constraintdef(oid) ilike '%carrier_resolution IS NULL%') then
    raise exception '0150 precondition: loads_carrier_resolution_values does not permit NULL carrier_resolution. STOP.';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'public.dispatches'::regclass and t.tgname = 'dispatches_guard_carrier_scope' and not t.tgisinternal and t.tgenabled in ('O','A')) then
    raise exception '0150 precondition: the 0132 dispatch guard trigger is missing or disabled. STOP.';
  end if;
  -- the 0149 repair must already be live (create_dispatch / cancel_dispatch declare the enum-typed c_active)
  if not exists (select 1 from pg_proc x where x.oid = to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)')
                  and regexp_replace(x.prosrc, '\\s+', '', 'g') like '%c\\_activeconstantpublic.dispatch\\_status[]%')
     or not exists (select 1 from pg_proc x where x.oid = to_regprocedure('public.cancel_dispatch(uuid,text)')
                  and regexp_replace(x.prosrc, '\\s+', '', 'g') like '%c\\_activeconstantpublic.dispatch\\_status[]%') then
    raise exception '0150 precondition: proposal 0149 (enum-typed c_active in create_dispatch/cancel_dispatch) is not applied. STOP.';
  end if;
  -- the 0132 guards must be byte-for-byte (normalised) the reviewed 0132 definitions: 0150 relies on their claim-on-first-dispatch semantics
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_guard_md5
    from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()');
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_load_guard_md5
    from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()');
  if v_guard_md5 is distinct from {q(fp['guard_dispatch_carrier_scope'])} then raise exception '0150 precondition: guard_dispatch_carrier_scope() is not the reviewed 0132 definition (md5 %). STOP.', v_guard_md5; end if;
  if v_load_guard_md5 is distinct from {q(fp['guard_load_carrier_change'])} then raise exception '0150 precondition: guard_load_carrier_change() is not the reviewed 0132 definition (md5 %). STOP.', v_load_guard_md5; end if;

  -- LOCKS, deterministic order (loads by id, then exception records by id). Load-first matches
  -- create_dispatch / cancel_dispatch / transition_dispatch_status, so no deadlock; a concurrent
  -- dispatch or evidence insert (FK KEY SHARE) waits here and is evaluated AFTER we commit.
  perform 1 from public.loads l where l.carrier_resolution = 'unresolved' order by l.id for update;
  perform 1 from public.unresolved_carrier_records u
   where u.record_type = 'load' and u.status = 'unresolved'
     and u.record_id in (select l.id from public.loads l where l.carrier_resolution = 'unresolved')
   order by u.id for update;

  -- PLAN: evaluated AFTER the locks (fresh statement snapshot)
  create temp table _mig0150_plan on commit drop as
  with
{analysis('  ')}
  select v.*, (v.problems = '') as is_candidate from verdict_rows v;

  select count(*), count(*) filter (where is_candidate), count(*) filter (where not is_candidate)
    into v_n_pool, v_n_cand, v_n_bad from _mig0150_plan;

  if v_n_bad > 0 then
    select string_agg(load_number || ' [' || problems || ']', E'\\n' order by load_number) into v_list from (select * from _mig0150_plan where not is_candidate order by load_number limit 25) z;
    raise exception E'0150 precondition: % zero-dispatch unresolved load(s) carry contradictory or unexpected evidence -- nothing was changed. Resolve them first (see candidate_review.sql):\\n%', v_n_bad, v_list;
  end if;
  if v_n_cand <> v_expected_count then
    raise exception '0150 precondition: candidate count % <> expected count %. Re-run candidate_review.sql and re-approve. STOP.', v_n_cand, v_expected_count;
  end if;
  select md5(coalesce(string_agg(load_id::text, ',' order by load_id), '')) into v_digest from _mig0150_plan where is_candidate;
  if v_digest is distinct from v_expected_digest then
    raise exception '0150 precondition: candidate digest % <> expected digest %. STOP.', v_digest, v_expected_digest;
  end if;

  -- pre-mutation fingerprints for the Phase 3 "exactly the candidates changed" proofs
  create temp table _mig0150_snap_loads on commit drop as
    select l.id, md5(to_jsonb(l)::text) as full_md5, md5((to_jsonb(l) - array['updated_at','carrier_resolution'])::text) as core_md5 from public.loads l;
  create temp table _mig0150_snap_exc on commit drop as
    select u.id, md5(to_jsonb(u)::text) as full_md5, md5((to_jsonb(u) - array['updated_at','status','resolved_at','resolution_note'])::text) as core_md5 from public.unresolved_carrier_records u;
  create temp table _mig0150_snap_misc on commit drop as
    select (select count(*) from public.loads) n_loads, (select count(*) from public.dispatches) n_dispatches,
           (select count(*) from public.unresolved_carrier_records) n_exc,
           (select md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by p.load_id), '')) from public.carrier_backfill_0133_provenance p) prov0133_md5,
           v_guard_md5 guard_md5, v_load_guard_md5 load_guard_md5, v_digest digest, v_n_cand n_cand;

  raise notice '0150 PHASE 1 passed: % zero-dispatch unresolved load(s), % candidate(s) (digest %), locks held.', v_n_pool, v_n_cand, v_digest;
end
$mig$;

-- ======================= PHASE 2 -- MUTATION ===================================
create table public.carrier_backfill_0150_provenance (
  load_id                       uuid primary key references public.loads (id) on delete cascade,
  organization_id               uuid not null references public.organizations (id) on delete cascade,
  load_number                   text,
  prior_carrier_id              uuid,
  prior_carrier_resolution      text not null check (prior_carrier_resolution = 'unresolved'),
  prior_carrier_locked_at       timestamptz,
  exception_record_id           uuid references public.unresolved_carrier_records (id) on delete set null,
  prior_exception_status        public.unresolved_record_status not null,
  prior_exception_resolved_by   uuid,
  prior_exception_resolved_at   timestamptz,
  prior_exception_resolution_note text,
  prior_exception_reason        text not null,
  prior_exception_detail        jsonb not null,
  closed_exception_status       public.unresolved_record_status not null,
  closed_exception_note         text not null,
  expected_candidate_count      integer not null,
  candidate_digest              text not null,
  applied_at                    timestamptz not null default now(),
  applied_by                    text not null default current_user
);

comment on table public.carrier_backfill_0150_provenance is
  'Permanent record of every load migration 0150 returned from carrier_resolution=unresolved to NULL (zero-dispatch, zero-evidence legacy loads): the load''s prior carrier fields, the exception record it closed (full prior state) and the approved count/digest. ROLLBACK_0150 acts strictly off this table and refuses if any of these loads has changed since. Select-only for the app.';

alter table public.carrier_backfill_0150_provenance enable row level security;
create policy carrier_backfill_0150_provenance_select on public.carrier_backfill_0150_provenance
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','accountant']::public.org_role[]));
revoke all on public.carrier_backfill_0150_provenance from anon;
revoke all on public.carrier_backfill_0150_provenance from authenticated;
grant select on public.carrier_backfill_0150_provenance to authenticated;

insert into public.carrier_backfill_0150_provenance
  (load_id, organization_id, load_number, prior_carrier_id, prior_carrier_resolution, prior_carrier_locked_at, exception_record_id,
   prior_exception_status, prior_exception_resolved_by, prior_exception_resolved_at, prior_exception_resolution_note,
   prior_exception_reason, prior_exception_detail, closed_exception_status, closed_exception_note, expected_candidate_count, candidate_digest)
select p.load_id, p.organization_id, p.load_number, p.carrier_id, 'unresolved', p.carrier_locked_at, u.id,
       u.status, u.resolved_by, u.resolved_at, u.resolution_note, u.reason, u.detail,
       {q(CLOSE_STATUS)}::public.unresolved_record_status, {q(CLOSE_NOTE)}, m.n_cand, m.digest
from _mig0150_plan p
join public.unresolved_carrier_records u on u.id = p.exc_id
cross join _mig0150_snap_misc m
where p.is_candidate;

do $mig$
declare v_n integer; v_want integer;
begin
  select count(*) into v_want from _mig0150_plan where is_candidate;

  update public.loads l
     set carrier_resolution = null
    from _mig0150_plan p
   where l.id = p.load_id and p.is_candidate
     and l.carrier_resolution = 'unresolved' and l.carrier_id is null and l.carrier_locked_at is null and l.financial_dispatch_id is null;
  get diagnostics v_n = row_count;
  if v_n <> v_want then raise exception '0150 mutation: updated % load(s), expected %.', v_n, v_want; end if;

  update public.unresolved_carrier_records u
     set status = {q(CLOSE_STATUS)}::public.unresolved_record_status,
         resolved_at = now(),
         resolution_note = {q(CLOSE_NOTE)}
    from _mig0150_plan p
   where u.id = p.exc_id and p.is_candidate and u.status = 'unresolved' and u.resolved_by is null and u.resolved_at is null and u.resolution_note is null;
  get diagnostics v_n = row_count;
  if v_n <> v_want then raise exception '0150 mutation: closed % exception record(s), expected %.', v_n, v_want; end if;
end
$mig$;

-- ======================= PHASE 3 -- POSTCONDITIONS =============================
do $mig$
declare m record; v_n integer;
begin
  select * into m from _mig0150_snap_misc;

  -- exactly the candidates changed, and only carrier_resolution changed on them
  select count(*) into v_n from public.loads l join _mig0150_snap_loads s on s.id = l.id
   where (l.id in (select load_id from _mig0150_plan where is_candidate)
          and (l.carrier_resolution is not null or l.carrier_id is not null or l.carrier_locked_at is not null
               or md5((to_jsonb(l) - array['updated_at','carrier_resolution'])::text) <> s.core_md5))
      or (l.id not in (select load_id from _mig0150_plan where is_candidate) and md5(to_jsonb(l)::text) <> s.full_md5);
  if v_n <> 0 then raise exception '0150 postcondition: % load row(s) differ from the plan (a non-candidate changed, or a candidate changed beyond carrier_resolution).', v_n; end if;
  select count(*) into v_n from public.loads l where l.id not in (select id from _mig0150_snap_loads);
  if v_n <> 0 then raise exception '0150 postcondition: unexpected new load row(s).'; end if;

  select count(*) into v_n from public.unresolved_carrier_records u join _mig0150_snap_exc s on s.id = u.id
   where (u.id in (select exc_id from _mig0150_plan where is_candidate)
          and (u.status <> {q(CLOSE_STATUS)}::public.unresolved_record_status or u.resolved_at is null or u.resolved_by is not null or u.resolution_note is distinct from {q(CLOSE_NOTE)}
               or md5((to_jsonb(u) - array['updated_at','status','resolved_at','resolution_note'])::text) <> s.core_md5))
      or (u.id not in (select exc_id from _mig0150_plan where is_candidate) and md5(to_jsonb(u)::text) <> s.full_md5);
  if v_n <> 0 then raise exception '0150 postcondition: % exception record(s) differ from the plan.', v_n; end if;

  if (select count(*) from public.loads) <> m.n_loads then raise exception '0150 postcondition: loads count changed.'; end if;
  if (select count(*) from public.dispatches) <> m.n_dispatches then raise exception '0150 postcondition: dispatches count changed.'; end if;
  if (select count(*) from public.unresolved_carrier_records) <> m.n_exc then raise exception '0150 postcondition: exception record count changed (records are closed, never created or deleted).'; end if;
  if (select md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by p.load_id), '')) from public.carrier_backfill_0133_provenance p) <> m.prov0133_md5 then
    raise exception '0150 postcondition: carrier_backfill_0133_provenance changed (0150 never edits it).';
  end if;

  -- provenance complete and consistent
  select count(*) into v_n from public.carrier_backfill_0150_provenance;
  if v_n <> m.n_cand then raise exception '0150 postcondition: provenance rows % <> candidates %.', v_n, m.n_cand; end if;
  select count(*) into v_n from public.carrier_backfill_0150_provenance v
   where not exists (select 1 from public.loads l where l.id = v.load_id and l.organization_id = v.organization_id and l.carrier_resolution is null and l.carrier_id is null)
      or not exists (select 1 from public.unresolved_carrier_records u where u.id = v.exception_record_id and u.record_type = 'load' and u.record_id = v.load_id
                        and u.status = v.closed_exception_status and u.resolution_note = v.closed_exception_note)
      or v.prior_exception_status <> 'unresolved' or v.expected_candidate_count <> m.n_cand or v.candidate_digest <> m.digest;
  if v_n <> 0 then raise exception '0150 postcondition: % provenance row(s) inconsistent.', v_n; end if;

  -- no zero-dispatch unresolved load remains; no candidate keeps an open exception
  if exists (select 1 from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id)) then
    raise exception '0150 postcondition: a zero-dispatch unresolved load remains.';
  end if;
  if exists (select 1 from public.unresolved_carrier_records u join public.carrier_backfill_0150_provenance v on v.load_id = u.record_id
              where u.record_type = 'load' and u.status = 'unresolved') then
    raise exception '0150 postcondition: a normalised load still has an open exception record.';
  end if;

  -- the 0132 guards are untouched
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()')) <> m.guard_md5
     or (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()')) <> m.load_guard_md5 then
    raise exception '0150 postcondition: a 0132 guard function changed.';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'public.dispatches'::regclass and t.tgname = 'dispatches_guard_carrier_scope' and not t.tgisinternal and t.tgenabled in ('O','A')) then
    raise exception '0150 postcondition: the dispatch guard trigger is missing or disabled.';
  end if;

  raise notice '0150 complete: % load(s) returned to pending carrier assignment (digest %); their exception records archived; provenance written. No carrier was assigned.', m.n_cand, m.digest;
end
$mig$;

commit;
"""


# ---------------------------------------------------------------------------- read-only verifiers
def verifier_tail(title, label):
    return f"""verdict as (
  select count(*) filter (where result = 'PASS') as n_pass,
         count(*) filter (where result = 'FAIL') as n_fail,
         count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ({q(label + ' FAIL: ')} || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail
from rows r cross join verdict v
where v.gate = 0
union all
select 9000, 'RESULT', {q(title)}, 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows'
from verdict v
where v.gate = 0
order by 1;
"""


def common_checks(fp):
    """rows shared by preflight and post-apply: server + guard fingerprints."""
    return f"""  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 101, 'SERVER', 'version()', 'INFO', version()::text
  union all
  select 200, 'GUARD', '0132 guard_dispatch_carrier_scope() is the reviewed definition',
         case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()')) = {q(fp['guard_dispatch_carrier_scope'])} then 'PASS' else 'FAIL' end,
         coalesce((select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()')), 'MISSING')
  union all
  select 201, 'GUARD', '0132 guard_load_carrier_change() is the reviewed definition',
         case when (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()')) = {q(fp['guard_load_carrier_change'])} then 'PASS' else 'FAIL' end,
         coalesce((select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()')), 'MISSING')
  union all
  select 202, 'GUARD', 'trigger dispatches_guard_carrier_scope present and enabled (BEFORE, row-level, both row-writing events)',
         case when exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.dispatches') and t.tgname = 'dispatches_guard_carrier_scope' and not t.tgisinternal
                            and t.tgenabled in ('O','A') and (t.tgtype::int & 1) <> 0 and (t.tgtype::int & 2) <> 0 and (t.tgtype::int & 4) <> 0 and (t.tgtype::int & 16) <> 0
                            and t.tgfoid = to_regprocedure('public.guard_dispatch_carrier_scope()')::oid) then 'PASS' else 'FAIL' end,
         (select count(*) from pg_trigger t where t.tgrelid = to_regclass('public.dispatches') and not t.tgisinternal)::text || ' user triggers on dispatches'
  union all
  select 203, 'GUARD', 'proposal 0149 live: create_dispatch and cancel_dispatch declare the enum-typed c_active',
         case when (select count(*) from pg_proc x where x.oid in (to_regprocedure('public.create_dispatch(uuid,uuid,uuid,uuid,uuid,numeric,text)'), to_regprocedure('public.cancel_dispatch(uuid,text)'))
                     and regexp_replace(x.prosrc, '\\s+', '', 'g') like '%c\\_activeconstantpublic.dispatch\\_status[]%') = 2 then 'PASS' else 'FAIL' end,
         'live function bodies inspected'
"""


def preflight():
    fp = fingerprints()
    return f"""-- =============================================================================
-- preflight.sql
{HEADER_NOT_APPROVED}
--
-- Run AFTER 0130..0147 and 0149 and BEFORE applying 0150. READ-ONLY: ONE select statement over catalogs and
-- public tables; no data-/schema-changing statement, no transaction control, no temporary object.
-- The evidence counts use query_to_xml() over a catalog-validated, identifier-quoted SELECT count(*).
-- RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the statement RAISES
-- (invalid input syntax for type integer: "PREFLIGHT 0150 FAIL ...") whose text is the complete report.
-- To also check your approved count, replace the two marked null literals (same values as in proposed_0150.sql).
-- =============================================================================
with cfg as (
  select {PLACEHOLDER_COUNT} as expected_count,   -- <<< OWNER (optional here): approved candidate count
         {PLACEHOLDER_DIGEST} as expected_digest  -- <<< OWNER (optional here): approved digest
),
{analysis('')},
agg as (
  select count(*) as n_pool, count(*) filter (where problems = '') as n_cand, count(*) filter (where problems <> '') as n_bad,
         {DIGEST_EXPR} as digest
  from verdict_rows
),
rows as (
{common_checks(fp)}  union all
  select 300, '0133', 'carrier_backfill_0133_provenance and unresolved_carrier_records exist (0133 applied)',
         case when to_regclass('public.carrier_backfill_0133_provenance') is not null and to_regclass('public.unresolved_carrier_records') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all
  select 301, '0133', 'unresolved_record_status has the ''{CLOSE_STATUS}'' label',
         case when exists (select 1 from pg_enum e where e.enumtypid = to_regtype('public.unresolved_record_status') and e.enumlabel = {q(CLOSE_STATUS)}) then 'PASS' else 'FAIL' end,
         coalesce((select string_agg(e.enumlabel::text, ',' order by e.enumsortorder) from pg_enum e where e.enumtypid = to_regtype('public.unresolved_record_status')), 'MISSING')
  union all
  select 302, '0132', 'loads_carrier_resolution_values permits NULL',
         case when exists (select 1 from pg_constraint where conrelid = to_regclass('public.loads') and conname = 'loads_carrier_resolution_values' and pg_get_constraintdef(oid) ilike '%carrier_resolution IS NULL%') then 'PASS' else 'FAIL' end,
         coalesce((select pg_get_constraintdef(oid) from pg_constraint where conrelid = to_regclass('public.loads') and conname = 'loads_carrier_resolution_values'), 'MISSING')
  union all
  select 303, '0150', '0150 not already applied (carrier_backfill_0150_provenance absent)',
         case when to_regclass('public.carrier_backfill_0150_provenance') is null then 'PASS' else 'FAIL' end, 'catalog'
  union all
  select 304, '0142-0145', 'required carrier-evidence tables exist (' || array_to_string(array{[t for t in REQUIRED_EVIDENCE]!r}::text[], ', ') || ')',
         case when (select count(*) from evlive where required and rel is not null and has_col) = {len(REQUIRED_EVIDENCE)} then 'PASS' else 'FAIL' end,
         (select count(*) from evlive where rel is not null and has_col)::text || ' of ' || (select count(*) from evlive)::text || ' evidence tables present (absent tables contribute zero rows)'
  union all
  select 310, 'POOL', 'zero-dispatch loads currently carrier_resolution=''unresolved''', 'INFO', (select n_pool from agg)::text
  union all
  select 311, 'POOL', 'candidates (every condition met)', 'INFO', (select n_cand from agg)::text
  union all
  select 312, 'POOL', 'contradictory / unexpected evidence among the pool (must be 0)', case when (select n_bad from agg) = 0 then 'PASS' else 'FAIL' end, (select n_bad from agg)::text
  union all
  select 313, 'POOL', 'candidate digest', 'INFO', (select digest from agg)
  union all
  select 314, 'POOL', 'approved expected count (if supplied) equals the candidate count',
         case when (select expected_count from cfg) is null then 'INFO' when (select expected_count from cfg) = (select n_cand from agg) then 'PASS' else 'FAIL' end,
         coalesce((select expected_count from cfg)::text, 'not supplied to this verifier') || ' vs ' || (select n_cand from agg)::text
  union all
  select 315, 'POOL', 'approved expected digest (if supplied) equals the candidate digest',
         case when (select expected_digest from cfg) is null then 'INFO' when (select expected_digest from cfg) = (select digest from agg) then 'PASS' else 'FAIL' end,
         coalesce((select expected_digest from cfg), 'not supplied to this verifier')
  union all
  select 320, 'POOL', 'problem: ' || v.load_number || ' (' || v.load_id::text || ')', 'FAIL', v.problems from verdict_rows v where v.problems <> ''
  union all
  select 330, 'CONTEXT', 'unresolved loads that HAVE dispatches (left untouched by 0150)', 'INFO',
         (select count(*) from public.loads l where l.carrier_resolution = 'unresolved' and exists (select 1 from public.dispatches d where d.load_id = l.id))::text
  union all
  select 331, 'CONTEXT', 'loads with NULL carrier_resolution', 'INFO', (select count(*) from public.loads where carrier_resolution is null)::text
  union all
  select 332, 'CONTEXT', 'user triggers on public.loads (side effects of the 0150 write)', 'INFO',
         coalesce((select string_agg(t.tgname::text, ', ' order by t.tgname) from pg_trigger t where t.tgrelid = to_regclass('public.loads') and not t.tgisinternal), '(none)')
),
{verifier_tail('PREFLIGHT 0150: candidates are exactly the zero-evidence legacy unresolved loads', 'PREFLIGHT 0150')}"""


def post_apply():
    fp = fingerprints()
    return f"""-- =============================================================================
-- post_apply.sql
{HEADER_NOT_APPROVED}
--
-- Run AFTER applying 0150 (and any time later). READ-ONLY: ONE select statement. Every normalised load must
-- be in state A (still pending: carrier_id NULL, carrier_resolution NULL, no dispatch) or state B (claimed
-- since by its first dispatch: carrier_id set, carrier_resolution 'resolved', at least one dispatch, carrier
-- in the load's organization). Anything else fails. RESULT: rows INFO/PASS + a final RESULT | PASS row, or a
-- raised error whose text is the complete report.
-- =============================================================================
with pv as (
  select v.*, l.id as l_id, l.organization_id as l_org, l.carrier_id as l_carrier, l.carrier_resolution as l_res, l.carrier_locked_at as l_locked,
         (select count(*) from public.dispatches d where d.load_id = v.load_id) as n_disp,
         (select c.organization_id from public.carriers c where c.id = l.carrier_id) as carrier_org,
         u.status::text as u_status, u.resolution_note as u_note, u.record_type as u_type, u.record_id as u_rid, u.resolved_by as u_by, u.resolved_at as u_at
  from public.carrier_backfill_0150_provenance v
  left join public.loads l on l.id = v.load_id
  left join public.unresolved_carrier_records u on u.id = v.exception_record_id
),
st as (
  select pv.*,
         case when l_id is null then 'X-load-missing'
              when l_org is distinct from organization_id then 'X-org-changed'
              when l_carrier is null and l_res is null and n_disp = 0 then 'A'
              when l_carrier is not null and l_res = 'resolved' and n_disp > 0 and carrier_org = l_org then 'B'
              else 'X-unexpected-state' end as state
  from pv
),
rows as (
{common_checks(fp)}  union all
  select 300, 'PROVENANCE', 'carrier_backfill_0150_provenance exists', case when to_regclass('public.carrier_backfill_0150_provenance') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all
  select 301, 'PROVENANCE', 'provenance rows (loads normalised by 0150)', 'INFO', (select count(*) from pv)::text
  union all
  select 302, 'PROVENANCE', 'approved count / digest recorded', 'INFO',
         coalesce((select min(expected_candidate_count)::text || ' / ' || min(candidate_digest) from pv), 'no rows')
  union all
  select 303, 'PROVENANCE', 'every row records the same count, digest and count = number of rows',
         case when (select count(distinct expected_candidate_count) from pv) <= 1 and (select count(distinct candidate_digest) from pv) <= 1
                   and coalesce((select min(expected_candidate_count) from pv), 0) = (select count(*) from pv) then 'PASS' else 'FAIL' end,
         (select count(*) from pv)::text
  union all
  select 310, 'LOADS', 'still pending (state A: carrier_id NULL, carrier_resolution NULL, no dispatch)', 'INFO', (select count(*) from st where state = 'A')::text
  union all
  select 311, 'LOADS', 'claimed since by their first dispatch (state B)', 'INFO', (select count(*) from st where state = 'B')::text
  union all
  select 312, 'LOADS', 'every normalised load is in state A or B', case when not exists (select 1 from st where state not in ('A','B')) then 'PASS' else 'FAIL' end,
         coalesce((select string_agg(load_number || ':' || state, ', ' order by load_number) from st where state not in ('A','B')), 'none')
  union all
  select 313, 'LOADS', 'no state-A load carries a carrier_locked_at or financial_dispatch_id',
         case when not exists (select 1 from st join public.loads l on l.id = st.load_id where st.state = 'A' and (l.carrier_locked_at is not null or l.financial_dispatch_id is not null)) then 'PASS' else 'FAIL' end, 'loads'
  union all
  select 314, 'LOADS', 'no zero-dispatch load remains carrier_resolution=''unresolved''',
         case when not exists (select 1 from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id)) then 'PASS' else 'FAIL' end,
         (select count(*) from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id))::text
  union all
  select 320, 'EXCEPTIONS', 'every closed exception record is the archived_legacy record with the 0150 note, no resolver, still record_type=load for this load',
         case when not exists (select 1 from pv where u_status is distinct from closed_exception_status::text or u_note is distinct from closed_exception_note
                                or u_type is distinct from 'load' or u_rid is distinct from load_id or u_by is not null or u_at is null) then 'PASS' else 'FAIL' end,
         (select count(*) from pv where u_status is distinct from closed_exception_status::text or u_note is distinct from closed_exception_note or u_type is distinct from 'load' or u_rid is distinct from load_id or u_by is not null or u_at is null)::text || ' inconsistent'
  union all
  select 321, 'EXCEPTIONS', 'no normalised load has an open exception record',
         case when not exists (select 1 from public.unresolved_carrier_records u join pv on pv.load_id = u.record_id where u.record_type = 'load' and u.status = 'unresolved') then 'PASS' else 'FAIL' end, 'unresolved_carrier_records'
  union all
  select 322, 'EXCEPTIONS', 'prior exception state recorded (open, unresolved status, exact 0133 reason)',
         case when not exists (select 1 from pv where prior_exception_status::text <> 'unresolved' or prior_exception_reason <> {q(REASON)}
                                or prior_exception_detail <> jsonb_build_object('rule', {q(RULE)}, 'dispatches', '[]'::jsonb)) then 'PASS' else 'FAIL' end, 'provenance'
  union all
  select 330, 'LOAD', v.load_number || ' (' || v.load_id::text || ')', 'INFO', 'state ' || v.state || ', organization ' || v.organization_id::text from st v
),
{verifier_tail('POST-APPLY 0150: normalised loads and exception records are consistent', 'POST-APPLY 0150')}"""


def review():
    fp = fingerprints()
    return f"""-- =============================================================================
-- candidate_review.sql -- owner review of exactly which loads 0150 would change.
{HEADER_NOT_APPROVED}
--
-- READ-ONLY: ONE select statement; changes nothing and never fails on findings (it REPORTS). Run after
-- 0133 (and 0147/0149), before applying 0150. It lists every zero-dispatch load that 0133 left 'unresolved':
--   disposition CANDIDATE -> 0150 would return it to pending carrier assignment (carrier_resolution NULL)
--   disposition BLOCKED   -> contradictory/unexpected evidence; 0150 would ABORT until it is resolved
-- Shown per load: load number, organization (id + name), load status, age, evidence counts, exception id.
-- Customer/broker names, rates and addresses are deliberately NOT selected.
-- The SUMMARY rows give the count and digest to paste into proposed_0150.sql.
-- =============================================================================
with
{analysis('')},
agg as (
  select count(*) as n_pool, count(*) filter (where problems = '') as n_cand, count(*) filter (where problems <> '') as n_bad,
         {DIGEST_EXPR} as digest
  from verdict_rows
)
select 0 as ord, 'SUMMARY' as section, 'zero-dispatch loads left unresolved by 0133' as item, (select n_pool from agg)::text as value, null::text as detail
union all select 1, 'SUMMARY', 'CANDIDATES (approve this count)', (select n_cand from agg)::text, 'paste into v_expected_count in proposed_0150.sql'
union all select 2, 'SUMMARY', 'BLOCKED (contradictory evidence; 0150 aborts while > 0)', (select n_bad from agg)::text, null
union all select 3, 'SUMMARY', 'candidate digest (REQUIRED: paste into v_expected_digest)', (select digest from agg), 'md5 of the candidate load ids, sorted'
union all select 4, 'SUMMARY', 'unresolved loads WITH dispatches (never touched by 0150)',
       (select count(*) from public.loads l where l.carrier_resolution = 'unresolved' and exists (select 1 from public.dispatches d where d.load_id = l.id))::text, 'these still need a human decision'
union all
select 10 + row_number() over (order by v.load_number, v.load_id)::int, case when v.problems = '' then 'CANDIDATE' else 'BLOCKED' end,
       v.load_number || '  [' || v.load_id::text || ']',
       'org ' || coalesce((select o.name::text from public.organizations o where o.id = v.organization_id), '?') || ' [' || v.organization_id::text || '] | load status ' || v.load_status
         || ' | org carriers ' || (select count(*) from public.carriers c where c.organization_id = v.organization_id)::text,
       case when v.problems = '' then 'exception ' || v.exc_id::text || ' opened ' || coalesce((select u.created_at::date::text from public.unresolved_carrier_records u where u.id = v.exc_id), '?')
                                  || ' | no dispatch, no carrier/financial evidence | first dispatch will choose the carrier'
            else 'PROBLEM: ' || v.problems end
from verdict_rows v
order by 1;
"""


# ---------------------------------------------------------------------------- rollback.sql
def rollback():
    return f"""-- =============================================================================
-- rollback.sql -- EMERGENCY reversal of proposal 0150 (returns the loads to carrier_resolution='unresolved').
{HEADER_NOT_APPROVED}
--
-- Acts STRICTLY off public.carrier_backfill_0150_provenance and REFUSES (changing nothing) unless every
-- normalised load is still exactly as 0150 left it: carrier_id NULL, carrier_resolution NULL, carrier_locked_at
-- and financial_dispatch_id NULL, ZERO dispatches; its exception record still archived_legacy with the 0150
-- note and no newer open record for the load. If ANY load has since been claimed by a first dispatch the whole
-- rollback refuses (a claimed load must never be re-blocked): stop dispatching with DISPATCH_WRITES_DISABLED=1
-- instead, or resolve individually. Restores the loads' carrier_resolution, the exception records' status/
-- resolved_*/note, then drops the provenance table. updated_at is not restorable (set_updated_at trigger).
-- Must be rolled back BEFORE ROLLBACK_0133 (which refuses while any provenance load has changed).
-- Single transaction; run once.
-- =============================================================================
begin;

do $mig$
declare v_n integer; v_rows integer; v_list text;
begin
  if to_regclass('public.carrier_backfill_0150_provenance') is null then raise exception 'ROLLBACK 0150: provenance table missing -- nothing to roll back (or already rolled back). STOP.'; end if;
  select count(*) into v_rows from public.carrier_backfill_0150_provenance;

  -- lock in the same deterministic order as the migration
  perform 1 from public.loads l where l.id in (select load_id from public.carrier_backfill_0150_provenance) order by l.id for update;
  perform 1 from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id in (select load_id from public.carrier_backfill_0150_provenance) order by u.id for update;

  create temp table _rb0150_bad on commit drop as
    select v.load_number, v.load_id,
           concat_ws('; ',
             case when l.id is null then 'load missing' end,
             case when l.id is not null and (l.carrier_id is not null or l.carrier_resolution is not null or l.carrier_locked_at is not null or l.financial_dispatch_id is not null)
                  then 'load changed since 0150 (carrier_id=' || coalesce(l.carrier_id::text, 'NULL') || ', carrier_resolution=' || coalesce(l.carrier_resolution, 'NULL') || ')' end,
             case when exists (select 1 from public.dispatches d where d.load_id = v.load_id) then 'now has dispatch(es)' end,
             case when not exists (select 1 from public.unresolved_carrier_records u where u.id = v.exception_record_id and u.record_type = 'load' and u.record_id = v.load_id
                                      and u.status = v.closed_exception_status and u.resolution_note = v.closed_exception_note) then 'exception record changed since 0150' end,
             case when exists (select 1 from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id = v.load_id and u.status = 'unresolved') then 'a newer OPEN exception record exists' end) as problem
    from public.carrier_backfill_0150_provenance v
    left join public.loads l on l.id = v.load_id;
  select count(*) into v_n from _rb0150_bad where problem <> '';
  if v_n > 0 then
    select string_agg(load_number || ' [' || problem || ']', E'\\n' order by load_number) into v_list from _rb0150_bad where problem <> '';
    raise exception E'ROLLBACK 0150 REFUSED: % of % normalised load(s) changed since 0150 -- nothing was changed:\\n%', v_n, v_rows, v_list;
  end if;

  update public.loads l set carrier_resolution = 'unresolved'
   from public.carrier_backfill_0150_provenance v
   where l.id = v.load_id and l.carrier_resolution is null and l.carrier_id is null;
  get diagnostics v_n = row_count;
  if v_n <> v_rows then raise exception 'ROLLBACK 0150: restored % load(s), expected %.', v_n, v_rows; end if;

  update public.unresolved_carrier_records u
     set status = v.prior_exception_status, resolved_by = v.prior_exception_resolved_by,
         resolved_at = v.prior_exception_resolved_at, resolution_note = v.prior_exception_resolution_note
    from public.carrier_backfill_0150_provenance v
   where u.id = v.exception_record_id and u.status = v.closed_exception_status and u.resolution_note = v.closed_exception_note;
  get diagnostics v_n = row_count;
  if v_n <> v_rows then raise exception 'ROLLBACK 0150: restored % exception record(s), expected %.', v_n, v_rows; end if;

  drop table public.carrier_backfill_0150_provenance;

  if exists (select 1 from public.loads l where l.carrier_resolution = 'unresolved' and not exists (select 1 from public.dispatches d where d.load_id = l.id)
               and not exists (select 1 from public.unresolved_carrier_records u where u.record_type = 'load' and u.record_id = l.id and u.status = 'unresolved')) then
    raise exception 'ROLLBACK 0150 postcondition: a restored unresolved load has no open exception record.';
  end if;
  raise notice 'ROLLBACK 0150 complete: % load(s) restored to carrier_resolution=unresolved; exception records reopened; provenance dropped.', v_rows;
end
$mig$;

commit;
"""


def build_all():
    return {
        "proposed_0150.sql": proposed(),
        "preflight.sql": preflight(),
        "candidate_review.sql": review(),
        "post_apply.sql": post_apply(),
        "rollback.sql": rollback(),
    }


if __name__ == "__main__":
    files = build_all()
    if "--check" in sys.argv:
        stale = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t]
        print("stale: " + ", ".join(stale) if stale else "all generated files are current")
        sys.exit(1 if stale else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {sha256(t.encode())[:16]})")
