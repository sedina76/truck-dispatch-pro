-- =============================================================================
-- 0145_carrier_dispatch_service_agreements_and_issuance.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0001-0144 live. Phase 3B.4.
--
-- GOAL: versioned, carrier-specific dispatch-service agreements (a NEW,
-- additive, effective-dated, approval-gated fee schedule), and safe atomic
-- dispatch_service_invoice issuance -- closing the DISPATCH_SERVICE_
-- AGREEMENT_REQUIRED early-return 0144 (Section E, Option 2) deliberately
-- left in place until an authoritative fee source existed.
--
-- ===========================================================================
-- SECTION A -- REINSPECTION FINDINGS (Phase 3B.4, Section B of the task)
-- ===========================================================================
-- organizations (0002): name/dba_name/mc_number/dot_number/business_phone/
--   business_email/address_line1/address_line2/city/state/postal_code/
--   country already exist -- authoritative for the dispatch organization's
--   own legal/contact identity in the new snapshot. NO remittance-
--   instructions free-text field exists anywhere for the dispatch
--   organization itself (organization_bank_accounts, 0014, holds ENCRYPTED
--   routing/account numbers gated to owner/admin for the org's OWN
--   incoming factoring/broker payments -- a materially different concept,
--   not a "how to pay us" display string for an outgoing carrier-facing
--   invoice). This migration adds ONE new nullable column,
--   organizations.remittance_instructions, mirroring carrier_remittance_
--   profiles.remittance_instructions (0130) exactly -- the minimal,
--   additive gap-fill, not a new table.
-- platform_settings.dispatch_service_terms_days (0130): singleton,
--   organization-agnostic, NOT NULL DEFAULT 15 -- the PLATFORM-WIDE
--   fallback payment-terms default for every dispatch-service invoice,
--   confirmed still live and unused by any RPC before this migration.
-- carriers.dispatch_service_terms_days (0130): nullable, 0-365, a PER-
--   CARRIER override of the platform default -- confirmed still live and
--   unused by any RPC before this migration.
-- carriers / carrier_remittance_profiles (0130): legal_name/dba_name/
--   mc_number/dot_number/address/contact/phone/email + remittance_name/
--   remittance_address*/remittance_email/remittance_instructions --
--   already the authoritative carrier RECIPIENT identity source
--   issue_carrier_invoice() (0144) already snapshots for carrier_freight_
--   invoice; reused verbatim for dispatch_service_invoice's own recipient
--   block (Section J) -- no new carrier-side columns needed.
-- EXISTING dispatch-fee-shaped fields, inspected and found NOT
--   authoritative for this migration: dispatches.dispatch_fee_percentage/
--   load_rate/dispatch_fee_amount/carrier_net_amount were REAL stored
--   columns on `dispatches` from 0004 through 0069 (Financial Column
--   Isolation), at which point 0069_financial_column_removal.sql DROPPED
--   all four from `dispatches` and moved them to a dedicated 1:1 table,
--   `dispatch_financials` (0067), kept live by
--   mirror_dispatch_financials() -- an informal, PER-DISPATCH, always-
--   computed (10% default) figure used by the pre-existing carrier-
--   settlements/profitability subsystem (0033-0038) for INTERNAL
--   estimated-proceeds reporting. It is architecturally SEPARATE from,
--   and predates, the formal, versioned, APPROVAL-gated agreement this
--   migration adds -- exactly as carrier_freight_invoice (0142) is
--   separate from the older, informal `invoices`/`factored_invoices`
--   legacy tables. Nothing in this migration reads from or writes to
--   dispatch_financials; a future, SEPARATE reconciliation slice (not
--   this one -- Section A's "do not add settlement deduction posting"
--   forbids it here) would decide how/whether the two ever meet.
-- CRITICAL FINDING -- a real, live defect in already-committed migration
--   0144, discovered during this inspection: issue_carrier_invoice()'s
--   loads_payload snapshot subquery reads `l.rate` directly from
--   `public.loads`. `loads.rate` does NOT exist in a real, fully-migrated
--   database -- 0069_financial_column_removal.sql dropped it (see above);
--   the authoritative value has lived in `load_financials.rate` (0067)
--   ever since, and create_load_with_stops() (0114) already writes there
--   directly, not to `loads.rate`. This was masked ONLY because the
--   TEST_SUPPORT_0130_0133_schema.sql fixture had (incorrectly, under a
--   comment mistakenly describing loads.rate as "the real 0004 rate
--   column") grown its OWN `loads.rate` column to match -- meaning 0144
--   has never actually been exercised against an accurate reproduction of
--   the real schema. Migrations 0001-0144 are frozen (this phase's own
--   explicit baseline) -- corrected here, in 0145, via CREATE OR REPLACE
--   of issue_carrier_invoice() itself (Section I already requires
--   "replace/extend issue_carrier_invoice() through migration 0145" for
--   the dispatch-service branch; this is the SAME precedent -- a later
--   migration correcting an earlier migration's function body, as already
--   established repeatedly: 0067->0068->0069, 0136->0138->0139, 0144's
--   own Phase 3B.3C.1/3B.3C.3 corrections) -- now reading
--   load_financials.rate, matching real production and create_load_with_
--   stops() exactly. TEST_SUPPORT_0130_0133_schema.sql is corrected in
--   the SAME phase (not itself a migration) to add the real
--   load_financials table plus a TEST-ONLY compatibility mirror trigger,
--   so every already-committed 0144 test (which still inserts `rate`
--   directly into `loads`) keeps working UNCHANGED while seeing the same
--   value through the corrected, production-accurate read path.
-- carrier_invoice_line_items (0142/0144): source_load_id/source_
--   dispatch_id exist but carry NO uniqueness constraint of their own --
--   confirmed nothing today prevents the SAME load from appearing on two
--   different line items/invoices. Section G's explicit warning ("do not
--   rely only on JSON snapshot contents for duplicate-billing
--   protection") is honored here with a real UNIQUE constraint on a new,
--   dedicated billing-source ledger table (below) -- never the snapshot
--   JSON alone.
-- carrier_invoice_issuance_snapshots (0142): invoice_id UNIQUE -- exactly
--   one snapshot per invoice, confirmed -- the authoritative, immutable
--   source this migration reads a load's already-issued freight amount
--   from (snapshot_payload->'loads', matched by load_id, field
--   'agreed_freight_charge') for percentage-of-freight dispatch fees --
--   never the live, mutable `load_financials.rate` once a freight invoice
--   has been issued for that load (Section F's explicit requirement).
-- carrier_invoice_number_counters / dispatch_invoice_prefix (0142):
--   platform_settings.dispatch_invoice_prefix (default 'DISP') and
--   _generate_carrier_invoice_number_internal('dispatch_service_invoice',
--   organization_id, prefix) were ALREADY wired for structural
--   completeness in 0142/0144 but unreachable (0144's STEP 10 always
--   returned first) -- reused verbatim here, now reachable.
-- issue_carrier_invoice()'s dispatch-service branch (0144, STEP 10):
--   currently `return jsonb_build_object(..., 'code',
--   'DISPATCH_SERVICE_AGREEMENT_REQUIRED', ...)` unconditionally, before
--   any lock beyond the invoice row itself. Confirmed via `grep` that no
--   application code (src/) references this exact string anywhere --
--   safe to retire in favor of Section K's more specific structured codes
--   (AGREEMENT_REQUIRED / AGREEMENT_NOT_APPROVED / AGREEMENT_NOT_
--   EFFECTIVE / ...).
-- Lock order / idempotency design (0143/0144): the organization+
--   operation+idempotency-key advisory lock, the canonical SHA-256
--   fingerprint (compute_financial_request_fingerprint), and the STEPS
--   1-9 pre-branch validation (auth/role, org, fingerprint, advisory
--   lock, invoice lock+revalidate, idempotency replay/collision,
--   status/payment-state checks) are ALREADY fully generic across BOTH
--   invoice_document_type values -- confirmed by direct re-read of 0144's
--   own source: STEP 10 is the FIRST and ONLY point where the two
--   document types' logic diverges. This migration exploits that
--   precisely: STEPS 1-9 are reused completely unchanged; STEP 10 now
--   dispatches to a NEW, dedicated internal function
--   (_issue_dispatch_service_invoice_internal) for the entire dispatch-
--   service-specific lock order/snapshot/apply block, rather than
--   growing the already-large freight-invoice function with a second,
--   unrelated document type's worth of branching logic throughout every
--   remaining step. issue_carrier_invoice()'s own PUBLIC SIGNATURE is
--   unchanged, per this task's explicit preference.
--
-- ===========================================================================
-- SECTION B -- WHAT THIS MIGRATION DOES
-- ===========================================================================
--   PHASE 1: preconditions.
--   PHASE 2: organizations.remittance_instructions (additive column);
--     entity_type gains 'carrier_dispatch_service_agreement'.
--   PHASE 3: agreement schema -- carrier_dispatch_service_agreements
--     (container) + carrier_dispatch_service_agreement_versions
--     (effective-dated, approval-gated terms) with a native PostgreSQL
--     EXCLUSION CONSTRAINT (btree_gist) making "no two APPROVED versions
--     for the same carrier may have overlapping effective date ranges" a
--     database-enforced, concurrency-safe invariant -- not a trigger-
--     based check-then-insert race (see LOCK_ORDER_0145_DISPATCH_
--     SERVICE_BILLING.md for the full derivation; this mirrors the SAME
--     effective-dated-overlap CONCEPT already established for
--     driver_pay_rates in 0031, but as a real exclusion constraint rather
--     than that migration's own trigger-based check, since Section E
--     explicitly requires concurrency-safety here).
--   PHASE 4: lifecycle-guard trigger on agreement versions -- financial
--     terms immutable once approved; only documented status transitions
--     permitted; approval snapshots approver/time.
--   PHASE 5: carrier_dispatch_service_billing_lines -- the explicit
--     billing-source ledger (Section G), with a real UNIQUE(load_id)
--     constraint as the authoritative anti-double-billing backstop.
--   PHASE 6: guarded SECURITY DEFINER RPCs -- create_carrier_dispatch_
--     service_agreement, create_carrier_dispatch_service_agreement_
--     version, approve_carrier_dispatch_service_agreement_version
--     (optionally supersedes a prior version atomically), deactivate_
--     carrier_dispatch_service_agreement_version, deactivate_carrier_
--     dispatch_service_agreement.
--   PHASE 7: issue_carrier_invoice() STEP 10 corrected (loads.rate ->
--     load_financials.rate fix folded in here) to dispatch to the new
--     _issue_dispatch_service_invoice_internal() for dispatch_service_
--     invoice, instead of an unconditional early return.
--   PHASE 8: postconditions.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not modify migrations 0001-0144 (their own files)
--   * does not add payment collection or settlement deduction posting
--   * does not deduct the dispatch fee from the carrier freight invoice
--   * does not add email/WhatsApp/factoring-transmission/PDF/portal/
--     QuickBooks/any external API call
--   * does not guess a dispatch fee when no approved, effective agreement
--     version exists
--   * does not let the browser submit a final fee -- every dispatch-
--     service line item is created BY this migration's own RPC, from
--     server-locked, server-computed values only
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is null then
    raise exception '0145 precondition: 0143 not applied (compute_financial_request_fingerprint missing). STOP.';
  end if;
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null then
    raise exception '0145 precondition: 0144 not applied (issue_carrier_invoice missing). STOP.';
  end if;
  if to_regclass('public.load_financials') is null then
    raise exception '0145 precondition: public.load_financials does not exist (0067 not applied, or the disposable-test fixture was not corrected). STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='remittance_instructions') then
    raise exception '0145 precondition: organizations.remittance_instructions already exists. STOP.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreements') is not null then
    raise exception '0145 precondition: public.carrier_dispatch_service_agreements already exists. STOP.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreement_versions') is not null then
    raise exception '0145 precondition: public.carrier_dispatch_service_agreement_versions already exists. STOP.';
  end if;
  if to_regclass('public.carrier_dispatch_service_billing_lines') is not null then
    raise exception '0145 precondition: public.carrier_dispatch_service_billing_lines already exists. STOP.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreement_idempotency') is not null then
    raise exception '0145 precondition: public.carrier_dispatch_service_agreement_idempotency already exists. STOP.';
  end if;
  if to_regprocedure('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)') is not null then
    raise exception '0145 precondition: _carrier_dispatch_service_agreement_effective_dates_lock_key already exists. STOP.';
  end if;
  raise notice '0145 PHASE 1 preconditions passed. 0143/0144 live, load_financials present, none of this migration''s own objects exist yet.';
end
$mig$;

-- ======================= PHASE 2 -- organizations + entity_type ============
alter table public.organizations
  add column remittance_instructions text;

comment on column public.organizations.remittance_instructions is
  'Phase 3B.4: free-text "how to pay us" instructions the dispatch organization wants displayed on a dispatch_service_invoice issued to a carrier -- mirrors carrier_remittance_profiles.remittance_instructions (0130) exactly. NULL by default (no default remittance text is silently invented). Distinct from organization_bank_accounts (0014, encrypted routing/account numbers for the org''s OWN incoming factoring/broker payments) -- this is a display string only, never encrypted, never a raw account number.';

alter type public.entity_type add value if not exists 'carrier_dispatch_service_agreement';

-- ======================= PHASE 3 -- agreement schema ========================
create type public.dispatch_service_agreement_status as enum ('active', 'inactive');

comment on type public.dispatch_service_agreement_status is
  'Phase 3B.4: container-level state for a carrier_dispatch_service_agreements row -- ''active'' means the dispatch org still has a live agreement relationship with this carrier at all (independent of which, if any, of its versions is currently approved/effective); ''inactive'' means the whole relationship has ended (no version under it may ever be used for a NEW issuance again, though history remains readable and already-issued invoices are untouched).';

create type public.dispatch_service_agreement_version_status as enum ('draft', 'approved', 'superseded', 'inactive');

comment on type public.dispatch_service_agreement_version_status is
  'Phase 3B.4 (Section E): draft (proposed terms, never billable) -> approved (the ONLY billable state; approval snapshots approver/time; financial terms become immutable) -> superseded (a later version was approved in its place; the row and its terms are preserved, immutable, forever) OR inactive (deactivated directly, from draft -- a cancelled proposal, fields never set -- or from approved -- ended without a replacement, fields preserved). No transition ever leads back to draft or approved.';

