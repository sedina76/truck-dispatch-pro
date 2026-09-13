-- =============================================================================
-- 0142_immutable_carrier_invoice_foundation.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0001-0141 live. Phase 3B.3A.
--
-- BUSINESS MODEL THIS SCHEMA ENCODES:
--   1. One dispatch organization oversees multiple carriers.
--   2. Each freight invoice belongs to exactly one carrier.
--   3. The carrier invoices its own broker or customer.
--   4. Factoring selection comes only from that carrier's OWN factoring
--      policy (carriers.factoring_mode) and carrier-specific default
--      relationship (factoring_relationships, 0136-0138) -- never an
--      organization-wide default.
--   5. The dispatch company separately invoices the carrier for dispatch
--      services -- a completely different legal issuer/recipient pair.
--   6. Dispatch fees are NEVER mixed into or deducted from the carrier's
--      freight invoice to its broker/customer -- they live on their own,
--      separate dispatch_service_invoice document.
--   7. External delivery (email/WhatsApp/factoring API/portal) is
--      explicitly NOT part of this migration.
--
-- WHAT THIS MIGRATION DOES (foundation only -- see "ISSUANCE RPC" below):
--   A. THREE independent state dimensions, never one overloaded column
--      (Phase 3B.3A.1 correction -- the original draft mixed payment
--      states into the issuance enum, found and corrected before this
--      migration was ever applied):
--        i.   invoice_document_type (carrier_freight_invoice /
--             dispatch_service_invoice) -- WHO issued/receives it.
--        ii.  invoice_issuance_status (draft / ready_for_issue / issued /
--             voided) -- WHETHER the invoice legally exists yet. Terminal:
--             voided. There is no 'disputed' issuance state -- whole-
--             invoice dispute handling has no defined transition
--             semantics yet (does a dispute freeze payment? block
--             factoring submission? require a resolution workflow?) and
--             is explicitly DEFERRED to a future dispute-tracking table/
--             migration rather than bolted onto issuance prematurely.
--        iii. invoice_payment_status (unpaid / partially_paid / paid) --
--             HOW MUCH has been collected. Structurally tied to
--             amount_paid/total_amount (cinv_payment_status_consistency)
--             and to invoice_issuance_status (cinv_payment_requires_issued:
--             draft/ready_for_issue MUST be unpaid; only issued/voided may
--             be partially_paid/paid -- Section A's required invariant).
--      Factoring status is NOT stored on carrier_invoices at all (Section
--      H's read-only problem functions read the EXISTING factoring tables
--      live -- 0136-0141 -- never a cached/duplicated status column here).
--      Delivery status (email/WhatsApp/API/portal) is not modeled
--      anywhere in this migration -- there is nothing to deliver yet.
--   B. public.carrier_invoices -- a NEW table, entirely additive,
--      independent of the legacy public.invoices/invoice_line_items/
--      payments/factored_invoices tables (Section A found those tables
--      structurally single-carrier: no carrier_id column at all, invoice
--      numbering global-per-org via generate_invoice_number(), and deeply
--      wired into QuickBooks sync, AR/collections/statements reporting,
--      and PDF/email code that all assume "the dispatch org bills a
--      broker/customer directly". Retrofitting carrier_id and a second
--      issuer/recipient shape onto that table would either destructively
--      reinterpret 8+ years of live query/report assumptions or require
--      every one of those call sites to branch on a new column they don't
--      expect. A new, additive table is the only choice consistent with
--      "do not destructively reinterpret existing invoice rows" and
--      "existing invoices remain legacy... until explicitly reviewed and
--      reissued" -- see Section J below and this migration's own report.)
--   C. public.carrier_invoice_line_items -- mutable pre-issuance charges,
--      mirrors the legacy invoice_line_items shape.
--   D. public.carrier_invoice_loads -- join table validating which loads
--      back a carrier_freight_invoice (Section L step 8's future subject).
--   E. public.carrier_invoice_number_counters + a private, mechanism-only
--      atomic counter function -- generalizes the PROVEN
--      invoice_number_counters / generate_invoice_number() pattern
--      (0065/0129: INSERT...ON CONFLICT DO UPDATE...RETURNING, one
--      statement, Postgres-serialized) to a polymorphic issuer scope
--      (carrier_id for freight invoices, organization_id for
--      dispatch-service invoices), per-calendar-year, exactly as directed
--      by Section G.
--   F. public.carrier_invoice_issuance_snapshots -- the immutable,
--      one-to-one, issuance-time financial/identity snapshot (Section D).
--   G. public.carrier_invoice_lifecycle_idempotency -- mirrors 0141's
--      factoring_integration_lifecycle_idempotency shape exactly, ready
--      for the 0143 issuance RPC to use for idempotent retry (Section G).
--   H. Guard triggers enforcing immutability (Section E), the lifecycle
--      state machine (Section F), and role-scoped field protection
--      (Section K) -- all BEFORE-ROW triggers, which fire for EVERY role
--      including service_role/superuser (RLS bypass never bypasses a
--      trigger), so "service-role use alone must not bypass immutable
--      financial controls" holds structurally, not just by convention.
--   I. Three read-only "problem" functions (mirroring 0141's
--      factoring_relationship_lifecycle_problem() /
--      factoring_integration_lifecycle_problem() convention exactly):
--      carrier_invoice_recipient_problem(), which also independently
--      re-derives eligibility (matching classify_carrier_factoring_
--      readiness()'s own party-gate reasoning: carrier_brokers/
--      carrier_customers.factoring_eligible / .factoring_ineligible_
--      direct_billing_approved) rather than merely re-reading a stored
--      classification -- carrier_invoice_factoring_readiness_problem(),
--      and carrier_invoice_issuance_problem() (aggregates both, plus
--      totals/loads/carrier-numbering-readiness checks). These give
--      Section H/I real, independently testable DB-level backing today,
--      without performing issuance.
--   J. A read-only legacy-invoice classifier (Section J): classify_
--      legacy_invoice_for_carrier_migration(uuid) returns text, plus
--      public.legacy_invoice_carrier_migration_review (an unresolved-
--      record-style audit table, matching this schema's own established
--      convention: unresolved_carrier_records, 0133) and a callable (NOT
--      auto-run) scan_legacy_invoices_for_carrier_migration() SECURITY
--      DEFINER procedure a human explicitly invokes -- this migration
--      itself writes ZERO rows into that review table and reads/mutates
--      ZERO existing public.invoices rows. Existing invoices remain
--      entirely legacy and untouched. review/reviewed_by/reviewed_at are
--      NOT directly client-writable at all (Phase 3B.3A.1 correction --
--      the original draft granted authenticated a column-level UPDATE on
--      those three columns directly, which permits audit identity/time
--      forgery). The ONLY mutation path is the new owner/admin-only
--      review_legacy_invoice_carrier_migration() RPC, which derives
--      reviewed_by from auth.uid() and reviewed_at from the database
--      clock, enforces optimistic concurrency + idempotency, rejects
--      cross-organization access, and writes one audit event via the
--      existing log_activity() convention.
--   K. Column-level privilege model on carrier_invoices (Phase 3B.3A.1,
--      tightened further in Phase 3B.3A.2 -- Section A of that phase's
--      task): the blanket `alter default privileges ... grant ... to
--      authenticated` UPDATE grant (0010/TEST_SUPPORT) is explicitly
--      REVOKED on this table, and ONLY `notes` is re-granted -- the single
--      column every authenticated org member (including dispatcher) may
--      set via a direct client UPDATE. Every other column -- including
--      any added by a FUTURE migration -- defaults to NO client UPDATE
--      grant at all, structurally, not because a trigger's denylist
--      happened to mention it. due_date/payment_terms_days/broker_id/
--      customer_id/currency changes now go ONLY through the new
--      update_carrier_invoice_draft() RPC (item L below); issuance_status/
--      voided_at/voided_by/void_reason/payment fields have NO write path
--      anywhere yet, direct or via RPC -- deferred to 0143 (Section C/D).
--   L. public.update_carrier_invoice_draft(uuid, jsonb, timestamptz, text,
--      text) -- Phase 3B.3A.2 Section B, closed in Phase 3B.3A.3 Section
--      A/B: a guarded, role-tiered RPC using a strict-allowlist jsonb
--      PATCH object (presence of a key = set it, including to null;
--      absence = leave unchanged) for due_date/payment_terms_days/
--      broker_id/customer_id/currency/notes. Owner/admin get the full
--      field set; accountant gets billing fields (due_date/payment_
--      terms_days/currency) + notes; dispatcher gets notes only; driver/
--      viewer are refused immediately. Revalidates recipient eligibility
--      (active status, genuine carrier-party relationship) before
--      writing, never after. Lock order: derive organization -> acquire
--      a pg_advisory_xact_lock scoped to (organization, 'update_draft',
--      idempotency_key) -> lock the invoice row -> revalidate -> resolve
--      idempotency -> validate -> mutate+audit+idempotency-insert as one
--      savepoint-scoped atomic block. This closes the one gap the prior
--      phase's invoice-row-only locking left open: two truly concurrent
--      calls sharing the SAME idempotency key but targeting DIFFERENT
--      invoices are now fully serialized before either can touch the
--      idempotency table, so a same-key/different-invoice collision can
--      never leak a raw uniqueness error -- it always returns a
--      structured IDEMPOTENCY_KEY_REUSED, with the mutation/audit event
--      either never attempted or (in the vanishingly rare defense-in-
--      depth branch) fully rolled back together as one unit. The request
--      fingerprint covers invoice id + patch + reason + expected_
--      updated_at (deterministic, canonical via jsonb's own key-order
--      normalization, no randomness, never client-supplied). Optimistic
--      concurrency (STALE_RECORD); exactly one audit event per successful
--      call, zero for a collision. Never touches carrier_id/invoice_
--      document_type/issuance_status/payment_status/invoice_number/
--      totals/snapshot identity -- those remain entirely outside this
--      RPC's allowlist, not merely unused by it.
--
-- ISSUANCE RPC -- DEFERRED TO 0143, NOT IMPLEMENTED HERE (Section L):
--   The 18-step atomic issuance RPC Section L describes must authenticate,
--   lock the invoice, resolve document type/issuer/carrier/recipient,
--   validate load ownership, recalculate totals, validate factoring
--   readiness, LOCK the default factoring relationship + carrier +
--   factoring company + NOA document (mirroring activate_carrier_
--   factoring_integration()'s own proven fixed lock order, 0141) atomically
--   with number allocation and snapshot insertion, transition the invoice,
--   write one audit event, and record an idempotency result -- as ONE
--   correct, fully-tested transaction. Attempting to also design, implement,
--   AND prove that correct under the full concurrency matrix (Section M)
--   in this same migration, on top of a brand-new schema with no existing
--   issuance behavior to reference, is exactly the "partially safe
--   issuance function" this phase is explicitly told not to build. This
--   migration instead builds every piece that RPC will need (numbering
--   mechanism, snapshot table + immutability, lifecycle guard, problem
--   functions, idempotency table) so 0143 is additive on top of a proven
--   foundation, not a redesign. See this phase's final report for the
--   exact proposed 0143 RPC shape.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not touch public.invoices / invoice_line_items / payments /
--     factored_invoices / factoring_events in any way -- no ALTER, no
--     data migration, no FK from the new tables back to the old ones
--   * does not implement the issuance RPC (see above -- 0143)
--   * does not implement a draft -> ready_for_issue RPC, a void RPC, or
--     any credit/debit adjustment RPC (Phase 3B.3A.2 Section C/D,
--     explicitly deferred): 'ready_for_issue' and 'voided' are reserved
--     issuance_status values with void_at/void_by/void_reason columns
--     reserved alongside them, but issuance_status/voided_at/voided_by/
--     void_reason have ZERO column grant for any role -- no authenticated
--     session, including owner/admin, can reach 'ready_for_issue',
--     'issued', or 'voided' via a direct UPDATE, and no RPC reaches them
--     either yet. 0143 will own: prepare/validate for issuance; the
--     ready_for_issue transition; atomic issuance; voiding; and
--     idempotent retries for all of the above. Final intended void
--     authority (for 0143 to implement, not this migration): owner/admin
--     may void through that future guarded RPC; accountant cannot void
--     unless separately approved later; dispatcher/driver/viewer can
--     never void.
--   * does not implement a payment-recording RPC or any FK from a payment
--     table to carrier_invoices -- amount_paid/payment_status exist and
--     are kept mathematically consistent by CHECK constraints (Section B),
--     but there is NO write path to them at all yet for any role (no
--     column grant, no RPC) -- see this migration's own header for the
--     full payment-architecture findings and the proposed future slice
--   * does not add a whole-invoice dispute table/status -- deferred until
--     its transition semantics are actually designed
--   * does not add email, WhatsApp, factoring API, or portal delivery
--   * does not add QuickBooks synchronization for the new invoice types
--   * does not generate or transmit a real invoice PDF
--   * does not backfill or reinterpret any existing invoices row
--   * does not modify migrations 0001-0141
--   * does not use service_role for any ordinary authenticated financial
--     action (RLS + SECURITY DEFINER helper functions only, exactly like
--     0136-0141)
--
-- PAYMENT ARCHITECTURE FINDINGS (Section B, inspected before finalizing
-- the columns below):
--   * Legacy payments reference invoices via a plain FK
--     (public.payments.invoice_id -> public.invoices.id, 0006) -- a
--     separate row per payment, summed by apply_payment_to_invoice()
--     (0009/0026) into invoices.amount_paid; balance_due is a GENERATED
--     column (total_amount - amount_paid), never a second stored source
--     of truth.
--   * No payment table can reference carrier_invoices yet -- there is no
--     FK, no rollup trigger, and this migration adds neither. A future
--     migration (0143 or later, NOT this one) would most likely add a
--     carrier_invoice_payments table mirroring payments' own shape
--     (amount/method/status/void_reason/voided_by/voided_at) plus its own
--     apply_payment_to_carrier_invoice() rollup trigger -- the exact
--     proven pattern, not a new design.
--   * amount_paid on the legacy invoices table is TRIGGER-MAINTAINED (a
--     rollup of posted payments), never a value a client sets directly.
--     Partial payments exist (posted, summed). Reversals exist (a payment
--     is voided -- status='voided', void_reason required, NEVER deleted --
--     payments.status/voided_by/voided_at/void_reason, 0026). There is NO
--     refund table, NO credit-balance concept, and NO written-off state
--     anywhere in this schema -- guard_payment_amount() (0026) explicitly
--     BLOCKS any payment that would overpay an invoice's balance_due,
--     "since no credits/unapplied-cash table exists anywhere in this
--     schema" (0026's own comment). This migration follows that same
--     precedent: cinv_payment_status_consistency below makes overpayment
--     structurally impossible (amount_paid can never exceed total_amount),
--     and written_off is deliberately NOT added without explicit approval.
--   * carrier_invoices.amount_paid/payment_status/balance_due are kept in
--     this migration (Section B permits this "only if database
--     constraints keep them mathematically consistent") specifically
--     because they ARE fully constrained (cinv_payment_status_consistency
--     + cinv_payment_requires_issued) -- but with zero write path (no
--     grant, no RPC) until the payment-FK/integration slice above lands.
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regclass('public.carrier_invoices') is not null then
    raise exception '0142 precondition: public.carrier_invoices already exists -- 0142 partially applied? STOP.';
  end if;
  if to_regprocedure('public.factoring_integration_lifecycle_problem(uuid)') is null then
    raise exception '0142 precondition: 0141''s factoring_integration_lifecycle_problem(uuid) missing -- apply 0136-0141 first. STOP.';
  end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is null then
    raise exception '0142 precondition: classify_carrier_factoring_readiness(uuid,uuid,uuid) missing. STOP.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='invoice_code') then
    raise exception '0142 precondition: carriers.invoice_code (0130) missing. STOP.';
  end if;
  raise notice '0142 PHASE 1 preconditions passed.';
end
$mig$;

-- ======================= PHASE 2 -- ENUMS ===================================
create type public.invoice_document_type as enum (
  'carrier_freight_invoice', 'dispatch_service_invoice'
);

comment on type public.invoice_document_type is
  'carrier_freight_invoice: issuer=carrier, recipient=that carrier''s broker/customer, revenue belongs to the carrier, may be submitted to that carrier''s factor. dispatch_service_invoice: issuer=dispatch organization, recipient=carrier, revenue belongs to the dispatch company, never submitted to any carrier''s factor.';

create type public.invoice_issuance_status as enum (
  'draft', 'ready_for_issue', 'issued', 'voided'
);

comment on type public.invoice_issuance_status is
  'WHETHER the invoice legally exists yet -- issuance/legal-identity state ONLY. Deliberately does NOT carry payment, factoring, or delivery state (each lives on its own dimension so no single column is ever overloaded -- Phase 3B.3A.1 correction). draft/ready_for_issue: no invoice number, no snapshot. issued: number + snapshot both exist and are immutable. voided is terminal. There is no disputed value here -- see invoice_payment_status and this migration''s header for why whole-invoice disputes are deferred.';

create type public.invoice_payment_status as enum (
  'unpaid', 'partially_paid', 'paid'
);

comment on type public.invoice_payment_status is
  'HOW MUCH has been collected -- entirely independent of invoice_issuance_status. Structurally tied to amount_paid/total_amount (cinv_payment_status_consistency) and gated to issued/voided invoices only (cinv_payment_requires_issued: draft/ready_for_issue must always be unpaid). No written_off/credit-balance value exists -- this schema''s legacy payment architecture has no such concept (see this migration''s header) and none is added here without explicit approval.';

create type public.invoice_recipient_type as enum ('broker', 'customer');

comment on type public.invoice_recipient_type is
  'Meaningful ONLY for carrier_freight_invoice (exactly one of broker/customer). A dispatch_service_invoice''s recipient is always the carrier named in carrier_invoices.carrier_id -- this enum is not used for that document type.';

-- ======================= PHASE 3 -- ORG-LEVEL DISPATCH-INVOICE PREFIX =======
-- carriers.invoice_code / carriers.dispatch_service_terms_days and
-- platform_settings.dispatch_service_terms_days already exist (0130,
-- added specifically "for the later numbering cutover" -- this is that
-- later slice). dispatch_invoice_prefix is the one piece 0130 did not yet
-- add: the configurable per-organization prefix for dispatch-service
-- invoice numbers (Section G: "prefix and sequence policy can later be
-- configured without changing issued numbers").
alter table public.platform_settings
  add column dispatch_invoice_prefix text not null default 'DISP'
    constraint platform_settings_dispatch_invoice_prefix_format
    check (dispatch_invoice_prefix ~ '^[A-Z0-9][A-Z0-9-]{0,15}$');

comment on column public.platform_settings.dispatch_invoice_prefix is
  'Per-organization prefix for dispatch-service invoice numbers (e.g. DISP-2026-00001). Changing this affects only FUTURE numbers -- already-issued numbers are immutable and never renumbered.';

-- ======================= PHASE 4 -- carrier_invoices ========================
create table public.carrier_invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_document_type public.invoice_document_type not null,
  issuance_status public.invoice_issuance_status not null default 'draft',
  payment_status public.invoice_payment_status not null default 'unpaid',

  -- The carrier is ALWAYS the "carrier-side" party: issuer for
  -- carrier_freight_invoice, billed recipient for dispatch_service_invoice.
  -- ON DELETE RESTRICT -- a carrier with any invoice history, draft or
  -- issued, can never be silently cascaded away.
  carrier_id uuid not null references public.carriers (id) on delete restrict,

  -- Meaningful ONLY for carrier_freight_invoice -- see cinv_recipient_shape.
  recipient_type public.invoice_recipient_type,
  recipient_broker_id uuid references public.brokers (id) on delete restrict,
  recipient_customer_id uuid references public.customers (id) on delete restrict,

  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  payment_terms_days integer check (payment_terms_days is null or payment_terms_days between 0 and 365),
  due_date date,

  -- Recalculated from carrier_invoice_line_items by
  -- recalculate_carrier_invoice_totals() below whenever line items change
  -- pre-issuance; frozen (see the lifecycle guard) once issued -- the
  -- issuance snapshot, not these live columns, is authoritative afterward.
  subtotal_amount numeric(12, 2) not null default 0,
  tax_amount numeric(12, 2) not null default 0,
  adjustments_amount numeric(12, 2) not null default 0,
  total_amount numeric(12, 2) not null default 0,

  -- Payment aggregates (Section B): kept here because, and only because,
  -- the two CHECK constraints below keep them mathematically consistent
  -- with payment_status/issuance_status at all times. There is NO write
  -- path to these three columns for any role yet (no column grant, no
  -- RPC) -- see this migration's header for the full payment-architecture
  -- findings and the deferred future integration slice.
  amount_paid numeric(12, 2) not null default 0,
  balance_due numeric(12, 2) generated always as (total_amount - amount_paid) stored,

  -- NULL until issuance (Section F: "drafts have no legal invoice number").
  -- Allocated exactly once, atomically, by the future issuance RPC via
  -- _generate_carrier_invoice_number_internal() below.
  invoice_number text,
  issued_at timestamptz,
  issued_by uuid references public.profiles (id) on delete set null,

  voided_at timestamptz,
  voided_by uuid references public.profiles (id) on delete set null,
  void_reason text,

  notes text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint cinv_amounts_nonnegative check (
    subtotal_amount >= 0 and tax_amount >= 0 and total_amount >= 0
  ),

  -- Exactly one recipient for carrier_freight_invoice (broker XOR
  -- customer); NEITHER for dispatch_service_invoice (its recipient is
  -- always carrier_id itself -- Section I: "do not allow both or neither").
  constraint cinv_recipient_shape check (
    (invoice_document_type = 'carrier_freight_invoice' and (
      (recipient_type = 'broker' and recipient_broker_id is not null and recipient_customer_id is null)
      or (recipient_type = 'customer' and recipient_customer_id is not null and recipient_broker_id is null)
    ))
    or
    (invoice_document_type = 'dispatch_service_invoice'
      and recipient_type is null and recipient_broker_id is null and recipient_customer_id is null)
  ),

  -- Section F: a number/issued_at/issued_by can exist ONLY once the
  -- invoice has actually left draft/ready_for_issue -- and MUST exist for
  -- every state from 'issued' onward. This is the structural half of "the
  -- invoice number is allocated only during atomic issuance"; the guard
  -- trigger below enforces the other half (nobody can set it directly).
  constraint cinv_number_iff_issued check (
    (issuance_status in ('draft', 'ready_for_issue') and invoice_number is null and issued_at is null and issued_by is null)
    or
    (issuance_status not in ('draft', 'ready_for_issue') and invoice_number is not null and issued_at is not null)
  ),

  constraint cinv_void_fields_iff_voided check (
    (issuance_status = 'voided' and voided_at is not null and void_reason is not null and btrim(void_reason) <> '')
    or (issuance_status <> 'voided' and voided_at is null and voided_by is null and void_reason is null)
  ),

  -- Section A's required invariant: "draft and ready-for-issue invoices
  -- must be unpaid" / "only issued invoices may become partially paid or
  -- paid". A voided invoice may still show whatever payment_status it had
  -- at the moment it was voided (Section A: "voiding does not erase
  -- payment history") -- so the allowed set for a non-unpaid payment
  -- status is 'issued' OR 'voided', never 'draft'/'ready_for_issue'.
  constraint cinv_payment_requires_issued check (
    payment_status = 'unpaid' or issuance_status in ('issued', 'voided')
  ),

  -- Ties payment_status to amount_paid/total_amount so the two can never
  -- drift -- and makes overpayment structurally impossible (amount_paid
  -- can never exceed total_amount), matching this schema's existing
  -- guard_payment_amount() precedent (0026) of blocking overpayment
  -- outright rather than inventing a credit-balance concept.
  constraint cinv_payment_status_consistency check (
    (payment_status = 'unpaid' and amount_paid = 0)
    or (payment_status = 'partially_paid' and amount_paid > 0 and amount_paid < total_amount)
    or (payment_status = 'paid' and amount_paid = total_amount)
  )
);

comment on table public.carrier_invoices is
  'Phase 3B.3A foundation (3B.3A.1 correction: issuance/payment state split into two independent columns). NEW, additive invoice-document model, entirely independent of the legacy public.invoices table (single-carrier era). carrier_id is always the carrier-side party (issuer for carrier_freight_invoice, billed recipient for dispatch_service_invoice). No issuance or payment RPC references this table yet (0143+).';

create index idx_carrier_invoices_org on public.carrier_invoices (organization_id);
create index idx_carrier_invoices_carrier on public.carrier_invoices (carrier_id);
create index idx_carrier_invoices_status on public.carrier_invoices (organization_id, issuance_status);
create index idx_carrier_invoices_payment_status on public.carrier_invoices (organization_id, payment_status);
create index idx_carrier_invoices_recipient_broker on public.carrier_invoices (recipient_broker_id) where recipient_broker_id is not null;
create index idx_carrier_invoices_recipient_customer on public.carrier_invoices (recipient_customer_id) where recipient_customer_id is not null;

-- Section G: numbers scoped per legal issuer -- carrier-scoped for freight
-- invoices, organization-scoped for dispatch-service invoices. Two partial
-- unique indexes (never a single one) because the two document types have
-- two entirely different issuer scopes.
create unique index cinv_freight_number_unique
  on public.carrier_invoices (carrier_id, invoice_number)
  where invoice_document_type = 'carrier_freight_invoice' and invoice_number is not null;

create unique index cinv_dispatch_number_unique
  on public.carrier_invoices (organization_id, invoice_number)
  where invoice_document_type = 'dispatch_service_invoice' and invoice_number is not null;

drop trigger if exists set_updated_at on public.carrier_invoices;
create trigger set_updated_at before update on public.carrier_invoices
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- guard_carrier_invoice_org_consistency: recipient_broker_id/
-- recipient_customer_id/carrier_id must belong to the SAME organization as
-- the invoice -- mirrors invoices_guard_party_org (0112) and
-- guard_statement_party_org (0030) exactly, applied to the new table from
-- day one instead of as a later repair.
-- ---------------------------------------------------------------------------
create or replace function public.guard_carrier_invoice_org_consistency()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
begin
  select organization_id into v_org from public.carriers where id = new.carrier_id;
  if v_org is null or v_org <> new.organization_id then
    raise exception 'carrier_invoices: carrier_id must belong to the same organization as the invoice.' using errcode = '23514';
  end if;
  if new.recipient_broker_id is not null then
    select organization_id into v_org from public.brokers where id = new.recipient_broker_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'carrier_invoices: recipient_broker_id must belong to the same organization as the invoice.' using errcode = '23514';
    end if;
  end if;
  if new.recipient_customer_id is not null then
    select organization_id into v_org from public.customers where id = new.recipient_customer_id;
    if v_org is null or v_org <> new.organization_id then
      raise exception 'carrier_invoices: recipient_customer_id must belong to the same organization as the invoice.' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$fn$;

drop trigger if exists a0142_guard_org_consistency on public.carrier_invoices;
create trigger a0142_guard_org_consistency
  before insert or update on public.carrier_invoices
  for each row execute function public.guard_carrier_invoice_org_consistency();

-- ======================= PHASE 5 -- carrier_invoice_line_items ==============
create table public.carrier_invoice_line_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.carrier_invoices (id) on delete cascade,
  description text not null,
  quantity numeric(10, 2) not null default 1,
  unit_price numeric(10, 2) not null default 0,
  line_total numeric(12, 2) generated always as (quantity * unit_price) stored,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_carrier_invoice_line_items_invoice on public.carrier_invoice_line_items (invoice_id);

drop trigger if exists set_updated_at on public.carrier_invoice_line_items;
create trigger set_updated_at before update on public.carrier_invoice_line_items
  for each row execute function public.set_updated_at();

-- Line items are mutable ONLY while the parent invoice is still
-- draft/ready_for_issue -- once issued, the snapshot is authoritative and
-- line items must never silently change under it (Section E: totals
-- cannot change post-issuance).
create or replace function public.guard_carrier_invoice_line_item_mutability()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_org uuid;
  v_status public.invoice_issuance_status;
begin
  select organization_id, issuance_status into v_org, v_status
  from public.carrier_invoices where id = v_invoice_id;
  if v_status is null then
    raise exception 'carrier_invoice_line_items: invoice not found.' using errcode = '23503';
  end if;
  if v_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoice_line_items: line items are immutable once the invoice has left draft/ready_for_issue (current status: %).', v_status using errcode = '55000';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.organization_id <> v_org then
    raise exception 'carrier_invoice_line_items: organization_id must match the invoice''s own organization.' using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists a0142_guard_line_item_mutability on public.carrier_invoice_line_items;
create trigger a0142_guard_line_item_mutability
  before insert or update or delete on public.carrier_invoice_line_items
  for each row execute function public.guard_carrier_invoice_line_item_mutability();

-- Recalculates the parent invoice's subtotal/total from its line items --
-- mirrors the legacy schema's own recalculate_invoice_totals() convention.
-- tax_amount/adjustments_amount are NOT derived from line items (no tax/
-- adjustment line-item concept in this foundation) -- they stay whatever
-- was explicitly set on carrier_invoices itself; total_amount = subtotal
-- + tax + adjustments.
create or replace function public.recalculate_carrier_invoice_totals()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_subtotal numeric(12, 2);
begin
  select coalesce(sum(line_total), 0) into v_subtotal
  from public.carrier_invoice_line_items where invoice_id = v_invoice_id;

  update public.carrier_invoices
    set subtotal_amount = v_subtotal,
        total_amount = v_subtotal + tax_amount + adjustments_amount
    where id = v_invoice_id;

  return coalesce(new, old);
end;
$fn$;

drop trigger if exists a0142_recalculate_totals on public.carrier_invoice_line_items;
create trigger a0142_recalculate_totals
  after insert or update or delete on public.carrier_invoice_line_items
  for each row execute function public.recalculate_carrier_invoice_totals();

-- ======================= PHASE 6 -- carrier_invoice_loads ===================
create table public.carrier_invoice_loads (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.carrier_invoices (id) on delete cascade,
  load_id uuid not null references public.loads (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint civl_invoice_load_uq unique (invoice_id, load_id)
);

create index idx_carrier_invoice_loads_invoice on public.carrier_invoice_loads (invoice_id);
create index idx_carrier_invoice_loads_load on public.carrier_invoice_loads (load_id);

-- Same org-consistency + carrier-consistency shape as loads.carrier_id
-- (0132/0133) -- a load attached to a carrier_freight_invoice must belong
-- to THIS invoice's own organization AND (when the load has a resolved
-- carrier_id) that load's carrier must match the invoice's own carrier_id.
-- A dispatch_service_invoice may reference loads too (its "covered
-- load(s)" per Section D) without this carrier match, since its carrier_id
-- is the BILLED party, not necessarily every covered load's operational
-- carrier in every future scenario -- kept permissive here deliberately;
-- 0143's issuance RPC is the place a stricter rule can be added once real
-- dispatch-service billing requirements are reviewed.
create or replace function public.guard_carrier_invoice_load_consistency()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_load record;
  v_invoice record;
begin
  select organization_id, carrier_id, invoice_document_type into v_invoice
  from public.carrier_invoices where id = new.invoice_id;
  if v_invoice.organization_id is null then
    raise exception 'carrier_invoice_loads: invoice not found.' using errcode = '23503';
  end if;
  if new.organization_id <> v_invoice.organization_id then
    raise exception 'carrier_invoice_loads: organization_id must match the invoice''s own organization.' using errcode = '23514';
  end if;

  select organization_id, carrier_id into v_load from public.loads where id = new.load_id;
  if v_load.organization_id is null or v_load.organization_id <> v_invoice.organization_id then
    raise exception 'carrier_invoice_loads: load must belong to the same organization as the invoice.' using errcode = '23514';
  end if;
  if v_invoice.invoice_document_type = 'carrier_freight_invoice'
    and v_load.carrier_id is not null and v_load.carrier_id <> v_invoice.carrier_id then
    raise exception 'carrier_invoice_loads: load''s own carrier_id does not match this carrier_freight_invoice''s carrier.' using errcode = '23514';
  end if;
  return new;
end;
$fn$;

drop trigger if exists a0142_guard_load_consistency on public.carrier_invoice_loads;
create trigger a0142_guard_load_consistency
  before insert or update on public.carrier_invoice_loads
  for each row execute function public.guard_carrier_invoice_load_consistency();

-- Load links cannot be silently replaced once issued: block INSERT/DELETE
-- against carrier_invoice_loads for an invoice that has already left
-- draft/ready_for_issue (mirrors guard_carrier_invoice_line_item_mutability).
create or replace function public.guard_carrier_invoice_load_mutability()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_status public.invoice_issuance_status;
begin
  select issuance_status into v_status
  from public.carrier_invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if v_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoice_loads: load links are immutable once the invoice has left draft/ready_for_issue (current status: %).', v_status using errcode = '55000';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists a0142_guard_load_mutability on public.carrier_invoice_loads;
create trigger a0142_guard_load_mutability
  before insert or delete on public.carrier_invoice_loads
  for each row execute function public.guard_carrier_invoice_load_mutability();

-- ======================= PHASE 7 -- numbering ===============================
-- Generalizes invoice_number_counters/generate_invoice_number() (0065,
-- hardened 0129) to a polymorphic issuer scope. issuer_id is carrier_id
-- for carrier_freight_invoice, organization_id for dispatch_service_invoice
-- -- no FK (it points into two different tables depending on
-- invoice_document_type), exactly as invoice_number_counters itself has no
-- FK misuse protection beyond being reachable only through a trusted
-- SECURITY DEFINER mechanism function with zero authorization logic of its
-- own (0129's own documented pattern). Resets per calendar year, per
-- issuer -- same policy this schema already uses for its one existing
-- numbering system, kept consistent rather than inventing a new default.
create table public.carrier_invoice_number_counters (
  invoice_document_type public.invoice_document_type not null,
  issuer_id uuid not null,
  year integer not null,
  last_number integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (invoice_document_type, issuer_id, year)
);

-- 0010/TEST_SUPPORT's `alter default privileges ... grant ... to
-- authenticated` means every new table starts with full CRUD granted to
-- authenticated -- explicitly revoke INSERT/UPDATE/DELETE here (RLS alone
-- is not the whole story; a table-level grant exists independently of any
-- policy), matching invoice_number_counters (0065) and
-- factoring_integration_lifecycle_idempotency (0141) exactly.
revoke insert, update, delete on public.carrier_invoice_number_counters from authenticated;
revoke all on public.carrier_invoice_number_counters from anon;

alter table public.carrier_invoice_number_counters enable row level security;

create policy carrier_invoice_number_counters_select
  on public.carrier_invoice_number_counters for select
  using (
    public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[])
    and (
      (invoice_document_type = 'carrier_freight_invoice'
        and exists (select 1 from public.carriers c where c.id = issuer_id and c.organization_id = public.current_org_id()))
      or
      (invoice_document_type = 'dispatch_service_invoice' and issuer_id = public.current_org_id())
    )
  );

comment on table public.carrier_invoice_number_counters is
  'One row per (document type, issuer, calendar year). Touched only via _generate_carrier_invoice_number_internal()''s SECURITY DEFINER privileges -- no client INSERT/UPDATE/DELETE policy, matching invoice_number_counters (0065).';

-- Mechanism ONLY -- no authorization logic, exactly like 0129's
-- _generate_invoice_number_internal(uuid). EXECUTE is revoked from every
-- application-facing role; reachable only from a future trusted
-- SECURITY DEFINER caller (0143's issuance RPC) that has ALREADY verified
-- the caller is authorized to issue for this specific carrier/organization.
create function public._generate_carrier_invoice_number_internal(
  p_invoice_document_type public.invoice_document_type,
  p_issuer_id uuid,
  p_prefix text
)
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_year integer := extract(year from current_date)::integer;
  v_number integer;
begin
  insert into public.carrier_invoice_number_counters (invoice_document_type, issuer_id, year, last_number)
  values (p_invoice_document_type, p_issuer_id, v_year, 1)
  on conflict (invoice_document_type, issuer_id, year)
  do update set last_number = carrier_invoice_number_counters.last_number + 1, updated_at = now()
  returning last_number into v_number;

  return p_prefix || '-' || v_year || '-' || lpad(v_number::text, 5, '0');
end;
$fn$;

revoke all on function public._generate_carrier_invoice_number_internal(public.invoice_document_type, uuid, text) from public, anon, authenticated, service_role;

comment on function public._generate_carrier_invoice_number_internal(public.invoice_document_type, uuid, text) is
  'Private atomic counter mechanism ONLY (no authorization logic) -- format {prefix}-{year}-{NNNNN}, resets per calendar year per issuer. NO EXECUTE grant to any application-facing role; reachable only from a trusted SECURITY DEFINER caller (0143''s issuance RPC) after that caller has independently verified authorization. Two concurrent callers for the SAME (document_type, issuer_id, year) can never receive the same number -- Postgres serializes the single INSERT...ON CONFLICT...RETURNING statement.';

-- ======================= PHASE 8 -- idempotency table =======================
-- Byte-for-byte the same shape as 0141's factoring_integration_lifecycle_
-- idempotency (plus request_fingerprint, added in Phase 3B.3A.2 -- see
-- below), ready for 0143's issuance RPC (Section G: "idempotent retry
-- returns the original invoice number") AND already used, today, by
-- update_carrier_invoice_draft() below (the `action` column distinguishes
-- callers -- 'update_draft' now, issuance-related values reserved for
-- 0143).
create table public.carrier_invoice_lifecycle_idempotency (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  idempotency_key text not null,
  invoice_id uuid not null references public.carrier_invoices (id) on delete cascade,
  action text not null,
  -- Phase 3B.3A.2 (Section F item 17: "different payload with the same
  -- key is rejected"): a fingerprint of the REQUEST (not just the key) --
  -- an idempotency key replayed with a materially different payload must
  -- be rejected outright, never silently replay the old result and never
  -- silently apply the new one.
  request_fingerprint text not null,
  result jsonb not null,
  created_at timestamptz not null default now(),
  constraint civ_idempotency_unique unique (organization_id, idempotency_key)
);

revoke insert, update, delete on public.carrier_invoice_lifecycle_idempotency from authenticated;
revoke all on public.carrier_invoice_lifecycle_idempotency from anon;

alter table public.carrier_invoice_lifecycle_idempotency enable row level security;

create policy carrier_invoice_lifecycle_idempotency_select
  on public.carrier_invoice_lifecycle_idempotency for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

comment on table public.carrier_invoice_lifecycle_idempotency is
  'Used by update_carrier_invoice_draft() today and reserved for 0143''s issuance RPC. No client INSERT/UPDATE/DELETE policy -- writable only via a SECURITY DEFINER RPC, matching factoring_integration_lifecycle_idempotency (0141). request_fingerprint lets a replay with a DIFFERENT payload under the same key be rejected rather than silently replayed or silently applied.';

-- ======================= PHASE 9 -- immutable issuance snapshot =============
-- Phase 3B.3A.1 correction (Section E): the original CHECK only ever
-- looked one level deep, at snapshot_payload->'factoring'->>'secret_
-- reference' -- a nested object or an array element anywhere else in the
-- payload could still carry a forbidden key undetected. This recursive
-- helper walks the ENTIRE jsonb tree (objects AND arrays, any depth) and
-- is used both for secret_reference and for a wider set of obvious
-- credential-shaped keys (api_key, access_token, refresh_token, password,
-- client_secret, credential, credentials, private_key). Matching is
-- case-insensitive (lower(key)) so 'API_Key'/'ApiKey'-style variants are
-- also caught. IMMUTABLE: it only ever examines its own jsonb argument,
-- no table lookups, safe and required for use inside a CHECK constraint.
create function public.jsonb_contains_forbidden_key(p_node jsonb, p_forbidden_keys text[])
returns boolean
language plpgsql
immutable
as $fn$
declare
  v_key text;
  v_val jsonb;
  v_elem jsonb;
begin
  if p_node is null then
    return false;
  end if;
  if jsonb_typeof(p_node) = 'object' then
    for v_key, v_val in select key, value from jsonb_each(p_node) loop
      if lower(v_key) = any(p_forbidden_keys) then
        return true;
      end if;
      if public.jsonb_contains_forbidden_key(v_val, p_forbidden_keys) then
        return true;
      end if;
    end loop;
    return false;
  elsif jsonb_typeof(p_node) = 'array' then
    for v_elem in select value from jsonb_array_elements(p_node) loop
      if public.jsonb_contains_forbidden_key(v_elem, p_forbidden_keys) then
        return true;
      end if;
    end loop;
    return false;
  else
    return false;
  end if;
end;
$fn$;

comment on function public.jsonb_contains_forbidden_key(jsonb, text[]) is
  'Recursively walks a jsonb value (objects AND arrays, any depth) and returns true if any object key (case-insensitively) matches an entry in p_forbidden_keys. Used by carrier_invoice_issuance_snapshots'' civs_no_forbidden_keys CHECK -- never trust a shallow, one-level lookup for something as consequential as excluding credential material from an immutable financial snapshot.';

create table public.carrier_invoice_issuance_snapshots (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null unique references public.carrier_invoices (id) on delete restrict,
  organization_id uuid not null references public.organizations (id) on delete restrict,
  invoice_document_type public.invoice_document_type not null,
  issuance_schema_version integer not null default 1,

  issued_at timestamptz not null default now(),
  issued_by uuid references public.profiles (id) on delete set null,

  currency text not null,
  invoice_number text not null,
  payment_terms_days integer,
  due_date date,
  subtotal_amount numeric(12, 2) not null,
  tax_amount numeric(12, 2) not null default 0,
  adjustments_amount numeric(12, 2) not null default 0,
  total_amount numeric(12, 2) not null,
  amount_due_at_issuance numeric(12, 2) not null,

  -- Denormalized for indexing/joins/reporting ONLY -- the authoritative,
  -- exhaustive identity (Section D's full field list: carrier legal name/
  -- DBA/address/MC/DOT/remittance, recipient identity, load identifiers,
  -- factoring identity, dispatch-service identity, etc.) lives in
  -- snapshot_payload, which is what "remains stable even if a carrier,
  -- broker, customer, factor, address, email, rate, or policy changes
  -- later" actually refers to -- these two columns exist only so a report
  -- can filter/join without parsing JSONB every time.
  carrier_id uuid references public.carriers (id) on delete restrict,
  recipient_broker_id uuid references public.brokers (id) on delete restrict,
  recipient_customer_id uuid references public.customers (id) on delete restrict,

  -- Full structured detail -- see this migration's header (Section D) for
  -- the exhaustive field list this must contain. Never contains
  -- secret_reference, or any other credential-shaped key, AT ANY DEPTH
  -- (structurally checked below via jsonb_contains_forbidden_key,
  -- recursively -- Phase 3B.3A.1 Section E correction).
  snapshot_payload jsonb not null,

  created_at timestamptz not null default now(),

  constraint civs_amounts_nonnegative check (
    subtotal_amount >= 0 and tax_amount >= 0 and total_amount >= 0 and amount_due_at_issuance >= 0
  ),
  -- Section E: snapshot_payload must be a genuine JSON object (never a
  -- bare array/scalar someone could otherwise smuggle secret-shaped data
  -- inside without it ever being an "object key" at the top level), and
  -- must never contain secret_reference or any other obvious credential
  -- key, at ANY depth, inside ANY nested object or array. The server-
  -- generated, allowlisted snapshot structure the future issuance RPC
  -- builds remains the PRIMARY protection (it never even reads a raw
  -- secret in the first place) -- this CHECK is the defense-in-depth
  -- backstop that makes a mistake in that RPC unable to reach storage.
  constraint civs_payload_is_object check (jsonb_typeof(snapshot_payload) = 'object'),
  constraint civs_no_forbidden_keys check (
    not public.jsonb_contains_forbidden_key(
      snapshot_payload,
      array['secret_reference', 'api_key', 'access_token', 'refresh_token', 'password', 'client_secret', 'credential', 'credentials', 'private_key']
    )
  )
);

comment on table public.carrier_invoice_issuance_snapshots is
  'Phase 3B.3A Section D: one-to-one immutable financial/identity snapshot, created ONLY at successful issuance. Client roles (including service_role -- see the guard trigger below) can never UPDATE or DELETE a row here once inserted. snapshot_payload structure: {issuer:{...}, recipient:{...}, loads:[{...}], factoring:{...}|null, dispatch_service:{...}|null} -- see 0142''s own header comment and TEST_0142 for the exact shape 0143''s issuance RPC must populate.';

create index idx_carrier_invoice_issuance_snapshots_org on public.carrier_invoice_issuance_snapshots (organization_id);
create index idx_carrier_invoice_issuance_snapshots_carrier on public.carrier_invoice_issuance_snapshots (carrier_id) where carrier_id is not null;

-- Section E: "client roles cannot INSERT, UPDATE, or DELETE snapshots
-- directly" AND "service-role use alone must not bypass immutable
-- financial controls". No role -- including service_role -- is granted
-- INSERT here (there is no issuance RPC yet to legitimately need it); once
-- 0143 adds the issuance RPC, THAT SECURITY DEFINER function's own owner
-- privileges are what perform the single INSERT, never a table grant to
-- any role.
revoke all on public.carrier_invoice_issuance_snapshots from public, anon, authenticated, service_role;
grant select on public.carrier_invoice_issuance_snapshots to authenticated;

alter table public.carrier_invoice_issuance_snapshots enable row level security;

create policy carrier_invoice_issuance_snapshots_select
  on public.carrier_invoice_issuance_snapshots for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

-- BEFORE trigger: fires for EVERY role regardless of RLS/BYPASSRLS/table
-- grants -- this is the structural guarantee that "service-role use alone
-- must not bypass immutable financial controls" (Section E), not merely a
-- missing grant that a future migration could accidentally add back.
create or replace function public.guard_carrier_invoice_issuance_snapshot_immutable()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if tg_op = 'UPDATE' then
    raise exception 'carrier_invoice_issuance_snapshots: an issuance snapshot is immutable and can never be updated, by any role.' using errcode = '55000';
  elsif tg_op = 'DELETE' then
    raise exception 'carrier_invoice_issuance_snapshots: an issuance snapshot is immutable and can never be deleted, by any role.' using errcode = '55000';
  end if;
  return null;
end;
$fn$;

drop trigger if exists a0142_guard_snapshot_immutable on public.carrier_invoice_issuance_snapshots;
create trigger a0142_guard_snapshot_immutable
  before update or delete on public.carrier_invoice_issuance_snapshots
  for each row execute function public.guard_carrier_invoice_issuance_snapshot_immutable();

-- ======================= PHASE 10 -- carrier_invoices lifecycle guard =======
-- Phase 3B.3A.1/3B.3A.2 correction -- Section A/D combined. This trigger
-- is a BACKSTOP, not the primary authorization boundary: the primary
-- boundary for authenticated is the column-privilege model in Phase 11
-- below (Phase 3B.3A.2: blanket UPDATE revoked, ONLY notes re-granted --
-- carrier_id/invoice_document_type/recipient_*/currency/issuance_status/
-- voided_*/void_reason/due_date/payment_terms_days now have ZERO direct-
-- UPDATE grant for any role, full stop). This trigger still matters
-- because (a) it also fires for any FUTURE SECURITY DEFINER RPC (the new
-- update_carrier_invoice_draft() below included), which bypasses column
-- grants entirely, and (b) it enforces invariants no column grant can
-- express (state machines, cross-column consistency, snapshot
-- existence). Its own role checks below are now REDUNDANT for a direct
-- authenticated UPDATE (grants already block every field they cover
-- except notes) but remain load-bearing defense-in-depth for
-- update_carrier_invoice_draft() and any future issuance/void RPC (0143).
--   (1) once issued/voided, carrier/document-type/recipient/invoice
--       number/issuance identity/currency/issued totals are frozen
--       forever -- payment_status/amount_paid are DELIBERATELY excluded
--       from this frozen set (Section A: "only issued invoices may become
--       partially paid or paid" -- they must remain changeable post-
--       issuance by a future payment mechanism).
--   (2) the issuance-status state machine (draft/ready_for_issue/issued/
--       voided ONLY -- no payment value ever appears here, Section A) only
--       allows specific transitions.
--   (3) nobody may set issuance_status='issued' via a raw UPDATE without
--       an existing snapshot row + allocated number -- reserved for the
--       future issuance RPC (0143).
--   (4) role-scoped identity-field protection, kept as defense-in-depth
--       (Section D: "keep trigger backstops where helpful, but do not
--       make a growing denylist the primary authorization boundary").
--   (5) voiding requires a non-empty void_reason ALWAYS (cinv_void_fields_
--       iff_voided already enforces this structurally, at the CHECK
--       level, so this is belt-and-suspenders); an invoice with
--       amount_paid > 0 can only be voided by owner/admin, never
--       accountant/dispatcher (Section A: "an invoice with applied
--       payments cannot be casually voided").
--   (6) payment_status/amount_paid changes can never, in the same
--       statement, move issuance_status backward to draft/ready_for_issue
--       -- structurally impossible already since cinv_payment_requires_
--       issued forbids a non-unpaid payment_status on a draft/ready_for_
--       issue row, but this trigger also explicitly rejects issued/voided
--       -> draft/ready_for_issue regardless of what else changed in the
--       same statement (Section A: "payment changes cannot return an
--       issued invoice to draft").
create or replace function public.guard_carrier_invoice_lifecycle_transition()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_snapshot_exists boolean;
begin
  if tg_op = 'UPDATE' then
    -- ---- (4) role-scoped identity-field protection -- ANY status ----
    if (new.carrier_id is distinct from old.carrier_id
        or new.invoice_document_type is distinct from old.invoice_document_type
        or new.recipient_type is distinct from old.recipient_type
        or new.recipient_broker_id is distinct from old.recipient_broker_id
        or new.recipient_customer_id is distinct from old.recipient_customer_id
        or new.currency is distinct from old.currency)
       and not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
      raise exception 'carrier_invoices: only owner, admin, or accountant may change the legal issuer, document type, recipient, or currency.' using errcode = '42501';
    end if;

    -- ---- (1) frozen-forever once issued/voided ----
    if old.issuance_status not in ('draft', 'ready_for_issue') then
      if (new.carrier_id is distinct from old.carrier_id
          or new.invoice_document_type is distinct from old.invoice_document_type
          or new.recipient_type is distinct from old.recipient_type
          or new.recipient_broker_id is distinct from old.recipient_broker_id
          or new.recipient_customer_id is distinct from old.recipient_customer_id
          or new.invoice_number is distinct from old.invoice_number
          or new.issued_at is distinct from old.issued_at
          or new.issued_by is distinct from old.issued_by
          or new.currency is distinct from old.currency
          or new.subtotal_amount is distinct from old.subtotal_amount
          or new.tax_amount is distinct from old.tax_amount
          or new.adjustments_amount is distinct from old.adjustments_amount
          or new.total_amount is distinct from old.total_amount) then
        raise exception 'carrier_invoices: carrier, document type, recipient, invoice number, issuance identity, currency, and issued totals are immutable once the invoice is no longer draft/ready_for_issue.' using errcode = '55000';
      end if;
    end if;

    -- ---- (3) the 'issued' transition itself must be RPC-driven ----
    if new.issuance_status = 'issued' and old.issuance_status <> 'issued' then
      select exists(select 1 from public.carrier_invoice_issuance_snapshots where invoice_id = new.id) into v_snapshot_exists;
      if not v_snapshot_exists then
        raise exception 'carrier_invoices: cannot transition to issued without an existing issuance snapshot -- this transition is reserved for the issuance RPC (0143).' using errcode = '55000';
      end if;
      if new.invoice_number is null then
        raise exception 'carrier_invoices: cannot transition to issued without an allocated invoice_number.' using errcode = '55000';
      end if;
    end if;

    -- ---- (6) a payment-only (or any) change can never regress issuance_status ----
    if new.issuance_status is distinct from old.issuance_status
      and old.issuance_status in ('issued', 'voided')
      and new.issuance_status in ('draft', 'ready_for_issue') then
      raise exception 'carrier_invoices: an issued or voided invoice can never return to draft/ready_for_issue.' using errcode = '55000';
    end if;

    -- ---- (2) issuance-status state machine (payment-free) ----
    if new.issuance_status is distinct from old.issuance_status then
      if not (
        (old.issuance_status = 'draft' and new.issuance_status in ('ready_for_issue', 'voided'))
        or (old.issuance_status = 'ready_for_issue' and new.issuance_status in ('draft', 'issued', 'voided'))
        or (old.issuance_status = 'issued' and new.issuance_status = 'voided')
      ) then
        raise exception 'carrier_invoices: % -> % is not a permitted issuance transition.', old.issuance_status, new.issuance_status using errcode = '55000';
      end if;
      -- 'voided' is terminal: no row above has old.issuance_status =
      -- 'voided', so nothing can ever leave it.
    end if;

    -- ---- (5) voiding is never casual ----
    if new.issuance_status = 'voided' and old.issuance_status <> 'voided' then
      if new.void_reason is null or btrim(new.void_reason) = '' then
        raise exception 'carrier_invoices: voiding requires a non-empty void_reason.' using errcode = '23514';
      end if;
      if old.amount_paid > 0 and not public.has_role(array['owner', 'admin']::public.org_role[]) then
        raise exception 'carrier_invoices: an invoice with applied payments can only be voided by an owner or admin.' using errcode = '42501';
      end if;
    end if;
  end if;

  return new;
end;
$fn$;

drop trigger if exists a0142_guard_lifecycle_transition on public.carrier_invoices;
create trigger a0142_guard_lifecycle_transition
  before update on public.carrier_invoices
  for each row execute function public.guard_carrier_invoice_lifecycle_transition();

-- Paid invoices cannot be deleted; nothing beyond draft/ready_for_issue can
-- be deleted at all (correction is void, not delete) -- fires for every
-- role, same reasoning as the snapshot immutability trigger.
create or replace function public.guard_carrier_invoice_delete()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if old.issuance_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoices: an invoice that has been issued (status: %) cannot be deleted -- void it instead.', old.issuance_status using errcode = '55000';
  end if;
  return old;
end;
$fn$;

drop trigger if exists a0142_guard_delete on public.carrier_invoices;
create trigger a0142_guard_delete
  before delete on public.carrier_invoices
  for each row execute function public.guard_carrier_invoice_delete();

-- ======================= PHASE 11 -- RLS + COLUMN PRIVILEGES ================
-- Phase 3B.3A.1 correction (Section D, "Preferred" design): column-level
-- grants are now the PRIMARY authorization boundary for carrier_invoices,
-- not a trigger denylist. The blanket `alter default privileges ... grant
-- ... to authenticated` UPDATE (0010/TEST_SUPPORT) is explicitly revoked,
-- then ONLY three genuinely-safe, purely-operational draft columns are
-- re-granted. Every other existing column -- and, critically, every
-- column ANY future migration ever adds -- defaults to NO client UPDATE
-- grant at all, structurally, until someone deliberately re-grants it.
-- This directly satisfies "a future/unrecognized column is not
-- automatically dispatcher-writable" (and is not automatically writable
-- by ANY role, which is stricter and safer than the task's minimum ask).
-- NOTE on the limits of column-level grants here: Postgres GRANT/REVOKE
-- operates on the single shared `authenticated` Postgres role -- it
-- cannot itself distinguish owner/admin/accountant from dispatcher (that
-- distinction is application-level, via profiles.role/has_role() inside
-- RLS and the trigger). Column grants below therefore define the outer
-- boundary reachable by ANY authenticated org member; has_role() checks
-- in the RLS policies (row-level: which ROWS) and the lifecycle trigger
-- (field-level: which of these granted COLUMNS a non-owner/admin/
-- accountant may actually change) narrow it further per role -- exactly
-- the two-layer model already proven for factoring_relationships
-- (guard_factoring_relationship_protected_fields, 0136).
--
-- Phase 3B.3A.2 correction (Section A): the prior pass still granted
-- carrier_id/invoice_document_type/recipient_*/currency/issuance_status/
-- voided_at/voided_by/void_reason/due_date/payment_terms_days directly to
-- authenticated, relying on the lifecycle trigger's role check as the
-- REAL boundary for who could use them. That is exactly the "trigger
-- denylist as primary boundary" posture Section D warns against -- it
-- also meant issuance_status/void_reason/voided_at/voided_by were
-- reachable via a raw UPDATE at all (gated only by role + a snapshot-
-- existence check), when nothing should be able to reach them yet.
--
-- Columns intentionally EXCLUDED from this grant, for EVERY authenticated
-- role, with NO exception, full stop: organization_id, carrier_id,
-- invoice_document_type, recipient_type, recipient_broker_id,
-- recipient_customer_id, currency, due_date, payment_terms_days,
-- subtotal_amount, tax_amount, adjustments_amount, total_amount,
-- amount_paid, payment_status, issuance_status, invoice_number,
-- issued_at, issued_by, voided_at, voided_by, void_reason, created_by,
-- created_at, updated_at. None of these has ANY direct-UPDATE write path
-- for any role any more -- not owner, not admin. Recipient/currency/
-- due_date/payment_terms_days changes now go ONLY through
-- update_carrier_invoice_draft() below (a SECURITY DEFINER RPC, which
-- bypasses table/column grants entirely by design -- exactly like every
-- other guarded RPC in this schema). issuance_status/void_reason/
-- voided_at/voided_by have NO write path anywhere yet, direct or via RPC
-- -- draft->ready_for_issue, issuance, and voiding are ALL explicitly
-- deferred to 0143 (Section C/D). Payment fields remain deferred per
-- Section B (the payment-FK/integration slice).
revoke update on public.carrier_invoices from authenticated;
grant update (notes) on public.carrier_invoices to authenticated;

comment on column public.carrier_invoices.notes is 'The ONLY column any authenticated org member (including dispatcher) may set via a direct client UPDATE (Phase 3B.3A.2, Section A) -- every other column, including any a future migration ever adds, has zero UPDATE grant by default and requires a guarded RPC.';

alter table public.carrier_invoices enable row level security;
alter table public.carrier_invoice_line_items enable row level security;
alter table public.carrier_invoice_loads enable row level security;

create policy carrier_invoices_select
  on public.carrier_invoices for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

-- Section K: owner/admin/accountant may create any draft; dispatcher may
-- ALSO create a draft (never anything beyond draft) -- INSERT still needs
-- a row-level (not just column-level) check since every column is
-- supplied at once; the column-level grant above is what then prevents
-- dispatcher from ever changing carrier_id/recipient/currency/etc. on a
-- SUBSEQUENT update, regardless of what the lifecycle trigger also says.
create policy carrier_invoices_insert
  on public.carrier_invoices for insert
  with check (
    organization_id = public.current_org_id()
    and (
      public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
      or (public.has_role(array['dispatcher']::public.org_role[]) and issuance_status = 'draft')
    )
  );

-- The row-level USING/CHECK clauses below still gate WHICH ROWS a role
-- may touch (org + role + status) -- the column-level grant above then
-- independently gates WHICH COLUMNS of that row an authenticated session
-- can actually set in the UPDATE's target list at all. Both must pass.
create policy carrier_invoices_update
  on public.carrier_invoices for update
  using (
    organization_id = public.current_org_id()
    and (
      public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
      or (public.has_role(array['dispatcher']::public.org_role[]) and issuance_status in ('draft', 'ready_for_issue'))
    )
  )
  with check (
    organization_id = public.current_org_id()
    and (
      public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
      or (public.has_role(array['dispatcher']::public.org_role[]) and issuance_status in ('draft', 'ready_for_issue'))
    )
  );

-- Section K (Phase 3B.3A.2 Section C/D): issuance/void/ready-for-issue
-- authority is deliberately NOT exercised through this row-level policy
-- at all any more -- issuance_status/voided_at/voided_by/void_reason have
-- ZERO column grant for every role (Phase 11), so no direct UPDATE,
-- including from owner/admin, can ever reach 'ready_for_issue', 'issued',
-- or 'voided' today. This USING/WITH CHECK clause now only ever governs
-- notes edits (the one granted column) plus whatever a future guarded RPC
-- does under its own SECURITY DEFINER privileges (which bypass this
-- policy's row visibility concern not at all -- RLS still applies to
-- SECURITY DEFINER functions unless BYPASSRLS, which none of these use).
-- draft -> ready_for_issue, issuance, and voiding are explicitly deferred
-- to 0143, which will own: prepare/validate for issuance; the ready_for_
-- issue transition; atomic issuance; voiding; and idempotent retries for
-- all of the above.
create policy carrier_invoices_delete
  on public.carrier_invoices for delete
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy carrier_invoice_line_items_select
  on public.carrier_invoice_line_items for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

create policy carrier_invoice_line_items_insert
  on public.carrier_invoice_line_items for insert
  with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

create policy carrier_invoice_line_items_update
  on public.carrier_invoice_line_items for update
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

create policy carrier_invoice_line_items_delete
  on public.carrier_invoice_line_items for delete
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

create policy carrier_invoice_loads_select
  on public.carrier_invoice_loads for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

create policy carrier_invoice_loads_insert
  on public.carrier_invoice_loads for insert
  with check (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

create policy carrier_invoice_loads_delete
  on public.carrier_invoice_loads for delete
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

-- Driver/viewer: no policy at all on any of the four tables above beyond
-- what RLS default-denies -- structurally zero access, not merely a UI
-- omission (Section K: "no financial mutation authority", and 0066's own
-- SELECT-narrowing precedent excludes driver/viewer from every financial
-- table's SELECT too).

-- ======================= PHASE 12 -- read-only problem functions ===========
-- Section I: recipient resolution. Re-derives eligibility independently
-- (does not merely trust invoice_document_type/recipient_* columns are
-- internally consistent -- the CHECK constraint already guarantees shape,
-- this additionally validates the referenced party is genuinely usable
-- for a NEW invoice).
create function public.carrier_invoice_recipient_problem(p_invoice_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_inv record;
  v_party record;
begin
  select organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, recipient_customer_id
    into v_inv
  from public.carrier_invoices where id = p_invoice_id;
  if v_inv.organization_id is null then
    return 'invoice_not_found';
  end if;

  if v_inv.invoice_document_type = 'dispatch_service_invoice' then
    -- Recipient is always carrier_id itself -- just confirm the carrier
    -- is still active for a NEW invoice.
    if not exists (select 1 from public.carriers where id = v_inv.carrier_id and is_active) then
      return 'recipient_carrier_inactive';
    end if;
    return null;
  end if;

  -- carrier_freight_invoice from here.
  if v_inv.recipient_type = 'broker' then
    if v_inv.recipient_broker_id is null then
      return 'recipient_missing';
    end if;
    -- brokers has no is_active column -- "active" for a broker means not
    -- blacklisted (the only operational deactivation concept this schema
    -- has for brokers).
    if not exists (select 1 from public.brokers where id = v_inv.recipient_broker_id and not is_blacklisted) then
      return 'recipient_broker_blacklisted';
    end if;
    select status, factoring_eligible, factoring_ineligible_direct_billing_approved into v_party
    from public.carrier_brokers where carrier_id = v_inv.carrier_id and broker_id = v_inv.recipient_broker_id;
    if v_party.status is null then
      return 'recipient_relationship_missing';
    end if;
    if v_party.status <> 'active' then
      return 'recipient_relationship_inactive';
    end if;
  elsif v_inv.recipient_type = 'customer' then
    if v_inv.recipient_customer_id is null then
      return 'recipient_missing';
    end if;
    if not exists (select 1 from public.customers where id = v_inv.recipient_customer_id and is_active) then
      return 'recipient_customer_inactive';
    end if;
    select status, factoring_eligible, factoring_ineligible_direct_billing_approved into v_party
    from public.carrier_customers where carrier_id = v_inv.carrier_id and customer_id = v_inv.recipient_customer_id;
    if v_party.status is null then
      return 'recipient_relationship_missing';
    end if;
    if v_party.status <> 'active' then
      return 'recipient_relationship_inactive';
    end if;
  else
    return 'recipient_missing';
  end if;

  return null;
end;
$fn$;

revoke all on function public.carrier_invoice_recipient_problem(uuid) from public, anon, authenticated;

comment on function public.carrier_invoice_recipient_problem(uuid) is
  'Read-only. Returns null if the invoice''s recipient resolves cleanly for a NEW invoice, else a short problem code. Internal building block for 0143''s issuance RPC and for tests -- not itself exposed to authenticated/anon.';

-- Section H: factoring readiness at issuance. Freight invoices only --
-- dispatch_service_invoice never uses carrier factoring readiness at all.
create function public.carrier_invoice_factoring_readiness_problem(p_invoice_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_inv record;
  v_carrier record;
  v_classification jsonb;
begin
  select organization_id, invoice_document_type, carrier_id, recipient_broker_id, recipient_customer_id
    into v_inv
  from public.carrier_invoices where id = p_invoice_id;
  if v_inv.organization_id is null then
    return 'invoice_not_found';
  end if;
  if v_inv.invoice_document_type = 'dispatch_service_invoice' then
    return null; -- never applicable
  end if;

  select factoring_mode into v_carrier from public.carriers where id = v_inv.carrier_id;
  if v_carrier.factoring_mode = 'unconfigured' then
    return 'carrier_factoring_unconfigured';
  end if;
  if v_carrier.factoring_mode = 'direct' then
    return null; -- direct billing, no factor snapshot required
  end if;

  -- factoring_mode = 'factored' from here -- the classifier must return
  -- EXACTLY 'ready' (Section H), using the SAME carrier-scoped classifier
  -- 0139/0141 already established, called with THIS invoice's own
  -- recipient so a broker/customer-specific ineligibility/exception is
  -- correctly taken into account.
  v_classification := public.classify_carrier_factoring_readiness(v_inv.carrier_id, v_inv.recipient_broker_id, v_inv.recipient_customer_id);
  if not (v_classification->>'success')::boolean then
    return 'factoring_classifier_error';
  end if;
  if v_classification->>'classification' <> 'ready' then
    return 'factoring_not_ready:' || (v_classification->>'classification');
  end if;
  return null;
end;
$fn$;

revoke all on function public.carrier_invoice_factoring_readiness_problem(uuid) from public, anon, authenticated;

comment on function public.carrier_invoice_factoring_readiness_problem(uuid) is
  'Read-only. carrier_freight_invoice only (always null for dispatch_service_invoice). unconfigured carrier -> blocked; direct carrier -> null (no factor needed); factored carrier -> requires classify_carrier_factoring_readiness() = exactly ready.';

-- Aggregate issuance-readiness classifier -- everything an invoice must
-- satisfy before the (future) issuance RPC may proceed. Read-only; never
-- allocates a number or writes a snapshot.
create function public.carrier_invoice_issuance_problem(p_invoice_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_inv record;
  v_problem text;
  v_load_count integer;
begin
  select organization_id, invoice_document_type, carrier_id, issuance_status, total_amount
    into v_inv
  from public.carrier_invoices where id = p_invoice_id;
  if v_inv.organization_id is null then
    return 'invoice_not_found';
  end if;
  if v_inv.issuance_status not in ('draft', 'ready_for_issue') then
    return 'already_issued_or_beyond';
  end if;

  v_problem := public.carrier_invoice_recipient_problem(p_invoice_id);
  if v_problem is not null then return v_problem; end if;

  if v_inv.invoice_document_type = 'carrier_freight_invoice' then
    v_problem := public.carrier_invoice_factoring_readiness_problem(p_invoice_id);
    if v_problem is not null then return v_problem; end if;

    if not exists (select 1 from public.carriers where id = v_inv.carrier_id and invoice_code is not null) then
      return 'carrier_missing_invoice_code';
    end if;

    select count(*) into v_load_count from public.carrier_invoice_loads where invoice_id = p_invoice_id;
    if v_load_count = 0 then
      return 'no_loads_attached';
    end if;
  end if;

  if v_inv.total_amount <= 0 then
    return 'total_not_positive';
  end if;

  return null;
end;
$fn$;

revoke all on function public.carrier_invoice_issuance_problem(uuid) from public, anon, authenticated;

comment on function public.carrier_invoice_issuance_problem(uuid) is
  'Read-only aggregate readiness classifier for the (future) 0143 issuance RPC: recipient + factoring (freight only) + carrier numbering prerequisite + load attachment (freight only) + positive total. Returns null when the invoice may proceed to issuance.';

-- ======================= PHASE 12B -- guarded draft-update RPC ==============
-- Phase 3B.3A.2 Section B: the ONLY way any authenticated role may change
-- due_date/payment_terms_days/broker_id/customer_id/currency (notes also
-- has a direct column grant, Phase 11, so it may be set either way).
--
-- Uses an explicit jsonb PATCH object with a strict, flat allowlist
-- (Section B: "reject every unknown key recursively... do not use
-- unrestricted dynamic SQL") instead of individual nullable SQL
-- parameters -- a plain `p_due_date date default null` parameter cannot
-- distinguish "leave due_date unchanged" from "clear due_date to NULL";
-- presence/absence of a KEY in the patch resolves that ambiguity exactly.
-- Every allowed value is a scalar (string/number/null) -- a nested
-- object/array under any key fails jsonb_typeof validation immediately,
-- which is what actually makes key-smuggling via nesting impossible
-- ("reject unknown keys recursively") without needing a separate
-- recursive walk for this simple, flat field set.
--
-- STRICT VALIDATE-THEN-WRITE ordering: every check (idempotency,
-- patch shape, role/key permission, financial-reason requirement, row
-- lock/found/org/status/staleness, field type/format, recipient
-- existence+eligibility) happens BEFORE the first UPDATE statement. No
-- code path performs a partial write and then returns a failure --
-- "never report structured failure as success" (and never leave a
-- half-applied mutation behind either).
create function public.update_carrier_invoice_draft(
  p_invoice_id uuid,
  p_patch jsonb,
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
  v_org uuid;
  v_row record;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_fingerprint text;
  v_lock_key bigint;
  v_patch_keys text[];
  v_master_keys constant text[] := array['notes','due_date','payment_terms_days','broker_id','customer_id','currency'];
  v_financial_keys constant text[] := array['broker_id','customer_id','currency','payment_terms_days'];
  v_role_keys text[];
  v_new_notes text;
  v_new_due_date date;
  v_has_due_date boolean := false;
  v_new_payment_terms_days integer;
  v_has_payment_terms boolean := false;
  v_new_currency text;
  v_touches_recipient boolean := false;
  v_new_recipient_type public.invoice_recipient_type;
  v_new_broker_id uuid;
  v_new_customer_id uuid;
  v_party_status public.carrier_party_status;
  v_changed_fields text[] := '{}';
  v_result jsonb;
begin
  ------------------------------------------------------------------
  -- VALIDATE (nothing below this comment block, until the marked
  -- APPLY section, ever writes to carrier_invoices).
  ------------------------------------------------------------------
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'p_patch must be a JSON object.');
  end if;

  -- Phase 3B.3A.3 (Section A/B): final lock order, in this exact
  -- sequence, closing the last idempotency-collision gap --
  --   1. read invoice identity (p_invoice_id) WITHOUT trusting it yet
  --      (just a parameter at this point -- validated below);
  --   2. derive organization from the authenticated session;
  --   3. acquire an organization+operation+idempotency-key ADVISORY
  --      LOCK, scoped narrowly (never a global/cross-tenant lock --
  --      org_id is baked into the hashed key, so two different
  --      organizations reusing the identical key string never contend
  --      with each other at all);
  --   4. lock the invoice row (FOR UPDATE);
  --   5. re-read/revalidate organization + not-found (indistinguishable)
  --      from that SAME locked row -- never trust the pre-lock read;
  --   6. resolve any existing idempotency record -- now fully
  --      serialized against every other caller sharing this exact
  --      (org, operation, key) tuple, regardless of which invoice each
  --      one targets, which is exactly the gap the previous phase's
  --      invoice-only row lock did not close;
  --   7. validate the patch (role/fields/reason);
  --   8. mutate;
  --   9. audit (exactly one event per successful call);
  --   10. store the success result (with a narrow, defensive fallback
  --       for the now-vanishingly-rare case the advisory lock alone
  --       cannot cover -- see the INSERT's own exception handler below).
  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  -- Section A item 8/9/13: deterministic, canonical, randomness-free.
  -- p_patch::text on a JSONB value is ALREADY canonical regardless of
  -- input key order or nesting depth -- Postgres's jsonb storage
  -- normalizes key order on parse, confirmed empirically (a{"b":1,"a":2}
  -- and {"a":2,"b":1} serialize identically), so no separate key-sorting
  -- step is needed. Item 5: p_expected_updated_at is included so "same
  -- key + different expected version" is treated as a DIFFERENT logical
  -- request (IDEMPOTENCY_KEY_REUSED) unless it is the exact original
  -- retry contract (same key + same invoice + same patch + same reason +
  -- same expected version) -- the documented, deterministic choice for
  -- item 5. Item 14: there is no client-supplied-fingerprint parameter
  -- anywhere in this function's signature -- it is always computed here,
  -- server-side, from the caller's actual validated inputs.
  v_fingerprint := md5(
    coalesce(p_invoice_id::text, '') || '|' ||
    p_patch::text || '|' ||
    coalesce(p_reason, '') || '|' ||
    coalesce(p_expected_updated_at::text, '')
  );

  -- Item 7: scope includes organization AND operation ('update_draft'),
  -- never just the bare key -- two different RPCs (or a future one)
  -- reusing the same key string by coincidence never collide.
  v_lock_key := hashtextextended(v_org::text || '|update_draft|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select id, organization_id, invoice_document_type, issuance_status, updated_at, carrier_id,
         recipient_type, recipient_broker_id, recipient_customer_id
    into v_row
  from public.carrier_invoices where id = p_invoice_id for update;

  -- "Not found" and "belongs to another organization" are deliberately
  -- indistinguishable (item 6: also true for a same-key collision from a
  -- different organization -- the idempotency lookup below is itself
  -- organization-scoped, so another tenant's use of the identical key
  -- string is structurally invisible, never revealed by any code path).
  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_invoice_lifecycle_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_row.issuance_status not in ('draft', 'ready_for_issue') then
    return jsonb_build_object('success', false, 'code', 'NOT_EDITABLE', 'message', 'Only a draft or ready-for-issue invoice can be edited through this RPC.');
  end if;
  if v_row.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This invoice has changed since you loaded it. Reload and try again.');
  end if;

  select array_agg(k) into v_patch_keys from jsonb_object_keys(p_patch) k;
  v_patch_keys := coalesce(v_patch_keys, '{}');
  if not (v_patch_keys <@ v_master_keys) then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Unknown field in patch.');
  end if;
  if array_length(v_patch_keys, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'No recognized field was provided to change.');
  end if;

  if public.has_role(array['owner', 'admin']::public.org_role[]) then
    v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'broker_id', 'customer_id', 'currency'];
  elsif public.has_role(array['accountant']::public.org_role[]) then
    v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'currency'];
  elsif public.has_role(array['dispatcher']::public.org_role[]) then
    v_role_keys := array['notes'];
  else
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to edit this invoice.');
  end if;

  if not (v_patch_keys <@ v_role_keys) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'One or more fields in this patch are not permitted for your role.');
  end if;

  if (v_patch_keys && v_financial_keys) and (p_reason is null or btrim(p_reason) = '') then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A reason is required to change billing/recipient fields.');
  end if;

  -- ---- validate each field's shape/value (still no writes) ----
  if p_patch ? 'notes' then
    if jsonb_typeof(p_patch->'notes') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'notes must be a string or null.');
    end if;
    v_new_notes := p_patch->>'notes';
  end if;

  if p_patch ? 'due_date' then
    if jsonb_typeof(p_patch->'due_date') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'due_date must be a date string or null.');
    end if;
    begin
      v_new_due_date := nullif(p_patch->>'due_date', '')::date;
      v_has_due_date := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'due_date is not a valid date.');
    end;
  end if;

  if p_patch ? 'payment_terms_days' then
    if jsonb_typeof(p_patch->'payment_terms_days') not in ('number', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be a number or null.');
    end if;
    begin
      v_new_payment_terms_days := (p_patch->>'payment_terms_days')::integer;
      v_has_payment_terms := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days is not a valid integer.');
    end;
    if v_new_payment_terms_days is not null and (v_new_payment_terms_days < 0 or v_new_payment_terms_days > 365) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be between 0 and 365.');
    end if;
  end if;

  if p_patch ? 'currency' then
    if jsonb_typeof(p_patch->'currency') <> 'string' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a string.');
    end if;
    v_new_currency := p_patch->>'currency';
    if v_new_currency !~ '^[A-Z]{3}$' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a 3-letter uppercase code.');
    end if;
  end if;

  -- ---- recipient change (broker_id / customer_id) -- still no writes ----
  if (p_patch ? 'broker_id') or (p_patch ? 'customer_id') then
    if v_row.invoice_document_type = 'dispatch_service_invoice' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A dispatch-service invoice cannot receive a broker/customer recipient.');
    end if;
    v_touches_recipient := true;

    if (p_patch ? 'broker_id') and jsonb_typeof(p_patch->'broker_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id must be a uuid string or null.');
    end if;
    if (p_patch ? 'customer_id') and jsonb_typeof(p_patch->'customer_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'customer_id must be a uuid string or null.');
    end if;

    begin
      v_new_broker_id := case when p_patch ? 'broker_id' then nullif(p_patch->>'broker_id', '')::uuid else v_row.recipient_broker_id end;
      v_new_customer_id := case when p_patch ? 'customer_id' then nullif(p_patch->>'customer_id', '')::uuid else v_row.recipient_customer_id end;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id/customer_id must be valid uuids.');
    end;

    if (v_new_broker_id is not null) = (v_new_customer_id is not null) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Exactly one of broker_id or customer_id must be set for a freight invoice.');
    end if;
    v_new_recipient_type := case when v_new_broker_id is not null then 'broker' else 'customer' end;

    -- Cross-organization / never-existed is deliberately indistinguishable.
    -- Eligibility (active status, a genuine carrier-party relationship)
    -- is checked here, BEFORE any write, mirroring carrier_invoice_
    -- recipient_problem()'s own logic (which cannot itself be called yet
    -- here -- it reads the row's CURRENT, not-yet-updated recipient).
    if v_new_broker_id is not null then
      if not exists (select 1 from public.brokers where id = v_new_broker_id and organization_id = v_org and not is_blacklisted) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected broker is not available.');
      end if;
      select status into v_party_status from public.carrier_brokers where carrier_id = v_row.carrier_id and broker_id = v_new_broker_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected broker.');
      end if;
    else
      if not exists (select 1 from public.customers where id = v_new_customer_id and organization_id = v_org and is_active) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected customer is not available.');
      end if;
      select status into v_party_status from public.carrier_customers where carrier_id = v_row.carrier_id and customer_id = v_new_customer_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected customer.');
      end if;
    end if;
  end if;

  ------------------------------------------------------------------
  -- APPLY -- every validation above has already passed; from here on
  -- nothing may fail for a reason the caller could have anticipated.
  --
  -- Section A item 15 + item 10 ("a collision must produce no invoice
  -- update and no audit event"): the mutation, the audit event, AND the
  -- idempotency-record insert are wrapped in ONE nested block together
  -- (plpgsql's BEGIN/EXCEPTION implicitly opens a savepoint at its
  -- start). If the final INSERT below ever hits unique_violation on
  -- civ_idempotency_unique -- which, with the advisory lock already
  -- held, should be structurally unreachable for any caller going
  -- through this function; this is defense-in-depth for an out-of-band
  -- anomaly only -- the WHOLE block, mutation and audit event included,
  -- rolls back to that savepoint before this function returns its
  -- structured failure, so a collision truly produces zero mutation and
  -- zero audit event, never a partial success behind a reported failure.
  -- Any OTHER exception (a genuinely unrelated integrity failure) is
  -- re-raised unchanged, exactly as item 15 requires -- never mislabeled
  -- as an idempotency collision.
  ------------------------------------------------------------------
  begin
    if p_patch ? 'notes' then
      update public.carrier_invoices set notes = v_new_notes where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'notes');
    end if;
    if v_has_due_date then
      update public.carrier_invoices set due_date = v_new_due_date where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'due_date');
    end if;
    if v_has_payment_terms then
      update public.carrier_invoices set payment_terms_days = v_new_payment_terms_days where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'payment_terms_days');
    end if;
    if p_patch ? 'currency' then
      update public.carrier_invoices set currency = v_new_currency where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'currency');
    end if;
    if v_touches_recipient then
      update public.carrier_invoices
        set recipient_type = v_new_recipient_type, recipient_broker_id = v_new_broker_id, recipient_customer_id = v_new_customer_id
        where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'recipient');
    end if;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_draft_updated',
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields), 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'UPDATED', 'invoice_id', p_invoice_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'updated_at', (select updated_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency (organization_id, idempotency_key, invoice_id, action, request_fingerprint, result)
    values (v_org, p_idempotency_key, p_invoice_id, 'update_draft', v_fingerprint, v_result);
  exception
    when unique_violation then
      declare
        v_constraint text;
      begin
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'civ_idempotency_unique' then
          raise;
        end if;
      end;
      -- The whole APPLY block above (mutation + audit event + this same
      -- INSERT attempt) has already been rolled back to the savepoint at
      -- this point -- the row is exactly as it was before this call.
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_invoice_lifecycle_idempotency
      where organization_id = v_org and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

grant execute on function public.update_carrier_invoice_draft(uuid, jsonb, timestamptz, text, text) to authenticated;

comment on function public.update_carrier_invoice_draft(uuid, jsonb, timestamptz, text, text) is
  'Phase 3B.3A.2 Section B (Phase 3B.3A.3 Section A/B: idempotency-collision closure) -- the ONLY guarded path for due_date/payment_terms_days/broker_id/customer_id/currency changes (notes also has a direct column grant). p_patch is a strict, flat allowlisted JSON object -- presence of a key means "set it" (including to JSON null), absence means "leave unchanged". Role-gated: owner/admin get the full field set; accountant gets billing fields (due_date/payment_terms_days/currency) + notes; dispatcher gets notes only; driver/viewer are FORBIDDEN immediately. Only draft/ready_for_issue invoices are editable. carrier_id/invoice_document_type/issuance_status/payment_status/invoice_number/totals/snapshot identity are NEVER in the patch allowlist -- structurally immutable through this RPC, not merely unused. Lock order: derive organization -> acquire a pg_advisory_xact_lock scoped to (organization, ''update_draft'', idempotency_key) -> lock the invoice row -> revalidate org/not-found from that locked row -> resolve idempotency -> validate -> mutate+audit+idempotency-insert as one atomic block. The advisory lock (never a bare global lock -- organization_id is baked into the hashed key) fully serializes every caller sharing the same (org, operation, key) tuple regardless of which invoice each targets, closing the same-key/different-invoice race a prior pass left open; a client never receives a raw constraint name, SQL text, or internal identifier -- only IDEMPOTENCY_KEY_REUSED. The request fingerprint (deterministic, canonical, no randomness, never client-supplied) covers invoice id + patch + reason + expected_updated_at, so a replayed key with ANY different logical input -- including a different expected version -- is rejected as reused rather than silently replayed or applied; jsonb''s own key-order canonicalization means logically identical patches with differently-ordered keys always fingerprint identically. Optimistic concurrency (STALE_RECORD); exactly one log_activity() audit event per successful call, zero for a collision (the mutation+audit+insert are one savepoint-scoped block, rolled back together on collision); every validation happens before the first write.';

-- ======================= PHASE 13 -- legacy invoice classification =========
-- Section J: existing public.invoices rows are classified, NEVER
-- mutated, NEVER backfilled into the new snapshot model. This migration
-- writes zero rows here -- scan_legacy_invoices_for_carrier_migration()
-- is callable but not invoked by this migration.
create table public.legacy_invoice_carrier_migration_review (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  legacy_invoice_id uuid not null references public.invoices (id) on delete cascade,
  classification text not null,
  detail jsonb,
  reviewed boolean not null default false,
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  resolution text,
  review_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint livcr_legacy_invoice_uq unique (legacy_invoice_id),
  -- Mirrors cinv_void_fields_iff_voided's own "fields only iff state"
  -- shape: reviewed=true requires the review identity to be fully
  -- populated together, atomically, and never partially.
  constraint livcr_review_fields_iff_reviewed check (
    (reviewed and reviewed_by is not null and reviewed_at is not null and resolution is not null and btrim(resolution) <> '')
    or (not reviewed and reviewed_by is null and reviewed_at is null)
  )
);

create index idx_legacy_invoice_carrier_migration_review_org on public.legacy_invoice_carrier_migration_review (organization_id);
create index idx_legacy_invoice_carrier_migration_review_classification on public.legacy_invoice_carrier_migration_review (classification) where not reviewed;

drop trigger if exists set_updated_at on public.legacy_invoice_carrier_migration_review;
create trigger set_updated_at before update on public.legacy_invoice_carrier_migration_review
  for each row execute function public.set_updated_at();

-- Phase 3B.3A.1 correction (Section C): the original design granted
-- authenticated a direct column-level UPDATE on reviewed/reviewed_by/
-- reviewed_at, which permits audit identity/time forgery (any
-- authenticated org member could claim to be any profile id, at any
-- timestamp). This table is now READ-ONLY to every client role, full
-- stop -- INSERT/UPDATE/DELETE are all revoked from authenticated/anon.
-- The ONLY mutation path, for both the initial scan AND every review, is
-- a SECURITY DEFINER function (scan_legacy_invoices_for_carrier_migration
-- / review_legacy_invoice_carrier_migration below), which runs as its
-- owner and is therefore entirely unaffected by this revoke.
revoke insert, update, delete on public.legacy_invoice_carrier_migration_review from authenticated;
revoke all on public.legacy_invoice_carrier_migration_review from anon;

alter table public.legacy_invoice_carrier_migration_review enable row level security;

create policy legacy_invoice_carrier_migration_review_select
  on public.legacy_invoice_carrier_migration_review for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

comment on table public.legacy_invoice_carrier_migration_review is
  'Section J (Phase 3B.3A.1, Section C correction): read-only to EVERY client role, with zero exception -- reviewed/reviewed_by/reviewed_at/resolution/review_notes are settable ONLY by review_legacy_invoice_carrier_migration() (owner/admin only), which derives reviewed_by from auth.uid() and reviewed_at from the database clock, never from client input. classification/detail/legacy_invoice_id are populated ONLY by scan_legacy_invoices_for_carrier_migration(). All existing invoices remain legacy and ineligible for the new factoring submission workflow until explicitly reviewed and reissued.';

-- Idempotency for the review RPC below -- mirrors carrier_invoice_
-- lifecycle_idempotency / factoring_integration_lifecycle_idempotency
-- (0141) exactly: no client write path, keyed per organization.
create table public.legacy_invoice_review_idempotency (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  idempotency_key text not null,
  review_id uuid not null references public.legacy_invoice_carrier_migration_review (id) on delete cascade,
  result jsonb not null,
  created_at timestamptz not null default now(),
  constraint livcr_idempotency_unique unique (organization_id, idempotency_key)
);

revoke insert, update, delete on public.legacy_invoice_review_idempotency from authenticated;
revoke all on public.legacy_invoice_review_idempotency from anon;

alter table public.legacy_invoice_review_idempotency enable row level security;

create policy legacy_invoice_review_idempotency_select
  on public.legacy_invoice_review_idempotency for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin']::public.org_role[]));

-- Read-only classifier -- given one legacy invoice id, returns its
-- classification WITHOUT writing anything. classify_legacy_invoice_for_
-- carrier_migration() and the scan procedure below share this exact
-- decision logic so the two can never disagree.
create function public.classify_legacy_invoice_for_carrier_migration(p_invoice_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_inv record;
  v_load record;
  v_factored_count integer;
begin
  select id, organization_id, status, load_id, broker_id, customer_id, amount_paid, total_amount
    into v_inv
  from public.invoices where id = p_invoice_id;
  if v_inv.id is null then
    return 'not_found';
  end if;

  if v_inv.status = 'void' then
    return 'voided_cancelled';
  end if;
  if v_inv.status = 'paid' or (v_inv.amount_paid > 0 and v_inv.amount_paid < v_inv.total_amount) then
    return 'paid_or_partially_paid';
  end if;

  select count(*) into v_factored_count from public.factored_invoices where invoice_id = p_invoice_id;
  if v_factored_count > 0 then
    return 'existing_factoring_activity';
  end if;

  if v_inv.broker_id is not null and v_inv.customer_id is not null then
    return 'conflicting_recipient_evidence';
  end if;
  if v_inv.broker_id is null and v_inv.customer_id is null then
    return 'missing_recipient';
  end if;

  if v_inv.load_id is null then
    -- No load to derive a carrier from at all, and this legacy schema
    -- never stored carrier_id directly on invoices -- there is genuinely
    -- no carrier evidence to look at.
    return 'missing_carrier_evidence';
  end if;

  select carrier_id, carrier_resolution into v_load from public.loads where id = v_inv.load_id;
  if v_load.carrier_id is null then
    return 'missing_carrier_evidence';
  end if;
  if v_load.carrier_resolution = 'conflicting' then
    return 'conflicting_carrier_evidence';
  end if;
  if v_load.carrier_resolution = 'unresolved' then
    return 'missing_carrier_evidence';
  end if;

  return 'safely_identifiable_legacy';
end;
$fn$;

revoke all on function public.classify_legacy_invoice_for_carrier_migration(uuid) from public, anon, authenticated;

comment on function public.classify_legacy_invoice_for_carrier_migration(uuid) is
  'Read-only. Classifications: not_found, voided_cancelled, paid_or_partially_paid, existing_factoring_activity, conflicting_recipient_evidence, missing_recipient, missing_carrier_evidence, conflicting_carrier_evidence, safely_identifiable_legacy. Never mutates public.invoices. "safely_identifiable_legacy" still means LEGACY -- ineligible for the new factoring workflow until explicitly reviewed and reissued (Section J).';

-- Callable, NOT auto-run. A human (or a later, explicitly reviewed
-- migration) invokes this to populate the review table. This migration
-- itself never calls it -- zero rows are written here, zero existing
-- invoices rows are read-and-acted-upon automatically.
create function public.scan_legacy_invoices_for_carrier_migration()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_row record;
  v_classification text;
  v_count integer := 0;
begin
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'scan_legacy_invoices_for_carrier_migration: owner or admin only.' using errcode = '42501';
  end if;

  for v_row in select id, organization_id from public.invoices where organization_id = public.current_org_id() loop
    v_classification := public.classify_legacy_invoice_for_carrier_migration(v_row.id);
    insert into public.legacy_invoice_carrier_migration_review (organization_id, legacy_invoice_id, classification)
    values (v_row.organization_id, v_row.id, v_classification)
    on conflict (legacy_invoice_id) do update set classification = excluded.classification, updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$fn$;

grant execute on function public.scan_legacy_invoices_for_carrier_migration() to authenticated;

comment on function public.scan_legacy_invoices_for_carrier_migration() is
  'Owner/admin only, explicitly invoked (never automatic). Classifies every existing public.invoices row in the caller''s organization via classify_legacy_invoice_for_carrier_migration() and upserts the result into legacy_invoice_carrier_migration_review. Writes ONLY that review table -- public.invoices itself is read-only here, never mutated.';

-- ---------------------------------------------------------------------------
-- review_legacy_invoice_carrier_migration: Section C's guarded RPC -- the
-- ONLY way reviewed/reviewed_by/reviewed_at/resolution/review_notes can
-- ever be set. Owner/admin only (Section C: "prevent dispatcher/
-- accountant/driver/viewer review unless explicitly authorized" -- no
-- explicit authorization was given for any wider tier, so this stays as
-- narrow as scan_legacy_invoices_for_carrier_migration() itself).
--   * organization is DERIVED from the target row (never a parameter) --
--     rejects cross-organization access before revealing whether the row
--     even exists for a mismatched org (same "not found" vs "wrong org"
--     indistinguishability convention as invoices/actions.ts).
--   * reviewed_by is DERIVED from auth.uid() -- there is no p_reviewed_by
--     parameter in this signature at all, structurally, so a client
--     cannot even attempt to pass one.
--   * reviewed_at is DERIVED from now() (the database clock) -- there is
--     no p_reviewed_at parameter either.
--   * p_resolution is REQUIRED and must be non-empty (Section C: "require
--     a meaningful reason or resolution note").
--   * p_expected_updated_at enforces optimistic concurrency (STALE_RECORD
--     on mismatch) -- same convention as every other guarded RPC in this
--     schema (0138-0141).
--   * p_idempotency_key enforces deterministic idempotency -- an identical
--     key replays the exact original result rather than re-reviewing.
--   * writes exactly ONE audit event via the existing log_activity()
--     convention (entity_type='invoice', entity_id=legacy_invoice_id --
--     the genuine public.invoices row this review concerns).
--   * re-review is permitted (the row can be reviewed more than once --
--     e.g. a correction) but the row itself only ever holds the LATEST
--     reviewed_by/reviewed_at/resolution/review_notes; history is
--     preserved via the log_activity() audit trail (Section C: "preserve
--     review history rather than overwriting the only evidence" -- the
--     activity_logs row from the prior review is never deleted or
--     altered, so the only-evidence risk that phrase warns about does not
--     apply here).
-- ---------------------------------------------------------------------------
create function public.review_legacy_invoice_carrier_migration(
  p_review_id uuid,
  p_resolution text,
  p_notes text,
  p_expected_updated_at timestamptz,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_row record;
  v_cached jsonb;
  v_result jsonb;
begin
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  select result into v_cached from public.legacy_invoice_review_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached is not null then
    return v_cached;
  end if;

  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only an owner or admin may review a legacy invoice classification.');
  end if;

  if p_resolution is null or btrim(p_resolution) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A meaningful resolution is required.');
  end if;

  -- Row-lock BEFORE the organization/staleness checks so two concurrent
  -- reviews of the SAME row can never both pass the staleness check --
  -- the second waits for the first's transaction to commit (or roll
  -- back) before evaluating its own updated_at comparison.
  select id, organization_id, legacy_invoice_id, updated_at into v_row
  from public.legacy_invoice_carrier_migration_review
  where id = p_review_id
  for update;

  if v_row.id is null then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Review record not found.');
  end if;
  -- "Not found" and "belongs to another organization" are deliberately
  -- indistinguishable -- a forged review id from another tenant must
  -- never learn whether it exists elsewhere.
  if v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Review record not found.');
  end if;
  if v_row.updated_at <> p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This review record has changed since you loaded it. Reload and try again.');
  end if;

  update public.legacy_invoice_carrier_migration_review
    set reviewed = true,
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        resolution = btrim(p_resolution),
        review_notes = p_notes
    where id = p_review_id;

  perform public.log_activity('invoice'::public.entity_type, v_row.legacy_invoice_id, 'carrier_migration_reviewed',
    jsonb_build_object('review_id', p_review_id, 'resolution', btrim(p_resolution), 'notes', p_notes));

  v_result := jsonb_build_object(
    'success', true, 'code', 'REVIEWED', 'review_id', p_review_id,
    'reviewed_by', auth.uid(), 'reviewed_at', now(), 'resolution', btrim(p_resolution)
  );

  insert into public.legacy_invoice_review_idempotency (organization_id, idempotency_key, review_id, result)
  values (v_org, p_idempotency_key, p_review_id, v_result);

  return v_result;
end;
$fn$;

grant execute on function public.review_legacy_invoice_carrier_migration(uuid, text, text, timestamptz, text) to authenticated;

comment on function public.review_legacy_invoice_carrier_migration(uuid, text, text, timestamptz, text) is
  'Phase 3B.3A.1 Section C: the ONLY path that can ever set reviewed/reviewed_by/reviewed_at/resolution/review_notes. Owner/admin only. Derives organization from the target row (rejects cross-organization access), reviewed_by from auth.uid(), reviewed_at from now() -- never from client input, so identity/time cannot be forged even by a service-role-backed ordinary action. Enforces optimistic concurrency (STALE_RECORD) and deterministic idempotency. Writes exactly one log_activity() audit event per successful call.';

-- ======================= PHASE 14 -- POSTCONDITIONS =========================
do $mig$
begin
  if to_regclass('public.carrier_invoices') is null then
    raise exception '0142 postcondition: public.carrier_invoices was not created.';
  end if;
  if (select count(*) from pg_trigger where tgname = 'a0142_guard_lifecycle_transition') <> 1 then
    raise exception '0142 postcondition: lifecycle transition guard missing.';
  end if;
  if (select count(*) from pg_trigger where tgname = 'a0142_guard_snapshot_immutable') <> 1 then
    raise exception '0142 postcondition: snapshot immutability guard missing.';
  end if;
  if has_table_privilege('service_role', 'public.carrier_invoice_issuance_snapshots', 'INSERT')
    or has_table_privilege('authenticated', 'public.carrier_invoice_issuance_snapshots', 'INSERT') then
    raise exception '0142 postcondition: a role still has direct INSERT on carrier_invoice_issuance_snapshots.';
  end if;
  if to_regprocedure('public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)') is null then
    raise exception '0142 postcondition: numbering mechanism function missing.';
  end if;
  if exists (
    select 1 from pg_proc where proname = '_generate_carrier_invoice_number_internal' and pronamespace = 'public'::regnamespace
  ) and has_function_privilege('authenticated', 'public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)', 'EXECUTE') then
    raise exception '0142 postcondition: authenticated still has EXECUTE on the private numbering mechanism.';
  end if;
  if to_regclass('public.legacy_invoice_carrier_migration_review') is null then
    raise exception '0142 postcondition: legacy_invoice_carrier_migration_review was not created.';
  end if;
  if (select count(*) from public.legacy_invoice_carrier_migration_review) <> 0 then
    raise exception '0142 postcondition: legacy_invoice_carrier_migration_review must start empty -- this migration must never auto-scan.';
  end if;

  -- Phase 3B.3A.1 corrections:
  if exists (select 1 from pg_type where typname = 'invoice_lifecycle_status') then
    raise exception '0142 postcondition: the old, mixed invoice_lifecycle_status enum must not exist -- it must be fully replaced by invoice_issuance_status + invoice_payment_status.';
  end if;
  if not exists (select 1 from pg_type where typname = 'invoice_issuance_status') or not exists (select 1 from pg_type where typname = 'invoice_payment_status') then
    raise exception '0142 postcondition: invoice_issuance_status / invoice_payment_status enums missing.';
  end if;
  if exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'invoice_issuance_status' and e.enumlabel in ('partially_paid', 'paid', 'disputed')) then
    raise exception '0142 postcondition: invoice_issuance_status must never contain a payment or dispute value.';
  end if;
  if has_table_privilege('authenticated', 'public.carrier_invoice_issuance_snapshots', 'INSERT') then
    raise exception '0142 postcondition: authenticated still has INSERT on carrier_invoice_issuance_snapshots (already checked above too).';
  end if;
  if has_column_privilege('authenticated', 'public.carrier_invoices', 'organization_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'invoice_number', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'payment_status', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'amount_paid', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'total_amount', 'UPDATE') then
    raise exception '0142 postcondition: authenticated must not have direct UPDATE on organization_id/invoice_number/payment_status/amount_paid/total_amount.';
  end if;
  if not has_column_privilege('authenticated', 'public.carrier_invoices', 'notes', 'UPDATE') then
    raise exception '0142 postcondition: authenticated should still have UPDATE on the safe operational column notes.';
  end if;
  if has_table_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'UPDATE')
    or has_column_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'reviewed_by', 'UPDATE')
    or has_column_privilege('authenticated', 'public.legacy_invoice_carrier_migration_review', 'reviewed_at', 'UPDATE') then
    raise exception '0142 postcondition: authenticated must have ZERO direct UPDATE (table or column) on legacy_invoice_carrier_migration_review -- review_legacy_invoice_carrier_migration() is the only path.';
  end if;
  if not has_function_privilege('authenticated', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE') then
    raise exception '0142 postcondition: review_legacy_invoice_carrier_migration() should be EXECUTE-able by authenticated (its own internal owner/admin check gates actual use).';
  end if;
  if to_regprocedure('public.jsonb_contains_forbidden_key(jsonb,text[])') is null then
    raise exception '0142 postcondition: jsonb_contains_forbidden_key(jsonb,text[]) missing.';
  end if;

  -- Phase 3B.3A.2 corrections:
  if has_column_privilege('authenticated', 'public.carrier_invoices', 'carrier_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'invoice_document_type', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'recipient_type', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'recipient_broker_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'recipient_customer_id', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'currency', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'due_date', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'payment_terms_days', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'issuance_status', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'voided_at', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'voided_by', 'UPDATE')
    or has_column_privilege('authenticated', 'public.carrier_invoices', 'void_reason', 'UPDATE') then
    raise exception '0142 postcondition (3B.3A.2): authenticated must have ZERO direct UPDATE grant on carrier_id/invoice_document_type/recipient_*/currency/due_date/payment_terms_days/issuance_status/voided_*/void_reason -- notes is the only granted column.';
  end if;
  if to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is null then
    raise exception '0142 postcondition (3B.3A.2): update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) missing.';
  end if;
  if not has_function_privilege('authenticated', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0142 postcondition (3B.3A.2): authenticated should be able to EXECUTE update_carrier_invoice_draft (its own internal role/field checks gate actual use).';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='request_fingerprint') then
    raise exception '0142 postcondition (3B.3A.2): carrier_invoice_lifecycle_idempotency.request_fingerprint missing.';
  end if;

  -- Phase 3B.3A.3 correction: structural proxy confirming the
  -- advisory-lock-based idempotency-collision fix is actually present
  -- (not just that the function exists) -- source-inspects for the
  -- specific mechanism, matching this schema's own established
  -- "structural proxy, not just presence" postcondition convention.
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%pg_advisory_xact_lock%' then
    raise exception '0142 postcondition (3B.3A.3): update_carrier_invoice_draft() no longer acquires the organization+operation+idempotency-key advisory lock.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%hashtextextended%' then
    raise exception '0142 postcondition (3B.3A.3): update_carrier_invoice_draft() no longer derives its advisory-lock key from organization+operation+idempotency-key.';
  end if;

  raise notice '0142 complete (Phase 3B.3A.1 + 3B.3A.2 + 3B.3A.3 corrections): carrier_invoices separates issuance_status (draft/ready_for_issue/issued/voided) from payment_status (unpaid/partially_paid/paid); authenticated has EXACTLY ONE directly-grantable column on carrier_invoices (notes) -- carrier_id/invoice_document_type/recipient_*/currency/due_date/payment_terms_days/issuance_status/voided_*/void_reason/payment fields/totals/invoice_number all have zero direct grant, for every role, with no exception; update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) is the sole guarded path for due_date/payment_terms_days/broker_id/customer_id/currency (role-tiered: owner/admin full set, accountant billing fields, dispatcher notes only, driver/viewer refused), using a strict-allowlist jsonb patch, validate-then-write ordering, an organization+operation+idempotency-key advisory lock (acquired before the invoice row lock) that closes the same-key/different-invoice collision race, a canonical randomness-free request fingerprint covering invoice id + patch + reason + expected_updated_at, and a narrow (constraint-name-checked) defensive fallback that never mislabels an unrelated integrity failure as a collision; issuance_status transitions (ready_for_issue/issued/voided) and void_reason/voided_at/voided_by remain reachable by NO authenticated role, direct or via RPC -- fully deferred to 0143; carrier_invoice_issuance_snapshots remains immutable by trigger for every role with zero INSERT grants; snapshot_payload must be a JSON object with zero forbidden credential-shaped keys at ANY depth; legacy_invoice_carrier_migration_review remains READ-ONLY to every client role with review_legacy_invoice_carrier_migration() as the sole mutation path. No issuance RPC. No void RPC. No ready-for-issue RPC. No payment RPC. No delivery. No QuickBooks. No PDF. Migrations 0001-0141 untouched.';
end
$mig$;

commit;
