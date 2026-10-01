-- proposed_0157.sql -- F-08 (carrier invoices): carrier-invoice factoring submission, server-selected relationship, immutable snapshots, audit ledger, operator gate (DISABLED by default)
-- PROPOSAL 0157 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 -> 0155 -> (0156 optional, legacy, superseded) -> 0157 (this). The unrelated proposal 0148 must be renumbered to 0153 (unused) or to 0158 or higher.
--
-- OWNER DECISIONS IMPLEMENTED (recorded in 0156/OWNER_DECISIONS.md; they do not authorize production execution):
--   D-08a NO submission-time reconstruction for legacy invoices; D-08b factoring ONLY for carrier_invoices (legacy invoices are refused by construction: the RPC takes a carrier_invoices id and reads no legacy table);
--   D-57h supersedes D-08c for this pilot: ONLY owner/admin may submit; dispatcher grants permit preview/preparation only; the relationship is chosen SERVER-SIDE (the carrier's single active default) -- the client supplies only the invoice id + an idempotency key;
--   D-08d dispatch-service fees are a separate receivable: dispatch_service_invoice documents and any dispatch_service_fee line are refused; D-08e only ISSUED + UNPAID (amount_paid = 0) freight invoices;
--   D-08f carriers that are direct-billing / not factoring-eligible (or invoices issued while the carrier was direct-billing) are refused; D-08g advance/fee/reserve terms at submission are recorded in an IMMUTABLE snapshot;
--   D-08h only the SQL-Editor operator may enable/disable the gate (decision reference required, every change audited; disabling blocks NEW submissions only); D-08i the gate cannot be enabled while any 0155 review is pending,
--   any factoring exception is open, or the legacy 0156 gate is enabled (enforced by a trigger).
-- SCHEMA NOTE (carrier invoices have NO sent/viewed/disputed/cancelled state): 'issued' is the closest eligible state; 'draft'/'ready_for_issue'/'voided' are refused; no dispute concept exists (open exception records block instead).
-- Refuses (nothing changed) unless 0155 is applied, no 0157 object or same-named function exists, the schema objects it needs exist, and the legacy 0156 gate (if present) is disabled. One transaction, 15 s lock_timeout.
begin;
set local lock_timeout = '15s';

do $mig$
declare v_n integer; v_b boolean;
begin
  if to_regprocedure('public.carrier_evidence_for_relationship(uuid)') is null or to_regclass('public.carrier_inference_review_0155') is null then raise exception '0157 precondition: proposal 0155 is not applied. STOP.'; end if;
  if to_regclass('public.carrier_invoices') is null or to_regclass('public.carrier_invoice_issuance_snapshots') is null or to_regclass('public.carrier_invoice_line_items') is null then raise exception '0157 precondition: carrier invoice tables (0142/0144) missing. STOP.'; end if;
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamp with time zone,text,text)') is null or to_regclass('public.carrier_invoice_loads') is null or to_regclass('public.load_financials') is null or to_regclass('public.carrier_dispatch_service_agreement_versions') is null or to_regclass('public.carrier_dispatch_service_billing_lines') is null then raise exception '0157 precondition: issuance objects (0144/0145) missing. STOP.'; end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then raise exception '0157 precondition: classify_carrier_factoring_readiness missing. STOP.'; end if;
  select count(*) into v_n from pg_proc p where p.proname in ('submit_carrier_invoice_to_factor', 'preview_carrier_invoice_factoring', 'withdraw_carrier_invoice_factoring_submission', 'set_carrier_factoring_submitter', '_cif_evaluate_0157', '_cif_authorize_0157', '_cif_refuse_0157', 'verify_carrier_invoice_factoring_audit_chain_0157',
    'preview_carrier_invoice_issuance', 'create_carrier_invoice_draft_from_loads', 'mark_carrier_invoice_ready_for_issue', 'discard_carrier_invoice_draft', 'issue_prepared_carrier_invoice', 'preview_carrier_invoice_reissue', 'reissue_carrier_invoice',
    '_cif_freeze_0157', '_cif_diff_frozen_0157', '_cif_selection_0157', '_cif_create_draft_0157', '_cif_dispatch_fee_0157', '_cif_reissue_eval_0157', '_cif_issuance_guard_0157');
  if v_n <> 0 then raise exception '0157 precondition: % function(s) with a 0157 name already exist (any schema). STOP.', v_n; end if;
  if to_regclass('public.carrier_invoice_factoring_gate_0157') is not null or to_regclass('public.carrier_invoice_factoring_submissions_0157') is not null or to_regclass('public.carrier_invoice_factoring_snapshots_0157') is not null
     or to_regclass('public.carrier_invoice_factoring_audit_0157') is not null or to_regclass('public.carrier_factoring_submitter_grants_0157') is not null
     or to_regclass('public.carrier_invoice_issuance_terms_0157') is not null or to_regclass('public.carrier_invoice_workflow_ops_0157') is not null or to_regclass('public.carrier_invoice_billable_ledger_0157') is not null
     or to_regclass('public.carrier_invoice_reissues_0157') is not null or to_regclass('public.carrier_invoice_dispatch_fee_links_0157') is not null then raise exception '0157 precondition: a 0157 table already exists. STOP.'; end if;
  if to_regclass('public.factoring_submission_gate') is not null then   -- dynamic SQL: the table exists only if 0156 was applied (a static reference is planned even when the branch is not taken)
    execute 'select exists (select 1 from public.factoring_submission_gate g where g.enabled)' into v_b;
    if v_b then raise exception '0157 precondition: the legacy 0156 gate is ENABLED (D-08b: legacy invoices are excluded). STOP.'; end if;
  end if;
  raise notice '0157 PHASE 1 preconditions passed.';
end
$mig$;

create temp table _mig0157_snap on commit drop as
select (select md5(coalesce(string_agg(to_jsonb(c)::text, '|' order by c.id), '')) from public.carrier_invoices c) as ci_fp,
       (select md5(coalesce(string_agg(to_jsonb(r)::text, '|' order by r.id), '')) from public.factoring_relationships r) as rel_fp,
       (select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f) as fi_fp;

-- ======================= TABLES =====================================================================================
create table public.carrier_invoice_factoring_gate_0157 (
  singleton    boolean primary key default true check (singleton),
  enabled      boolean not null default false,
  decision_ref text,
  changed_by   text,
  changed_at   timestamptz,
  constraint carrier_invoice_factoring_gate_needs_decision check (not enabled or (decision_ref is not null and pg_catalog.btrim(decision_ref) <> ''))
);
insert into public.carrier_invoice_factoring_gate_0157 (singleton, enabled) values (true, false);

create table public.carrier_factoring_submitter_grants_0157 (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  carrier_id      uuid not null references public.carriers (id) on delete restrict,
  profile_id      uuid not null,
  reason          text not null check (pg_catalog.btrim(reason) <> ''),
  granted_by      uuid,
  granted_at      timestamptz not null default now(),
  revoked_by      uuid,
  revoked_at      timestamptz,
  revoke_reason   text
);
create unique index carrier_factoring_submitter_grants_0157_active on public.carrier_factoring_submitter_grants_0157 (carrier_id, profile_id) where revoked_at is null;

create table public.carrier_invoice_factoring_submissions_0157 (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references public.organizations (id) on delete restrict,
  carrier_id             uuid not null references public.carriers (id) on delete restrict,
  carrier_invoice_id     uuid not null references public.carrier_invoices (id) on delete restrict,
  relationship_id        uuid not null references public.factoring_relationships (id) on delete restrict,
  factoring_company_id   uuid not null references public.factoring_companies (id) on delete restrict,
  status                 text not null default 'submitted' check (status in ('submitted', 'withdrawn')),
  idempotency_key        text not null check (pg_catalog.btrim(idempotency_key) <> ''),
  submitted_by           uuid not null,
  submitted_at           timestamptz not null default now(),
  status_changed_at      timestamptz,
  status_changed_by      uuid,
  status_reason          text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint carrier_invoice_factoring_submissions_0157_key unique (organization_id, idempotency_key)
);
-- at most ONE live submission per carrier invoice (a withdrawn one does not block a new submission)
create unique index carrier_invoice_factoring_submissions_0157_one_active on public.carrier_invoice_factoring_submissions_0157 (carrier_invoice_id) where status = 'submitted';

create table public.carrier_invoice_factoring_snapshots_0157 (
  submission_id               uuid primary key references public.carrier_invoice_factoring_submissions_0157 (id) on delete restrict,
  organization_id             uuid not null references public.organizations (id) on delete restrict,
  carrier_id                  uuid not null references public.carriers (id) on delete restrict,
  carrier_legal_name          text,
  carrier_invoice_id          uuid not null references public.carrier_invoices (id) on delete restrict,
  invoice_number              text not null,
  currency                    text not null,
  invoice_total_amount        numeric(12, 2) not null,
  issuance_snapshot_id        uuid not null references public.carrier_invoice_issuance_snapshots (id) on delete restrict,
  recipient_type              text,
  recipient_broker_id         uuid,
  recipient_customer_id       uuid,
  factoring_company_id        uuid not null references public.factoring_companies (id) on delete restrict,
  factoring_company_name      text,
  relationship_id             uuid not null references public.factoring_relationships (id) on delete restrict,
  relationship_name           text,
  advance_percentage          numeric(7, 4) not null,
  factoring_fee_percentage    numeric(7, 4) not null,
  reserve_percentage          numeric(7, 4) not null,
  fee_timing                  text not null,
  other_fee_amount            numeric(12, 2) not null,
  expected_advance_amount     numeric(12, 2) not null,
  factoring_fee_amount        numeric(12, 2) not null,
  reserve_amount              numeric(12, 2) not null,
  expected_funding_amount     numeric(12, 2) not null,
  remittance_instructions     text,
  noa_reference               text,
  noa_effective_date          date,
  noa_approved_at             timestamptz,
  noa_document_id             uuid,
  submission_method           text,
  submission_destination      text,
  issuance_relationship_id    uuid,
  readiness                   jsonb not null,
  authorization_basis         text not null check (authorization_basis in ('owner', 'admin')),
  authorization_grant_id      uuid,
  gate_decision_ref           text not null,
  submitted_by                uuid not null,
  submitted_at                timestamptz not null
);

create table public.carrier_invoice_factoring_audit_0157 (
  seq               bigint primary key,
  occurred_at       timestamptz not null default pg_catalog.clock_timestamp(),
  organization_id   uuid references public.organizations (id) on delete restrict,
  actor_uid         uuid,
  actor_db_user     text not null default session_user,
  event_type        text not null check (event_type in ('submission', 'withdrawal', 'gate_change', 'grant_change', 'draft_creation', 'ready', 'draft_discard', 'issuance', 'reissue')),
  outcome           text not null check (outcome in ('success', 'refusal')),
  code              text not null,
  message           text,
  carrier_id        uuid,
  carrier_invoice_id uuid,
  submission_id     uuid,
  detail            jsonb not null default '{}'::jsonb,
  idempotency_key   text,
  prev_hash         text,
  row_hash          text not null
);
create unique index carrier_invoice_factoring_audit_0157_key on public.carrier_invoice_factoring_audit_0157 (organization_id, event_type, idempotency_key) where outcome = 'success' and idempotency_key is not null;

-- ---- issuance workflow tables (D-57): immutable issuance terms, workflow idempotency, billable-record ledger, reissue links, dispatch-fee links. ALL foreign keys are ON DELETE RESTRICT: no cascade can remove history.
create table public.carrier_invoice_issuance_terms_0157 (
  id                     uuid primary key default gen_random_uuid(),
  invoice_id             uuid not null unique references public.carrier_invoices (id) on delete restrict,
  organization_id        uuid not null references public.organizations (id) on delete restrict,
  carrier_id             uuid not null references public.carriers (id) on delete restrict,
  factoring_mode         text not null check (factoring_mode in ('factored', 'direct_billing')),
  recipient_type         text not null check (recipient_type in ('broker', 'customer')),
  recipient_broker_id    uuid,
  recipient_customer_id  uuid,
  frozen                 jsonb not null,
  frozen_fingerprint     text not null,
  issuance_snapshot_id   uuid not null references public.carrier_invoice_issuance_snapshots (id) on delete restrict,
  issued_by              uuid not null,
  issued_at              timestamptz not null default now(),
  idempotency_key        text not null check (pg_catalog.btrim(idempotency_key) <> ''),
  constraint carrier_invoice_issuance_terms_0157_key unique (organization_id, idempotency_key),
  constraint carrier_invoice_issuance_terms_0157_shape check ((factoring_mode = 'factored') = (frozen ->> 'relationship_id' is not null))
);

create table public.carrier_invoice_workflow_ops_0157 (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations (id) on delete restrict,
  operation           text not null check (operation in ('create_draft', 'mark_ready', 'issue', 'reissue', 'discard_draft')),
  idempotency_key     text not null check (pg_catalog.btrim(idempotency_key) <> ''),
  request_fingerprint text not null,
  invoice_id          uuid references public.carrier_invoices (id) on delete restrict,
  result              jsonb not null,
  created_by          uuid not null,
  created_at          timestamptz not null default now(),
  constraint carrier_invoice_workflow_ops_0157_key unique (organization_id, idempotency_key)
);

create table public.carrier_invoice_billable_ledger_0157 (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.organizations (id) on delete restrict,
  carrier_id       uuid not null references public.carriers (id) on delete restrict,
  load_id          uuid not null references public.loads (id) on delete restrict,
  invoice_id       uuid not null references public.carrier_invoices (id) on delete restrict,
  amount           numeric(12, 2) not null check (amount > 0),
  created_by       uuid not null,
  created_at       timestamptz not null default now(),
  released_at      timestamptz,
  released_reason  text,
  constraint carrier_invoice_billable_ledger_0157_release check ((released_at is null) = (released_reason is null))
);
-- a billable record (load) can be on at most ONE live (unreleased) invoice: the duplicate-billing barrier
create unique index carrier_invoice_billable_ledger_0157_live on public.carrier_invoice_billable_ledger_0157 (load_id) where released_at is null;
create index carrier_invoice_billable_ledger_0157_invoice on public.carrier_invoice_billable_ledger_0157 (invoice_id);

create table public.carrier_invoice_reissues_0157 (
  id                      uuid primary key default gen_random_uuid(),
  organization_id         uuid not null references public.organizations (id) on delete restrict,
  carrier_id              uuid not null references public.carriers (id) on delete restrict,
  original_invoice_id     uuid not null unique references public.carrier_invoices (id) on delete restrict,
  replacement_invoice_id  uuid not null unique references public.carrier_invoices (id) on delete restrict,
  reason                  text not null check (pg_catalog.btrim(reason) <> ''),
  drift_dimensions        text[] not null default '{}',
  reissued_by             uuid not null,
  reissued_at             timestamptz not null default now(),
  idempotency_key         text not null check (pg_catalog.btrim(idempotency_key) <> ''),
  constraint carrier_invoice_reissues_0157_distinct check (original_invoice_id <> replacement_invoice_id),
  constraint carrier_invoice_reissues_0157_key unique (organization_id, idempotency_key)
);

create table public.carrier_invoice_dispatch_fee_links_0157 (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references public.organizations (id) on delete restrict,
  carrier_id          uuid not null references public.carriers (id) on delete restrict,
  freight_invoice_id  uuid not null unique references public.carrier_invoices (id) on delete restrict,
  dispatch_invoice_id uuid not null references public.carrier_invoices (id) on delete restrict,
  disposition         text not null check (disposition in ('draft_created', 'carried_over')),
  created_by          uuid not null,
  created_at          timestamptz not null default now(),
  constraint carrier_invoice_dispatch_fee_links_0157_distinct check (freight_invoice_id <> dispatch_invoice_id)
);

-- ======================= TRIGGERS (integrity) =========================================================================
create function public._cif_audit_chain_0157() returns trigger language plpgsql set search_path = pg_catalog, pg_temp as
$t$
declare v_prev text; v_seq bigint;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('carrier_invoice_factoring_audit_0157', 0));
  select a.seq, a.row_hash into v_seq, v_prev from public.carrier_invoice_factoring_audit_0157 a order by a.seq desc limit 1;
  new.seq := coalesce(v_seq, 0) + 1;
  new.prev_hash := v_prev;
  new.row_hash := pg_catalog.md5(coalesce(v_prev, '') || '|' || new.seq::text || '|' || new.occurred_at::text || '|' || coalesce(new.organization_id::text, '') || '|' || coalesce(new.actor_uid::text, '') || '|' || new.actor_db_user || '|' || new.event_type || '|' || new.outcome
                          || '|' || new.code || '|' || coalesce(new.carrier_invoice_id::text, '') || '|' || coalesce(new.submission_id::text, '') || '|' || new.detail::text || '|' || coalesce(new.idempotency_key, ''));
  return new;