create type public.dispatch_service_fee_method as enum ('percentage_of_freight', 'flat_per_load');

comment on type public.dispatch_service_fee_method is
  'Phase 3B.4 (Section C): the two initially-supported dispatch-service fee bases. Deliberately NOT hybrid/tiered/subscription/hourly/fixed-period -- no existing requirement demands them, and Section C explicitly asks that they not be added speculatively.';

-- ---------------------------------------------------------------------------
-- carrier_dispatch_service_agreement_idempotency: Section D requires
-- "canonical SHA-256 idempotency" for every guarded agreement-lifecycle
-- RPC below -- but carrier_invoice_lifecycle_idempotency (0143) has
-- invoice_id uuid NOT NULL (it was purpose-built exclusively for
-- invoice-lifecycle operations, confirmed by direct re-read of 0142's
-- own table definition), so it cannot be reused for agreement/version
-- operations that have no invoice_id at all. A small, dedicated,
-- otherwise-identical table -- same canonical-fingerprint/advisory-lock/
-- replay-or-collision pattern as 0143's, with the invoice-specific
-- column dropped rather than made falsely nullable on the invoice
-- table.
-- ---------------------------------------------------------------------------
create table public.carrier_dispatch_service_agreement_idempotency (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  idempotency_key text not null check (btrim(idempotency_key) <> ''),
  operation text not null check (btrim(operation) <> ''),
  -- No FK to carrier_dispatch_service_agreements: this table is created
  -- BEFORE that one (its own idempotency mechanism must exist before any
  -- agreement-lifecycle RPC can run) -- a plain informational uuid,
  -- exactly like carrier_invoice_lifecycle_idempotency (0142) stores
  -- invoice_id with a real FK only because IT is created after
  -- carrier_invoices; the FK there is a convenience, not a correctness
  -- requirement of the idempotency mechanism itself.
  agreement_id uuid,
  request_fingerprint text not null,
  fingerprint_version integer not null default 1,
  result jsonb not null,
  state text not null default 'completed',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint cdsai_idempotency_unique unique (organization_id, operation, idempotency_key)
);

create trigger set_updated_at
  before update on public.carrier_dispatch_service_agreement_idempotency
  for each row execute function public.set_updated_at();

comment on table public.carrier_dispatch_service_agreement_idempotency is
  'Phase 3B.4: canonical SHA-256-fingerprinted idempotency for the agreement-lifecycle RPCs (create/create_version/approve/deactivate) -- the SAME pattern as carrier_invoice_lifecycle_idempotency (0143), scoped to (organization_id, operation, idempotency_key) exactly like the advisory lock each RPC takes, but without an invoice_id column (these operations have none).';

revoke insert, update, delete on public.carrier_dispatch_service_agreement_idempotency from authenticated;
revoke all on public.carrier_dispatch_service_agreement_idempotency from anon;

alter table public.carrier_dispatch_service_agreement_idempotency enable row level security;

create policy carrier_dispatch_service_agreement_idempotency_select
  on public.carrier_dispatch_service_agreement_idempotency for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

-- ---------------------------------------------------------------------------
-- carrier_dispatch_service_agreements: the container. One row per (org,
-- carrier, agreement_number) -- an org may have MULTIPLE distinct
-- agreements with the SAME carrier over time (e.g. a renegotiated
-- contract under a new agreement_number), each with its own version
-- history; nothing here requires exactly one agreement per carrier.
-- ---------------------------------------------------------------------------
create table public.carrier_dispatch_service_agreements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  agreement_number text not null check (btrim(agreement_number) <> ''),
  status public.dispatch_service_agreement_status not null default 'active',
  -- Denormalized convenience pointer to the latest APPROVED version
  -- (by version_number) -- maintained by approve_carrier_dispatch_
  -- service_agreement_version() below. NEVER authoritative for billing
  -- (issuance always re-derives the applicable version from the versions
  -- table directly, by carrier + effective date, under lock) -- purely a
  -- fast "what's our current rate" read for UI/reporting. FK added below,
  -- after the versions table exists (deferred, matching this project's
  -- own established "current_*_id added via a later ALTER TABLE, once
  -- its target table exists" convention).
  current_version_id uuid,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint cdsa_org_carrier_agreement_number_unique unique (organization_id, carrier_id, agreement_number)
);

comment on table public.carrier_dispatch_service_agreements is
  'Phase 3B.4: the dispatch-service agreement CONTAINER for one (organization, carrier, agreement_number) -- versioned terms live in carrier_dispatch_service_agreement_versions. No default agreement is ever silently created (Section C) -- every row here is the direct result of create_carrier_dispatch_service_agreement().';

create trigger set_updated_at
  before update on public.carrier_dispatch_service_agreements
  for each row execute function public.set_updated_at();

alter table public.carrier_dispatch_service_agreements enable row level security;

create policy carrier_dispatch_service_agreements_select
  on public.carrier_dispatch_service_agreements for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

-- NO direct authenticated INSERT/UPDATE/DELETE grant, for any role,
-- ever (Section D: "no direct authenticated table mutation") -- every
-- mutation goes through a guarded SECURITY DEFINER RPC below. Rows are
-- never deleted (historical financial configuration), matching this
-- project's own established "no DELETE policy" convention (e.g.
-- carrier_remittance_profiles, 0130).
revoke all on public.carrier_dispatch_service_agreements from anon, authenticated;
grant select on public.carrier_dispatch_service_agreements to authenticated;

-- ---------------------------------------------------------------------------
-- carrier_dispatch_service_agreement_versions: one row per proposed/
-- approved/superseded/inactive VERSION of an agreement's terms.
-- ---------------------------------------------------------------------------
create table public.carrier_dispatch_service_agreement_versions (
  id uuid primary key default gen_random_uuid(),
  agreement_id uuid not null references public.carrier_dispatch_service_agreements (id) on delete restrict,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  version_number integer not null check (version_number > 0),
  status public.dispatch_service_agreement_version_status not null default 'draft',

  fee_method public.dispatch_service_fee_method not null,
  -- Phase 3B.4 (Section C): percentage stored as the WHOLE-NUMBER-PERCENT
  -- convention already established by dispatches.dispatch_fee_percentage
  -- (0004: numeric(5,2) DEFAULT 10.00, i.e. "10.00" means 10%, divided by
  -- 100.0 wherever applied) -- 5% is stored here as 5.0000, NEVER as
  -- 0.050000. numeric(7,4) allows up to 999.9999 at the type level; the
  -- CHECK constraint below is the real, tighter ceiling.
  percentage_rate numeric(7, 4),
  flat_fee_per_load numeric(10, 2),
  minimum_fee numeric(10, 2),
  maximum_fee numeric(10, 2),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  -- NULL => fall back to carriers.dispatch_service_terms_days => finally
  -- platform_settings.dispatch_service_terms_days (Section A's 3-level
  -- chain; unchanged from the 2-level chain 0130 already documented,
  -- this simply becomes the new, most-specific first link).
  payment_terms_days integer check (payment_terms_days is null or payment_terms_days between 0 and 365),

  effective_from date not null,
  effective_to date,

  approved_by uuid references public.profiles (id) on delete set null,
  approved_at timestamptz,

  reason text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Section C: "percentage must be > 0 and within an explicit safe
  -- maximum" -- 50% is already an extreme outlier for a real dispatch
  -- fee (typically 5-15%); it exists to catch a data-entry error (e.g.
  -- "500" meant as "5.00"), not to permit a legitimately huge fee.
  -- "Flat fee must be positive" -- <= 50000.00 is the same class of
  -- sanity ceiling, not a business rule.
  constraint cdsav_fee_shape check (
    (fee_method = 'percentage_of_freight'
      and percentage_rate is not null and percentage_rate > 0 and percentage_rate <= 50.0000
      and flat_fee_per_load is null)
    or
    (fee_method = 'flat_per_load'
      and flat_fee_per_load is not null and flat_fee_per_load > 0 and flat_fee_per_load <= 50000.00
      and percentage_rate is null)
  ),
  constraint cdsav_minmax_fee_shape check (
    (minimum_fee is null or minimum_fee >= 0)
    and (maximum_fee is null or maximum_fee >= 0)
    and (minimum_fee is null or maximum_fee is null or minimum_fee <= maximum_fee)
  ),
  constraint cdsav_effective_range check (effective_to is null or effective_to >= effective_from),
  -- Section E's exact lifecycle: draft carries no approval fields;
  -- approved/superseded ALWAYS carry them (superseded rows keep the
  -- record of when/by whom they were originally approved -- "historical
  -- versions remain readable"); inactive may carry either shape,
  -- depending whether it was cancelled straight from draft or
  -- deactivated from approved.
  constraint cdsav_approval_fields check (
    (status = 'draft' and approved_by is null and approved_at is null)
    or (status in ('approved', 'superseded') and approved_by is not null and approved_at is not null)
    or (status = 'inactive')
  ),

  constraint cdsav_agreement_version_number_unique unique (agreement_id, version_number)
);

comment on table public.carrier_dispatch_service_agreement_versions is
  'Phase 3B.4: one row per proposed/approved/superseded/inactive set of dispatch-service fee terms. Financial terms (fee_method/percentage_rate/flat_fee_per_load/minimum_fee/maximum_fee/currency/payment_terms_days/effective_from/effective_to/carrier_id/agreement_id) become permanently immutable the moment status leaves ''draft'' -- see guard_carrier_dispatch_service_agreement_version_lifecycle() below. Approved versions never overlap in effective date range for the same carrier -- enforced by cdsav_no_overlap_when_approved, a real PostgreSQL exclusion constraint (concurrency-safe by construction), not a trigger-based check-then-insert race.';

create trigger set_updated_at
  before update on public.carrier_dispatch_service_agreement_versions
  for each row execute function public.set_updated_at();

-- Section E / Section C: "overlapping effective approved versions are
-- prohibited under concurrency" -- a native GiST exclusion constraint,
-- combining an equality match on carrier_id with a date-range overlap
-- test, restricted (partial) to status='approved' rows only (draft/
-- superseded/inactive versions may freely carry any dates -- only
-- BILLABLE versions need non-overlap). btree_gist supplies the "=" GiST
-- opclass for uuid so it can be combined with daterange's own native "&&"
-- operator in one exclusion constraint. This is enforced by PostgreSQL's
-- own index machinery at INSERT/UPDATE time -- exactly as concurrency-
-- safe as a unique constraint, immune to the classic check-then-insert
-- race a trigger-based version of this same rule (e.g. driver_pay_rates,
-- 0031) would be exposed to.
create extension if not exists btree_gist;

alter table public.carrier_dispatch_service_agreement_versions
  add constraint cdsav_no_overlap_when_approved
  exclude using gist (
    carrier_id with =,
    daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]') with &&
  )
  where (status = 'approved');

alter table public.carrier_dispatch_service_agreements
  add constraint cdsa_current_version_fk
  foreign key (current_version_id) references public.carrier_dispatch_service_agreement_versions (id) on delete set null;

alter table public.carrier_dispatch_service_agreement_versions enable row level security;

create policy carrier_dispatch_service_agreement_versions_select
  on public.carrier_dispatch_service_agreement_versions for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

revoke all on public.carrier_dispatch_service_agreement_versions from anon, authenticated;
grant select on public.carrier_dispatch_service_agreement_versions to authenticated;

