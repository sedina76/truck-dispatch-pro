-- =============================================================================
-- proposed_0150.sql -- BLOCKER A: normalize zero-evidence legacy 'unresolved' loads.
-- PROPOSAL 0150 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: applies AFTER 0130..0147 and 0149. Current proposal 0148 is unrelated and MUST be renumbered to 0153 or higher before promotion.
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
-- and it is the exact open 0133 record (organization, reason text, detail {rule: C4_zero_dispatch,
-- dispatches: []}, unresolved, no resolver); a matching 0133 provenance row; valid organization.
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

  if v_expected_digest is null or v_expected_digest !~ '^[0-9a-f]{32}$' then
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
  if not exists (select 1 from pg_enum e where e.enumtypid = to_regtype('public.unresolved_record_status') and e.enumlabel = 'archived_legacy') then
    raise exception '0150 precondition: unresolved_record_status has no ''archived_legacy'' label. STOP.';
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
                  and regexp_replace(x.prosrc, '\s+', '', 'g') like '%c\_activeconstantpublic.dispatch\_status[]%')
     or not exists (select 1 from pg_proc x where x.oid = to_regprocedure('public.cancel_dispatch(uuid,text)')
                  and regexp_replace(x.prosrc, '\s+', '', 'g') like '%c\_activeconstantpublic.dispatch\_status[]%') then
    raise exception '0150 precondition: proposal 0149 (enum-typed c_active in create_dispatch/cancel_dispatch) is not applied. STOP.';
  end if;
  -- the 0132 guards must be byte-for-byte (normalised) the reviewed 0132 definitions: 0150 relies on their claim-on-first-dispatch semantics
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_guard_md5
    from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()');
  select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) into v_load_guard_md5
    from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()');
  if v_guard_md5 is distinct from 'f9ae250c3e01e4a6317c6c7fd751586e' then raise exception '0150 precondition: guard_dispatch_carrier_scope() is not the reviewed 0132 definition (md5 %). STOP.', v_guard_md5; end if;
  if v_load_guard_md5 is distinct from 'c6ecf184de849411d32eee8b0cce3a4b' then raise exception '0150 precondition: guard_load_carrier_change() is not the reviewed 0132 definition (md5 %). STOP.', v_load_guard_md5; end if;

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
  evtab(tbl, col, required) as (values
      ('public.invoices', 'load_id', false),
      ('public.dispatch_advances', 'load_id', false),
      ('public.settlement_line_items', 'load_id', false),
      ('public.driver_settlement_items', 'load_id', false),
      ('public.expenses', 'load_id', false),
      ('public.compliance_overrides', 'load_id', false),
      ('public.dispatch_resource_reassignments', 'load_id', false),
      ('public.carrier_invoice_loads', 'load_id', true),
      ('public.carrier_invoice_line_items', 'source_load_id', true),
      ('public.carrier_dispatch_service_billing_lines', 'load_id', true)
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
               and u.reason = 'No dispatch on this load; a responsible carrier cannot be determined.'
               and u.detail = jsonb_build_object('rule', 'C4_zero_dispatch', 'dispatches', '[]'::jsonb)
               and u.resolved_by is null and u.resolved_at is null and u.resolution_note is null) as n_exc_exact,
           (select u.id from public.unresolved_carrier_records u
             where u.record_type = 'load' and u.record_id = p.load_id and u.status = 'unresolved'
               and u.organization_id = p.organization_id
               and u.reason = 'No dispatch on this load; a responsible carrier cannot be determined.'
               and u.detail = jsonb_build_object('rule', 'C4_zero_dispatch', 'dispatches', '[]'::jsonb)
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
  )
  select v.*, (v.problems = '') as is_candidate from verdict_rows v;

  select count(*), count(*) filter (where is_candidate), count(*) filter (where not is_candidate)
    into v_n_pool, v_n_cand, v_n_bad from _mig0150_plan;

  if v_n_bad > 0 then
    select string_agg(load_number || ' [' || problems || ']', E'\n' order by load_number) into v_list from (select * from _mig0150_plan where not is_candidate order by load_number limit 25) z;
    raise exception E'0150 precondition: % zero-dispatch unresolved load(s) carry contradictory or unexpected evidence -- nothing was changed. Resolve them first (see candidate_review.sql):\n%', v_n_bad, v_list;
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
       'archived_legacy'::public.unresolved_record_status, 'Closed by migration 0150: this legacy load has no dispatch and no carrier evidence of any kind, so no carrier can be proven from data. It was returned to pending carrier assignment (loads.carrier_id NULL, loads.carrier_resolution NULL); its carrier is established atomically by guard_dispatch_carrier_scope() (0132) at the first dispatch, chosen and authorized by the dispatching user. No carrier was assigned by this migration.', m.n_cand, m.digest
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
     set status = 'archived_legacy'::public.unresolved_record_status,
         resolved_at = now(),
         resolution_note = 'Closed by migration 0150: this legacy load has no dispatch and no carrier evidence of any kind, so no carrier can be proven from data. It was returned to pending carrier assignment (loads.carrier_id NULL, loads.carrier_resolution NULL); its carrier is established atomically by guard_dispatch_carrier_scope() (0132) at the first dispatch, chosen and authorized by the dispatching user. No carrier was assigned by this migration.'
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
          and (u.status <> 'archived_legacy'::public.unresolved_record_status or u.resolved_at is null or u.resolved_by is not null or u.resolution_note is distinct from 'Closed by migration 0150: this legacy load has no dispatch and no carrier evidence of any kind, so no carrier can be proven from data. It was returned to pending carrier assignment (loads.carrier_id NULL, loads.carrier_resolution NULL); its carrier is established atomically by guard_dispatch_carrier_scope() (0132) at the first dispatch, chosen and authorized by the dispatching user. No carrier was assigned by this migration.'
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
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_dispatch_carrier_scope()')) <> m.guard_md5
     or (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.guard_load_carrier_change()')) <> m.load_guard_md5 then
    raise exception '0150 postcondition: a 0132 guard function changed.';
  end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'public.dispatches'::regclass and t.tgname = 'dispatches_guard_carrier_scope' and not t.tgisinternal and t.tgenabled in ('O','A')) then
    raise exception '0150 postcondition: the dispatch guard trigger is missing or disabled.';
  end if;

  raise notice '0150 complete: % load(s) returned to pending carrier assignment (digest %); their exception records archived; provenance written. No carrier was assigned.', m.n_cand, m.digest;
end
$mig$;

commit;