end $t$;
create trigger carrier_invoice_factoring_audit_0157_chain before insert on public.carrier_invoice_factoring_audit_0157 for each row execute function public._cif_audit_chain_0157();

create function public._cif_immutable_0157() returns trigger language plpgsql set search_path = pg_catalog, pg_temp as
$t$ begin raise exception '% rows are append-only / immutable historical records.', tg_table_name using errcode = '42501'; end $t$;
create trigger carrier_invoice_factoring_audit_0157_immutable before update or delete on public.carrier_invoice_factoring_audit_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_factoring_audit_0157_no_truncate before truncate on public.carrier_invoice_factoring_audit_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_invoice_factoring_snapshots_0157_immutable before update or delete on public.carrier_invoice_factoring_snapshots_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_factoring_snapshots_0157_no_truncate before truncate on public.carrier_invoice_factoring_snapshots_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_invoice_factoring_submissions_0157_no_delete before delete on public.carrier_invoice_factoring_submissions_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_factoring_submissions_0157_no_truncate before truncate on public.carrier_invoice_factoring_submissions_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_factoring_submitter_grants_0157_no_delete before delete on public.carrier_factoring_submitter_grants_0157 for each row execute function public._cif_immutable_0157();

-- submissions: identity columns are frozen; the only permitted change is submitted -> withdrawn (terminal; D-57e: no rejected/funded state exists until a factor-response workflow and authorized writer exist); consistency of organization / carrier / relationship is enforced on insert
create function public._cif_submission_guard_0157() returns trigger language plpgsql set search_path = pg_catalog, pg_temp as
$t$
declare v_ci record; v_rel record; v_co record;
begin
  if tg_op = 'INSERT' then
    select c.organization_id, c.carrier_id, c.invoice_document_type into v_ci from public.carrier_invoices c where c.id = new.carrier_invoice_id;
    select r.organization_id, r.carrier_id, r.factoring_company_id into v_rel from public.factoring_relationships r where r.id = new.relationship_id;
    select f.organization_id into v_co from public.factoring_companies f where f.id = new.factoring_company_id;
    if v_ci.organization_id is distinct from new.organization_id or v_ci.carrier_id is distinct from new.carrier_id or v_ci.invoice_document_type is distinct from 'carrier_freight_invoice' then raise exception 'submission: the carrier invoice does not match the stated organization/carrier (or is not a freight invoice).' using errcode = '42501'; end if;
    if v_rel.organization_id is distinct from new.organization_id or v_rel.carrier_id is distinct from new.carrier_id or v_rel.factoring_company_id is distinct from new.factoring_company_id or v_co.organization_id is distinct from new.organization_id then raise exception 'submission: the relationship/factor does not belong to this carrier and organization.' using errcode = '42501'; end if;
    if new.status <> 'submitted' then raise exception 'submission: a new submission must start as submitted.' using errcode = '42501'; end if;
    return new;
  end if;
  if new.organization_id is distinct from old.organization_id or new.carrier_id is distinct from old.carrier_id or new.carrier_invoice_id is distinct from old.carrier_invoice_id or new.relationship_id is distinct from old.relationship_id
     or new.factoring_company_id is distinct from old.factoring_company_id or new.idempotency_key is distinct from old.idempotency_key or new.submitted_by is distinct from old.submitted_by or new.submitted_at is distinct from old.submitted_at or new.id is distinct from old.id then
    raise exception 'submission: identity columns are immutable.' using errcode = '42501';
  end if;
  if new.status is distinct from old.status and not (old.status = 'submitted' and new.status = 'withdrawn') then
    raise exception 'submission: status transition % -> % is not permitted (permitted: submitted -> withdrawn; all others are terminal).', old.status, new.status using errcode = '42501';
  end if;
  return new;
end $t$;
create trigger carrier_invoice_factoring_submissions_0157_guard before insert or update on public.carrier_invoice_factoring_submissions_0157 for each row execute function public._cif_submission_guard_0157();

create function public._cif_snapshot_guard_0157() returns trigger language plpgsql set search_path = pg_catalog, pg_temp as
$t$
declare v_s record;
begin
  select s.organization_id, s.carrier_id, s.carrier_invoice_id, s.relationship_id, s.factoring_company_id into v_s from public.carrier_invoice_factoring_submissions_0157 s where s.id = new.submission_id;
  if v_s.organization_id is distinct from new.organization_id or v_s.carrier_id is distinct from new.carrier_id or v_s.carrier_invoice_id is distinct from new.carrier_invoice_id or v_s.relationship_id is distinct from new.relationship_id or v_s.factoring_company_id is distinct from new.factoring_company_id then
    raise exception 'snapshot: does not match its submission.' using errcode = '42501';
  end if;
  return new;
end $t$;
create trigger carrier_invoice_factoring_snapshots_0157_guard before insert on public.carrier_invoice_factoring_snapshots_0157 for each row execute function public._cif_snapshot_guard_0157();

-- issuance-workflow tables: append-only, except that a ledger row can be RELEASED exactly once (only after its invoice is voided)
create trigger carrier_invoice_issuance_terms_0157_immutable before update or delete on public.carrier_invoice_issuance_terms_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_issuance_terms_0157_no_truncate before truncate on public.carrier_invoice_issuance_terms_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_invoice_workflow_ops_0157_immutable before update or delete on public.carrier_invoice_workflow_ops_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_workflow_ops_0157_no_truncate before truncate on public.carrier_invoice_workflow_ops_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_invoice_reissues_0157_immutable before update or delete on public.carrier_invoice_reissues_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_reissues_0157_no_truncate before truncate on public.carrier_invoice_reissues_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_invoice_dispatch_fee_links_0157_immutable before update or delete on public.carrier_invoice_dispatch_fee_links_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_dispatch_fee_links_0157_no_truncate before truncate on public.carrier_invoice_dispatch_fee_links_0157 for each statement execute function public._cif_immutable_0157();
create trigger carrier_invoice_billable_ledger_0157_no_delete before delete on public.carrier_invoice_billable_ledger_0157 for each row execute function public._cif_immutable_0157();
create trigger carrier_invoice_billable_ledger_0157_no_truncate before truncate on public.carrier_invoice_billable_ledger_0157 for each statement execute function public._cif_immutable_0157();

create function public._cif_issuance_guard_0157() returns trigger language plpgsql security definer set search_path = pg_catalog, pg_temp as
$t$
declare v_i record; v_i2 record; v_l record; v_s record;
begin
  if tg_table_name = 'carrier_invoice_issuance_terms_0157' then
    select c.organization_id, c.carrier_id, c.invoice_document_type::text as dt, c.issuance_status::text as st, c.recipient_type::text as rt, c.recipient_broker_id as rb, c.recipient_customer_id as rc into v_i from public.carrier_invoices c where c.id = new.invoice_id;
    select s.invoice_id, s.organization_id into v_s from public.carrier_invoice_issuance_snapshots s where s.id = new.issuance_snapshot_id;
    if v_i.organization_id is distinct from new.organization_id or v_i.carrier_id is distinct from new.carrier_id or v_i.dt <> 'carrier_freight_invoice' or v_i.st <> 'issued'
       or v_i.rt is distinct from new.recipient_type or v_i.rb is distinct from new.recipient_broker_id or v_i.rc is distinct from new.recipient_customer_id or v_s.invoice_id is distinct from new.invoice_id then
      raise exception 'issuance terms: do not match the issued freight invoice / its issuance snapshot.' using errcode = '42501';
    end if;
    if new.frozen_fingerprint is distinct from pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(new.frozen::text, 'UTF8')), 'hex') then raise exception 'issuance terms: fingerprint mismatch.' using errcode = '42501'; end if;
  elsif tg_table_name = 'carrier_invoice_billable_ledger_0157' then
    if tg_op = 'INSERT' then
      select c.organization_id, c.carrier_id, c.invoice_document_type::text as dt, c.issuance_status::text as st into v_i from public.carrier_invoices c where c.id = new.invoice_id;
      select l.organization_id, l.carrier_id into v_l from public.loads l where l.id = new.load_id;
      if v_i.organization_id is distinct from new.organization_id or v_i.carrier_id is distinct from new.carrier_id or v_i.dt <> 'carrier_freight_invoice' or v_l.organization_id is distinct from new.organization_id or v_l.carrier_id is distinct from new.carrier_id
         or new.released_at is not null then
        raise exception 'billable ledger: the load / invoice / carrier / organization do not match.' using errcode = '42501';
      end if;
    else
      if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.carrier_id is distinct from old.carrier_id or new.load_id is distinct from old.load_id or new.invoice_id is distinct from old.invoice_id
         or new.amount is distinct from old.amount or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at or old.released_at is not null or new.released_at is null then
        raise exception 'billable ledger: a row can only be released once; nothing else may change.' using errcode = '42501';
      end if;
      if (select c.issuance_status::text from public.carrier_invoices c where c.id = old.invoice_id) not in ('voided', 'draft', 'ready_for_issue') then raise exception 'billable ledger: a record is released only when its invoice is voided or is a never-issued draft.' using errcode = '42501'; end if;
    end if;
  elsif tg_table_name = 'carrier_invoice_reissues_0157' then
    select c.organization_id, c.carrier_id, c.issuance_status::text as st, c.invoice_document_type::text as dt into v_i from public.carrier_invoices c where c.id = new.original_invoice_id;
    select c.organization_id, c.carrier_id, c.issuance_status::text as st, c.invoice_document_type::text as dt into v_i2 from public.carrier_invoices c where c.id = new.replacement_invoice_id;
    if v_i.organization_id is distinct from new.organization_id or v_i2.organization_id is distinct from new.organization_id or v_i.carrier_id is distinct from new.carrier_id or v_i2.carrier_id is distinct from new.carrier_id
       or v_i.st <> 'voided' or v_i2.st <> 'issued' or v_i.dt <> 'carrier_freight_invoice' or v_i2.dt <> 'carrier_freight_invoice' then
      raise exception 'reissue link: original must be a voided and replacement an issued freight invoice of the same organization and carrier.' using errcode = '42501';
    end if;
  elsif tg_table_name = 'carrier_invoice_dispatch_fee_links_0157' then
    select c.organization_id, c.carrier_id, c.invoice_document_type::text as dt into v_i from public.carrier_invoices c where c.id = new.freight_invoice_id;
    select c.organization_id, c.carrier_id, c.invoice_document_type::text as dt into v_i2 from public.carrier_invoices c where c.id = new.dispatch_invoice_id;
    if v_i.organization_id is distinct from new.organization_id or v_i2.organization_id is distinct from new.organization_id or v_i.carrier_id is distinct from new.carrier_id or v_i2.carrier_id is distinct from new.carrier_id
       or v_i.dt <> 'carrier_freight_invoice' or v_i2.dt <> 'dispatch_service_invoice' then
      raise exception 'dispatch-fee link: must join a freight invoice to a dispatch-service invoice of the same organization and carrier.' using errcode = '42501';
    end if;
  end if;
  return new;
end $t$;
create trigger carrier_invoice_issuance_terms_0157_guard before insert on public.carrier_invoice_issuance_terms_0157 for each row execute function public._cif_issuance_guard_0157();
create trigger carrier_invoice_billable_ledger_0157_guard before insert or update on public.carrier_invoice_billable_ledger_0157 for each row execute function public._cif_issuance_guard_0157();
create trigger carrier_invoice_reissues_0157_guard before insert on public.carrier_invoice_reissues_0157 for each row execute function public._cif_issuance_guard_0157();
create trigger carrier_invoice_dispatch_fee_links_0157_guard before insert on public.carrier_invoice_dispatch_fee_links_0157 for each row execute function public._cif_issuance_guard_0157();

-- the operator gate: only the SQL-Editor operator can reach the table; D-08i is enforced here; every change is audited with the database user
create function public._cif_gate_guard_0157() returns trigger language plpgsql security definer set search_path = pg_catalog, pg_temp as
$t$
declare v_legacy boolean;
begin
  if tg_op = 'UPDATE' then
    if new.enabled and not old.enabled then
      if exists (select 1 from public.carrier_inference_review_0155 v where v.decision_status = 'pending' and v.classification <> 'supported') then
        raise exception 'gate: D-08i -- a 0155 carrier-inference review is still pending; resolve every review before enabling.' using errcode = '42501';
      end if;
      if exists (select 1 from public.unresolved_carrier_records u where u.status = 'unresolved' and u.record_type in ('factoring_relationship', 'factored_invoice')) then
        raise exception 'gate: D-08i -- an open factoring exception record exists; resolve every applicable legacy factoring conflict before enabling.' using errcode = '42501';
      end if;
      if to_regclass('public.factoring_submission_gate') is not null then
        execute 'select exists (select 1 from public.factoring_submission_gate g where g.enabled)' into v_legacy;
        if v_legacy then raise exception 'gate: the legacy 0156 gate is enabled (D-08b).' using errcode = '42501'; end if;
      end if;
    end if;
    new.singleton := true;
    new.changed_by := session_user;
    new.changed_at := pg_catalog.now();
  end if;
  return new;
end $t$;
create trigger carrier_invoice_factoring_gate_0157_guard before update on public.carrier_invoice_factoring_gate_0157 for each row execute function public._cif_gate_guard_0157();
create trigger carrier_invoice_factoring_gate_0157_no_ins_del before insert or delete on public.carrier_invoice_factoring_gate_0157 for each row execute function public._cif_immutable_0157();

create function public._cif_gate_audit_0157() returns trigger language plpgsql security definer set search_path = pg_catalog, pg_temp as
$t$
begin
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, detail)
  values (null, null, 'gate_change', 'success', case when new.enabled then 'GATE_ENABLED' else 'GATE_DISABLED' end, 'Operator changed the carrier-invoice factoring gate.',
          pg_catalog.jsonb_build_object('enabled', new.enabled, 'previous_enabled', old.enabled, 'decision_ref', new.decision_ref, 'operator', new.changed_by));
  return new;
end $t$;
create trigger carrier_invoice_factoring_gate_0157_audit after update on public.carrier_invoice_factoring_gate_0157 for each row execute function public._cif_gate_audit_0157();

-- ======================= INTERNAL HELPERS (owner-only) =================================================================
create function public._cif_refuse_0157(p_org uuid, p_uid uuid, p_event text, p_carrier uuid, p_invoice uuid, p_code text, p_message text, p_extra jsonb default '{}'::jsonb, p_audit boolean default true)
returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
begin
  if p_audit and p_org is not null then
    insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, detail)
    values (p_org, p_uid, p_event, 'refusal', p_code, p_message, p_carrier, p_invoice, coalesce(p_extra, '{}'::jsonb));
  end if;
  return pg_catalog.jsonb_build_object('success', false, 'code', p_code, 'message', p_message) || coalesce(p_extra, '{}'::jsonb);
end
$fn$;

create function public._cif_authorize_0157(p_uid uuid, p_org uuid, p_carrier uuid) returns text language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_role text;
begin
  select p.role::text into v_role from public.profiles p where p.id = p_uid and p.organization_id = p_org;
  if v_role in ('owner', 'admin') then return 'owner_or_admin'; end if;
  if v_role = 'dispatcher' and exists (select 1 from public.carrier_factoring_submitter_grants_0157 g where g.organization_id = p_org and g.carrier_id = p_carrier and g.profile_id = p_uid and g.revoked_at is null) then return 'dispatcher_grant'; end if;
  return null;
end
$fn$;

-- The single evaluation used by BOTH the preview and the submission (the submission re-runs it under locks). Returns {ok:false, code, message} or {ok:true, ...everything the snapshot records}.
create function public._cif_evaluate_0157(p_invoice_id uuid, p_uid uuid, p_org uuid) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare
  v_inv record; v_snap record; v_carrier record; v_rel record; v_co record; v_readiness jsonb; v_fac jsonb; v_n integer; v_basis text; v_grant uuid;
  v_terms record; v_now jsonb; v_drift text[] := array[]::text[]; v_face numeric(12, 2); v_adv numeric(12, 2); v_fee numeric(12, 2); v_res numeric(12, 2); v_other numeric(12, 2); v_fund numeric(12, 2); v_dest text;