-- ======================= PHASE 4 -- version lifecycle guard =================
-- Section C/E: "approved versions are immutable", "a used agreement
-- version is permanently immutable" (its financial TERMS -- see below for
-- why status may still legally transition afterward), "changing terms
-- creates a new version", only the documented status transitions are
-- legal. A pure lock-ordering device this is NOT (contrast guard_load_
-- stops_parent_lock, 0144) -- this trigger enforces real business rules,
-- deliberately.
create function public.guard_carrier_dispatch_service_agreement_version_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if tg_op = 'DELETE' then
    -- No DELETE policy is ever granted (see RLS grants above) -- this
    -- branch is unreachable via any authenticated path, kept only so a
    -- future service-role/migration script cannot silently delete a used
    -- version either (Section E: "an agreement version already used by
    -- an invoice cannot be deleted").
    if exists (select 1 from public.carrier_dispatch_service_billing_lines where agreement_version_id = old.id) then
      raise exception 'carrier_dispatch_service_agreement_versions: a version already used by a dispatch-service invoice can never be deleted.' using errcode = '55000';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    -- Financial terms are immutable the instant a version leaves
    -- 'draft' -- regardless of whether it has ever been used for
    -- billing. "Approved versions are immutable" (Section C) is the
    -- general rule; "a used agreement version is permanently immutable"
    -- (Section C) is the SAME rule restated for the case that matters
    -- most, not a second, stricter rule -- status MAY still legally
    -- transition afterward (approved -> superseded/inactive), which is
    -- exactly what "deactivation cannot invalidate an already issued
    -- invoice" (Section E) requires to even be possible.
    if old.status <> 'draft' then
      if new.fee_method is distinct from old.fee_method
        or new.percentage_rate is distinct from old.percentage_rate
        or new.flat_fee_per_load is distinct from old.flat_fee_per_load
        or new.minimum_fee is distinct from old.minimum_fee
        or new.maximum_fee is distinct from old.maximum_fee
        or new.currency is distinct from old.currency
        or new.payment_terms_days is distinct from old.payment_terms_days
        or new.effective_from is distinct from old.effective_from
        or new.effective_to is distinct from old.effective_to
        or new.carrier_id is distinct from old.carrier_id
        or new.agreement_id is distinct from old.agreement_id
      then
        raise exception 'carrier_dispatch_service_agreement_versions: financial terms are immutable once a version leaves draft (current status: %). Propose a new version instead.', old.status using errcode = '55000';
      end if;
    end if;

    -- Legal status transitions only: draft->approved, draft->inactive,
    -- approved->superseded, approved->inactive. Nothing else, ever
    -- (superseded/inactive are terminal; no path ever returns to draft
    -- or approved).
    if new.status is distinct from old.status then
      if not (
        (old.status = 'draft' and new.status in ('approved', 'inactive'))
        or (old.status = 'approved' and new.status in ('superseded', 'inactive'))
      ) then
        raise exception 'carrier_dispatch_service_agreement_versions: % -> % is not a permitted status transition.', old.status, new.status using errcode = '55000';
      end if;
    end if;
  end if;

  return coalesce(new, old);
end;
$fn$;

comment on function public.guard_carrier_dispatch_service_agreement_version_lifecycle() is
  'Phase 3B.4: financial terms (fee_method/rate/fee/min/max/currency/payment_terms_days/effective dates/carrier_id/agreement_id) become immutable the instant a version leaves draft; only draft->approved, draft->inactive, approved->superseded, and approved->inactive are legal status transitions; a version already referenced by carrier_dispatch_service_billing_lines can never be deleted.';

create trigger a0145_guard_agreement_version_lifecycle
  before update or delete on public.carrier_dispatch_service_agreement_versions
  for each row execute function public.guard_carrier_dispatch_service_agreement_version_lifecycle();

-- ======================= PHASE 5 -- billing-source ledger ===================
-- Section G: an explicit join/ledger linking a dispatch-service invoice
-- to the carrier, the agreement version actually used, the covered load,
-- the related freight invoice (percentage-of-freight only), the
-- authoritative freight amount, the calculated fee, currency, and method.
-- unique(load_id) is the REAL anti-double-billing backstop (Section G:
-- "do not rely only on JSON snapshot contents") -- a load may appear in
-- this ledger AT MOST ONCE, ever, regardless of which agreement/version/
-- invoice would otherwise reference it; this is deliberately STRICTER
-- than "same load/same agreement" (a load's dispatch service is billed
-- once, period -- rebilling it under a DIFFERENT later agreement version
-- would still be double billing the same completed work).
create table public.carrier_dispatch_service_billing_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.carrier_invoices (id) on delete restrict,
  carrier_id uuid not null references public.carriers (id) on delete restrict,
  agreement_version_id uuid not null references public.carrier_dispatch_service_agreement_versions (id) on delete restrict,
  load_id uuid not null references public.loads (id) on delete restrict,
  source_freight_invoice_id uuid references public.carrier_invoices (id) on delete restrict,
  fee_method public.dispatch_service_fee_method not null,
  authoritative_freight_amount numeric(12, 2),
  calculated_fee numeric(10, 2) not null check (calculated_fee >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default now(),

  constraint cdsbl_freight_basis_shape check (
    (fee_method = 'percentage_of_freight' and source_freight_invoice_id is not null and authoritative_freight_amount is not null)
    or
    (fee_method = 'flat_per_load' and source_freight_invoice_id is null and authoritative_freight_amount is null)
  ),

  unique (load_id)
);

comment on table public.carrier_dispatch_service_billing_lines is
  'Phase 3B.4 (Section G): the explicit, real-constraint billing-source ledger -- one row per load ever billed for dispatch service, permanently. unique(load_id) is the authoritative anti-double-billing backstop; JSON snapshot contents are never relied on alone for this. Insert-only from issue_carrier_invoice()''s own SECURITY DEFINER context -- never directly writable by any client role.

Phase 3B.4.1 (Section H) -- duplicate-billing CORRECTION policy, documented explicitly (no credit/reissue workflow is implemented in this phase):
  - One dispatch-service charge obligation exists per load, ever. unique(load_id) enforces this as a database invariant, not merely an application check.
  - There is no DELETE path on this table (no policy grants it, no RPC performs it) -- a billing line, once created, is permanent history.
  - Voiding the dispatch-service invoice that references a billing line (were a void mechanism ever added for dispatch-service invoices) does NOT delete or otherwise free the billing line -- the load remains permanently ineligible for a new dispatch-service charge. This is a deliberate design choice: a voided invoice reflects a billing/administrative correction to how an already-earned obligation was invoiced, never a reversal of the underlying obligation itself.
  - Correcting an erroneous fee (wrong rate, wrong amount, wrong load) requires a FUTURE, explicit credit/reissue workflow -- issuing a negative-amount credit against the original billing line/invoice, or another equally explicit mechanism -- never a silent second charge and never a deletion of the original row. No such workflow exists yet; this is a documented, deliberate scope boundary, not an oversight.
  - Users cannot bypass this protection by creating a brand-new agreement, a brand-new version, or superseding the version that was originally used -- unique(load_id) is scoped to the load alone, never to any agreement/version/invoice, so no new agreement-side object can ever make an already-billed load billable again (proved by TEST_0145''s own Scenario G1: a fresh, later, non-overlapping approved version for the same carrier still gets LOAD_ALREADY_BILLED for a load billed under an earlier, now-superseded version).';

alter table public.carrier_dispatch_service_billing_lines enable row level security;

create policy carrier_dispatch_service_billing_lines_select
  on public.carrier_dispatch_service_billing_lines for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

revoke all on public.carrier_dispatch_service_billing_lines from anon, authenticated;
grant select on public.carrier_dispatch_service_billing_lines to authenticated;

create index idx_cdsbl_agreement_version on public.carrier_dispatch_service_billing_lines (agreement_version_id);
create index idx_cdsbl_invoice on public.carrier_dispatch_service_billing_lines (invoice_id);
create index idx_cdsbl_source_freight_invoice on public.carrier_dispatch_service_billing_lines (source_freight_invoice_id) where source_freight_invoice_id is not null;

-- ======================= PHASE 5B -- effective-date serialization lock ======
-- Phase 3B.4.1, Section A: the GiST exclusion constraint
-- (cdsav_no_overlap_when_approved) alone is not deadlock-free under
-- genuine concurrency -- when two DIFFERENT, uncommitted transactions
-- each try to approve a DIFFERENT, mutually-overlapping row for the
-- SAME carrier, PostgreSQL's own exclusion-constraint check can require
-- each to wait on the OTHER's still-uncommitted row before it can decide
-- whether a real conflict exists; if both wait on each other, that is a
-- genuine AB-BA cycle and PostgreSQL's deadlock detector (correctly)
-- aborts one side with a raw 40P01 error -- never an acceptable "normal
-- outcome" for a client-facing financial RPC.
--
-- Fix: serialize EVERY operation capable of creating or changing an
-- approved effective-date range for a given carrier behind a single
-- transaction-scoped advisory lock, acquired BEFORE that operation ever
-- reaches a row lock/insert/update on carrier_dispatch_service_
-- agreement_versions -- so at most ONE transaction is ever "inside" the
-- overlap-sensitive section for a given carrier at a time. The second
-- transaction blocks on the ADVISORY lock (a completely different,
-- lightweight wait mechanism with no interaction with the GiST index's
-- own two-phase check), not on the exclusion constraint itself -- by the
-- time it proceeds, the first transaction has already fully committed
-- or rolled back, so the exclusion constraint (kept as a pure backstop)
-- only ever needs to compare against ALREADY-COMMITTED rows, which
-- cannot deadlock (Postgres never needs to wait on a committed row's
-- own transaction -- it has none in flight).
--
-- Scoped to (organization_id, carrier_id) -- NOT agreement_id -- per
-- Section A: overlapping approved versions could otherwise exist across
-- two SEPARATE agreement container rows for the same carrier (nothing
-- prevents an organization from creating more than one agreement
-- container per carrier), and the exclusion constraint itself is scoped
-- to carrier_id alone, not to any one agreement. Every one of the five
-- lifecycle RPCs below, and _issue_dispatch_service_invoice_internal()'s
-- own applicable-version lookup, acquires this SAME key, in the SAME
-- position (immediately after the pre-existing per-operation advisory
-- lock, immediately before any carrier_dispatch_service_agreement_
-- versions row lock/insert/update) -- see LOCK_ORDER_0145_DISPATCH_
-- SERVICE_BILLING.md for the full, updated proof.
create function public._carrier_dispatch_service_agreement_effective_dates_lock_key(
  p_organization_id uuid,
  p_carrier_id uuid
)
returns bigint
language sql
immutable
as $fn$
  select hashtextextended(
    p_organization_id::text || '|' || p_carrier_id::text || '|carrier_dispatch_service_agreement_effective_dates', 0
  );
$fn$;

comment on function public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid, uuid) is
  'Phase 3B.4.1: the single, canonical (organization_id, carrier_id)-scoped advisory-lock key every dispatch-service-agreement lifecycle RPC and issuance path acquires (pg_advisory_xact_lock) before touching any carrier_dispatch_service_agreement_versions row for that carrier -- serializes the entire overlap-sensitive section so the GiST exclusion constraint (kept as a backstop) never has to arbitrate between two uncommitted transactions, eliminating the 40P01 deadlock class structurally rather than papering over it.';

revoke all on function public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid, uuid) from public, anon, authenticated;

-- ======================= PHASE 6 -- agreement lifecycle RPCs ================
-- Section D authorization model for all five RPCs below:
--   owner/admin: create agreement, create version, approve, supersede
--     (folded into approve, see below), deactivate (version and/or
--     agreement).
--   accountant: MAY create a draft version (Section D: "prepare a draft
--     proposal if useful") -- never approve, never deactivate, never
--     create the agreement container itself (starting a new agreement
--     relationship is a bigger commitment than proposing draft terms
--     under one that already exists).
--   dispatcher/driver/viewer: no write access to any of the RPCs below
--     (read-only, via the SELECT policies above).
--   service_role: has no auth.uid() of its own -- structurally cannot
--     pass the auth.uid() is null check every RPC below performs first,
--     exactly like issue_carrier_invoice() (0144) -- "not an ordinary-
--     user substitute" is enforced identically, not merely asserted.

create function public.create_carrier_dispatch_service_agreement(
  p_carrier_id uuid,
  p_agreement_number text,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'create_carrier_dispatch_service_agreement';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_carrier public.carriers%rowtype;
  v_id uuid;
  v_result jsonb;
  v_constraint text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  if p_agreement_number is null or btrim(p_agreement_number) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An agreement number/reference is required.');
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only owners and admins may create a dispatch-service agreement.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'carrier_id', p_carrier_id, 'agreement_number', btrim(p_agreement_number),
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    )
  );
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_dispatch_service_agreement_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  -- Phase 3B.4.1, Section A: the SAME carrier-scoped effective-dates lock
  -- every version-lifecycle operation for this carrier acquires -- see
  -- PHASE 5B's own header comment. This container carries no date range
  -- of its own, but acquiring it here too keeps agreement creation
  -- serialized against a concurrent version-lifecycle operation for the
  -- same carrier under the identical key/order, per Section A.
  perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(v_org, p_carrier_id));

  select * into v_carrier from public.carriers where id = p_carrier_id and organization_id = v_org for update;
  if v_carrier.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Carrier not found.');
  end if;

  begin
    insert into public.carrier_dispatch_service_agreements
      (organization_id, carrier_id, agreement_number, status, created_by)
    values
      (v_org, p_carrier_id, btrim(p_agreement_number), 'active', v_uid)
    returning id into v_id;

    perform public.log_activity('carrier_dispatch_service_agreement'::public.entity_type, v_id, 'dispatch_service_agreement_created',
      jsonb_build_object('carrier_id', p_carrier_id, 'agreement_number', btrim(p_agreement_number), 'reason', p_reason));

    v_result := jsonb_build_object('success', true, 'code', 'CREATED', 'agreement_id', v_id, 'agreement_number', btrim(p_agreement_number));

    insert into public.carrier_dispatch_service_agreement_idempotency
      (organization_id, idempotency_key, operation, agreement_id, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, v_operation, v_id, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint = 'cdsa_org_carrier_agreement_number_unique' then
        return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An agreement with this number already exists for this carrier.');
      end if;
      if v_constraint <> 'cdsai_idempotency_unique' then
        raise;
      end if;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_dispatch_service_agreement_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

comment on function public.create_carrier_dispatch_service_agreement(uuid, text, text, text) is
  'Phase 3B.4: owner/admin only. Creates the agreement CONTAINER (status=active, no version yet -- Section C: "no default agreement is silently created"). Canonical SHA-256 idempotency via carrier_dispatch_service_agreement_idempotency (a dedicated table -- carrier_invoice_lifecycle_idempotency, 0143, has invoice_id NOT NULL and cannot represent a non-invoice operation).';

revoke all on function public.create_carrier_dispatch_service_agreement(uuid, text, text, text) from public, anon;
grant execute on function public.create_carrier_dispatch_service_agreement(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create function public.create_carrier_dispatch_service_agreement_version(
  p_agreement_id uuid,
  p_fee_method public.dispatch_service_fee_method,
  p_percentage_rate numeric,
  p_flat_fee_per_load numeric,
  p_minimum_fee numeric,
  p_maximum_fee numeric,
  p_currency text,
  p_payment_terms_days integer,
  p_effective_from date,
  p_effective_to date,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'create_carrier_dispatch_service_agreement_version';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_agreement public.carrier_dispatch_service_agreements%rowtype;
  v_next_version integer;
  v_id uuid;
  v_result jsonb;
  v_constraint text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  -- Section D: owner/admin full authority; accountant may propose a
  -- draft (never approve/deactivate -- those RPCs check owner/admin only).
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to propose dispatch-service agreement terms.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'agreement_id', p_agreement_id, 'fee_method', p_fee_method, 'percentage_rate', p_percentage_rate,
      'flat_fee_per_load', p_flat_fee_per_load, 'minimum_fee', p_minimum_fee, 'maximum_fee', p_maximum_fee,
      'currency', p_currency, 'payment_terms_days', p_payment_terms_days,
      'effective_from', p_effective_from, 'effective_to', p_effective_to,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    )
  );
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_dispatch_service_agreement_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  -- Phase 3B.4.1, Section A/E: a provisional (unlocked) read of the
  -- agreement's own carrier_id is enough to derive the SAME carrier-
  -- scoped effective-dates lock key every other lifecycle operation for
  -- this carrier acquires -- acquired here BEFORE the agreement row is
  -- locked. Section E: "every creator locks the agreement container
  -- first" -- the row lock below, on the SAME agreement_id, is what
  -- actually serializes version_number allocation (every concurrent
  -- proposer for this agreement blocks on the identical row); the
  -- carrier-scoped lock additionally serializes against a concurrent
  -- approve/supersede/deactivate for the SAME CARRIER (which may span a
  -- different agreement_id).
  declare v_provisional_carrier_id uuid;
  begin
    select carrier_id into v_provisional_carrier_id from public.carrier_dispatch_service_agreements where id = p_agreement_id and organization_id = v_org;
    if v_provisional_carrier_id is not null then
      perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(v_org, v_provisional_carrier_id));
    end if;
  end;

  select * into v_agreement from public.carrier_dispatch_service_agreements where id = p_agreement_id and organization_id = v_org for update;
  if v_agreement.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Agreement not found.');
  end if;

  if p_effective_from is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An effective start date is required.');
  end if;
  if p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'A valid 3-letter currency code is required.');
  end if;
  if p_fee_method = 'percentage_of_freight' and (p_percentage_rate is null or p_percentage_rate <= 0 or p_percentage_rate > 50.0000) then
    return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'A percentage rate greater than 0 and no more than 50% is required for this fee method.');
  end if;
  if p_fee_method = 'flat_per_load' and (p_flat_fee_per_load is null or p_flat_fee_per_load <= 0 or p_flat_fee_per_load > 50000.00) then
    return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'A positive flat fee per load (no more than 50,000) is required for this fee method.');
  end if;

  select coalesce(max(version_number), 0) + 1 into v_next_version
  from public.carrier_dispatch_service_agreement_versions where agreement_id = p_agreement_id;

  begin
    insert into public.carrier_dispatch_service_agreement_versions
      (agreement_id, organization_id, carrier_id, version_number, status, fee_method, percentage_rate, flat_fee_per_load,
       minimum_fee, maximum_fee, currency, payment_terms_days, effective_from, effective_to, reason, created_by)
    values
      (p_agreement_id, v_org, v_agreement.carrier_id, v_next_version, 'draft', p_fee_method, p_percentage_rate, p_flat_fee_per_load,
       p_minimum_fee, p_maximum_fee, p_currency, p_payment_terms_days, p_effective_from, p_effective_to, p_reason, v_uid)
    returning id into v_id;

    perform public.log_activity('carrier_dispatch_service_agreement'::public.entity_type, p_agreement_id, 'dispatch_service_agreement_version_proposed',
      jsonb_build_object('version_id', v_id, 'version_number', v_next_version, 'fee_method', p_fee_method, 'reason', p_reason));

    v_result := jsonb_build_object('success', true, 'code', 'CREATED', 'agreement_id', p_agreement_id, 'version_id', v_id, 'version_number', v_next_version);

    insert into public.carrier_dispatch_service_agreement_idempotency
      (organization_id, idempotency_key, operation, agreement_id, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, v_operation, p_agreement_id, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      -- Phase 3B.4.1, Section E: structurally unreachable in practice
      -- (the agreement row lock above already serializes every proposer
      -- for this SAME agreement_id, so two concurrent callers can never
      -- both compute the same v_next_version) -- kept as a controlled,
      -- structured fallback rather than a raw constraint-name leak, in
      -- case a future caller ever bypasses the row lock (e.g. a direct
      -- service-role INSERT).
      if v_constraint = 'cdsav_agreement_version_number_unique' then
        return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'The agreement changed while proposing this version. Reload and try again.');
      end if;
      if v_constraint <> 'cdsai_idempotency_unique' then
        raise;
      end if;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_dispatch_service_agreement_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