begin
  select c.id, c.organization_id, c.carrier_id, c.invoice_document_type::text as doc_type, c.issuance_status::text as issuance, c.payment_status::text as pay_status, c.total_amount, c.amount_paid, c.subtotal_amount, c.currency, c.invoice_number,
         c.recipient_type::text as recipient_type, c.recipient_broker_id, c.recipient_customer_id into v_inv from public.carrier_invoices c where c.id = p_invoice_id and c.organization_id = p_org;
  if v_inv.id is null then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Carrier invoice not found.'); end if;
  v_basis := public._cif_authorize_0157(p_uid, p_org, v_inv.carrier_id);
  if v_basis is null then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED_FOR_CARRIER', 'message', 'You are not authorized to submit invoices of this carrier for factoring.', 'carrier_id', v_inv.carrier_id); end if;
  if v_basis = 'dispatcher_grant' then select g.id into v_grant from public.carrier_factoring_submitter_grants_0157 g where g.organization_id = p_org and g.carrier_id = v_inv.carrier_id and g.profile_id = p_uid and g.revoked_at is null; end if;
  if v_inv.doc_type <> 'carrier_freight_invoice' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'WRONG_DOCUMENT_TYPE', 'message', 'Only carrier freight invoices can be factored; dispatch-service invoices are a separate receivable.', 'carrier_id', v_inv.carrier_id); end if;
  if v_inv.issuance = 'voided' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_VOIDED', 'message', 'A voided invoice cannot be factored.', 'carrier_id', v_inv.carrier_id); end if;
  if v_inv.issuance <> 'issued' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_NOT_ISSUED', 'message', 'Only an issued invoice can be factored.', 'carrier_id', v_inv.carrier_id); end if;
  if v_inv.pay_status <> 'unpaid' or v_inv.amount_paid <> 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_PAID_OR_PARTIAL', 'message', 'A paid or partially paid invoice cannot be factored.', 'carrier_id', v_inv.carrier_id); end if;
  if v_inv.total_amount is null or v_inv.total_amount <= 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_AMOUNT_INVALID', 'message', 'The invoice total must be greater than zero.', 'carrier_id', v_inv.carrier_id); end if;
  -- dispatch-service fees are a separate carrier-to-dispatcher receivable: none may sit on a factorable invoice
  if exists (select 1 from public.carrier_invoice_line_items li where li.invoice_id = p_invoice_id and li.line_type::text = 'dispatch_service_fee') then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'DISPATCH_FEE_ON_INVOICE', 'message', 'This invoice contains a dispatch-service fee line; dispatch fees are a separate receivable and cannot be factored.', 'carrier_id', v_inv.carrier_id);
  end if;
  select count(*) into v_n from public.carrier_invoice_issuance_snapshots s where s.invoice_id = p_invoice_id;
  if v_n <> 1 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'SNAPSHOT_MISSING', 'message', 'This invoice has no single issuance snapshot and cannot be factored.', 'carrier_id', v_inv.carrier_id); end if;
  select s.id, s.total_amount, s.carrier_id, s.snapshot_payload, s.currency, s.invoice_number, s.recipient_broker_id, s.recipient_customer_id into v_snap from public.carrier_invoice_issuance_snapshots s where s.invoice_id = p_invoice_id;
  if v_snap.total_amount <> v_inv.total_amount or v_snap.carrier_id is distinct from v_inv.carrier_id or v_snap.currency <> v_inv.currency or v_snap.invoice_number is distinct from v_inv.invoice_number then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'SNAPSHOT_MISMATCH', 'message', 'The invoice no longer matches its issuance snapshot; it cannot be factored.', 'carrier_id', v_inv.carrier_id);
  end if;
  v_fac := v_snap.snapshot_payload -> 'factoring';
  if v_fac is null or pg_catalog.jsonb_typeof(v_fac) <> 'object' or v_fac ->> 'mode' is distinct from 'factored' then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'ISSUED_AS_DIRECT_BILLING', 'message', 'This invoice was issued for direct billing and cannot be factored; it must be correctly reissued.', 'reissue_required', true, 'carrier_id', v_inv.carrier_id);
  end if;
  select t.id, t.factoring_mode, t.frozen, t.recipient_type, t.recipient_broker_id, t.recipient_customer_id into v_terms from public.carrier_invoice_issuance_terms_0157 t where t.invoice_id = p_invoice_id;
  if v_terms.id is null then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'ISSUANCE_RECORD_MISSING_REISSUE_REQUIRED', 'message', 'This invoice was not issued through the controlled issuance workflow; it must be reissued before it can be factored.', 'reissue_required', true, 'carrier_id', v_inv.carrier_id);
  end if;
  if v_terms.factoring_mode <> 'factored' then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'ISSUED_AS_DIRECT_BILLING', 'message', 'This invoice was issued for direct billing and cannot be factored; it must be correctly reissued.', 'reissue_required', true, 'carrier_id', v_inv.carrier_id);
  end if;
  select c.id, c.organization_id, c.is_active, c.factoring_mode::text as mode, coalesce(c.legal_name, c.dba_name) as name into v_carrier from public.carriers c where c.id = v_inv.carrier_id;
  if v_carrier.id is null or v_carrier.organization_id <> p_org or not v_carrier.is_active then return pg_catalog.jsonb_build_object('ok', false, 'code', 'CARRIER_INACTIVE', 'message', 'The carrier is missing, inactive or belongs to another organization.', 'carrier_id', v_inv.carrier_id); end if;
  if v_carrier.mode <> 'factored' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'DIRECT_BILLING', 'message', 'This carrier is configured for direct billing or is unconfigured; it cannot use factoring.', 'carrier_id', v_inv.carrier_id); end if;
  -- the relationship is chosen HERE, never by the client: exactly one active default of THIS carrier in THIS organization
  select count(*) into v_n from public.factoring_relationships r where r.carrier_id = v_inv.carrier_id and r.organization_id = p_org and r.is_default and r.is_active;
  if v_n = 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NO_ACTIVE_DEFAULT_RELATIONSHIP', 'message', 'This carrier has no active default factoring relationship.', 'carrier_id', v_inv.carrier_id); end if;
  if v_n > 1 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'MULTIPLE_DEFAULT_RELATIONSHIPS', 'message', 'This carrier has more than one active default factoring relationship; an owner or admin must fix the configuration.', 'carrier_id', v_inv.carrier_id); end if;
  select r.id, r.organization_id, r.carrier_id, r.factoring_company_id, r.relationship_name, r.default_advance_percentage, r.default_factoring_fee_percentage, r.default_reserve_percentage, r.fee_timing, r.other_fee_default, r.effective_from, r.effective_to,
         r.remittance_instructions, r.noa_reference, r.noa_effective_date, r.noa_approved_at, r.noa_document_id, r.submission_method::text as submission_method, r.submission_destination_email, r.submission_notes, r.submission_integration_id
    into v_rel from public.factoring_relationships r where r.carrier_id = v_inv.carrier_id and r.organization_id = p_org and r.is_default and r.is_active;
  -- D-57d: the issuance-time relationship, factor, NOA, recipient, routing and terms must equal the carrier's CURRENT active default; ANY difference refuses (nothing is written except a safe refusal audit row).
  v_now := public._cif_freeze_0157(v_rel.id);
  if v_terms.frozen ->> 'relationship_id' is distinct from v_now ->> 'relationship_id' or v_fac ->> 'relationship_id' is distinct from v_now ->> 'relationship_id' then v_drift := pg_catalog.array_append(v_drift, 'relationship'::text); end if;
  if v_terms.frozen ->> 'factoring_company_id' is distinct from v_now ->> 'factoring_company_id' or v_fac -> 'company' ->> 'id' is distinct from v_now ->> 'factoring_company_id' then v_drift := pg_catalog.array_append(v_drift, 'factor'::text); end if;
  if v_terms.frozen -> 'noa' is distinct from v_now -> 'noa' or v_fac -> 'noa' ->> 'reference' is distinct from v_now -> 'noa' ->> 'reference' or v_fac -> 'noa' ->> 'document_id' is distinct from v_now -> 'noa' ->> 'document_id' then v_drift := pg_catalog.array_append(v_drift, 'noa'::text); end if;
  if v_terms.recipient_type is distinct from v_inv.recipient_type or v_terms.recipient_broker_id is distinct from v_inv.recipient_broker_id or v_terms.recipient_customer_id is distinct from v_inv.recipient_customer_id
     or v_snap.recipient_broker_id is distinct from v_inv.recipient_broker_id or v_snap.recipient_customer_id is distinct from v_inv.recipient_customer_id then v_drift := pg_catalog.array_append(v_drift, 'recipient'::text); end if;
  if v_terms.frozen -> 'routing' is distinct from v_now -> 'routing' or v_fac ->> 'remittance_instructions' is distinct from v_now -> 'routing' ->> 'remittance_instructions' or v_fac -> 'submission' ->> 'method' is distinct from v_now -> 'routing' ->> 'submission_method' then v_drift := pg_catalog.array_append(v_drift, 'routing'::text); end if;
  if v_terms.frozen -> 'terms' is distinct from v_now -> 'terms' then v_drift := pg_catalog.array_append(v_drift, 'terms'::text); end if;
  if pg_catalog.cardinality(v_drift) > 0 then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'RELATIONSHIP_DRIFT_REISSUE_REQUIRED', 'message', 'The carrier''s factoring relationship, factor, NOA, recipient, routing or terms changed since this invoice was issued. It cannot be submitted; it must be reissued.',
      'reissue_required', true, 'drift_dimensions', pg_catalog.to_jsonb(v_drift), 'carrier_id', v_inv.carrier_id);
  end if;
  if v_rel.effective_from > current_date or (v_rel.effective_to is not null and v_rel.effective_to < current_date) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'RELATIONSHIP_NOT_EFFECTIVE', 'message', 'The carrier''s factoring relationship is not currently effective.', 'carrier_id', v_inv.carrier_id); end if;
  select f.id, f.organization_id, f.is_active, coalesce(f.legal_name, f.name) as name into v_co from public.factoring_companies f where f.id = v_rel.factoring_company_id;
  if v_co.id is null or v_co.organization_id <> p_org or not v_co.is_active then return pg_catalog.jsonb_build_object('ok', false, 'code', 'COMPANY_INACTIVE', 'message', 'The factoring company is inactive.', 'carrier_id', v_inv.carrier_id); end if;
  v_readiness := public.classify_carrier_factoring_readiness(v_inv.carrier_id, v_inv.recipient_broker_id, v_inv.recipient_customer_id);
  if v_readiness ->> 'classification' is distinct from 'ready' then
    return pg_catalog.jsonb_build_object('ok', false, 'code', case when v_readiness ->> 'classification' in ('carrier_party_ineligible', 'carrier_party_direct_billing_exception', 'carrier_party_inactive', 'direct_billing') then 'NOT_FACTORING_ELIGIBLE' else 'NOT_READY' end,
      'message', case when v_readiness ->> 'classification' in ('carrier_party_ineligible', 'carrier_party_direct_billing_exception', 'carrier_party_inactive', 'direct_billing') then 'This carrier/recipient is not factoring-eligible or is approved for direct billing.' else 'This carrier is not ready to factor this invoice.' end,
      'classification', v_readiness ->> 'classification', 'carrier_id', v_inv.carrier_id);
  end if;
  if (v_readiness ->> 'relationship_id')::uuid is distinct from v_rel.id then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_READY', 'message', 'This carrier is not ready to factor this invoice.', 'carrier_id', v_inv.carrier_id); end if;
  if exists (select 1 from public.unresolved_carrier_records u where u.status = 'unresolved' and u.organization_id = p_org and ((u.record_type = 'factoring_relationship' and u.record_id = v_rel.id) or (u.record_type in ('invoice', 'factored_invoice') and u.record_id = p_invoice_id)))
     or exists (select 1 from public.carrier_inference_review_0155 v where v.relationship_id = v_rel.id and v.decision_status = 'pending' and v.classification <> 'supported') then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'UNRESOLVED_LEGACY_RECORD', 'message', 'An unresolved legacy record exists for this invoice or factoring relationship; an owner or admin must resolve it first.', 'carrier_id', v_inv.carrier_id);
  end if;
  v_face := v_inv.total_amount;
  v_adv := round(v_face * v_rel.default_advance_percentage / 100, 2);
  v_fee := round(v_face * v_rel.default_factoring_fee_percentage / 100, 2);
  v_res := round(v_face * v_rel.default_reserve_percentage / 100, 2);
  v_other := coalesce(v_rel.other_fee_default, 0);
  v_fund := v_adv - v_other - (case when v_rel.fee_timing = 'deducted_at_funding' then v_fee else 0 end);
  if v_fund < 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NEGATIVE_FUNDING', 'message', 'Estimated funding for this invoice would be negative under the carrier''s factoring terms.', 'carrier_id', v_inv.carrier_id); end if;
  v_dest := case v_rel.submission_method when 'secure_email' then v_rel.submission_destination_email when 'api' then 'api-integration:' || coalesce(v_rel.submission_integration_id::text, '') else v_rel.submission_notes end;
  return pg_catalog.jsonb_build_object('ok', true, 'carrier_id', v_inv.carrier_id, 'carrier_name', v_carrier.name, 'carrier_invoice_id', p_invoice_id, 'invoice_number', v_inv.invoice_number, 'currency', v_inv.currency, 'invoice_total', v_face,
    'issuance_snapshot_id', v_snap.id, 'recipient_type', v_inv.recipient_type, 'recipient_broker_id', v_inv.recipient_broker_id, 'recipient_customer_id', v_inv.recipient_customer_id,
    'relationship_id', v_rel.id, 'relationship_name', v_rel.relationship_name, 'factoring_company_id', v_co.id, 'factoring_company_name', v_co.name,
    'advance_percentage', v_rel.default_advance_percentage, 'factoring_fee_percentage', v_rel.default_factoring_fee_percentage, 'reserve_percentage', v_rel.default_reserve_percentage, 'fee_timing', v_rel.fee_timing,
    'other_fee_amount', v_other, 'expected_advance_amount', v_adv, 'factoring_fee_amount', v_fee, 'reserve_amount', v_res, 'expected_funding_amount', v_fund,
    'remittance_instructions', v_rel.remittance_instructions, 'noa_reference', v_rel.noa_reference, 'noa_effective_date', v_rel.noa_effective_date, 'noa_approved_at', v_rel.noa_approved_at, 'noa_document_id', v_rel.noa_document_id,
    'submission_method', v_rel.submission_method, 'submission_destination', v_dest, 'issuance_relationship_id', nullif(v_fac ->> 'relationship_id', '')::uuid, 'readiness', v_readiness, 'authorization_basis', case when v_basis = 'dispatcher_grant' then 'dispatcher_grant' else (select p.role::text from public.profiles p where p.id = p_uid) end, 'authorization_grant_id', v_grant);
end
$fn$;

-- ======================= PUBLIC RPCs ===================================================================================
create function public.preview_carrier_invoice_factoring(p_carrier_invoice_id uuid) returns jsonb language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_ev jsonb; v_gate boolean;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin', 'dispatcher')) then
    return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FORBIDDEN', 'message', 'You are not permitted to submit invoices for factoring.');
  end if;
  select g.enabled into v_gate from public.carrier_invoice_factoring_gate_0157 g where g.singleton;
  if not coalesce(v_gate, false) then return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FEATURE_DISABLED', 'message', 'Factoring submission for carrier invoices is not enabled.'); end if;
  v_ev := public._cif_evaluate_0157(p_carrier_invoice_id, v_uid, v_org);
  if not (v_ev ->> 'ok')::boolean then return (v_ev - 'ok') || pg_catalog.jsonb_build_object('success', false, 'eligible', false); end if;
  if exists (select 1 from public.carrier_invoice_factoring_submissions_0157 s where s.carrier_invoice_id = p_carrier_invoice_id and s.status = 'submitted') then
    return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'ALREADY_SUBMITTED', 'message', 'This invoice has already been submitted to a factor.');
  end if;
  return pg_catalog.jsonb_build_object('success', true, 'eligible', true, 'carrier_id', v_ev -> 'carrier_id', 'carrier_name', v_ev -> 'carrier_name', 'invoice_number', v_ev -> 'invoice_number', 'currency', v_ev -> 'currency', 'invoice_total', v_ev -> 'invoice_total',
    'factoring_company_name', v_ev -> 'factoring_company_name', 'relationship_name', v_ev -> 'relationship_name', 'advance_percentage', v_ev -> 'advance_percentage', 'factoring_fee_percentage', v_ev -> 'factoring_fee_percentage',
    'reserve_percentage', v_ev -> 'reserve_percentage', 'fee_timing', v_ev -> 'fee_timing', 'expected_advance_amount', v_ev -> 'expected_advance_amount', 'factoring_fee_amount', v_ev -> 'factoring_fee_amount',
    'reserve_amount', v_ev -> 'reserve_amount', 'expected_funding_amount', v_ev -> 'expected_funding_amount', 'submission_method', v_ev -> 'submission_method', 'submission_destination', v_ev -> 'submission_destination',
    'noa_reference', v_ev -> 'noa_reference');
end
$fn$;

create function public.submit_carrier_invoice_to_factor(p_carrier_invoice_id uuid, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare
  v_uid uuid := auth.uid(); v_org uuid; v_ci record; v_gate record; v_rel uuid; v_co uuid; v_ex record; v_ev jsonb; v_sub uuid; v_basis text; v_now timestamptz := pg_catalog.clock_timestamp(); v_result jsonb;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org) then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not a member of an organization.'); end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' or p_carrier_invoice_id is null then
    return public._cif_refuse_0157(v_org, v_uid, 'submission', null, p_carrier_invoice_id, 'INVALID_REQUEST', 'A carrier invoice id and an idempotency key are required.');
  end if;
  select c.id, c.carrier_id into v_ci from public.carrier_invoices c where c.id = p_carrier_invoice_id and c.organization_id = v_org;
  if v_ci.id is null then return public._cif_refuse_0157(v_org, v_uid, 'submission', null, p_carrier_invoice_id, 'NOT_FOUND', 'Carrier invoice not found.'); end if;
  -- D-57h: tenant lookup precedes the pilot role gate; a grant never authorizes submission or replay.
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin')) then
    return public._cif_refuse_0157(v_org, v_uid, 'submission', null, p_carrier_invoice_id, 'FORBIDDEN', 'You are not permitted to submit invoices for factoring.');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cif_submit:' || p_carrier_invoice_id::text, 0));
  v_basis := public._cif_authorize_0157(v_uid, v_org, v_ci.carrier_id);
  if v_basis is null then return public._cif_refuse_0157(v_org, v_uid, 'submission', v_ci.carrier_id, p_carrier_invoice_id, 'NOT_AUTHORIZED_FOR_CARRIER', 'You are not authorized to submit invoices of this carrier for factoring.'); end if;

  -- idempotency (after authorization; organization-scoped key bound to the original invoice)
  select s.id, s.carrier_invoice_id, s.status, s.relationship_id into v_ex from public.carrier_invoice_factoring_submissions_0157 s where s.organization_id = v_org and s.idempotency_key = p_idempotency_key;
  if v_ex.id is not null then
    if v_ex.carrier_invoice_id <> p_carrier_invoice_id then return public._cif_refuse_0157(v_org, v_uid, 'submission', v_ci.carrier_id, p_carrier_invoice_id, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different invoice.'); end if;
    return pg_catalog.jsonb_build_object('success', true, 'idempotent_replay', true, 'submission_id', v_ex.id, 'status', v_ex.status, 'carrier_id', v_ci.carrier_id, 'message', 'This invoice was already submitted with this request.');
  end if;
  select g.enabled, g.decision_ref into v_gate from public.carrier_invoice_factoring_gate_0157 g where g.singleton;
  if not coalesce(v_gate.enabled, false) then return public._cif_refuse_0157(v_org, v_uid, 'submission', v_ci.carrier_id, p_carrier_invoice_id, 'FEATURE_DISABLED', 'Factoring submission for carrier invoices is not enabled.'); end if;

  -- fixed lock order: relationship (the carrier's single active default) -> carrier -> factoring company -> invoice
  select r.id, r.factoring_company_id into v_rel, v_co from public.factoring_relationships r where r.carrier_id = v_ci.carrier_id and r.organization_id = v_org and r.is_default and r.is_active
    and (select count(*) from public.factoring_relationships x where x.carrier_id = v_ci.carrier_id and x.organization_id = v_org and x.is_default and x.is_active) = 1;
  if v_rel is not null then
    perform 1 from public.factoring_relationships r where r.id = v_rel for update;
    perform 1 from public.carriers c where c.id = v_ci.carrier_id for share;
    perform 1 from public.factoring_companies f where f.id = v_co for share;
  end if;
  perform 1 from public.carrier_invoices c where c.id = p_carrier_invoice_id for share;

  select s.id into v_sub from public.carrier_invoice_factoring_submissions_0157 s where s.carrier_invoice_id = p_carrier_invoice_id and s.status = 'submitted';
  if v_sub is not null then
    return public._cif_refuse_0157(v_org, v_uid, 'submission', v_ci.carrier_id, p_carrier_invoice_id, 'ALREADY_SUBMITTED', 'This invoice has already been submitted to a factor.', pg_catalog.jsonb_build_object('submission_id', v_sub));
  end if;
  v_ev := public._cif_evaluate_0157(p_carrier_invoice_id, v_uid, v_org);
  if not (v_ev ->> 'ok')::boolean then
    return public._cif_refuse_0157(v_org, v_uid, 'submission', v_ci.carrier_id, p_carrier_invoice_id, v_ev ->> 'code', v_ev ->> 'message', (v_ev - 'ok' - 'code' - 'message' - 'carrier_id'));
  end if;

  begin
    insert into public.carrier_invoice_factoring_submissions_0157 (organization_id, carrier_id, carrier_invoice_id, relationship_id, factoring_company_id, status, idempotency_key, submitted_by, submitted_at)
    values (v_org, v_ci.carrier_id, p_carrier_invoice_id, (v_ev ->> 'relationship_id')::uuid, (v_ev ->> 'factoring_company_id')::uuid, 'submitted', p_idempotency_key, v_uid, v_now) returning id into v_sub;
  exception when unique_violation then
    return public._cif_refuse_0157(v_org, v_uid, 'submission', v_ci.carrier_id, p_carrier_invoice_id, 'ALREADY_SUBMITTED', 'This invoice has already been submitted to a factor.');
  end;
  insert into public.carrier_invoice_factoring_snapshots_0157 (submission_id, organization_id, carrier_id, carrier_legal_name, carrier_invoice_id, invoice_number, currency, invoice_total_amount, issuance_snapshot_id, recipient_type, recipient_broker_id, recipient_customer_id,
    factoring_company_id, factoring_company_name, relationship_id, relationship_name, advance_percentage, factoring_fee_percentage, reserve_percentage, fee_timing, other_fee_amount, expected_advance_amount, factoring_fee_amount, reserve_amount, expected_funding_amount,
    remittance_instructions, noa_reference, noa_effective_date, noa_approved_at, noa_document_id, submission_method, submission_destination, issuance_relationship_id, readiness, authorization_basis, authorization_grant_id, gate_decision_ref, submitted_by, submitted_at)
  values (v_sub, v_org, v_ci.carrier_id, v_ev ->> 'carrier_name', p_carrier_invoice_id, v_ev ->> 'invoice_number', v_ev ->> 'currency', (v_ev ->> 'invoice_total')::numeric, (v_ev ->> 'issuance_snapshot_id')::uuid, v_ev ->> 'recipient_type', nullif(v_ev ->> 'recipient_broker_id', '')::uuid, nullif(v_ev ->> 'recipient_customer_id', '')::uuid,
    (v_ev ->> 'factoring_company_id')::uuid, v_ev ->> 'factoring_company_name', (v_ev ->> 'relationship_id')::uuid, v_ev ->> 'relationship_name', (v_ev ->> 'advance_percentage')::numeric, (v_ev ->> 'factoring_fee_percentage')::numeric, (v_ev ->> 'reserve_percentage')::numeric, v_ev ->> 'fee_timing',
    (v_ev ->> 'other_fee_amount')::numeric, (v_ev ->> 'expected_advance_amount')::numeric, (v_ev ->> 'factoring_fee_amount')::numeric, (v_ev ->> 'reserve_amount')::numeric, (v_ev ->> 'expected_funding_amount')::numeric,
    v_ev ->> 'remittance_instructions', v_ev ->> 'noa_reference', nullif(v_ev ->> 'noa_effective_date', '')::date, nullif(v_ev ->> 'noa_approved_at', '')::timestamptz, nullif(v_ev ->> 'noa_document_id', '')::uuid, v_ev ->> 'submission_method', v_ev ->> 'submission_destination',
    nullif(v_ev ->> 'issuance_relationship_id', '')::uuid, v_ev -> 'readiness', v_ev ->> 'authorization_basis', nullif(v_ev ->> 'authorization_grant_id', '')::uuid, v_gate.decision_ref, v_uid, v_now);
  v_result := pg_catalog.jsonb_build_object('success', true, 'submission_id', v_sub, 'status', 'submitted', 'carrier_id', v_ci.carrier_id, 'relationship_id', v_ev -> 'relationship_id', 'message', 'The invoice was submitted to the carrier''s factor.');
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, submission_id, detail, idempotency_key)
  values (v_org, v_uid, 'submission', 'success', 'SUBMITTED', 'The invoice was submitted to the carrier''s factor.', v_ci.carrier_id, p_carrier_invoice_id, v_sub, pg_catalog.jsonb_build_object('relationship_id', v_ev -> 'relationship_id', 'authorization_basis', v_ev -> 'authorization_basis'), p_idempotency_key);
  return v_result;
end
$fn$;

create function public.withdraw_carrier_invoice_factoring_submission(p_submission_id uuid, p_reason text, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_s record; v_prior record;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may withdraw a factoring submission.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_reason is null or pg_catalog.btrim(p_reason) = '' or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' then
    return public._cif_refuse_0157(v_org, v_uid, 'withdrawal', null, null, 'INVALID_REQUEST', 'A reason and an idempotency key are required.');
  end if;
  select s.id, s.carrier_id, s.carrier_invoice_id, s.status into v_s from public.carrier_invoice_factoring_submissions_0157 s where s.id = p_submission_id and s.organization_id = v_org for update;
  if v_s.id is null then return public._cif_refuse_0157(v_org, v_uid, 'withdrawal', null, null, 'NOT_FOUND', 'Submission not found.'); end if;
  select a.submission_id, a.detail into v_prior from public.carrier_invoice_factoring_audit_0157 a where a.organization_id = v_org and a.event_type = 'withdrawal' and a.outcome = 'success' and a.idempotency_key = p_idempotency_key;
  if v_prior.submission_id is not null then
    if v_prior.submission_id = p_submission_id then return pg_catalog.jsonb_build_object('success', true, 'idempotent_replay', true, 'submission_id', p_submission_id, 'status', 'withdrawn'); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'withdrawal', v_s.carrier_id, v_s.carrier_invoice_id, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different submission.');
  end if;
  if v_s.status <> 'submitted' then return public._cif_refuse_0157(v_org, v_uid, 'withdrawal', v_s.carrier_id, v_s.carrier_invoice_id, 'NOT_APPLICABLE', 'Only a submission in status submitted can be withdrawn.'); end if;
  update public.carrier_invoice_factoring_submissions_0157 set status = 'withdrawn', status_changed_at = pg_catalog.now(), status_changed_by = v_uid, status_reason = pg_catalog.btrim(p_reason), updated_at = pg_catalog.now() where id = v_s.id;
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, submission_id, detail, idempotency_key)
  values (v_org, v_uid, 'withdrawal', 'success', 'WITHDRAWN', 'The factoring submission was withdrawn (snapshot preserved).', v_s.carrier_id, v_s.carrier_invoice_id, v_s.id, pg_catalog.jsonb_build_object('reason', pg_catalog.btrim(p_reason)), p_idempotency_key);
  return pg_catalog.jsonb_build_object('success', true, 'submission_id', v_s.id, 'status', 'withdrawn');
end
$fn$;

create function public.set_carrier_factoring_submitter(p_carrier_id uuid, p_profile_id uuid, p_allowed boolean, p_reason text, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_prior record; v_g uuid;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may manage factoring submitters.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  if p_carrier_id is null or p_profile_id is null or p_allowed is null or p_reason is null or pg_catalog.btrim(p_reason) = '' or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' then
    return public._cif_refuse_0157(v_org, v_uid, 'grant_change', p_carrier_id, null, 'INVALID_REQUEST', 'carrier, profile, allowed, reason and idempotency key are required.');
  end if;
  if not exists (select 1 from public.carriers c where c.id = p_carrier_id and c.organization_id = v_org) or not exists (select 1 from public.profiles p where p.id = p_profile_id and p.organization_id = v_org and p.role::text = 'dispatcher') then
    return public._cif_refuse_0157(v_org, v_uid, 'grant_change', p_carrier_id, null, 'NOT_FOUND', 'The carrier or dispatcher was not found in this organization.');
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cif_grant:' || p_carrier_id::text || ':' || p_profile_id::text, 0));
  select a.detail into v_prior from public.carrier_invoice_factoring_audit_0157 a where a.organization_id = v_org and a.event_type = 'grant_change' and a.outcome = 'success' and a.idempotency_key = p_idempotency_key;
  if v_prior.detail is not null then
    if v_prior.detail ->> 'carrier_id' = p_carrier_id::text and v_prior.detail ->> 'profile_id' = p_profile_id::text and (v_prior.detail ->> 'allowed')::boolean = p_allowed then return pg_catalog.jsonb_build_object('success', true, 'idempotent_replay', true, 'allowed', p_allowed); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'grant_change', p_carrier_id, null, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different request.');
  end if;
  if p_allowed then
    insert into public.carrier_factoring_submitter_grants_0157 (organization_id, carrier_id, profile_id, reason, granted_by) values (v_org, p_carrier_id, p_profile_id, pg_catalog.btrim(p_reason), v_uid)
    on conflict (carrier_id, profile_id) where revoked_at is null do nothing returning id into v_g;
  else
    update public.carrier_factoring_submitter_grants_0157 set revoked_at = pg_catalog.now(), revoked_by = v_uid, revoke_reason = pg_catalog.btrim(p_reason) where carrier_id = p_carrier_id and profile_id = p_profile_id and organization_id = v_org and revoked_at is null returning id into v_g;
  end if;
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, detail, idempotency_key)
  values (v_org, v_uid, 'grant_change', 'success', case when p_allowed then 'SUBMITTER_GRANTED' else 'SUBMITTER_REVOKED' end, 'Carrier factoring submitter access changed.', p_carrier_id,
          pg_catalog.jsonb_build_object('carrier_id', p_carrier_id, 'profile_id', p_profile_id, 'allowed', p_allowed, 'changed', v_g is not null, 'reason', pg_catalog.btrim(p_reason)), p_idempotency_key);
  return pg_catalog.jsonb_build_object('success', true, 'allowed', p_allowed, 'changed', v_g is not null);
end
$fn$;

create function public.verify_carrier_invoice_factoring_audit_chain_0157() returns integer language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare r record; v_prev text := null; v_bad integer := 0; v_expected_seq bigint := 1;
begin
  for r in select * from public.carrier_invoice_factoring_audit_0157 order by seq loop
    if r.seq <> v_expected_seq or r.prev_hash is distinct from v_prev
       or r.row_hash <> pg_catalog.md5(coalesce(v_prev, '') || '|' || r.seq::text || '|' || r.occurred_at::text || '|' || coalesce(r.organization_id::text, '') || '|' || coalesce(r.actor_uid::text, '') || '|' || r.actor_db_user || '|' || r.event_type || '|' || r.outcome
            || '|' || r.code || '|' || coalesce(r.carrier_invoice_id::text, '') || '|' || coalesce(r.submission_id::text, '') || '|' || r.detail::text || '|' || coalesce(r.idempotency_key, '')) then v_bad := v_bad + 1; end if;
    v_prev := r.row_hash; v_expected_seq := r.seq + 1;
  end loop;
  return v_bad;
end
$fn$;


-- ======================= ISSUANCE WORKFLOW: INTERNAL HELPERS (owner-only) ==================================================
-- The relationship facts that an issued invoice depends on, frozen at issuance and re-derived at submission (D-57d compares every dimension).
create function public._cif_freeze_0157(p_rel uuid) returns jsonb language sql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
  select pg_catalog.jsonb_build_object('relationship_id', r.id, 'factoring_company_id', r.factoring_company_id,
    'noa', pg_catalog.jsonb_build_object('reference', r.noa_reference, 'effective_date', r.noa_effective_date, 'approved', r.noa_approved, 'approved_at', r.noa_approved_at, 'document_id', r.noa_document_id),
    'routing', pg_catalog.jsonb_build_object('remittance_instructions', r.remittance_instructions, 'submission_method', r.submission_method::text,
      'submission_destination', case r.submission_method::text when 'secure_email' then r.submission_destination_email when 'api' then 'api-integration:' || coalesce(r.submission_integration_id::text, '') else r.submission_notes end),
    'terms', pg_catalog.jsonb_build_object('advance_percentage', r.default_advance_percentage, 'factoring_fee_percentage', r.default_factoring_fee_percentage, 'reserve_percentage', r.default_reserve_percentage, 'fee_timing', r.fee_timing::text, 'other_fee_default', coalesce(r.other_fee_default, 0)))
  from public.factoring_relationships r where r.id = p_rel
$fn$;

create function public._cif_diff_frozen_0157(p_old jsonb, p_new jsonb) returns text[] language sql immutable set search_path = pg_catalog, pg_temp as
$fn$
  select coalesce(pg_catalog.array_agg(d order by d), array[]::text[]) from (
    select 'relationship' as d where p_old ->> 'relationship_id' is distinct from p_new ->> 'relationship_id'
    union all select 'factor' where p_old ->> 'factoring_company_id' is distinct from p_new ->> 'factoring_company_id'
    union all select 'noa' where p_old -> 'noa' is distinct from p_new -> 'noa'
    union all select 'routing' where p_old -> 'routing' is distinct from p_new -> 'routing'
    union all select 'terms' where p_old -> 'terms' is distinct from p_new -> 'terms') x
$fn$;

-- The single selection/eligibility evaluation shared by the preview, the draft creation, ready-for-issue, issuance and reissue. Everything is resolved SERVER-SIDE from the carrier + the selected loads; the caller supplies no relationship, factor, recipient routing, organization or total.
create function public._cif_selection_0157(p_org uuid, p_uid uuid, p_carrier uuid, p_load_ids uuid[], p_rtype text, p_rid uuid, p_exclude uuid) returns jsonb language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare
  v_basis text; v_car record; v_n integer; v_cnt integer; v_rel record; v_co record; v_readiness jsonb; v_rname text; v_loads jsonb; v_total numeric(12, 2); v_frozen jsonb; v_mode text; v_fac jsonb := null;
  v_ver record; v_fee_total numeric(12, 2); v_fee numeric(12, 2); v_r record; v_dfee jsonb; v_adv numeric(12, 2); v_ffee numeric(12, 2); v_res numeric(12, 2); v_other numeric(12, 2); v_fund numeric(12, 2);
begin
  if p_carrier is null or p_load_ids is null or p_rtype is null or p_rid is null then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVALID_REQUEST', 'message', 'A carrier, loads and a recipient are required.'); end if;
  if p_rtype not in ('broker', 'customer') then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVALID_REQUEST', 'message', 'The recipient must be a broker or a customer.'); end if;
  if pg_catalog.cardinality(p_load_ids) < 1 or pg_catalog.cardinality(p_load_ids) > 200 or exists (select 1 from pg_catalog.unnest(p_load_ids) x where x is null)
     or (select pg_catalog.count(distinct x) from pg_catalog.unnest(p_load_ids) x) <> pg_catalog.cardinality(p_load_ids) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_SELECTION_INVALID', 'message', 'Select between 1 and 200 distinct loads.');
  end if;
  select c.id, c.is_active, c.factoring_mode::text as mode, coalesce(c.legal_name, c.dba_name) as name, c.invoice_code into v_car from public.carriers c where c.id = p_carrier and c.organization_id = p_org;
  if v_car.id is null then return pg_catalog.jsonb_build_object('ok', false, 'code', 'CARRIER_NOT_FOUND', 'message', 'The carrier was not found.'); end if;
  v_basis := public._cif_authorize_0157(p_uid, p_org, p_carrier);
  if v_basis is null then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_AUTHORIZED_FOR_CARRIER', 'message', 'You are not authorized to invoice this carrier.', 'carrier_id', p_carrier); end if;
  if not v_car.is_active then return pg_catalog.jsonb_build_object('ok', false, 'code', 'CARRIER_INACTIVE', 'message', 'The carrier is inactive.', 'carrier_id', p_carrier); end if;
  if v_car.invoice_code is null or pg_catalog.btrim(v_car.invoice_code) = '' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'CARRIER_INVOICE_CODE_MISSING', 'message', 'The carrier has no invoice code; set one before invoicing.', 'carrier_id', p_carrier); end if;
  if v_car.mode = 'unconfigured' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'FACTORING_POLICY_UNCONFIGURED', 'message', 'This carrier has no billing policy configured (direct or factored).', 'carrier_id', p_carrier); end if;
  if p_rtype = 'broker' then select b.company_name into v_rname from public.brokers b where b.id = p_rid and b.organization_id = p_org;
  else select b.company_name into v_rname from public.customers b where b.id = p_rid and b.organization_id = p_org; end if;
  if not found then return pg_catalog.jsonb_build_object('ok', false, 'code', 'RECIPIENT_NOT_FOUND', 'message', 'The broker or customer was not found.', 'carrier_id', p_carrier); end if;
  -- loads: same organization, this carrier only, this recipient only, billable, priced, not already on a live invoice
  select pg_catalog.count(*) into v_cnt from public.loads l where l.id = any (p_load_ids) and l.organization_id = p_org;
  if v_cnt <> pg_catalog.cardinality(p_load_ids) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_NOT_FOUND', 'message', 'One or more selected loads were not found.', 'carrier_id', p_carrier); end if;
  if exists (select 1 from public.loads l where l.id = any (p_load_ids) and l.carrier_id is distinct from p_carrier) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_CARRIER_MISMATCH', 'message', 'Every selected load must belong to the selected carrier.', 'carrier_id', p_carrier); end if;
  if exists (select 1 from public.loads l where l.id = any (p_load_ids) and ((p_rtype = 'broker' and l.broker_id is distinct from p_rid) or (p_rtype = 'customer' and l.customer_id is distinct from p_rid))) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_RECIPIENT_MISMATCH', 'message', 'Every selected load must belong to the selected broker or customer.', 'carrier_id', p_carrier);
  end if;
  if exists (select 1 from public.loads l where l.id = any (p_load_ids) and l.status::text not in ('delivered', 'pod_received')) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_NOT_BILLABLE', 'message', 'Only delivered loads can be invoiced.', 'carrier_id', p_carrier); end if;
  if exists (select 1 from public.loads l left join public.load_financials f on f.load_id = l.id where l.id = any (p_load_ids) and (f.rate is null or pg_catalog.round(f.rate, 2) <= 0)) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_AMOUNT_INVALID', 'message', 'Every selected load needs a freight amount greater than zero.', 'carrier_id', p_carrier); end if;
  if exists (select 1 from public.carrier_invoice_billable_ledger_0157 g where g.load_id = any (p_load_ids) and g.released_at is null and g.invoice_id is distinct from p_exclude)
     or exists (select 1 from public.carrier_invoice_loads cil join public.carrier_invoices ci on ci.id = cil.invoice_id where cil.load_id = any (p_load_ids) and ci.invoice_document_type::text = 'carrier_freight_invoice' and ci.issuance_status::text <> 'voided' and ci.id is distinct from p_exclude
                 and not exists (select 1 from public.carrier_invoice_billable_ledger_0157 g where g.invoice_id = cil.invoice_id and g.load_id = cil.load_id and g.released_at is not null)) then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_ALREADY_INVOICED', 'message', 'One or more selected loads are already on another live carrier invoice.', 'carrier_id', p_carrier);
  end if;
  select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('load_id', l.id, 'load_number', l.load_number, 'amount', pg_catalog.round(f.rate, 2)) order by l.id), pg_catalog.sum(pg_catalog.round(f.rate, 2)) into v_loads, v_total
    from public.loads l join public.load_financials f on f.load_id = l.id where l.id = any (p_load_ids);
  -- legacy exceptions / unresolved 0155 reviews of any of this carrier's relationships block issuance
  if exists (select 1 from public.unresolved_carrier_records u join public.factoring_relationships r on r.id = u.record_id where u.status = 'unresolved' and u.organization_id = p_org and u.record_type = 'factoring_relationship' and r.carrier_id = p_carrier)
     or exists (select 1 from public.carrier_inference_review_0155 v join public.factoring_relationships r on r.id = v.relationship_id where r.carrier_id = p_carrier and r.organization_id = p_org and v.decision_status = 'pending' and v.classification <> 'supported') then
    return pg_catalog.jsonb_build_object('ok', false, 'code', 'UNRESOLVED_LEGACY_RECORD', 'message', 'An unresolved legacy record exists for this carrier''s factoring relationship; an owner or admin must resolve it first.', 'carrier_id', p_carrier);
  end if;
  if v_car.mode = 'direct' then
    v_mode := 'direct_billing'; v_frozen := '{}'::jsonb;
  else
    v_mode := 'factored';
    select pg_catalog.count(*) into v_n from public.factoring_relationships r where r.carrier_id = p_carrier and r.organization_id = p_org and r.is_default and r.is_active;
    if v_n = 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NO_ACTIVE_DEFAULT_RELATIONSHIP', 'message', 'This carrier has no active default factoring relationship.', 'carrier_id', p_carrier); end if;
    if v_n > 1 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'MULTIPLE_DEFAULT_RELATIONSHIPS', 'message', 'This carrier has more than one active default factoring relationship; an owner or admin must fix the configuration.', 'carrier_id', p_carrier); end if;
    select r.id, r.relationship_name, r.factoring_company_id, r.effective_from, r.effective_to, r.default_advance_percentage, r.default_factoring_fee_percentage, r.default_reserve_percentage, r.fee_timing, r.other_fee_default, r.noa_reference, r.submission_method::text as submission_method, r.remittance_instructions
      into v_rel from public.factoring_relationships r where r.carrier_id = p_carrier and r.organization_id = p_org and r.is_default and r.is_active;
    if v_rel.effective_from > current_date or (v_rel.effective_to is not null and v_rel.effective_to < current_date) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'RELATIONSHIP_NOT_EFFECTIVE', 'message', 'The carrier''s factoring relationship is not currently effective.', 'carrier_id', p_carrier); end if;
    select f.id, f.organization_id, f.is_active, coalesce(f.legal_name, f.name) as name into v_co from public.factoring_companies f where f.id = v_rel.factoring_company_id;
    if v_co.id is null or v_co.organization_id <> p_org or not v_co.is_active then return pg_catalog.jsonb_build_object('ok', false, 'code', 'COMPANY_INACTIVE', 'message', 'The factoring company is inactive.', 'carrier_id', p_carrier); end if;
    v_readiness := public.classify_carrier_factoring_readiness(p_carrier, case when p_rtype = 'broker' then p_rid end, case when p_rtype = 'customer' then p_rid end);
    if v_readiness ->> 'classification' is distinct from 'ready' or (v_readiness ->> 'relationship_id')::uuid is distinct from v_rel.id then
      return pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_READY', 'message', 'This carrier is not ready to factor invoices to this recipient.', 'classification', v_readiness ->> 'classification', 'carrier_id', p_carrier);
    end if;
    v_frozen := public._cif_freeze_0157(v_rel.id);
    v_adv := pg_catalog.round(v_total * v_rel.default_advance_percentage / 100, 2); v_ffee := pg_catalog.round(v_total * v_rel.default_factoring_fee_percentage / 100, 2); v_res := pg_catalog.round(v_total * v_rel.default_reserve_percentage / 100, 2);
    v_other := coalesce(v_rel.other_fee_default, 0); v_fund := v_adv - v_other - (case when v_rel.fee_timing = 'deducted_at_funding' then v_ffee else 0 end);
    v_fac := pg_catalog.jsonb_build_object('factoring_company_name', v_co.name, 'relationship_name', v_rel.relationship_name, 'advance_percentage', v_rel.default_advance_percentage, 'factoring_fee_percentage', v_rel.default_factoring_fee_percentage,
      'reserve_percentage', v_rel.default_reserve_percentage, 'fee_timing', v_rel.fee_timing, 'other_fee_amount', v_other, 'expected_advance_amount', v_adv, 'factoring_fee_amount', v_ffee, 'reserve_amount', v_res, 'expected_funding_amount', v_fund,
      'noa_reference', v_rel.noa_reference, 'submission_method', v_rel.submission_method, 'remittance_instructions', v_rel.remittance_instructions);
  end if;
  -- dispatch-service fee: a SEPARATE carrier-to-dispatcher receivable, never part of this invoice, factored amount or recipient; shown here as an estimate from the approved agreement (if any)
  select v.id, v.fee_method::text as fee_method, v.percentage_rate, v.flat_fee_per_load, v.minimum_fee, v.maximum_fee, v.currency into v_ver
    from public.carrier_dispatch_service_agreement_versions v join public.carrier_dispatch_service_agreements a on a.id = v.agreement_id
   where v.carrier_id = p_carrier and v.organization_id = p_org and a.status = 'active' and v.status = 'approved' and v.effective_from <= current_date and (v.effective_to is null or v.effective_to >= current_date) order by v.effective_from desc limit 1;
  if v_ver.id is null then v_dfee := pg_catalog.jsonb_build_object('status', 'no_effective_agreement', 'estimated_total', null);
  elsif v_ver.currency <> 'USD' then v_dfee := pg_catalog.jsonb_build_object('status', 'currency_mismatch', 'estimated_total', null);
  else
    v_fee_total := 0;
    for v_r in select pg_catalog.round(f.rate, 2) as amt from public.loads l join public.load_financials f on f.load_id = l.id where l.id = any (p_load_ids) loop
      v_fee := case when v_ver.fee_method = 'percentage_of_freight' then pg_catalog.round(v_r.amt * v_ver.percentage_rate / 100.0, 2) else v_ver.flat_fee_per_load end;
      if v_ver.minimum_fee is not null and v_fee < v_ver.minimum_fee then v_fee := v_ver.minimum_fee; end if;
      if v_ver.maximum_fee is not null and v_fee > v_ver.maximum_fee then v_fee := v_ver.maximum_fee; end if;
      v_fee_total := v_fee_total + coalesce(v_fee, 0);
    end loop;
    v_dfee := pg_catalog.jsonb_build_object('status', 'agreement_effective', 'fee_method', v_ver.fee_method, 'estimated_total', v_fee_total, 'currency', v_ver.currency);
  end if;
  return pg_catalog.jsonb_build_object('ok', true, 'carrier_id', p_carrier, 'carrier_name', v_car.name, 'billing_mode', v_mode, 'recipient_type', p_rtype, 'recipient_id', p_rid, 'recipient_name', v_rname, 'currency', 'USD',
    'loads', v_loads, 'load_count', pg_catalog.cardinality(p_load_ids), 'freight_total', v_total, 'factoring', v_fac, 'dispatch_fee', v_dfee, 'frozen', v_frozen, 'authorization_basis', v_basis);