comment on function public.create_carrier_dispatch_service_agreement_version(uuid, public.dispatch_service_fee_method, numeric, numeric, numeric, numeric, text, integer, date, date, text, text) is
  'Phase 3B.4: owner/admin/accountant. Creates a new DRAFT version under an existing agreement -- never billable until approved. Locks the agreement row first, serializing version_number allocation.';

revoke all on function public.create_carrier_dispatch_service_agreement_version(uuid, public.dispatch_service_fee_method, numeric, numeric, numeric, numeric, text, integer, date, date, text, text) from public, anon;
grant execute on function public.create_carrier_dispatch_service_agreement_version(uuid, public.dispatch_service_fee_method, numeric, numeric, numeric, numeric, text, integer, date, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create function public.approve_carrier_dispatch_service_agreement_version(
  p_version_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text,
  p_supersede_version_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'approve_carrier_dispatch_service_agreement_version';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_version public.carrier_dispatch_service_agreement_versions%rowtype;
  v_supersede public.carrier_dispatch_service_agreement_versions%rowtype;
  v_result jsonb;
  v_constraint text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  -- Section D: approval/supersession is owner/admin ONLY -- accountant
  -- may propose (create_..._version above) but never approve/activate.
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only owners and admins may approve a dispatch-service agreement version.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'version_id', p_version_id, 'supersede_version_id', p_supersede_version_id,
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  -- Phase 3B.4.1, Section A: acquire the carrier-scoped effective-dates
  -- lock BEFORE locking the version row -- a provisional (unlocked) read
  -- of carrier_id is sufficient to derive the key, since carrier_id is
  -- immutable on this table once a version is created (no RPC or guard
  -- trigger ever changes it). This is THE critical fix for the 40P01
  -- deadlock: at most one approval/supersession/deactivation for this
  -- carrier is ever "inside" the overlap-sensitive section at a time --
  -- see PHASE 5B's own header comment and LOCK_ORDER_0145_DISPATCH_
  -- SERVICE_BILLING.md.
  declare v_provisional_carrier_id uuid;
  begin
    select carrier_id into v_provisional_carrier_id from public.carrier_dispatch_service_agreement_versions where id = p_version_id and organization_id = v_org;
    if v_provisional_carrier_id is not null then
      perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(v_org, v_provisional_carrier_id));
    end if;
  end;

  select * into v_version from public.carrier_dispatch_service_agreement_versions where id = p_version_id and organization_id = v_org for update;
  if v_version.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Agreement version not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_dispatch_service_agreement_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_version.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This agreement version has changed since you loaded it. Reload and try again.');
  end if;
  if v_version.status <> 'draft' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only a draft version can be approved.', 'current_status', v_version.status);
  end if;

  -- Ascending-id lock order when BOTH a supersede target and the version
  -- being approved are locked in the same transaction -- avoids a
  -- reversal against any future path that might lock two versions of
  -- the same agreement together (none exists today; documented in
  -- LOCK_ORDER_0145_DISPATCH_SERVICE_BILLING.md regardless).
  if p_supersede_version_id is not null then
    if p_supersede_version_id = p_version_id then
      return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'A version cannot supersede itself.');
    end if;
    if p_supersede_version_id < p_version_id then
      select * into v_supersede from public.carrier_dispatch_service_agreement_versions where id = p_supersede_version_id and organization_id = v_org for update;
    end if;
  end if;
  if p_supersede_version_id is not null and v_supersede.id is null and p_supersede_version_id > p_version_id then
    select * into v_supersede from public.carrier_dispatch_service_agreement_versions where id = p_supersede_version_id and organization_id = v_org for update;
  end if;

  if p_supersede_version_id is not null then
    if v_supersede.id is null then
      return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'The version to supersede was not found.');
    end if;
    if v_supersede.agreement_id <> v_version.agreement_id then
      return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'The version to supersede does not belong to the same agreement.');
    end if;
    if v_supersede.status <> 'approved' then
      return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only a currently-approved version can be superseded.', 'current_status', v_supersede.status);
    end if;
  end if;

  -- Phase 3B.4.1, Section A: explicit, application-level overlap check,
  -- performed WHILE HOLDING the carrier-scoped advisory lock acquired
  -- above -- no other transaction can be concurrently approving/
  -- superseding/deactivating a version for this SAME carrier, so this
  -- check-then-write is race-free without depending on the exclusion
  -- constraint's own atomicity to arbitrate between two uncommitted
  -- rows. p_supersede_version_id is explicitly excluded here even though
  -- it is still (at this point) 'approved' -- it is about to be
  -- superseded by the SAME transaction, atomically, below.
  if exists (
    select 1 from public.carrier_dispatch_service_agreement_versions v2
    where v2.carrier_id = v_version.carrier_id
      and v2.id <> p_version_id
      and (p_supersede_version_id is null or v2.id <> p_supersede_version_id)
      and v2.status = 'approved'
      and daterange(v2.effective_from, coalesce(v2.effective_to, 'infinity'::date), '[]')
          && daterange(v_version.effective_from, coalesce(v_version.effective_to, 'infinity'::date), '[]')
  ) then
    return jsonb_build_object('success', false, 'code', 'AGREEMENT_OVERLAP', 'message', 'This version''s effective date range overlaps an already-approved version for this carrier.');
  end if;

  begin
    -- Supersede FIRST (removes the old version from the partial
    -- exclusion-constraint index before the new version's own approval
    -- is attempted against it), then approve. The GiST exclusion
    -- constraint (cdsav_no_overlap_when_approved) remains a pure
    -- backstop below -- given the app-level check above and the
    -- carrier-scoped lock held for this entire transaction, it should
    -- never actually fire in normal operation.
    if p_supersede_version_id is not null then
      update public.carrier_dispatch_service_agreement_versions
        set status = 'superseded'
        where id = p_supersede_version_id;
    end if;

    update public.carrier_dispatch_service_agreement_versions
      set status = 'approved', approved_by = v_uid, approved_at = now()
      where id = p_version_id;

    update public.carrier_dispatch_service_agreements
      set current_version_id = p_version_id
      where id = v_version.agreement_id
        and (current_version_id is null or current_version_id in (
          select id from public.carrier_dispatch_service_agreement_versions
          where agreement_id = v_version.agreement_id and version_number < v_version.version_number
        ) or current_version_id = p_supersede_version_id);

    perform public.log_activity('carrier_dispatch_service_agreement'::public.entity_type, v_version.agreement_id, 'dispatch_service_agreement_version_approved',
      jsonb_build_object('version_id', p_version_id, 'superseded_version_id', p_supersede_version_id, 'reason', p_reason));

    v_result := jsonb_build_object('success', true, 'code', 'APPROVED', 'agreement_id', v_version.agreement_id, 'version_id', p_version_id, 'superseded_version_id', p_supersede_version_id);

    insert into public.carrier_dispatch_service_agreement_idempotency
      (organization_id, idempotency_key, operation, agreement_id, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, v_operation, v_version.agreement_id, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when exclusion_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'cdsav_no_overlap_when_approved' then
        raise;
      end if;
      return jsonb_build_object('success', false, 'code', 'AGREEMENT_OVERLAP', 'message', 'This version''s effective date range overlaps an already-approved version for this carrier.');
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'cdsai_idempotency_unique' then
        raise;
      end if;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_dispatch_service_agreement_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

comment on function public.approve_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text, uuid) is
  'Phase 3B.4: owner/admin only. Approves a draft version (approval snapshots approver/time); optionally supersedes a specific currently-approved version of the SAME agreement atomically, in the same transaction. AGREEMENT_OVERLAP is returned, never a raw SQL error, if the resulting approved set would overlap another approved version''s effective range for the same carrier (cdsav_no_overlap_when_approved, a real exclusion constraint -- concurrency-safe by construction).';

revoke all on function public.approve_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text, uuid) from public, anon;
grant execute on function public.approve_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text, uuid) to authenticated;

-- ---------------------------------------------------------------------------
create function public.deactivate_carrier_dispatch_service_agreement_version(
  p_version_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'deactivate_carrier_dispatch_service_agreement_version';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_version public.carrier_dispatch_service_agreement_versions%rowtype;
  v_result jsonb;
  v_constraint text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only owners and admins may deactivate a dispatch-service agreement version.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'version_id', p_version_id, 'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  -- Phase 3B.4.1, Section A: the SAME carrier-scoped effective-dates
  -- lock -- deactivating an approved version REMOVES it from the
  -- approved set, so this must serialize against a concurrent approval
  -- for the same carrier exactly like the other four lifecycle RPCs.
  declare v_provisional_carrier_id uuid;
  begin
    select carrier_id into v_provisional_carrier_id from public.carrier_dispatch_service_agreement_versions where id = p_version_id and organization_id = v_org;
    if v_provisional_carrier_id is not null then
      perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(v_org, v_provisional_carrier_id));
    end if;
  end;

  select * into v_version from public.carrier_dispatch_service_agreement_versions where id = p_version_id and organization_id = v_org for update;
  if v_version.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Agreement version not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_dispatch_service_agreement_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_version.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This agreement version has changed since you loaded it. Reload and try again.');
  end if;
  if v_version.status not in ('draft', 'approved') then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only a draft or approved version can be deactivated.', 'current_status', v_version.status);
  end if;

  begin
    update public.carrier_dispatch_service_agreement_versions set status = 'inactive' where id = p_version_id;

    perform public.log_activity('carrier_dispatch_service_agreement'::public.entity_type, v_version.agreement_id, 'dispatch_service_agreement_version_deactivated',
      jsonb_build_object('version_id', p_version_id, 'reason', p_reason));

    v_result := jsonb_build_object('success', true, 'code', 'DEACTIVATED', 'agreement_id', v_version.agreement_id, 'version_id', p_version_id);

    insert into public.carrier_dispatch_service_agreement_idempotency
      (organization_id, idempotency_key, operation, agreement_id, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, v_operation, v_version.agreement_id, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'cdsai_idempotency_unique' then
        raise;
      end if;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_dispatch_service_agreement_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

comment on function public.deactivate_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text) is
  'Phase 3B.4: owner/admin only. Deactivates a draft (cancel a proposal) or approved (end without a replacement) version. Never touches any already-issued dispatch-service invoice or its snapshot -- deactivation is forward-looking only (Section E: "deactivation cannot invalidate an already issued invoice").';

revoke all on function public.deactivate_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.deactivate_carrier_dispatch_service_agreement_version(uuid, timestamptz, text, text) to authenticated;