end
$fn$;

-- creates the draft (invoice + load links + freight lines + ledger rows) from an already-validated selection; the caller holds the per-load advisory locks
create function public._cif_create_draft_0157(p_org uuid, p_uid uuid, p_carrier uuid, p_load_ids uuid[], p_rtype text, p_rid uuid, p_notes text) returns uuid language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_inv uuid; r record;
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, issuance_status, carrier_id, recipient_type, recipient_broker_id, recipient_customer_id, currency, notes, created_by)
  values (p_org, 'carrier_freight_invoice', 'draft', p_carrier, p_rtype::public.invoice_recipient_type, case when p_rtype = 'broker' then p_rid end, case when p_rtype = 'customer' then p_rid end, 'USD', p_notes, p_uid) returning id into v_inv;
  for r in select l.id, l.load_number, pg_catalog.round(f.rate, 2) as amt from public.loads l join public.load_financials f on f.load_id = l.id where l.id = any (p_load_ids) order by l.id loop
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values (p_org, v_inv, r.id);
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, line_type, source_load_id, description, quantity, unit_price) values (p_org, v_inv, 'freight_charge', r.id, 'Freight charge - Load ' || r.load_number, 1, r.amt);
    insert into public.carrier_invoice_billable_ledger_0157 (organization_id, carrier_id, load_id, invoice_id, amount, created_by) values (p_org, p_carrier, r.id, v_inv, r.amt, p_uid);
  end loop;
  return v_inv;