-- ---------------------------------------------------------------------------
create function public.deactivate_carrier_dispatch_service_agreement(
  p_agreement_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'deactivate_carrier_dispatch_service_agreement';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_agreement public.carrier_dispatch_service_agreements%rowtype;
  v_result jsonb;
  v_constraint text;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only owners and admins may deactivate a dispatch-service agreement.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'agreement_id', p_agreement_id, 'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  -- Phase 3B.4.1, Section A: the SAME carrier-scoped effective-dates
  -- lock, for consistency with every other lifecycle operation on this
  -- carrier's agreements -- deactivating the CONTAINER never itself
  -- changes any version's effective range, but acquiring the identical
  -- key/order here too means a future change to this function can never
  -- accidentally introduce a reversal against the other five operations.
  declare v_provisional_carrier_id uuid;
  begin
    select carrier_id into v_provisional_carrier_id from public.carrier_dispatch_service_agreements where id = p_agreement_id and organization_id = v_org;
    if v_provisional_carrier_id is not null then
      perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(v_org, v_provisional_carrier_id));
    end if;
  end;

  select * into v_agreement from public.carrier_dispatch_service_agreements where id = p_agreement_id and organization_id = v_org for update;
  if v_agreement.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Agreement not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_dispatch_service_agreement_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_agreement.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This agreement has changed since you loaded it. Reload and try again.');
  end if;
  if v_agreement.status <> 'active' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'This agreement is already inactive.');
  end if;

  begin
    update public.carrier_dispatch_service_agreements set status = 'inactive' where id = p_agreement_id;

    perform public.log_activity('carrier_dispatch_service_agreement'::public.entity_type, p_agreement_id, 'dispatch_service_agreement_deactivated',
      jsonb_build_object('reason', p_reason));

    v_result := jsonb_build_object('success', true, 'code', 'DEACTIVATED', 'agreement_id', p_agreement_id);

    insert into public.carrier_dispatch_service_agreement_idempotency
      (organization_id, idempotency_key, operation, agreement_id, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, v_operation, p_agreement_id, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'cdsai_idempotency_unique' then
        raise;
      end if;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_dispatch_service_agreement_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

comment on function public.deactivate_carrier_dispatch_service_agreement(uuid, timestamptz, text, text) is
  'Phase 3B.4: owner/admin only. Deactivates the whole agreement container -- no version under it may be used for a NEW issuance again. Never touches already-issued invoices.';

revoke all on function public.deactivate_carrier_dispatch_service_agreement(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.deactivate_carrier_dispatch_service_agreement(uuid, timestamptz, text, text) to authenticated;

-- ======================= PHASE 7 -- issue_carrier_invoice() extension =======
-- _issue_dispatch_service_invoice_internal(): the ENTIRE dispatch-service-
-- specific lock order / fee computation / snapshot / apply block --
-- called from issue_carrier_invoice()'s own STEP 10 (below), after that
-- function's STEPS 1-9 (auth, org, fingerprint, advisory lock, invoice
-- lock+revalidate, idempotency replay/collision, status/payment-state
-- checks) have ALREADY run, fully shared, unchanged. EXECUTE revoked from
-- every role -- reachable ONLY from issue_carrier_invoice()'s own trusted
-- SECURITY DEFINER context, exactly like _generate_carrier_invoice_
-- number_internal (0142).
--
-- Global lock order (continuing from issue_carrier_invoice()'s own
-- position 1-2: advisory lock, carrier_invoices FOR UPDATE) -- see
-- LOCK_ORDER_0145_DISPATCH_SERVICE_BILLING.md for the full, trigger-
-- inclusive proof this introduces no reversal against 0144's own order:
--   3. loads (FOR UPDATE, ascending id) -- the SAME table/resource/order
--      0144's freight path already uses at its own position 3.
--   4. the applicable agreement version (FOR UPDATE) -- a brand-new
--      resource; nothing else in this schema locks it.
--   5. carriers (FOR UPDATE) -- the SAME table/resource 0144's freight
--      path locks (at its own position 5); loads is locked before
--      carriers in BOTH paths -- no reversal.
--   6. the dispatch organization's own `organizations` row (FOR SHARE)
--      -- a brand-new resource; nothing else in this schema locks it.
--   7. the related freight invoice + its snapshot (FOR SHARE, ascending
--      by freight invoice id), per covered load, percentage-of-freight
--      only -- a DIFFERENT carrier_invoices row than the one already
--      locked at position 2 (that RPC never locks two carrier_invoices
--      rows together, so no reversal is possible against it).
--   8. carrier_dispatch_service_billing_lines (INSERT only -- the
--      unique(load_id) constraint is the atomic anti-double-billing
--      check).
--   9. the number counter (atomic internally, no separate lock).
--   10. snapshot insert + invoice status transition(s) + audit +
--       idempotency (one savepoint-scoped block, mirroring 0144's own).
create function public._issue_dispatch_service_invoice_internal(
  p_invoice_id uuid,
  p_row public.carrier_invoices,
  p_uid uuid,
  p_org uuid,
  p_reason text,
  p_idempotency_key text,
  p_operation text,
  p_schema_version integer,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_load_ids uuid[];
  v_load_id uuid;
  v_load public.loads%rowtype;
  v_version_id uuid;
  v_version public.carrier_dispatch_service_agreement_versions%rowtype;
  v_carrier public.carriers%rowtype;
  v_remit public.carrier_remittance_profiles%rowtype;
  v_org_row public.organizations%rowtype;
  v_agreement_status public.dispatch_service_agreement_status;
  v_any_version_exists boolean;
  v_any_approved_exists boolean;
  v_freight_invoice_id uuid;
  v_freight_invoice_number text;
  v_freight_issued_at timestamptz;
  v_freight_snapshot jsonb;
  v_freight_amount numeric(12, 2);
  v_fee numeric(10, 2);
  v_subtotal numeric(12, 2) := 0;
  v_total numeric(12, 2);
  v_payment_terms integer;
  v_due_date date;
  v_number text;
  v_li_id uuid;
  v_billing_lines jsonb := '[]'::jsonb;
  v_line_no integer := 0;
  v_snapshot_payload jsonb;
  v_result jsonb;
  v_constraint text;
begin
  ------------------------------------------------------------------
  -- Loads (lock-order position 3): reuse the SAME "at least one source
  -- load, ascending id, FOR UPDATE" pattern 0144's freight path already
  -- established. Dispatch-service invoices need no load_stops/route
  -- validation at all (Section J never snapshots a route) -- so the
  -- load_stops parent-lock trigger (0144) never comes into play here.
  ------------------------------------------------------------------
  select array_agg(load_id) into v_load_ids from public.carrier_invoice_loads where invoice_id = p_invoice_id;
  if v_load_ids is null or array_length(v_load_ids, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'At least one covered load must be attached before issuance.');
  end if;

  for v_load_id in select unnest(v_load_ids) as id order by 1 loop
    perform 1 from public.loads where id = v_load_id for update;
  end loop;

  if exists (select 1 from public.loads where id = any(v_load_ids) and carrier_id is distinct from p_row.carrier_id) then
    return jsonb_build_object('success', false, 'code', 'LOAD_NOT_ELIGIBLE', 'message', 'One or more covered loads no longer belong to this invoice''s carrier.');
  end if;
  if exists (select 1 from public.loads where id = any(v_load_ids) and status not in ('delivered', 'pod_received', 'invoiced', 'closed')) then
    return jsonb_build_object('success', false, 'code', 'LOAD_NOT_ELIGIBLE', 'message', 'One or more covered loads are not yet delivered/completed.');
  end if;

  ------------------------------------------------------------------
  -- Phase 3B.4.1, Section A: acquire the SAME carrier-scoped effective-
  -- dates advisory lock every agreement-lifecycle RPC acquires, BEFORE
  -- looking up or locking any version row -- serializes this lookup
  -- against a concurrent approve/supersede/deactivate for this SAME
  -- carrier. Because this lock is held for this entire transaction, and
  -- every lifecycle RPC holds the IDENTICAL lock for its own entire
  -- transaction, whichever side gets here first fully completes (commit
  -- or rollback) before the other proceeds -- the version this call then
  -- reads is always a fully-resolved, never a torn, state.
  ------------------------------------------------------------------
  perform pg_advisory_xact_lock(public._carrier_dispatch_service_agreement_effective_dates_lock_key(p_org, p_row.carrier_id));

  ------------------------------------------------------------------
  -- Applicable agreement version (lock-order position 4): the SINGLE
  -- approved version for (carrier, TODAY) governs every covered load in
  -- THIS invoice (Section F's own suggested simplification, extended
  -- uniformly rather than per-load-service-date -- documented explicitly
  -- as a deliberate simplification, not an oversight; a future migration
  -- may revisit per-load service-date lookup if a real need arises).
  ------------------------------------------------------------------
  select v.id into v_version_id
  from public.carrier_dispatch_service_agreement_versions v
  join public.carrier_dispatch_service_agreements a on a.id = v.agreement_id
  where v.carrier_id = p_row.carrier_id and v.organization_id = p_org
    and a.status = 'active' and v.status = 'approved'
    and v.effective_from <= current_date and (v.effective_to is null or v.effective_to >= current_date)
  order by v.effective_from desc
  limit 1;

  if v_version_id is null then
    select exists (
      select 1 from public.carrier_dispatch_service_agreement_versions where carrier_id = p_row.carrier_id and organization_id = p_org
    ) into v_any_version_exists;
    if not v_any_version_exists then
      return jsonb_build_object('success', false, 'code', 'AGREEMENT_REQUIRED', 'message', 'This carrier has no dispatch-service agreement. Create and approve one before issuing.');
    end if;
    select exists (
      select 1 from public.carrier_dispatch_service_agreement_versions where carrier_id = p_row.carrier_id and organization_id = p_org and status = 'approved'
    ) into v_any_approved_exists;
    if not v_any_approved_exists then
      return jsonb_build_object('success', false, 'code', 'AGREEMENT_NOT_APPROVED', 'message', 'This carrier''s dispatch-service agreement has no approved version yet.');
    end if;
    return jsonb_build_object('success', false, 'code', 'AGREEMENT_NOT_EFFECTIVE', 'message', 'This carrier has an approved dispatch-service agreement version, but none is effective today.');
  end if;

  select * into v_version from public.carrier_dispatch_service_agreement_versions where id = v_version_id for update;

  -- Re-validate under lock -- a concurrent supersede/deactivate could
  -- have landed between the unlocked lookup above and this lock
  -- (STALE_AGREEMENT, never a silent stale read).
  if v_version.status <> 'approved'
    or v_version.effective_from > current_date
    or (v_version.effective_to is not null and v_version.effective_to < current_date)
  then
    return jsonb_build_object('success', false, 'code', 'STALE_AGREEMENT', 'message', 'The dispatch-service agreement version changed while this invoice was being issued. Reload and try again.');
  end if;
  if v_version.currency <> p_row.currency then
    return jsonb_build_object('success', false, 'code', 'AGREEMENT_CURRENCY_MISMATCH', 'message', 'The agreement version''s currency does not match this invoice''s currency.');
  end if;

  ------------------------------------------------------------------
  -- Carrier (lock-order position 5) -- SAME table/order as 0144's
  -- freight path (loads always locked before carriers, in both paths).
  -- Phase 3B.4.1, Section C: a carrier not found/wrong-org (CARRIER_
  -- MISMATCH, matching 0144's own established meaning) or inactive
  -- (CARRIER_INACTIVE -- a distinct, dispatch-service-specific code, for
  -- accurate UI behavior, rather than overloading CARRIER_MISMATCH the
  -- way 0144's freight path does) can never receive a NEW dispatch-
  -- service invoice. This FOR UPDATE lock is held for the rest of this
  -- transaction -- a concurrent deactivation of this SAME carrier row
  -- either fully precedes this check (seen here, rejected) or blocks
  -- until this transaction commits/rolls back (never interleaves).
  ------------------------------------------------------------------
  select * into v_carrier from public.carriers where id = p_row.carrier_id for update;
  if v_carrier.id is null or v_carrier.organization_id <> p_org then
    return jsonb_build_object('success', false, 'code', 'CARRIER_MISMATCH', 'message', 'The carrier on this invoice is not available.');
  end if;
  if not v_carrier.is_active then
    return jsonb_build_object('success', false, 'code', 'CARRIER_INACTIVE', 'message', 'This carrier is inactive and cannot receive new dispatch-service invoices.');
  end if;
  select * into v_remit from public.carrier_remittance_profiles where carrier_id = v_carrier.id for share;

  ------------------------------------------------------------------
  -- Dispatch organization identity (lock-order position 6) -- a brand-
  -- new resource; FOR SHARE is sufficient (read-only identity capture).
  --
  -- Phase 3B.4.1, Section G: organizations.remittance_instructions (the
  -- ONLY remittance/payment-instruction field 0145 itself introduced --
  -- see PHASE 2 -- and the sole field this snapshot's own 'issuer'
  -- block ever reads for remittance) is the single authoritative
  -- source. A dispatch-service invoice is a LEGAL demand for payment
  -- FROM the carrier TO this organization -- issuing one with an empty
  -- remittance_instructions would mean telling the carrier to pay an
  -- organization with no stated instructions for how, which this
  -- schema never fabricates a substitute for (no bank-account/routing
  -- data is ever added here -- only the free-text instructions field
  -- itself, exactly as the carrier's own remittance snapshot already
  -- works). Checked immediately after locking the row, before any
  -- per-load work or number allocation.
  ------------------------------------------------------------------
  select * into v_org_row from public.organizations where id = p_org for share;
  if v_org_row.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'The dispatch organization was not found.');
  end if;
  if v_org_row.remittance_instructions is null or btrim(v_org_row.remittance_instructions) = '' then
    return jsonb_build_object('success', false, 'code', 'DISPATCH_REMITTANCE_REQUIRED', 'message', 'This organization has no remittance/payment instructions on file yet. Add them before issuing a dispatch-service invoice.');
  end if;

  ------------------------------------------------------------------
  -- Per-load fee calculation (lock-order position 7 for the freight
  -- basis, percentage_of_freight only) + billing-ledger insert
  -- (position 8) + line item, one row per covered load, ascending id.
  ------------------------------------------------------------------
  for v_load_id in select unnest(v_load_ids) as id order by 1 loop
    select * into v_load from public.loads where id = v_load_id;

    if v_version.fee_method = 'percentage_of_freight' then
      select ci.id, ci.invoice_number, ci.issued_at into v_freight_invoice_id, v_freight_invoice_number, v_freight_issued_at
      from public.carrier_invoice_loads cil
      join public.carrier_invoices ci on ci.id = cil.invoice_id
      where cil.load_id = v_load_id
        and ci.invoice_document_type = 'carrier_freight_invoice'
        and ci.issuance_status = 'issued'
        and ci.carrier_id = p_row.carrier_id
      order by ci.issued_at desc
      limit 1;

      if v_freight_invoice_id is null then
        return jsonb_build_object('success', false, 'code', 'FREIGHT_INVOICE_REQUIRED', 'message', 'Load '||v_load.load_number||' has no issued carrier freight invoice yet -- required before a percentage-based dispatch-service fee can be calculated.', 'load_id', v_load_id);
      end if;

      -- FOR SHARE: the freight invoice is already issued/immutable, but
      -- still explicitly locked, matching this project's own established
      -- "lock even an already-immutable row before reading it into a NEW
      -- snapshot" convention (0144: NOA document, remittance profile).
      perform 1 from public.carrier_invoices where id = v_freight_invoice_id for share;
      if (select carrier_id from public.carrier_invoices where id = v_freight_invoice_id) is distinct from p_row.carrier_id then
        return jsonb_build_object('success', false, 'code', 'FREIGHT_INVOICE_CARRIER_MISMATCH', 'message', 'The related freight invoice no longer belongs to this dispatch-service invoice''s carrier.', 'load_id', v_load_id);
      end if;

      select snapshot_payload into v_freight_snapshot from public.carrier_invoice_issuance_snapshots where invoice_id = v_freight_invoice_id for share;
      select (elem ->> 'agreed_freight_charge')::numeric into v_freight_amount
      from jsonb_array_elements(coalesce(v_freight_snapshot -> 'loads', '[]'::jsonb)) elem
      where (elem ->> 'load_id')::uuid = v_load_id;

      if v_freight_amount is null or v_freight_amount <= 0 then
        return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'No authoritative freight amount was found for load '||v_load.load_number||' in the related freight invoice''s snapshot.', 'load_id', v_load_id);
      end if;

      v_fee := round(v_freight_amount * (v_version.percentage_rate / 100.0), 2);
    else -- flat_per_load
      v_freight_invoice_id := null;
      v_freight_invoice_number := null;
      v_freight_amount := null;
      v_fee := v_version.flat_fee_per_load;
    end if;

    if v_version.minimum_fee is not null and v_fee < v_version.minimum_fee then
      v_fee := v_version.minimum_fee;
    end if;
    if v_version.maximum_fee is not null and v_fee > v_version.maximum_fee then
      v_fee := v_version.maximum_fee;
    end if;
    if v_fee <= 0 then
      return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'The calculated dispatch-service fee for load '||v_load.load_number||' is not a positive amount.', 'load_id', v_load_id);
    end if;

    begin
      insert into public.carrier_dispatch_service_billing_lines
        (organization_id, invoice_id, carrier_id, agreement_version_id, load_id, source_freight_invoice_id,
         fee_method, authoritative_freight_amount, calculated_fee, currency)
      values
        (p_org, p_invoice_id, p_row.carrier_id, v_version_id, v_load_id, v_freight_invoice_id,
         v_version.fee_method, v_freight_amount, v_fee, v_version.currency);
    exception
      when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'carrier_dispatch_service_billing_lines_load_id_key' then
          raise;
        end if;
        return jsonb_build_object('success', false, 'code', 'LOAD_ALREADY_BILLED', 'message', 'Load '||v_load.load_number||' has already been billed for dispatch service.', 'load_id', v_load_id);
    end;

    insert into public.carrier_invoice_line_items
      (organization_id, invoice_id, line_type, source_load_id, description, quantity, unit_price)
    values
      (p_org, p_invoice_id, 'dispatch_service_fee', v_load_id,
       'Dispatch service fee -- Load '||v_load.load_number||
         case when v_version.fee_method = 'percentage_of_freight' then ' ('||v_version.percentage_rate||'% of '||v_freight_invoice_number||')' else ' (flat rate)' end,
       1, v_fee)
    returning id into v_li_id;

    v_line_no := v_line_no + 1;
    v_billing_lines := v_billing_lines || jsonb_build_object(
      'load_id', v_load_id, 'load_number', v_load.load_number,
      'fee_method', v_version.fee_method,
      'source_freight_invoice_id', v_freight_invoice_id, 'source_freight_invoice_number', v_freight_invoice_number,
      'authoritative_freight_amount', v_freight_amount, 'calculated_fee', v_fee
    );
    v_subtotal := v_subtotal + v_fee;
  end loop;

  -- Phase 3B.4.1, Section C: "revalidate immediately before snapshot
  -- construction" -- v_carrier has been locked FOR UPDATE since before
  -- this loop began, so nothing could actually have changed it since;
  -- this is a deliberate, defensive re-read of the row this transaction
  -- already holds (not a new lock, not a new resource), guarding against
  -- any future refactor that might reorder the carrier lock relative to
  -- this point without noticing the invariant it depends on.
  if not (select is_active from public.carriers where id = v_carrier.id) then
    return jsonb_build_object('success', false, 'code', 'CARRIER_INACTIVE', 'message', 'This carrier is inactive and cannot receive new dispatch-service invoices.');
  end if;

  v_total := v_subtotal + p_row.tax_amount + p_row.adjustments_amount;
  if v_total <= 0 then
    return jsonb_build_object('success', false, 'code', 'FEE_CALCULATION_INVALID', 'message', 'The invoice total must be greater than zero.');
  end if;

  v_payment_terms := coalesce(v_version.payment_terms_days, v_carrier.dispatch_service_terms_days, (select dispatch_service_terms_days from public.platform_settings limit 1));
  v_due_date := current_date + v_payment_terms;

  v_number := public._generate_carrier_invoice_number_internal('dispatch_service_invoice'::public.invoice_document_type, p_org,
    (select dispatch_invoice_prefix from public.platform_settings limit 1));

  ------------------------------------------------------------------
  -- Snapshot (Section J) -- dispatch organization identity/remittance,
  -- carrier recipient identity, agreement identity/terms, per-load
  -- billing detail. Never broker/customer, never any factoring
  -- identity/NOA/integration/secret_reference/carrier-factoring
  -- destination -- Section A/I's legal-separation requirement.
  ------------------------------------------------------------------
  v_snapshot_payload := jsonb_build_object(
    'schema_version', 1,
    'invoice_id', p_invoice_id,
    'invoice_document_type', 'dispatch_service_invoice',
    'invoice_number', v_number,
    'organization_id', p_org,
    'issued_at', now(),
    'issued_by', p_uid,
    'currency', v_version.currency,
    'payment_terms_days', v_payment_terms,
    'due_date', v_due_date,
    'subtotal_amount', v_subtotal,
    'tax_amount', p_row.tax_amount,
    'adjustments_amount', p_row.adjustments_amount,
    'total_amount', v_total,
    'issuer', jsonb_build_object(
      'organization_id', v_org_row.id, 'legal_name', v_org_row.name, 'dba_name', v_org_row.dba_name,
      'mc_number', v_org_row.mc_number, 'dot_number', v_org_row.dot_number,
      'address_line1', v_org_row.address_line1, 'address_line2', v_org_row.address_line2,
      'city', v_org_row.city, 'state', v_org_row.state, 'postal_code', v_org_row.postal_code, 'country', v_org_row.country,
      'phone', v_org_row.business_phone, 'email', v_org_row.business_email,
      'remittance_instructions', v_org_row.remittance_instructions
    ),
    'recipient', jsonb_build_object(
      'type', 'carrier', 'carrier_id', v_carrier.id, 'legal_name', v_carrier.legal_name, 'dba_name', v_carrier.dba_name,
      'mc_number', v_carrier.mc_number, 'dot_number', v_carrier.dot_number,
      'address_line1', v_carrier.address_line1, 'address_line2', v_carrier.address_line2,
      'city', v_carrier.city, 'state', v_carrier.state, 'postal_code', v_carrier.postal_code, 'country', v_carrier.country,
      'contact_name', v_carrier.contact_name, 'phone', v_carrier.phone, 'email', v_carrier.email,
      'remittance', case when v_remit.carrier_id is null then null else jsonb_build_object(
        'remittance_name', v_remit.remittance_name, 'remittance_email', v_remit.remittance_email,
        'remittance_instructions', v_remit.remittance_instructions
      ) end
    ),
    'agreement', jsonb_build_object(
      'agreement_id', v_version.agreement_id, 'version_id', v_version.id, 'version_number', v_version.version_number,
      'fee_method', v_version.fee_method, 'percentage_rate', v_version.percentage_rate, 'flat_fee_per_load', v_version.flat_fee_per_load,
      'minimum_fee', v_version.minimum_fee, 'maximum_fee', v_version.maximum_fee,
      'effective_from', v_version.effective_from, 'effective_to', v_version.effective_to,
      'approved_by', v_version.approved_by, 'approved_at', v_version.approved_at
    ),
    'billing_lines', v_billing_lines,
    'line_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', li.id, 'description', li.description, 'quantity', li.quantity,
        'unit_price', li.unit_price, 'amount', li.line_total, 'source_load_id', li.source_load_id
      ) order by li.sort_order, li.created_at), '[]'::jsonb)
      from public.carrier_invoice_line_items li where li.invoice_id = p_invoice_id and li.line_type = 'dispatch_service_fee'
    ),
    'factoring', null,
    'issuing_user_id', p_uid
  );

  if public.jsonb_contains_forbidden_key(
    v_snapshot_payload,
    array['secret_reference', 'api_key', 'access_token', 'refresh_token', 'password', 'client_secret', 'credential', 'credentials', 'private_key']
  ) then
    raise exception 'issue_carrier_invoice (dispatch-service): internal invariant violated -- the constructed snapshot payload contains a forbidden credential-shaped key. Aborting.' using errcode = '55000';
  end if;

  begin
    if p_row.issuance_status = 'draft' then
      update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = p_invoice_id;
    end if;

    insert into public.carrier_invoice_issuance_snapshots
      (invoice_id, organization_id, invoice_document_type, issued_by, currency, invoice_number,
       payment_terms_days, due_date, subtotal_amount, tax_amount, adjustments_amount, total_amount,
       amount_due_at_issuance, carrier_id, recipient_broker_id, recipient_customer_id, snapshot_payload)
    values
      (p_invoice_id, p_org, 'dispatch_service_invoice', p_uid, v_version.currency, v_number,
       v_payment_terms, v_due_date, v_subtotal, p_row.tax_amount, p_row.adjustments_amount, v_total,
       v_total, p_row.carrier_id, null, null, v_snapshot_payload);

    update public.carrier_invoices
      set issuance_status = 'issued', invoice_number = v_number, issued_at = now(), issued_by = p_uid,
          subtotal_amount = v_subtotal, total_amount = v_total, due_date = v_due_date, payment_terms_days = v_payment_terms,
          currency = v_version.currency
      where id = p_invoice_id;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'dispatch_service_invoice_issued',
      jsonb_build_object('invoice_number', v_number, 'total_amount', v_total, 'agreement_version_id', v_version.id, 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'ISSUED', 'invoice_id', p_invoice_id, 'invoice_number', v_number,
      'total_amount', v_total, 'issued_at', (select issued_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (p_org, p_idempotency_key, p_invoice_id, p_operation, p_fingerprint, p_schema_version, v_result, 'completed', p_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'civ_idempotency_unique' then
        raise;
      end if;
      select result into v_result from public.carrier_invoice_lifecycle_idempotency
      where organization_id = p_org and operation = p_operation and idempotency_key = p_idempotency_key;
      return v_result;
  end;

  return v_result;
end;
$fn$;

comment on function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text) is
  'Phase 3B.4: internal-only (EXECUTE revoked from every role) -- the entire dispatch-service-specific issuance body, called exclusively from issue_carrier_invoice()''s own STEP 10 after that function''s fully-shared STEPS 1-9 have already run. Never includes broker/customer/factoring identity; never alters a carrier_freight_invoice; never posts a settlement deduction; never trusts a client-supplied fee -- every fee is computed here, from locked, server-read sources only.';

revoke all on function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text) from public, anon, authenticated;

-- Redefine issue_carrier_invoice() itself: STEPS 1-9 UNCHANGED verbatim
-- from 0144 (re-typed here since CREATE OR REPLACE requires the whole
-- body); STEP 10 now dispatches to the function above instead of an
-- unconditional early return; the freight-invoice-specific STEPS 11
-- onward are otherwise BYTE-IDENTICAL to 0144's own body, with exactly
-- ONE substantive change: the loads_payload snapshot subquery's
-- 'agreed_freight_charge' now reads load_financials.rate (Section A's
-- critical finding), never loads.rate.
create or replace function public.issue_carrier_invoice(
  p_invoice_id uuid,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid;
  v_org uuid;
  v_operation constant text := 'issue_carrier_invoice';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_row public.carrier_invoices%rowtype;
  v_load_ids uuid[];
  v_load_id uuid;
  v_stop_id uuid;
  v_dispatch_ids uuid[];
  v_dispatch_id uuid;
  v_loads_payload jsonb;
  v_provisional_relationship_id uuid;
  v_relationship public.factoring_relationships%rowtype;
  v_carrier public.carriers%rowtype;
  v_company public.factoring_companies%rowtype;
  v_doc public.documents%rowtype;
  v_integration public.carrier_factoring_integrations%rowtype;
  v_classification jsonb;
  v_factoring_payload jsonb;
  v_remit public.carrier_remittance_profiles%rowtype;
  v_broker public.brokers%rowtype;
  v_customer public.customers%rowtype;
  v_party_status public.carrier_party_status;
  v_party_billing_email text;
  v_party_payment_terms integer;
  v_recipient_payload jsonb;
  v_problem text;
  v_li_id uuid;
  v_subtotal numeric(12, 2);
  v_total numeric(12, 2);
  v_payment_terms integer;
  v_due_date date;
  v_number text;
  v_snapshot_payload jsonb;
  v_result jsonb;
  v_constraint text;
begin
  ------------------------------------------------------------------
  -- STEP 1: authenticate + role.
  ------------------------------------------------------------------
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to issue invoices.');
  end if;

  ------------------------------------------------------------------
  -- STEP 2: derive organization.
  ------------------------------------------------------------------
  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  ------------------------------------------------------------------
  -- STEP 3: canonical SHA-256 fingerprint (0143 mechanism).
  ------------------------------------------------------------------
  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation,
      'schema_version', v_schema_version,
      'organization_id', v_org,
      'invoice_id', p_invoice_id,
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );

  ------------------------------------------------------------------
  -- STEP 4: organization+operation+idempotency-key advisory lock.
  ------------------------------------------------------------------
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  ------------------------------------------------------------------
  -- STEP 5: lock the carrier_invoices row.
  ------------------------------------------------------------------
  select * into v_row from public.carrier_invoices where id = p_invoice_id for update;

  ------------------------------------------------------------------
  -- STEP 6: revalidate organization / not-found.
  ------------------------------------------------------------------
  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  ------------------------------------------------------------------
  -- STEP 7: resolve idempotency replay/collision (operation-scoped).
  ------------------------------------------------------------------
  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_invoice_lifecycle_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_row.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This invoice has changed since you loaded it. Reload and try again.');
  end if;

  ------------------------------------------------------------------
  -- STEP 8: issuance_status must be draft or ready_for_issue.
  ------------------------------------------------------------------
  if v_row.issuance_status = 'issued' then
    return jsonb_build_object('success', false, 'code', 'ALREADY_ISSUED', 'message', 'This invoice has already been issued.', 'invoice_number', v_row.invoice_number);
  end if;
  if v_row.issuance_status not in ('draft', 'ready_for_issue') then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only a draft or ready-for-issue invoice can be issued.');
  end if;

  ------------------------------------------------------------------
  -- STEP 9: payment_status unpaid and amount_paid zero.
  ------------------------------------------------------------------
  if v_row.payment_status <> 'unpaid' or v_row.amount_paid <> 0 then
    return jsonb_build_object('success', false, 'code', 'PAYMENT_STATE_INVALID', 'message', 'This invoice has payment activity recorded and cannot be issued through this path.');
  end if;

  ------------------------------------------------------------------
  -- STEP 10 (Phase 3B.4 correction): dispatch_service_invoice now goes
  -- through the full atomic path (_issue_dispatch_service_invoice_
  -- internal) instead of an unconditional DISPATCH_SERVICE_AGREEMENT_
  -- REQUIRED early return -- structured AGREEMENT_REQUIRED/AGREEMENT_
  -- NOT_APPROVED/AGREEMENT_NOT_EFFECTIVE now distinguish exactly why, if
  -- issuance cannot proceed.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'dispatch_service_invoice' then
    return public._issue_dispatch_service_invoice_internal(
      p_invoice_id, v_row, v_uid, v_org, p_reason, p_idempotency_key, v_operation, v_schema_version, v_fingerprint
    );
  end if;

  ------------------------------------------------------------------
  -- STEP 11 (global lock-order position 3): lock every source load,
  -- ascending id, BEFORE any carrier/factoring lock.
  ------------------------------------------------------------------
  select array_agg(load_id) into v_load_ids from public.carrier_invoice_loads where invoice_id = p_invoice_id;
  if v_load_ids is null or array_length(v_load_ids, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'At least one source load must be attached before issuance.');
  end if;

  for v_load_id in select unnest(v_load_ids) as id order by 1 loop
    perform 1 from public.loads where id = v_load_id for update;
  end loop;

  if exists (select 1 from public.loads where id = any(v_load_ids) and carrier_id is distinct from v_row.carrier_id) then
    return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more attached loads no longer belong to this invoice''s carrier.');
  end if;

  ------------------------------------------------------------------
  -- STEP 11a (Phase 3B.3C.2, Section C): lock every load_stops row for
  -- the attached loads, in deterministic (load_id, stop_sequence, id)
  -- order, THEN reject missing/duplicate/malformed/ambiguous origin-
  -- destination structure -- only after every stop is locked, never
  -- from a provisional pre-lock read. A row lock alone cannot lock the
  -- ABSENCE of a row (a new stop being inserted mid-issuance) -- the
  -- Phase 3 guard trigger below (guard_load_stops_parent_lock) closes
  -- that gap structurally: every load_stops INSERT must itself lock the
  -- SAME parent loads row this RPC already holds (step 11), so a
  -- concurrent insert attempt blocks here until this transaction
  -- commits or rolls back -- never observed mid-issuance, never
  -- silently racing the snapshot.
  ------------------------------------------------------------------
  for v_stop_id in
    select id from public.load_stops
    where load_id = any(v_load_ids)
    order by load_id, stop_sequence, id
  loop
    perform 1 from public.load_stops where id = v_stop_id for update;
  end loop;

  -- Missing: every attached load must have at least one pickup AND at
  -- least one delivery stop.
  if exists (
    select 1 from public.loads l
    where l.id = any(v_load_ids)
      and (
        not exists (select 1 from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup')
        or not exists (select 1 from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery')
      )
  ) then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'One or more attached loads is missing a pickup or delivery stop.');
  end if;

  -- Duplicate/ambiguous: two stops on the SAME load sharing the
  -- identical stop_sequence value means "which one is actually first"
  -- is undefined -- never silently pick one via ORDER BY ... LIMIT 1.
  if exists (
    select 1 from public.load_stops ls
    where ls.load_id = any(v_load_ids)
    group by ls.load_id, ls.stop_sequence
    having count(*) > 1
  ) then
    return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more attached loads has ambiguous stop sequencing (duplicate stop_sequence values).');
  end if;

  -- Malformed: the resolved destination (latest-sequence delivery) must
  -- never sequence before the resolved origin (earliest-sequence
  -- pickup) -- a structurally inverted route.
  if exists (
    select 1 from public.loads l
    where l.id = any(v_load_ids)
      and (select max(ls.stop_sequence) from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery')
          < (select min(ls.stop_sequence) from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup')
  ) then
    return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more attached loads has a malformed route (a delivery stop sequenced before any pickup stop).');
  end if;

  ------------------------------------------------------------------
  -- STEP 11b (Phase 3B.3C.2, Section D): for every line item that
  -- references a source dispatch, lock that dispatch row (ascending
  -- id) and validate its load/carrier association under lock.
  ------------------------------------------------------------------
  select array_agg(distinct source_dispatch_id order by source_dispatch_id) into v_dispatch_ids
  from public.carrier_invoice_line_items
  where invoice_id = p_invoice_id and line_type = 'freight_charge' and source_dispatch_id is not null;

  if v_dispatch_ids is not null and array_length(v_dispatch_ids, 1) > 0 then
    for v_dispatch_id in select unnest(v_dispatch_ids) as id order by 1 loop
      perform 1 from public.dispatches where id = v_dispatch_id for share;
    end loop;
    if exists (
      select 1 from public.dispatches d
      where d.id = any(v_dispatch_ids)
        and (d.load_id <> all(v_load_ids) or d.carrier_id is distinct from v_row.carrier_id)
    ) then
      return jsonb_build_object('success', false, 'code', 'SOURCE_LOAD_CONFLICT', 'message', 'One or more line items reference a dispatch that no longer belongs to this invoice''s attached loads or carrier.');
    end if;
  end if;

  ------------------------------------------------------------------
  -- STEP 12: provisional (unlocked) relationship discovery, THEN lock
  -- factoring_relationships (position 4) BEFORE carriers (position 5).
  ------------------------------------------------------------------
  if v_carrier.factoring_mode is null then
    select factoring_mode into v_carrier.factoring_mode from public.carriers where id = v_row.carrier_id;
  end if;

  select r.id into v_provisional_relationship_id
  from public.factoring_relationships r
  where r.carrier_id = v_row.carrier_id and r.is_default and r.is_active
  limit 1;

  if v_provisional_relationship_id is not null then
    select * into v_relationship from public.factoring_relationships where id = v_provisional_relationship_id for update;
  end if;

  select * into v_carrier from public.carriers where id = v_row.carrier_id for update;

  if v_carrier.factoring_mode = 'factored' then
    if v_provisional_relationship_id is null then
      if exists (select 1 from public.factoring_relationships where carrier_id = v_carrier.id and is_default and is_active) then
        return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while this invoice was being issued. Reload and try again.');
      end if;
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier is factored but has no ready default factoring relationship.');
    end if;
    if v_relationship.carrier_id <> v_carrier.id or not v_relationship.is_default or not v_relationship.is_active then
      return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while this invoice was being issued. Reload and try again.');
    end if;
  elsif v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', false, 'code', 'FACTORING_POLICY_UNCONFIGURED', 'message', 'This carrier has no factoring policy configured yet (direct or factored).');
  end if;

  v_classification := public.carrier_invoice_factoring_readiness_problem(p_invoice_id);
  if v_carrier.factoring_mode = 'factored' and v_classification is not null then
    return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s factoring configuration is not ready for issuance.', 'reason', v_classification);
  end if;

  if v_carrier.factoring_mode = 'factored' then
    select * into v_company from public.factoring_companies where id = v_relationship.factoring_company_id for share;
    if v_relationship.noa_document_id is not null then
      select * into v_doc from public.documents where id = v_relationship.noa_document_id for share;
    end if;
    if v_relationship.submission_method = 'api' then
      select * into v_integration from public.carrier_factoring_integrations
        where factoring_relationship_id = v_relationship.id and is_active
        for share;
    end if;
    v_factoring_payload := jsonb_build_object(
      'factoring_mode', 'factored',
      'factoring_company_legal_name', v_company.legal_name,
      'factoring_relationship_id', v_relationship.id,
      'noa_approved', v_relationship.noa_approved,
      'submission_method', v_relationship.submission_method,
      'submission_destination',
        case v_relationship.submission_method
          when 'secure_email' then v_relationship.submission_destination_email
          when 'api' then null
          else null
        end
    );
  else
    v_factoring_payload := jsonb_build_object('factoring_mode', v_carrier.factoring_mode);
  end if;

  ------------------------------------------------------------------
  -- STEP 13a: carrier remittance profile (position 9, FOR SHARE).
  ------------------------------------------------------------------
  select * into v_remit from public.carrier_remittance_profiles where carrier_id = v_carrier.id for share;

  ------------------------------------------------------------------
  -- STEP 14: recipient (position 10) -- broker or customer, then the
  -- carrier-party row, both FOR UPDATE.
  ------------------------------------------------------------------
  if v_row.recipient_type = 'broker' then
    select * into v_broker from public.brokers where id = v_row.recipient_broker_id for update;
    select status, billing_email, payment_terms_days into v_party_status, v_party_billing_email, v_party_payment_terms
      from public.carrier_brokers where carrier_id = v_carrier.id and broker_id = v_row.recipient_broker_id
      for update;
  else
    select * into v_customer from public.customers where id = v_row.recipient_customer_id for update;
    select status, billing_email, payment_terms_days into v_party_status, v_party_billing_email, v_party_payment_terms
      from public.carrier_customers where carrier_id = v_carrier.id and customer_id = v_row.recipient_customer_id
      for update;
  end if;

  v_problem := public.carrier_invoice_recipient_problem(p_invoice_id);
  if v_problem is not null then
    return jsonb_build_object('success', false, 'code', 'RECIPIENT_INELIGIBLE', 'message', 'The recipient is not eligible for this invoice.', 'reason', v_problem);
  end if;

  ------------------------------------------------------------------
  -- STEP 16 (global lock-order position 11): lock every line item row,
  -- ascending id, THEN recalculate totals from the now-locked set.
  ------------------------------------------------------------------
  for v_li_id in
    select id from public.carrier_invoice_line_items
    where invoice_id = p_invoice_id and line_type = 'freight_charge'
    order by id
  loop
    perform 1 from public.carrier_invoice_line_items where id = v_li_id for update;
  end loop;

  select coalesce(sum(line_total), 0) into v_subtotal
  from public.carrier_invoice_line_items
  where invoice_id = p_invoice_id and line_type = 'freight_charge';

  v_total := v_subtotal + v_row.tax_amount + v_row.adjustments_amount;
  if v_total <= 0 then
    return jsonb_build_object('success', false, 'code', 'TOTAL_INVALID', 'message', 'The invoice total must be greater than zero.');
  end if;

  if v_row.currency !~ '^[A-Z]{3}$' then
    return jsonb_build_object('success', false, 'code', 'TOTAL_INVALID', 'message', 'The invoice currency is not valid.');
  end if;
  v_payment_terms := coalesce(v_row.payment_terms_days, v_party_payment_terms, 30);
  v_due_date := coalesce(v_row.due_date, current_date + v_payment_terms);

  ------------------------------------------------------------------
  -- STEP 17 (global lock-order position 12): allocate the correct
  -- private, per-(document_type,issuer,year) invoice number.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'carrier_freight_invoice' then
    v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice'::public.invoice_document_type, v_carrier.id, v_carrier.invoice_code);
  else
    -- Unreachable (STEP 10 already returned for dispatch_service_invoice).
    v_number := public._generate_carrier_invoice_number_internal(
      'dispatch_service_invoice'::public.invoice_document_type, v_org,
      (select dispatch_invoice_prefix from public.platform_settings limit 1));
  end if;

  ------------------------------------------------------------------
  -- Recipient identity + loads payloads, built from already-locked rows
  -- only. Phase 3B.4 correction: 'agreed_freight_charge' now reads
  -- load_financials.rate (the real, current post-0069 authoritative
  -- source), never loads.rate (dropped by 0069 in real production --
  -- Section A's critical finding).
  ------------------------------------------------------------------
  if v_row.recipient_type = 'broker' then
    v_recipient_payload := jsonb_build_object(
      'type', 'broker', 'broker_id', v_broker.id, 'legal_name', v_broker.company_name,
      'mc_number', v_broker.mc_number, 'contact_name', v_broker.contact_name,
      'phone', v_broker.phone, 'email', v_broker.email,
      'address_line1', v_broker.address_line1, 'address_line2', v_broker.address_line2,
      'city', v_broker.city, 'state', v_broker.state, 'postal_code', v_broker.postal_code, 'country', v_broker.country,
      'billing_email', v_party_billing_email
    );
  else
    v_recipient_payload := jsonb_build_object(
      'type', 'customer', 'customer_id', v_customer.id, 'legal_name', v_customer.company_name,
      'contact_name', v_customer.contact_name, 'phone', v_customer.phone, 'email', v_customer.email,
      'address_line1', v_customer.billing_address_line1, 'address_line2', v_customer.billing_address_line2,
      'city', v_customer.city, 'state', v_customer.state, 'postal_code', v_customer.postal_code, 'country', v_customer.country,
      'billing_email', v_party_billing_email
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'load_id', l.id, 'load_number', l.load_number, 'agreed_freight_charge', lf.rate,
      'origin', (
        select jsonb_build_object('facility_name', ls.facility_name, 'city', ls.city, 'state', ls.state, 'scheduled_at', ls.scheduled_at, 'arrived_at', ls.arrived_at)
        from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'pickup' order by ls.stop_sequence asc limit 1
      ),
      'destination', (
        select jsonb_build_object('facility_name', ls.facility_name, 'city', ls.city, 'state', ls.state, 'scheduled_at', ls.scheduled_at, 'arrived_at', ls.arrived_at)
        from public.load_stops ls where ls.load_id = l.id and ls.stop_type = 'delivery' order by ls.stop_sequence desc limit 1
      )
    ) order by l.load_number), '[]'::jsonb)
    into v_loads_payload
  from public.loads l
  left join public.load_financials lf on lf.load_id = l.id
  where l.id = any(v_load_ids);

  ------------------------------------------------------------------
  -- Build the complete server-generated immutable snapshot payload.
  ------------------------------------------------------------------
  v_snapshot_payload := jsonb_build_object(
    'schema_version', 1,
    'invoice_id', p_invoice_id,
    'invoice_document_type', v_row.invoice_document_type,
    'invoice_number', v_number,
    'organization_id', v_org,
    'issued_at', now(),
    'issued_by', v_uid,
    'currency', v_row.currency,
    'payment_terms_days', v_payment_terms,
    'due_date', v_due_date,
    'subtotal_amount', v_subtotal,
    'tax_amount', v_row.tax_amount,
    'adjustments_amount', v_row.adjustments_amount,
    'total_amount', v_total,
    'line_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', li.id, 'description', li.description, 'quantity', li.quantity,
        'unit_price', li.unit_price, 'amount', li.line_total,
        'source_load_id', li.source_load_id, 'source_dispatch_id', li.source_dispatch_id
      ) order by li.sort_order, li.created_at), '[]'::jsonb)
      from public.carrier_invoice_line_items li where li.invoice_id = p_invoice_id and li.line_type = 'freight_charge'
    ),
    'issuer', jsonb_build_object(
      'carrier_id', v_carrier.id, 'legal_name', v_carrier.legal_name, 'dba_name', v_carrier.dba_name,
      'mc_number', v_carrier.mc_number, 'dot_number', v_carrier.dot_number,
      'address_line1', v_carrier.address_line1, 'address_line2', v_carrier.address_line2,
      'city', v_carrier.city, 'state', v_carrier.state, 'postal_code', v_carrier.postal_code, 'country', v_carrier.country,
      'contact_name', v_carrier.contact_name, 'phone', v_carrier.phone, 'email', v_carrier.email,
      'remittance', case when v_remit.carrier_id is null then null else jsonb_build_object(
        'remittance_name', v_remit.remittance_name, 'remittance_address_line1', v_remit.remittance_address_line1,
        'remittance_address_line2', v_remit.remittance_address_line2, 'remittance_city', v_remit.remittance_city,
        'remittance_state', v_remit.remittance_state, 'remittance_postal_code', v_remit.remittance_postal_code,
        'remittance_country', v_remit.remittance_country, 'remittance_email', v_remit.remittance_email,
        'remittance_instructions', v_remit.remittance_instructions
      ) end
    ),
    'recipient', v_recipient_payload,
    'loads', v_loads_payload,
    'factoring', v_factoring_payload,
    'dispatch_service', null,
    'issuing_user_id', v_uid
  );

  if public.jsonb_contains_forbidden_key(
    v_snapshot_payload,
    array['secret_reference', 'api_key', 'access_token', 'refresh_token', 'password', 'client_secret', 'credential', 'credentials', 'private_key']
  ) then
    raise exception 'issue_carrier_invoice: internal invariant violated -- the constructed snapshot payload contains a forbidden credential-shaped key. Aborting.' using errcode = '55000';
  end if;

  ------------------------------------------------------------------
  -- Apply phase: insert exactly one snapshot; set invoice_number/
  -- issued_at/issued_by/issuance_status='issued'/totals/due_date; write
  -- exactly one audit event; store the idempotency result -- all in ONE
  -- savepoint-scoped block.
  ------------------------------------------------------------------
  begin
    if v_row.issuance_status = 'draft' then
      update public.carrier_invoices set issuance_status = 'ready_for_issue' where id = p_invoice_id;
    end if;

    insert into public.carrier_invoice_issuance_snapshots
      (invoice_id, organization_id, invoice_document_type, issued_by, currency, invoice_number,
       payment_terms_days, due_date, subtotal_amount, tax_amount, adjustments_amount, total_amount,
       amount_due_at_issuance, carrier_id, recipient_broker_id, recipient_customer_id, snapshot_payload)
    values
      (p_invoice_id, v_org, v_row.invoice_document_type, v_uid, v_row.currency, v_number,
       v_payment_terms, v_due_date, v_subtotal, v_row.tax_amount, v_row.adjustments_amount, v_total,
       v_total, v_carrier.id, v_row.recipient_broker_id, v_row.recipient_customer_id, v_snapshot_payload);

    update public.carrier_invoices
      set issuance_status = 'issued', invoice_number = v_number, issued_at = now(), issued_by = v_uid,
          subtotal_amount = v_subtotal, total_amount = v_total, due_date = v_due_date, payment_terms_days = v_payment_terms
      where id = p_invoice_id;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_issued',
      jsonb_build_object('invoice_number', v_number, 'total_amount', v_total, 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'ISSUED', 'invoice_id', p_invoice_id, 'invoice_number', v_number,
      'total_amount', v_total, 'issued_at', (select issued_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, p_invoice_id, v_operation, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint <> 'civ_idempotency_unique' then
        raise;
      end if;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_invoice_lifecycle_idempotency
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

revoke all on function public.issue_carrier_invoice(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.issue_carrier_invoice(uuid, timestamptz, text, text) to authenticated;

comment on function public.issue_carrier_invoice(uuid, timestamptz, text, text) is
  'Phase 3B.4: STEPS 1-9 (auth/org/fingerprint/advisory-lock/invoice-lock/idempotency/status) are fully shared across both invoice_document_type values. carrier_freight_invoice issuance is unchanged in every respect except one correction: the loads-payload snapshot now reads agreed_freight_charge from load_financials.rate (the real, current post-0069 authoritative source) instead of the nonexistent-in-production loads.rate 0144 mistakenly read. dispatch_service_invoice issuance now dispatches to _issue_dispatch_service_invoice_internal() for its own full atomic lock order (loads -> agreement version -> carriers -> dispatch organization -> related freight invoice/snapshot where percentage-based -> billing ledger -> number -> snapshot+status+audit+idempotency) instead of an unconditional DISPATCH_SERVICE_AGREEMENT_REQUIRED early return. Never includes broker/customer or any carrier factoring identity in a dispatch-service snapshot; never alters a carrier_freight_invoice; never posts a settlement deduction; never trusts a client-supplied fee.';

-- ======================= PHASE 8 -- POSTCONDITIONS ==========================
do $mig$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='remittance_instructions') then
    raise exception '0145 postcondition: organizations.remittance_instructions missing.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreements') is null then
    raise exception '0145 postcondition: carrier_dispatch_service_agreements missing.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreement_versions') is null then
    raise exception '0145 postcondition: carrier_dispatch_service_agreement_versions missing.';
  end if;
  if to_regclass('public.carrier_dispatch_service_billing_lines') is null then
    raise exception '0145 postcondition: carrier_dispatch_service_billing_lines missing.';
  end if;
  if to_regclass('public.carrier_dispatch_service_agreement_idempotency') is null then
    raise exception '0145 postcondition: carrier_dispatch_service_agreement_idempotency missing.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_dispatch_service_agreement_versions' and c.conname = 'cdsav_no_overlap_when_approved' and c.contype = 'x'
  ) then
    raise exception '0145 postcondition: cdsav_no_overlap_when_approved exclusion constraint missing.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_dispatch_service_billing_lines' and c.contype = 'u' and c.conkey = (
      select array_agg(a.attnum) from pg_attribute a where a.attrelid = t.oid and a.attname = 'load_id'
    )
  ) then
    raise exception '0145 postcondition: carrier_dispatch_service_billing_lines has no unique(load_id) constraint.';
  end if;
  if to_regprocedure('public.create_carrier_dispatch_service_agreement(uuid,text,text,text)') is null then
    raise exception '0145 postcondition: create_carrier_dispatch_service_agreement missing.';
  end if;
  if to_regprocedure('public.create_carrier_dispatch_service_agreement_version(uuid,public.dispatch_service_fee_method,numeric,numeric,numeric,numeric,text,integer,date,date,text,text)') is null then
    raise exception '0145 postcondition: create_carrier_dispatch_service_agreement_version missing.';
  end if;
  if to_regprocedure('public.approve_carrier_dispatch_service_agreement_version(uuid,timestamptz,text,text,uuid)') is null then
    raise exception '0145 postcondition: approve_carrier_dispatch_service_agreement_version missing.';
  end if;
  if to_regprocedure('public.deactivate_carrier_dispatch_service_agreement_version(uuid,timestamptz,text,text)') is null then
    raise exception '0145 postcondition: deactivate_carrier_dispatch_service_agreement_version missing.';
  end if;
  if to_regprocedure('public.deactivate_carrier_dispatch_service_agreement(uuid,timestamptz,text,text)') is null then
    raise exception '0145 postcondition: deactivate_carrier_dispatch_service_agreement missing.';
  end if;
  if to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is null then
    raise exception '0145 postcondition: _issue_dispatch_service_invoice_internal missing.';
  end if;
  if has_function_privilege('authenticated', 'public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)', 'EXECUTE') then
    raise exception '0145 postcondition: authenticated should not be able to EXECUTE the internal dispatch-service issuance helper directly.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%DISPATCH_SERVICE_AGREEMENT_REQUIRED%' then
    raise exception '0145 postcondition: issue_carrier_invoice() still contains the retired DISPATCH_SERVICE_AGREEMENT_REQUIRED placeholder.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%l.rate%' then
    raise exception '0145 postcondition: issue_carrier_invoice() still reads l.rate (loads.rate) directly -- the real production bug this migration must fix.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%lf.rate%' then
    raise exception '0145 postcondition: issue_carrier_invoice() does not read load_financials.rate (lf.rate) for agreed_freight_charge.';
  end if;
  -- The internal function's own snapshot INSERT must pass the snapshots
  -- table's required recipient_broker_id/recipient_customer_id columns
  -- as LITERAL NULL, never a carrier-supplied or client-supplied value
  -- (a dispatch-service invoice''s recipient is always the carrier
  -- itself, via carrier_id, never a broker/customer).
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%null, null, v_snapshot_payload%' then
    raise exception '0145 postcondition: the dispatch-service internal function does not pass literal NULL recipient_broker_id/recipient_customer_id to the snapshot insert.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) ilike '%factoring_relationship%' then
    raise exception '0145 postcondition: the dispatch-service internal function appears to reference a factoring relationship.';
  end if;

  -- Phase 3B.4.1 postconditions.
  if to_regprocedure('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)') is null then
    raise exception '0145.1 postcondition: _carrier_dispatch_service_agreement_effective_dates_lock_key missing.';
  end if;
  if has_function_privilege('authenticated', 'public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)', 'EXECUTE') then
    raise exception '0145.1 postcondition: authenticated should not be able to EXECUTE the internal lock-key helper directly.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_dispatch_service_agreement_versions' and c.conname = 'cdsav_agreement_version_number_unique' and c.contype = 'u'
  ) then
    raise exception '0145.1 postcondition: cdsav_agreement_version_number_unique constraint missing.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_dispatch_service_agreements' and c.conname = 'cdsa_org_carrier_agreement_number_unique' and c.contype = 'u'
  ) then
    raise exception '0145.1 postcondition: cdsa_org_carrier_agreement_number_unique constraint missing.';
  end if;
  if (select prosrc from pg_proc where proname = 'approve_carrier_dispatch_service_agreement_version' and pronamespace = 'public'::regnamespace) not ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%' then
    raise exception '0145.1 postcondition: approve_carrier_dispatch_service_agreement_version does not acquire the carrier-scoped effective-dates lock.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%_carrier_dispatch_service_agreement_effective_dates_lock_key%' then
    raise exception '0145.1 postcondition: _issue_dispatch_service_invoice_internal does not acquire the carrier-scoped effective-dates lock.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%CARRIER_INACTIVE%' then
    raise exception '0145.1 postcondition: _issue_dispatch_service_invoice_internal does not return CARRIER_INACTIVE.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%DISPATCH_REMITTANCE_REQUIRED%' then
    raise exception '0145.1 postcondition: _issue_dispatch_service_invoice_internal does not return DISPATCH_REMITTANCE_REQUIRED.';
  end if;

  raise notice '0145 complete: organizations.remittance_instructions added; carrier_dispatch_service_agreements + carrier_dispatch_service_agreement_versions (draft/approved/superseded/inactive, percentage_of_freight/flat_per_load, cdsav_no_overlap_when_approved exclusion constraint) + carrier_dispatch_service_billing_lines (unique(load_id) anti-double-billing ledger) installed; create/create_version/approve(+supersede)/deactivate(version+agreement) RPCs installed (owner/admin, +accountant for draft proposals); issue_carrier_invoice() STEP 10 now atomically issues dispatch_service_invoice via _issue_dispatch_service_invoice_internal() (never broker/customer/factoring identity, never alters a carrier_freight_invoice, never posts a settlement deduction, never trusts a client fee) instead of the retired DISPATCH_SERVICE_AGREEMENT_REQUIRED placeholder; the real 0144 loads.rate-vs-load_financials.rate defect is corrected in the SAME CREATE OR REPLACE. Phase 3B.4.1: a carrier-scoped (organization_id, carrier_id) advisory lock now serializes every agreement-lifecycle operation and dispatch-service issuance BEFORE any overlap-sensitive row lock/insert/update, structurally eliminating the 40P01 exclusion-constraint deadlock class (GiST exclusion constraint kept as a pure backstop); CARRIER_INACTIVE and DISPATCH_REMITTANCE_REQUIRED added; a used agreement version can never rebill a load under a new version (unique(load_id), documented duplicate-billing correction policy). No payment collection. No settlement deduction posting. No email/WhatsApp/PDF/factoring-transmission/portal/QuickBooks logic added. Migrations 0001-0144 untouched.';
end
$mig$;

commit;