end
$fn$;

-- after a freight invoice is issued: link (or draft) the separate dispatch-service receivable. Never adds a fee to the freight invoice; issuing the dispatch-service invoice stays a separate step (0145).
create function public._cif_dispatch_fee_0157(p_org uuid, p_uid uuid, p_carrier uuid, p_freight uuid, p_load_ids uuid[], p_carry_from uuid) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_ver uuid; v_cur text; v_disp uuid; v_prev uuid; x uuid;
begin
  if p_carry_from is not null then
    select l.dispatch_invoice_id into v_prev from public.carrier_invoice_dispatch_fee_links_0157 l where l.freight_invoice_id = p_carry_from;
    if v_prev is not null then
      insert into public.carrier_invoice_dispatch_fee_links_0157 (organization_id, carrier_id, freight_invoice_id, dispatch_invoice_id, disposition, created_by) values (p_org, p_carrier, p_freight, v_prev, 'carried_over', p_uid);
      return pg_catalog.jsonb_build_object('status', 'carried_over', 'dispatch_invoice_id', v_prev);
    end if;
  end if;
  select v.id, v.currency into v_ver, v_cur from public.carrier_dispatch_service_agreement_versions v join public.carrier_dispatch_service_agreements a on a.id = v.agreement_id
   where v.carrier_id = p_carrier and v.organization_id = p_org and a.status = 'active' and v.status = 'approved' and v.effective_from <= current_date and (v.effective_to is null or v.effective_to >= current_date) order by v.effective_from desc limit 1;
  if v_ver is null then return pg_catalog.jsonb_build_object('status', 'no_effective_agreement'); end if;
  if exists (select 1 from public.carrier_dispatch_service_billing_lines b where b.load_id = any (p_load_ids)) then return pg_catalog.jsonb_build_object('status', 'already_billed'); end if;
  insert into public.carrier_invoices (organization_id, invoice_document_type, issuance_status, carrier_id, currency, created_by) values (p_org, 'dispatch_service_invoice', 'draft', p_carrier, v_cur, p_uid) returning id into v_disp;
  foreach x in array p_load_ids loop insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values (p_org, v_disp, x); end loop;
  insert into public.carrier_invoice_dispatch_fee_links_0157 (organization_id, carrier_id, freight_invoice_id, dispatch_invoice_id, disposition, created_by) values (p_org, p_carrier, p_freight, v_disp, 'draft_created', p_uid);
  return pg_catalog.jsonb_build_object('status', 'draft_created', 'dispatch_invoice_id', v_disp);
end
$fn$;

-- ======================= ISSUANCE WORKFLOW: PUBLIC RPCs ===================================================================
-- roles: owner/admin, or a dispatcher holding an active per-carrier grant, may PREPARE (preview / draft / ready / void-a-draft). ISSUING and REISSUING are owner/admin only (the existing issue_carrier_invoice, 0144, admits only owner/admin/accountant and is not modified here).
create function public.preview_carrier_invoice_issuance(p_carrier_id uuid, p_load_ids uuid[], p_recipient_type text, p_recipient_id uuid) returns jsonb language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_ctx jsonb;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin', 'dispatcher')) then
    return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FORBIDDEN', 'message', 'You are not permitted to prepare carrier invoices.');
  end if;
  v_ctx := public._cif_selection_0157(v_org, v_uid, p_carrier_id, p_load_ids, p_recipient_type, p_recipient_id, null);
  if not (v_ctx ->> 'ok')::boolean then return (v_ctx - 'ok') || pg_catalog.jsonb_build_object('success', false, 'eligible', false); end if;
  return (v_ctx - 'ok' - 'frozen') || pg_catalog.jsonb_build_object('success', true, 'eligible', true);
end
$fn$;

create function public.create_carrier_invoice_draft_from_loads(p_carrier_id uuid, p_load_ids uuid[], p_recipient_type text, p_recipient_id uuid, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_ctx jsonb; v_ids uuid[]; v_fp text; v_op record; v_inv uuid; v_x uuid; v_result jsonb;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin', 'dispatcher')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not permitted to prepare carrier invoices.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' or p_carrier_id is null or p_load_ids is null or p_recipient_type is null or p_recipient_id is null then
    return public._cif_refuse_0157(v_org, v_uid, 'draft_creation', p_carrier_id, null, 'INVALID_REQUEST', 'A carrier, loads, a recipient and an idempotency key are required.');
  end if;
  if public._cif_authorize_0157(v_uid, v_org, p_carrier_id) is null then return public._cif_refuse_0157(v_org, v_uid, 'draft_creation', p_carrier_id, null, 'NOT_AUTHORIZED_FOR_CARRIER', 'You are not authorized to invoice this carrier.'); end if;
  select coalesce(pg_catalog.array_agg(x order by x), '{}') into v_ids from pg_catalog.unnest(p_load_ids) x;
  v_fp := pg_catalog.md5(p_carrier_id::text || '|' || pg_catalog.array_to_string(v_ids, ',') || '|' || p_recipient_type || '|' || p_recipient_id::text);
  select o.operation, o.request_fingerprint, o.result into v_op from public.carrier_invoice_workflow_ops_0157 o where o.organization_id = v_org and o.idempotency_key = p_idempotency_key;
  if v_op.operation is not null then
    if v_op.operation = 'create_draft' and v_op.request_fingerprint = v_fp then return v_op.result || pg_catalog.jsonb_build_object('idempotent_replay', true); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'draft_creation', p_carrier_id, null, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different request.');
  end if;
  v_ctx := public._cif_selection_0157(v_org, v_uid, p_carrier_id, v_ids, p_recipient_type, p_recipient_id, null);
  if not (v_ctx ->> 'ok')::boolean then return public._cif_refuse_0157(v_org, v_uid, 'draft_creation', p_carrier_id, null, v_ctx ->> 'code', v_ctx ->> 'message'); end if;
  -- serialise concurrent selections of the same loads (ascending order), then re-evaluate under the locks
  foreach v_x in array v_ids loop perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cif_load:' || v_x::text, 0)); end loop;
  perform 1 from public.loads l where l.id = any (v_ids) order by l.id for update;
  v_ctx := public._cif_selection_0157(v_org, v_uid, p_carrier_id, v_ids, p_recipient_type, p_recipient_id, null);
  if not (v_ctx ->> 'ok')::boolean then return public._cif_refuse_0157(v_org, v_uid, 'draft_creation', p_carrier_id, null, v_ctx ->> 'code', v_ctx ->> 'message'); end if;
  v_inv := public._cif_create_draft_0157(v_org, v_uid, p_carrier_id, v_ids, p_recipient_type, p_recipient_id, null);
  v_result := pg_catalog.jsonb_build_object('success', true, 'invoice_id', v_inv, 'status', 'draft', 'carrier_id', p_carrier_id, 'billing_mode', v_ctx -> 'billing_mode', 'load_count', v_ctx -> 'load_count', 'freight_total', v_ctx -> 'freight_total', 'message', 'The draft carrier invoice was created.');
  insert into public.carrier_invoice_workflow_ops_0157 (organization_id, operation, idempotency_key, request_fingerprint, invoice_id, result, created_by) values (v_org, 'create_draft', p_idempotency_key, v_fp, v_inv, v_result, v_uid);
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, detail, idempotency_key)
  values (v_org, v_uid, 'draft_creation', 'success', 'DRAFT_CREATED', 'A draft carrier invoice was created from selected loads.', p_carrier_id, v_inv, pg_catalog.jsonb_build_object('load_count', v_ctx -> 'load_count', 'freight_total', v_ctx -> 'freight_total', 'billing_mode', v_ctx -> 'billing_mode'), p_idempotency_key);
  return v_result;
end
$fn$;

create function public.mark_carrier_invoice_ready_for_issue(p_invoice_id uuid, p_expected_updated_at timestamptz, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_i record; v_ids uuid[]; v_ctx jsonb; v_fp text; v_op record; v_upd timestamptz; v_result jsonb;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin', 'dispatcher')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not permitted to prepare carrier invoices.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_invoice_id is null or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' or p_expected_updated_at is null then return public._cif_refuse_0157(v_org, v_uid, 'ready', null, p_invoice_id, 'INVALID_REQUEST', 'An invoice, its last-seen update time and an idempotency key are required.'); end if;
  select c.id, c.carrier_id, c.issuance_status::text as st, c.updated_at, c.invoice_document_type::text as dt, c.recipient_type::text as rt, c.recipient_broker_id as rb, c.recipient_customer_id as rc, c.subtotal_amount into v_i from public.carrier_invoices c where c.id = p_invoice_id and c.organization_id = v_org for update;
  if v_i.id is null then return public._cif_refuse_0157(v_org, v_uid, 'ready', null, p_invoice_id, 'NOT_FOUND', 'Carrier invoice not found.'); end if;
  if public._cif_authorize_0157(v_uid, v_org, v_i.carrier_id) is null then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'NOT_AUTHORIZED_FOR_CARRIER', 'You are not authorized to invoice this carrier.'); end if;
  v_fp := pg_catalog.md5('ready|' || p_invoice_id::text);
  select o.operation, o.request_fingerprint, o.result into v_op from public.carrier_invoice_workflow_ops_0157 o where o.organization_id = v_org and o.idempotency_key = p_idempotency_key;
  if v_op.operation is not null then
    if v_op.operation = 'mark_ready' and v_op.request_fingerprint = v_fp then return v_op.result || pg_catalog.jsonb_build_object('idempotent_replay', true); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different request.');
  end if;
  if v_i.dt <> 'carrier_freight_invoice' then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'WRONG_DOCUMENT_TYPE', 'Only carrier freight invoices use this workflow.'); end if;
  if v_i.st <> 'draft' then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'INVOICE_NOT_DRAFT', 'Only a draft can be marked ready for issue.'); end if;
  if v_i.updated_at is distinct from p_expected_updated_at then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'STALE_INVOICE', 'The invoice changed since you loaded it. Reload and try again.'); end if;
  select coalesce(pg_catalog.array_agg(g.load_id order by g.load_id), '{}') into v_ids from public.carrier_invoice_billable_ledger_0157 g where g.invoice_id = p_invoice_id and g.released_at is null;
  if pg_catalog.cardinality(v_ids) = 0 then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'NOT_A_WORKFLOW_DRAFT', 'This draft was not created through the controlled issuance workflow.'); end if;
  if (select coalesce(pg_catalog.array_agg(cil.load_id order by cil.load_id), '{}') from public.carrier_invoice_loads cil where cil.invoice_id = p_invoice_id) is distinct from v_ids then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'DRAFT_LOADS_CHANGED', 'The draft''s loads no longer match its billable-record ledger.'); end if;
  v_ctx := public._cif_selection_0157(v_org, v_uid, v_i.carrier_id, v_ids, v_i.rt, coalesce(v_i.rb, v_i.rc), p_invoice_id);
  if not (v_ctx ->> 'ok')::boolean then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, v_ctx ->> 'code', v_ctx ->> 'message'); end if;
  if (v_ctx ->> 'freight_total')::numeric <> v_i.subtotal_amount then return public._cif_refuse_0157(v_org, v_uid, 'ready', v_i.carrier_id, p_invoice_id, 'INVOICE_TOTAL_MISMATCH', 'The draft total no longer matches its loads.'); end if;
  update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = p_invoice_id returning updated_at into v_upd;
  v_result := pg_catalog.jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'status', 'ready_for_issue', 'updated_at', v_upd, 'message', 'The invoice is ready for issue.');
  insert into public.carrier_invoice_workflow_ops_0157 (organization_id, operation, idempotency_key, request_fingerprint, invoice_id, result, created_by) values (v_org, 'mark_ready', p_idempotency_key, v_fp, p_invoice_id, v_result, v_uid);
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, detail, idempotency_key)
  values (v_org, v_uid, 'ready', 'success', 'MARKED_READY', 'A draft carrier invoice was marked ready for issue.', v_i.carrier_id, p_invoice_id, pg_catalog.jsonb_build_object('billing_mode', v_ctx -> 'billing_mode'), p_idempotency_key);
  return v_result;
end
$fn$;

create function public.discard_carrier_invoice_draft(p_invoice_id uuid, p_expected_updated_at timestamptz, p_reason text, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_i record; v_fp text; v_op record; v_result jsonb;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin', 'dispatcher')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You are not permitted to prepare carrier invoices.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_invoice_id is null or p_reason is null or pg_catalog.btrim(p_reason) = '' or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' or p_expected_updated_at is null then return public._cif_refuse_0157(v_org, v_uid, 'draft_discard', null, p_invoice_id, 'INVALID_REQUEST', 'An invoice, a reason, its last-seen update time and an idempotency key are required.'); end if;
  select c.id, c.carrier_id, c.issuance_status::text as st, c.updated_at, c.invoice_document_type::text as dt into v_i from public.carrier_invoices c where c.id = p_invoice_id and c.organization_id = v_org for update;
  if v_i.id is null then return public._cif_refuse_0157(v_org, v_uid, 'draft_discard', null, p_invoice_id, 'NOT_FOUND', 'Carrier invoice not found.'); end if;
  if public._cif_authorize_0157(v_uid, v_org, v_i.carrier_id) is null then return public._cif_refuse_0157(v_org, v_uid, 'draft_discard', v_i.carrier_id, p_invoice_id, 'NOT_AUTHORIZED_FOR_CARRIER', 'You are not authorized to invoice this carrier.'); end if;
  v_fp := pg_catalog.md5('void|' || p_invoice_id::text || '|' || pg_catalog.btrim(p_reason));
  select o.operation, o.request_fingerprint, o.result into v_op from public.carrier_invoice_workflow_ops_0157 o where o.organization_id = v_org and o.idempotency_key = p_idempotency_key;
  if v_op.operation is not null then
    if v_op.operation = 'discard_draft' and v_op.request_fingerprint = v_fp then return v_op.result || pg_catalog.jsonb_build_object('idempotent_replay', true); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'draft_discard', v_i.carrier_id, p_invoice_id, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different request.');
  end if;
  if v_i.dt <> 'carrier_freight_invoice' or v_i.st not in ('draft', 'ready_for_issue') then return public._cif_refuse_0157(v_org, v_uid, 'draft_discard', v_i.carrier_id, p_invoice_id, 'INVOICE_NOT_DRAFT', 'Only a draft or ready-for-issue freight invoice can be discarded here; use reissue for an issued invoice.'); end if;
  if v_i.updated_at is distinct from p_expected_updated_at then return public._cif_refuse_0157(v_org, v_uid, 'draft_discard', v_i.carrier_id, p_invoice_id, 'STALE_INVOICE', 'The invoice changed since you loaded it. Reload and try again.'); end if;
  -- a never-issued draft cannot be 'voided' (a voided invoice must carry an invoice number: cinv_number_iff_issued); it is DISCARDED: its loads are released (they can be drafted again) and it can never be marked ready or issued
  update public.carrier_invoices set issuance_status = 'draft', notes = coalesce(notes || E'\n', '') || 'Discarded: ' || pg_catalog.btrim(p_reason) where id = p_invoice_id;
  update public.carrier_invoice_billable_ledger_0157 set released_at = pg_catalog.now(), released_reason = 'draft discarded' where invoice_id = p_invoice_id and released_at is null;
  v_result := pg_catalog.jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'status', 'draft', 'discarded', true, 'message', 'The draft was discarded and its loads were released.');
  insert into public.carrier_invoice_workflow_ops_0157 (organization_id, operation, idempotency_key, request_fingerprint, invoice_id, result, created_by) values (v_org, 'discard_draft', p_idempotency_key, v_fp, p_invoice_id, v_result, v_uid);
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, detail, idempotency_key)
  values (v_org, v_uid, 'draft_discard', 'success', 'DRAFT_DISCARDED', 'A draft carrier invoice was discarded.', v_i.carrier_id, p_invoice_id, pg_catalog.jsonb_build_object('reason', pg_catalog.btrim(p_reason)), p_idempotency_key);
  return v_result;
end
$fn$;

create function public.issue_prepared_carrier_invoice(p_invoice_id uuid, p_expected_updated_at timestamptz, p_reason text, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare
  v_uid uuid := auth.uid(); v_org uuid; v_i record; v_ids uuid[]; v_ctx jsonb; v_fp text; v_op record; v_res jsonb; v_snap record; v_fz jsonb; v_pay jsonb; v_mode text; v_dfee jsonb; v_num text; v_result jsonb;
  v_fail text; v_fail_msg text;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may issue a carrier invoice.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_invoice_id is null or p_reason is null or pg_catalog.btrim(p_reason) = '' or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' or p_expected_updated_at is null then return public._cif_refuse_0157(v_org, v_uid, 'issuance', null, p_invoice_id, 'INVALID_REQUEST', 'An invoice, a reason, its last-seen update time and an idempotency key are required.'); end if;
  select c.id, c.carrier_id, c.issuance_status::text as st, c.updated_at, c.invoice_document_type::text as dt, c.recipient_type::text as rt, c.recipient_broker_id as rb, c.recipient_customer_id as rc, c.subtotal_amount into v_i from public.carrier_invoices c where c.id = p_invoice_id and c.organization_id = v_org for update;
  if v_i.id is null then return public._cif_refuse_0157(v_org, v_uid, 'issuance', null, p_invoice_id, 'NOT_FOUND', 'Carrier invoice not found.'); end if;
  v_fp := pg_catalog.md5('issue|' || p_invoice_id::text);
  select o.operation, o.request_fingerprint, o.result into v_op from public.carrier_invoice_workflow_ops_0157 o where o.organization_id = v_org and o.idempotency_key = p_idempotency_key;
  if v_op.operation is not null then
    if v_op.operation = 'issue' and v_op.request_fingerprint = v_fp then return v_op.result || pg_catalog.jsonb_build_object('idempotent_replay', true); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different request.');
  end if;
  if v_i.dt <> 'carrier_freight_invoice' then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, 'WRONG_DOCUMENT_TYPE', 'Only carrier freight invoices use this workflow.'); end if;
  if v_i.st <> 'ready_for_issue' then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, 'INVOICE_NOT_READY', 'Only an invoice marked ready for issue can be issued.'); end if;
  if v_i.updated_at is distinct from p_expected_updated_at then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, 'STALE_INVOICE', 'The invoice changed since you loaded it. Reload and try again.'); end if;
  select coalesce(pg_catalog.array_agg(g.load_id order by g.load_id), '{}') into v_ids from public.carrier_invoice_billable_ledger_0157 g where g.invoice_id = p_invoice_id and g.released_at is null;
  if pg_catalog.cardinality(v_ids) = 0 then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, 'NOT_A_WORKFLOW_DRAFT', 'This invoice was not prepared through the controlled issuance workflow.'); end if;
  v_ctx := public._cif_selection_0157(v_org, v_uid, v_i.carrier_id, v_ids, v_i.rt, coalesce(v_i.rb, v_i.rc), p_invoice_id);
  if not (v_ctx ->> 'ok')::boolean then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, v_ctx ->> 'code', v_ctx ->> 'message'); end if;
  if (v_ctx ->> 'freight_total')::numeric <> v_i.subtotal_amount then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, 'INVOICE_TOTAL_MISMATCH', 'The invoice total no longer matches its loads.'); end if;
  v_mode := v_ctx ->> 'billing_mode';
  begin
    v_res := public.issue_carrier_invoice(p_invoice_id, p_expected_updated_at, pg_catalog.btrim(p_reason), p_idempotency_key);
    if not coalesce((v_res ->> 'success')::boolean, false) then raise exception using errcode = 'CIF01', message = coalesce(v_res ->> 'code', 'ISSUE_FAILED'), detail = coalesce(v_res ->> 'message', 'The invoice could not be issued.'); end if;
    select s.id, s.snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots s where s.invoice_id = p_invoice_id;
    v_pay := v_snap.snapshot_payload -> 'factoring';
    if v_pay is null or pg_catalog.jsonb_typeof(v_pay) <> 'object' or v_pay ->> 'mode' = 'direct' then
      if v_mode <> 'direct_billing' then raise exception using errcode = 'CIF01', message = 'STALE_CONFIGURATION', detail = 'The carrier''s billing configuration changed while issuing. Please retry.'; end if;
      v_fz := '{}'::jsonb;
    else
      if v_mode <> 'factored' then raise exception using errcode = 'CIF01', message = 'STALE_CONFIGURATION', detail = 'The carrier''s billing configuration changed while issuing. Please retry.'; end if;
      perform 1 from public.factoring_relationships r where r.id = (v_pay ->> 'relationship_id')::uuid for share;
      v_fz := public._cif_freeze_0157((v_pay ->> 'relationship_id')::uuid);
      if v_fz is null or v_fz ->> 'factoring_company_id' is distinct from v_pay -> 'company' ->> 'id' or v_fz -> 'routing' ->> 'remittance_instructions' is distinct from v_pay ->> 'remittance_instructions' or v_fz -> 'noa' ->> 'reference' is distinct from v_pay -> 'noa' ->> 'reference'
         or v_fz is distinct from v_ctx -> 'frozen' then
        raise exception using errcode = 'CIF01', message = 'STALE_CONFIGURATION', detail = 'The carrier''s factoring configuration changed while issuing. Please retry.';
      end if;
    end if;
    insert into public.carrier_invoice_issuance_terms_0157 (invoice_id, organization_id, carrier_id, factoring_mode, recipient_type, recipient_broker_id, recipient_customer_id, frozen, frozen_fingerprint, issuance_snapshot_id, issued_by, idempotency_key)
    values (p_invoice_id, v_org, v_i.carrier_id, v_mode, v_i.rt, v_i.rb, v_i.rc, v_fz, pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_fz::text, 'UTF8')), 'hex'), v_snap.id, v_uid, p_idempotency_key);
    v_dfee := public._cif_dispatch_fee_0157(v_org, v_uid, v_i.carrier_id, p_invoice_id, v_ids, null);
  exception when sqlstate 'CIF01' then
    get stacked diagnostics v_fail = message_text, v_fail_msg = pg_exception_detail;
  end;
  if v_fail is not null then return public._cif_refuse_0157(v_org, v_uid, 'issuance', v_i.carrier_id, p_invoice_id, v_fail, coalesce(v_fail_msg, 'The invoice could not be issued.')); end if;
  select c.invoice_number into v_num from public.carrier_invoices c where c.id = p_invoice_id;
  v_result := pg_catalog.jsonb_build_object('success', true, 'invoice_id', p_invoice_id, 'invoice_number', v_num, 'status', 'issued', 'billing_mode', v_mode, 'dispatch_fee', v_dfee, 'message', 'The invoice was issued.');
  insert into public.carrier_invoice_workflow_ops_0157 (organization_id, operation, idempotency_key, request_fingerprint, invoice_id, result, created_by) values (v_org, 'issue', p_idempotency_key, v_fp, p_invoice_id, v_result, v_uid);
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, detail, idempotency_key)
  values (v_org, v_uid, 'issuance', 'success', 'ISSUED', 'A carrier invoice was issued through the controlled workflow.', v_i.carrier_id, p_invoice_id, pg_catalog.jsonb_build_object('billing_mode', v_mode, 'dispatch_fee_status', v_dfee ->> 'status', 'terms_fingerprint', pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_fz::text, 'UTF8')), 'hex')), p_idempotency_key);
  return v_result;
end
$fn$;

-- Reissue eligibility, shared by the preview and the reissue. Owner/admin only. Returns {ok:false, code, message} or {ok:true, ctx, old_total, drift_dimensions, load_ids, ...}.
create function public._cif_reissue_eval_0157(p_invoice_id uuid, p_uid uuid, p_org uuid) returns jsonb language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_i record; v_t record; v_ids uuid[]; v_ctx jsonb; v_dims text[];
begin
  select c.id, c.carrier_id, c.invoice_document_type::text as dt, c.issuance_status::text as st, c.payment_status::text as ps, c.amount_paid, c.total_amount, c.invoice_number, c.recipient_type::text as rt, c.recipient_broker_id as rb, c.recipient_customer_id as rc
    into v_i from public.carrier_invoices c where c.id = p_invoice_id and c.organization_id = p_org;
  if v_i.id is null then return pg_catalog.jsonb_build_object('ok', false, 'code', 'NOT_FOUND', 'message', 'Carrier invoice not found.'); end if;
  if not exists (select 1 from public.profiles p where p.id = p_uid and p.organization_id = p_org and p.role::text in ('owner', 'admin')) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may reissue a carrier invoice.', 'carrier_id', v_i.carrier_id); end if;
  if v_i.dt <> 'carrier_freight_invoice' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'WRONG_DOCUMENT_TYPE', 'message', 'Only carrier freight invoices can be reissued here.', 'carrier_id', v_i.carrier_id); end if;
  if v_i.st = 'voided' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_VOIDED', 'message', 'A voided invoice cannot be reissued.', 'carrier_id', v_i.carrier_id); end if;
  if v_i.st <> 'issued' then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_NOT_ISSUED', 'message', 'Only an issued invoice can be reissued.', 'carrier_id', v_i.carrier_id); end if;
  if v_i.ps <> 'unpaid' or v_i.amount_paid <> 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'INVOICE_PAID_OR_PARTIAL', 'message', 'A paid or partially paid invoice cannot be reissued automatically.', 'carrier_id', v_i.carrier_id); end if;
  if exists (select 1 from public.carrier_invoice_factoring_submissions_0157 s where s.carrier_invoice_id = p_invoice_id) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'SUBMISSION_EXISTS', 'message', 'This invoice has a factoring submission and cannot be reissued.', 'carrier_id', v_i.carrier_id); end if;
  if exists (select 1 from public.carrier_invoice_reissues_0157 r where r.original_invoice_id = p_invoice_id) then return pg_catalog.jsonb_build_object('ok', false, 'code', 'ALREADY_REISSUED', 'message', 'This invoice was already reissued.', 'carrier_id', v_i.carrier_id); end if;
  select coalesce(pg_catalog.array_agg(cil.load_id order by cil.load_id), '{}') into v_ids from public.carrier_invoice_loads cil where cil.invoice_id = p_invoice_id;
  if pg_catalog.cardinality(v_ids) = 0 then return pg_catalog.jsonb_build_object('ok', false, 'code', 'LOAD_SELECTION_INVALID', 'message', 'The invoice has no loads to reissue.', 'carrier_id', v_i.carrier_id); end if;
  v_ctx := public._cif_selection_0157(p_org, p_uid, v_i.carrier_id, v_ids, v_i.rt, coalesce(v_i.rb, v_i.rc), p_invoice_id);
  if not (v_ctx ->> 'ok')::boolean then return v_ctx; end if;
  if (v_ctx ->> 'freight_total')::numeric <> v_i.total_amount then return pg_catalog.jsonb_build_object('ok', false, 'code', 'REISSUE_TOTAL_CHANGED', 'message', 'The loads'' current freight total differs from this invoice; a reissue never changes amounts.', 'carrier_id', v_i.carrier_id); end if;
  select t.factoring_mode, t.frozen into v_t from public.carrier_invoice_issuance_terms_0157 t where t.invoice_id = p_invoice_id;
  if v_t.factoring_mode is null then v_dims := array['issuance_record_missing'];
  elsif v_t.factoring_mode <> v_ctx ->> 'billing_mode' then v_dims := array['billing_mode'];
  elsif v_t.factoring_mode = 'factored' then v_dims := public._cif_diff_frozen_0157(v_t.frozen, v_ctx -> 'frozen');
  else v_dims := array[]::text[]; end if;
  return pg_catalog.jsonb_build_object('ok', true, 'ctx', v_ctx, 'load_ids', pg_catalog.to_jsonb(v_ids), 'old_invoice_number', v_i.invoice_number, 'old_total', v_i.total_amount, 'drift_dimensions', pg_catalog.to_jsonb(v_dims), 'carrier_id', v_i.carrier_id, 'rt', v_i.rt, 'rid', coalesce(v_i.rb, v_i.rc));
end
$fn$;

create function public.preview_carrier_invoice_reissue(p_invoice_id uuid) returns jsonb language plpgsql stable security definer set search_path = pg_catalog, pg_temp as
$fn$
declare v_uid uuid := auth.uid(); v_org uuid; v_e jsonb;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin')) then
    return pg_catalog.jsonb_build_object('success', false, 'eligible', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may reissue a carrier invoice.');
  end if;
  v_e := public._cif_reissue_eval_0157(p_invoice_id, v_uid, v_org);
  if not (v_e ->> 'ok')::boolean then return (v_e - 'ok') || pg_catalog.jsonb_build_object('success', false, 'eligible', false); end if;
  return ((v_e -> 'ctx') - 'ok' - 'frozen') || pg_catalog.jsonb_build_object('success', true, 'eligible', true, 'old_invoice_number', v_e -> 'old_invoice_number', 'old_total', v_e -> 'old_total', 'drift_dimensions', v_e -> 'drift_dimensions', 'reissue_needed', pg_catalog.jsonb_array_length(v_e -> 'drift_dimensions') > 0);
end
$fn$;

create function public.reissue_carrier_invoice(p_invoice_id uuid, p_expected_updated_at timestamptz, p_reason text, p_idempotency_key text) returns jsonb language plpgsql security definer set search_path = pg_catalog, pg_temp as
$fn$
declare
  v_uid uuid := auth.uid(); v_org uuid; v_i record; v_e jsonb; v_ctx jsonb; v_ids uuid[]; v_fp text; v_op record; v_x uuid; v_new uuid; v_upd timestamptz; v_res jsonb; v_snap record; v_pay jsonb; v_fz jsonb; v_mode text; v_dfee jsonb; v_num text;
  v_dims text[]; v_result jsonb; v_fail text; v_fail_msg text;
begin
  if v_uid is null then return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.'); end if;
  v_org := public.current_org_id();
  if v_org is null or not exists (select 1 from public.profiles p where p.id = v_uid and p.organization_id = v_org and p.role::text in ('owner', 'admin')) then
    return pg_catalog.jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may reissue a carrier invoice.');
  end if;
  perform pg_catalog.set_config('lock_timeout', '5s', true);
  perform pg_catalog.set_config('statement_timeout', '30s', true);
  if p_invoice_id is null or p_reason is null or pg_catalog.btrim(p_reason) = '' or p_idempotency_key is null or pg_catalog.btrim(p_idempotency_key) = '' or p_expected_updated_at is null then return public._cif_refuse_0157(v_org, v_uid, 'reissue', null, p_invoice_id, 'INVALID_REQUEST', 'An invoice, a reason, its last-seen update time and an idempotency key are required.'); end if;
  select c.id, c.carrier_id, c.updated_at into v_i from public.carrier_invoices c where c.id = p_invoice_id and c.organization_id = v_org for update;
  if v_i.id is null then return public._cif_refuse_0157(v_org, v_uid, 'reissue', null, p_invoice_id, 'NOT_FOUND', 'Carrier invoice not found.'); end if;
  v_fp := pg_catalog.md5('reissue|' || p_invoice_id::text || '|' || pg_catalog.btrim(p_reason));
  select o.operation, o.request_fingerprint, o.result into v_op from public.carrier_invoice_workflow_ops_0157 o where o.organization_id = v_org and o.idempotency_key = p_idempotency_key;
  if v_op.operation is not null then
    if v_op.operation = 'reissue' and v_op.request_fingerprint = v_fp then return v_op.result || pg_catalog.jsonb_build_object('idempotent_replay', true); end if;
    return public._cif_refuse_0157(v_org, v_uid, 'reissue', v_i.carrier_id, p_invoice_id, 'IDEMPOTENCY_KEY_REUSED', 'This idempotency key was already used for a different request.');
  end if;
  if v_i.updated_at is distinct from p_expected_updated_at then return public._cif_refuse_0157(v_org, v_uid, 'reissue', v_i.carrier_id, p_invoice_id, 'STALE_INVOICE', 'The invoice changed since you loaded it. Reload and try again.'); end if;
  v_e := public._cif_reissue_eval_0157(p_invoice_id, v_uid, v_org);
  if not (v_e ->> 'ok')::boolean then return public._cif_refuse_0157(v_org, v_uid, 'reissue', v_i.carrier_id, p_invoice_id, v_e ->> 'code', v_e ->> 'message'); end if;
  select coalesce(pg_catalog.array_agg(x::uuid order by x::uuid), '{}') into v_ids from pg_catalog.jsonb_array_elements_text(v_e -> 'load_ids') x;
  foreach v_x in array v_ids loop perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('cif_load:' || v_x::text, 0)); end loop;
  -- re-evaluate under the locks (nothing has been written yet)
  v_e := public._cif_reissue_eval_0157(p_invoice_id, v_uid, v_org);
  if not (v_e ->> 'ok')::boolean then return public._cif_refuse_0157(v_org, v_uid, 'reissue', v_i.carrier_id, p_invoice_id, v_e ->> 'code', v_e ->> 'message'); end if;
  v_ctx := v_e -> 'ctx'; v_mode := v_ctx ->> 'billing_mode';
  select coalesce(pg_catalog.array_agg(d), array[]::text[]) into v_dims from pg_catalog.jsonb_array_elements_text(v_e -> 'drift_dimensions') d;
  begin
    update public.carrier_invoices set issuance_status = 'voided', voided_at = pg_catalog.now(), voided_by = v_uid, void_reason = 'Reissued: ' || pg_catalog.btrim(p_reason) where id = p_invoice_id;
    update public.carrier_invoice_billable_ledger_0157 set released_at = pg_catalog.now(), released_reason = 'invoice reissued' where invoice_id = p_invoice_id and released_at is null;
    v_new := public._cif_create_draft_0157(v_org, v_uid, v_i.carrier_id, v_ids, v_e ->> 'rt', (v_e ->> 'rid')::uuid, null);
    update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = v_new returning updated_at into v_upd;
    v_res := public.issue_carrier_invoice(v_new, v_upd, pg_catalog.btrim(p_reason), p_idempotency_key || ':issue');
    if not coalesce((v_res ->> 'success')::boolean, false) then raise exception using errcode = 'CIF01', message = coalesce(v_res ->> 'code', 'ISSUE_FAILED'), detail = coalesce(v_res ->> 'message', 'The replacement invoice could not be issued.'); end if;
    select s.id, s.snapshot_payload into v_snap from public.carrier_invoice_issuance_snapshots s where s.invoice_id = v_new;
    v_pay := v_snap.snapshot_payload -> 'factoring';
    if v_pay is null or pg_catalog.jsonb_typeof(v_pay) <> 'object' or v_pay ->> 'mode' = 'direct' then
      if v_mode <> 'direct_billing' then raise exception using errcode = 'CIF01', message = 'STALE_CONFIGURATION', detail = 'The carrier''s billing configuration changed while reissuing. Please retry.'; end if;
      v_fz := '{}'::jsonb;
    else
      if v_mode <> 'factored' then raise exception using errcode = 'CIF01', message = 'STALE_CONFIGURATION', detail = 'The carrier''s billing configuration changed while reissuing. Please retry.'; end if;
      perform 1 from public.factoring_relationships r where r.id = (v_pay ->> 'relationship_id')::uuid for share;
      v_fz := public._cif_freeze_0157((v_pay ->> 'relationship_id')::uuid);
      if v_fz is null or v_fz is distinct from v_ctx -> 'frozen' or v_fz ->> 'factoring_company_id' is distinct from v_pay -> 'company' ->> 'id' then raise exception using errcode = 'CIF01', message = 'STALE_CONFIGURATION', detail = 'The carrier''s factoring configuration changed while reissuing. Please retry.'; end if;
    end if;
    insert into public.carrier_invoice_issuance_terms_0157 (invoice_id, organization_id, carrier_id, factoring_mode, recipient_type, recipient_broker_id, recipient_customer_id, frozen, frozen_fingerprint, issuance_snapshot_id, issued_by, idempotency_key)
    values (v_new, v_org, v_i.carrier_id, v_mode, v_e ->> 'rt', case when v_e ->> 'rt' = 'broker' then (v_e ->> 'rid')::uuid end, case when v_e ->> 'rt' = 'customer' then (v_e ->> 'rid')::uuid end, v_fz,
            pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_fz::text, 'UTF8')), 'hex'), v_snap.id, v_uid, p_idempotency_key);
    insert into public.carrier_invoice_reissues_0157 (organization_id, carrier_id, original_invoice_id, replacement_invoice_id, reason, drift_dimensions, reissued_by, idempotency_key) values (v_org, v_i.carrier_id, p_invoice_id, v_new, pg_catalog.btrim(p_reason), v_dims, v_uid, p_idempotency_key);
    v_dfee := public._cif_dispatch_fee_0157(v_org, v_uid, v_i.carrier_id, v_new, v_ids, p_invoice_id);
  exception when sqlstate 'CIF01' then
    get stacked diagnostics v_fail = message_text, v_fail_msg = pg_exception_detail;
  end;
  if v_fail is not null then return public._cif_refuse_0157(v_org, v_uid, 'reissue', v_i.carrier_id, p_invoice_id, v_fail, coalesce(v_fail_msg, 'The invoice could not be reissued.')); end if;
  select c.invoice_number into v_num from public.carrier_invoices c where c.id = v_new;
  v_result := pg_catalog.jsonb_build_object('success', true, 'original_invoice_id', p_invoice_id, 'replacement_invoice_id', v_new, 'invoice_id', v_new, 'invoice_number', v_num, 'status', 'issued', 'billing_mode', v_mode, 'drift_dimensions', pg_catalog.to_jsonb(v_dims), 'dispatch_fee', v_dfee, 'message', 'The invoice was voided and reissued.');
  insert into public.carrier_invoice_workflow_ops_0157 (organization_id, operation, idempotency_key, request_fingerprint, invoice_id, result, created_by) values (v_org, 'reissue', p_idempotency_key, v_fp, v_new, v_result, v_uid);
  insert into public.carrier_invoice_factoring_audit_0157 (organization_id, actor_uid, event_type, outcome, code, message, carrier_id, carrier_invoice_id, detail, idempotency_key)
  values (v_org, v_uid, 'reissue', 'success', 'REISSUED', 'A carrier invoice was voided and reissued.', v_i.carrier_id, p_invoice_id, pg_catalog.jsonb_build_object('replacement_invoice_id', v_new, 'drift_dimensions', pg_catalog.to_jsonb(v_dims), 'reason', pg_catalog.btrim(p_reason)), p_idempotency_key);
  return v_result;
end
$fn$;

-- ======================= RLS + PRIVILEGES (explicit; independent of default privileges) ====================================
alter table public.carrier_invoice_factoring_gate_0157 enable row level security;
alter table public.carrier_factoring_submitter_grants_0157 enable row level security;
alter table public.carrier_invoice_factoring_submissions_0157 enable row level security;
alter table public.carrier_invoice_factoring_snapshots_0157 enable row level security;
alter table public.carrier_invoice_factoring_audit_0157 enable row level security;
create policy carrier_factoring_submitter_grants_0157_select on public.carrier_factoring_submitter_grants_0157 for select using (organization_id = public.current_org_id() and (public.has_role(array['owner','admin']::public.org_role[]) or profile_id = auth.uid()));
create policy carrier_invoice_factoring_submissions_0157_select on public.carrier_invoice_factoring_submissions_0157 for select using (organization_id = public.current_org_id()
  and (public.has_role(array['owner','admin','accountant']::public.org_role[]) or exists (select 1 from public.carrier_factoring_submitter_grants_0157 g where g.carrier_id = carrier_invoice_factoring_submissions_0157.carrier_id and g.profile_id = auth.uid() and g.revoked_at is null)));
create policy carrier_invoice_factoring_snapshots_0157_select on public.carrier_invoice_factoring_snapshots_0157 for select using (organization_id = public.current_org_id()
  and (public.has_role(array['owner','admin','accountant']::public.org_role[]) or exists (select 1 from public.carrier_factoring_submitter_grants_0157 g where g.carrier_id = carrier_invoice_factoring_snapshots_0157.carrier_id and g.profile_id = auth.uid() and g.revoked_at is null)));
alter table public.carrier_invoice_issuance_terms_0157 enable row level security;
alter table public.carrier_invoice_workflow_ops_0157 enable row level security;
alter table public.carrier_invoice_billable_ledger_0157 enable row level security;
alter table public.carrier_invoice_reissues_0157 enable row level security;
alter table public.carrier_invoice_dispatch_fee_links_0157 enable row level security;
create policy carrier_invoice_issuance_terms_0157_select on public.carrier_invoice_issuance_terms_0157 for select using (organization_id = public.current_org_id()
  and (public.has_role(array['owner','admin','accountant']::public.org_role[]) or exists (select 1 from public.carrier_factoring_submitter_grants_0157 g where g.carrier_id = carrier_invoice_issuance_terms_0157.carrier_id and g.profile_id = auth.uid() and g.revoked_at is null)));
create policy carrier_invoice_billable_ledger_0157_select on public.carrier_invoice_billable_ledger_0157 for select using (organization_id = public.current_org_id()
  and (public.has_role(array['owner','admin','accountant']::public.org_role[]) or exists (select 1 from public.carrier_factoring_submitter_grants_0157 g where g.carrier_id = carrier_invoice_billable_ledger_0157.carrier_id and g.profile_id = auth.uid() and g.revoked_at is null)));
create policy carrier_invoice_reissues_0157_select on public.carrier_invoice_reissues_0157 for select using (organization_id = public.current_org_id()
  and (public.has_role(array['owner','admin','accountant']::public.org_role[]) or exists (select 1 from public.carrier_factoring_submitter_grants_0157 g where g.carrier_id = carrier_invoice_reissues_0157.carrier_id and g.profile_id = auth.uid() and g.revoked_at is null)));
create policy carrier_invoice_dispatch_fee_links_0157_select on public.carrier_invoice_dispatch_fee_links_0157 for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','accountant']::public.org_role[]));
create policy carrier_invoice_workflow_ops_0157_select on public.carrier_invoice_workflow_ops_0157 for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
create policy carrier_invoice_factoring_audit_0157_select on public.carrier_invoice_factoring_audit_0157 for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin']::public.org_role[]));
revoke all on public.carrier_invoice_factoring_gate_0157, public.carrier_factoring_submitter_grants_0157, public.carrier_invoice_factoring_submissions_0157, public.carrier_invoice_factoring_snapshots_0157, public.carrier_invoice_factoring_audit_0157,
  public.carrier_invoice_issuance_terms_0157, public.carrier_invoice_workflow_ops_0157, public.carrier_invoice_billable_ledger_0157, public.carrier_invoice_reissues_0157, public.carrier_invoice_dispatch_fee_links_0157 from public, anon, authenticated, service_role;
grant select on public.carrier_factoring_submitter_grants_0157, public.carrier_invoice_factoring_submissions_0157, public.carrier_invoice_factoring_snapshots_0157, public.carrier_invoice_factoring_audit_0157,
  public.carrier_invoice_issuance_terms_0157, public.carrier_invoice_workflow_ops_0157, public.carrier_invoice_billable_ledger_0157, public.carrier_invoice_reissues_0157, public.carrier_invoice_dispatch_fee_links_0157 to authenticated;

revoke all on function public._cif_issuance_guard_0157(), public._cif_freeze_0157(uuid), public._cif_diff_frozen_0157(jsonb,jsonb), public._cif_selection_0157(uuid,uuid,uuid,uuid[],text,uuid,uuid), public._cif_create_draft_0157(uuid,uuid,uuid,uuid[],text,uuid,text),
  public._cif_dispatch_fee_0157(uuid,uuid,uuid,uuid,uuid[],uuid), public._cif_reissue_eval_0157(uuid,uuid,uuid) from public, anon, authenticated, service_role;
revoke all on function public._cif_audit_chain_0157(), public._cif_immutable_0157(), public._cif_submission_guard_0157(), public._cif_snapshot_guard_0157(), public._cif_gate_guard_0157(), public._cif_gate_audit_0157() from public, anon, authenticated, service_role;
revoke all on function public._cif_refuse_0157(uuid,uuid,text,uuid,uuid,text,text,jsonb,boolean), public._cif_authorize_0157(uuid,uuid,uuid), public._cif_evaluate_0157(uuid,uuid,uuid), public.verify_carrier_invoice_factoring_audit_chain_0157() from public, anon, authenticated, service_role;
revoke all on function public.preview_carrier_invoice_factoring(uuid), public.submit_carrier_invoice_to_factor(uuid,text), public.withdraw_carrier_invoice_factoring_submission(uuid,text,text), public.set_carrier_factoring_submitter(uuid,uuid,boolean,text,text),
  public.preview_carrier_invoice_issuance(uuid,uuid[],text,uuid), public.create_carrier_invoice_draft_from_loads(uuid,uuid[],text,uuid,text), public.mark_carrier_invoice_ready_for_issue(uuid,timestamptz,text), public.discard_carrier_invoice_draft(uuid,timestamptz,text,text), public.issue_prepared_carrier_invoice(uuid,timestamptz,text,text), public.preview_carrier_invoice_reissue(uuid), public.reissue_carrier_invoice(uuid,timestamptz,text,text) from public, anon, service_role;
grant execute on function public.preview_carrier_invoice_factoring(uuid), public.submit_carrier_invoice_to_factor(uuid,text), public.withdraw_carrier_invoice_factoring_submission(uuid,text,text), public.set_carrier_factoring_submitter(uuid,uuid,boolean,text,text),
  public.preview_carrier_invoice_issuance(uuid,uuid[],text,uuid), public.create_carrier_invoice_draft_from_loads(uuid,uuid[],text,uuid,text), public.mark_carrier_invoice_ready_for_issue(uuid,timestamptz,text), public.discard_carrier_invoice_draft(uuid,timestamptz,text,text), public.issue_prepared_carrier_invoice(uuid,timestamptz,text,text), public.preview_carrier_invoice_reissue(uuid), public.reissue_carrier_invoice(uuid,timestamptz,text,text) to authenticated;

-- ======================= POSTCONDITIONS ====================================================================================
do $mig$
declare s record; r record;
begin
  select * into s from _mig0157_snap;
  if (select md5(coalesce(string_agg(to_jsonb(c)::text, '|' order by c.id), '')) from public.carrier_invoices c) <> s.ci_fp or (select md5(coalesce(string_agg(to_jsonb(x)::text, '|' order by x.id), '')) from public.factoring_relationships x) <> s.rel_fp
     or (select md5(coalesce(string_agg(to_jsonb(f)::text, '|' order by f.id), '')) from public.factored_invoices f) <> s.fi_fp then raise exception '0157 postcondition: an existing carrier invoice, relationship or legacy factored invoice changed.'; end if;
  if (select count(*) from public.carrier_invoice_factoring_gate_0157) <> 1 or (select enabled from public.carrier_invoice_factoring_gate_0157) then raise exception '0157 postcondition: the gate must exist once and be DISABLED.'; end if;
  for r in select p.oid::regprocedure::text as sig, p.proname from pg_proc p where p.proname like '\_cif\_%' escape '\' or p.proname in ('submit_carrier_invoice_to_factor', 'preview_carrier_invoice_factoring', 'withdraw_carrier_invoice_factoring_submission', 'set_carrier_factoring_submitter', 'verify_carrier_invoice_factoring_audit_chain_0157',
    'preview_carrier_invoice_issuance', 'create_carrier_invoice_draft_from_loads', 'mark_carrier_invoice_ready_for_issue', 'discard_carrier_invoice_draft', 'issue_prepared_carrier_invoice', 'preview_carrier_invoice_reissue', 'reissue_carrier_invoice') loop
    if has_function_privilege('anon', r.sig, 'execute') or has_function_privilege('service_role', r.sig, 'execute') or (select p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') from pg_proc p where p.oid = r.sig::regprocedure) then raise exception '0157 postcondition: % is executable by anon/service_role/PUBLIC.', r.sig; end if;
    if r.proname like '\_cif\_%' escape '\' or r.proname = 'verify_carrier_invoice_factoring_audit_chain_0157' then if has_function_privilege('authenticated', r.sig, 'execute') then raise exception '0157 postcondition: internal % is executable by authenticated.', r.sig; end if; end if;
    if not (select p.proconfig::text in ('{"search_path=pg_catalog, pg_temp"}') from pg_proc p where p.oid = r.sig::regprocedure) then raise exception '0157 postcondition: % does not have the pinned search_path.', r.sig; end if;
  end loop;
  raise notice '0157 complete: gate DISABLED; nothing existing was changed.';
end
$mig$;
commit;
