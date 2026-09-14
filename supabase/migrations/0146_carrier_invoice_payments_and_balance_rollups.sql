-- =============================================================================
-- 0146_carrier_invoice_payments_and_balance_rollups.sql
-- Phase 3B.5 — Carrier Invoice Payments and Atomic Balance Rollups.
--
-- ===========================================================================
-- SECTION A — EXISTING PAYMENT ARCHITECTURE, RE-INSPECTED DIRECTLY
-- ===========================================================================
-- public.payments (0006) is scoped to public.invoices (invoice_id uuid not
-- null references public.invoices) -- the LEGACY broker/customer invoicing
-- model, a completely different table from public.carrier_invoices (0142).
-- apply_payment_to_invoice() (0009, hardened by 0026) is an AFTER INSERT OR
-- UPDATE OR DELETE trigger on public.payments that recalculates
-- public.invoices.amount_paid/status directly from a raw table -- no RPC, no
-- idempotency, no advisory lock, a direct authenticated INSERT/UPDATE/DELETE
-- grant on payments itself (0010's child_tables loop), and status='void'
-- transitions handled ad hoc. This entire mechanism is STRUCTURALLY isolated
-- from carrier_invoices already (different table, different FK target) --
-- Section B's separation is therefore already true by construction; this
-- migration does not touch public.payments/public.invoices/
-- apply_payment_to_invoice() at all.
--
-- 0026_accounts_receivable.sql's own additions to the LEGACY payments table
-- are the most directly relevant PRECEDENT (not a shared dependency) for
-- this migration's own design:
--   - payment_status enum ('posted', 'voided') -- reused here verbatim as
--     the shape for a NEW, carrier_invoice_payments-scoped enum (Section C).
--   - generate_payment_number(): a dedicated SEQUENCE + nextval() wrapped in
--     a SECURITY DEFINER function -- concurrency-safe by construction,
--     explicitly NOT count(*)+1/max()+1. Mirrored here as a brand-new,
--     dedicated sequence (never shared with the legacy one).
--   - guard_payment_amount(): "lock the invoice row FOR UPDATE, THEN check
--     the amount against balance_due" is exactly the concurrency-safety
--     mechanism this migration's own RPCs use (Section D/K), generalized
--     into a guarded RPC instead of an INSERT/UPDATE trigger (matching this
--     schema's own established evolution from trigger-based, 0009/0026, to
--     RPC-based, 0142-0145, for anything touching carrier_invoices).
--   - "no credits/unapplied-cash table exists -- per spec this blocks
--     rather than inventing one" -- the SAME choice this migration makes
--     for overpayment (Section D step 17: OVERPAYMENT, never a credit
--     balance).
--
-- public.carrier_invoices (0142) ALREADY carries everything the balance
-- rollup needs, re-verified by direct re-read:
--   - payment_status public.invoice_payment_status not null default 'unpaid'
--     (enum: unpaid/partially_paid/paid).
--   - amount_paid numeric(12,2) not null default 0.
--   - balance_due numeric(12,2) GENERATED ALWAYS AS (total_amount -
--     amount_paid) STORED -- ALREADY a generated column; Section G's
--     "prefer a generated balance_due column" requirement is therefore
--     ALREADY satisfied by 0142 -- nothing to add or change here.
--   - constraint cinv_payment_status_consistency: (unpaid AND amount_paid=0)
--     OR (partially_paid AND 0<amount_paid<total_amount) OR (paid AND
--     amount_paid=total_amount) -- this IS Section G's exact required
--     invariant, already enforced at the CHECK-constraint level since 0142.
--     This migration's RPCs compute amount_paid/payment_status correctly;
--     this pre-existing constraint is the real backstop against drift.
--   - constraint cinv_payment_requires_issued: payment_status='unpaid' OR
--     issuance_status in ('issued','voided') -- draft/ready_for_issue can
--     never carry a non-unpaid payment_status; already enforced.
--   - authenticated has ZERO direct grant on payment_status/amount_paid
--     (only `notes` is directly grantable, 0142 PHASE 11) -- this
--     migration's two new SECURITY DEFINER RPCs are therefore the ONLY
--     path capable of changing them, exactly matching Section D/E's own
--     "guarded RPC is the sole mutation path" requirement, with zero new
--     grants required on carrier_invoices itself.
--   - guard_carrier_invoice_lifecycle_transition() (0142) explicitly,
--     deliberately EXCLUDES payment_status/amount_paid from its "frozen
--     forever once issued" set (its own comment: "must remain changeable
--     post-issuance by a future payment mechanism" -- this migration IS
--     that mechanism) and never blocks an issuance_status-unchanged UPDATE
--     that only touches amount_paid/payment_status. It also does NOT, by
--     itself, reject a new payment against a 'voided' invoice (the CHECK
--     constraints permit a voided invoice to RETAIN whatever payment_status
--     it had at void time) -- so this migration's own RPC is the one and
--     only place that must explicitly reject posting to a voided invoice
--     (Section D step 10); a real, necessary check, not defense-in-depth.
--   - issuance_status='voided' is a legal enum value with a real CHECK
--     shape (cinv_void_fields_iff_voided) but, as of 0142-0145, has ZERO
--     write path anywhere (no void-invoice RPC exists yet) -- so this
--     migration's own tests reach that state only via a direct, trusted-
--     context UPDATE (matching this codebase's own established convention
--     for simulating a state no legitimate path can reach yet, e.g.
--     TEST_CONCURRENCY_0145's own Scenario 11).
--
-- carrier_invoice_issuance_snapshots (0142) is the authoritative,
-- IMMUTABLE source for payer identity: for a carrier_freight_invoice, the
-- payer is whichever broker/customer the snapshot's own 'recipient' block
-- names (also mirrored, unchanged, onto carrier_invoices.recipient_type/
-- recipient_broker_id/recipient_customer_id once issued -- both sources
-- agree by construction, since the snapshot IS what issuance wrote from
-- the same locked row). For a dispatch_service_invoice, the payer is
-- always the carrier itself (carrier_invoices.carrier_id) -- 0145's own
-- Section A: "Payer: carrier". Re-derived from these already-immutable
-- sources every time; never client-supplied (Section D: "do not trust a
-- client-supplied ... payer").
--
-- The snapshot's own 'factoring' key (0144) is the authoritative source
-- for Section H's factored-invoice boundary: null for a direct carrier or
-- for every dispatch_service_invoice (0145 never populates it); an object
-- with 'factoring_mode':'factored' for a factored carrier_freight_invoice.
-- factored_invoices/factoring_events (0071) are NOT this schema's
-- authoritative factoring-identity source for the NEW carrier_invoices
-- system at all -- they FK to the LEGACY public.invoices table
-- (factored_invoices.invoice_id references public.invoices), a completely
-- different, already-effectively-retired path (0140: submit_invoice_to_
-- factor() unconditionally rejects every legacy submission, since no
-- legacy invoice carries a database-issued carrier/financial snapshot).
-- This migration therefore reads ONLY the carrier_invoice_issuance_
-- snapshots.snapshot_payload -> 'factoring' block, and touches neither
-- factored_invoices nor factoring_events, per explicit instruction.
--
-- carrier_invoice_lifecycle_idempotency (0142, hardened 0143) already has
-- invoice_id uuid NOT NULL references carrier_invoices(id) -- unlike
-- 0145's own agreement-lifecycle case (where agreement_id could be null
-- before any invoice-scoped context existed), EVERY payment operation
-- (record or void) is inherently invoice-scoped from the start, so this
-- migration REUSES this existing table directly (Section I explicitly
-- allows "create OR extend") rather than adding a new one -- two new
-- operation values ('record_carrier_invoice_payment',
-- 'void_carrier_invoice_payment') under the SAME (organization_id,
-- operation, idempotency_key) durable scope issue_carrier_invoice() and
-- update_carrier_invoice_draft() already use, with zero risk of cross-
-- operation collision (the unique constraint is already operation-scoped).
--
-- public.payment_method (0001: ach/wire/check/credit_card/cash/factoring/
-- other) is NOT reused verbatim for the new ledger's own payment_method
-- column -- it includes 'factoring' as a label, which would let a caller
-- record an ordinary ledger entry SEMANTICALLY tagged as a factoring event,
-- directly undermining Section B/H's required separation (a factoring
-- advance is never an ordinary payment, regardless of what a free-text/
-- loosely-typed method label claims). A new, disjoint enum (Section C)
-- structurally excludes 'factoring' from what this ledger can ever record.
--
-- CONCLUSION -- reused: compute_financial_request_fingerprint() (0143);
-- the (organization_id, operation, idempotency_key) advisory-lock pattern;
-- carrier_invoice_lifecycle_idempotency (extended with 2 new operation
-- values); carrier_invoices.amount_paid/payment_status/balance_due exactly
-- as they already are (no schema change to carrier_invoices in this
-- migration at all); log_activity() with entity_type='invoice' (already
-- established for invoice-scoped events, 0144/0145) -- no new entity_type
-- value needed, avoiding 0145's own discovered enum-value-irreversibility
-- issue entirely. NOT reused, deliberately isolated: public.payments/
-- public.invoices/apply_payment_to_invoice() (different table entirely);
-- public.payment_method (would leak 'factoring' into an ordinary ledger);
-- factored_invoices/factoring_events (legacy-invoice-scoped, untouched
-- per explicit instruction).
--
-- ===========================================================================
-- SECTION A.1 (Phase 3B.5.1 addendum) -- AUTHORITATIVE ISSUED-SNAPSHOT
-- CONTRACT. IMPORTANT CORRECTION discovered during this addendum's own
-- work: issue_carrier_invoice() is defined ONCE by 0144 (`create function`,
-- lines ~589-1245) but then ENTIRELY REDEFINED by 0145 via `create or
-- replace function public.issue_carrier_invoice(...)` (0145 lines
-- ~1885-2380+, its own header: "the real 0144 loads.rate-vs-load_
-- financials.rate defect is corrected in the SAME CREATE OR REPLACE").
-- 0145's version is what is ACTUALLY installed and callable after this
-- migration's own precondition (0144+0145 applied) -- 0144's original
-- freight-snapshot-construction code is dead, superseded source, read for
-- history only. An early draft of this addendum, and of 0146's original
-- Phase 3B.5 header, documented ONLY 0144's original shape and missed
-- this redefinition -- caught not by re-reading source a second time, but
-- by direct psql introspection of an ACTUALLY-ISSUED snapshot row against
-- a real disposable database, which is why Section G's end-to-end tests
-- (real issue_carrier_invoice() calls, never a fabricated snapshot) are
-- required to be the primary compatibility proof, never source-reading or
-- a test fixture alone. _issue_dispatch_service_invoice_internal() (0145,
-- `create function`, lines ~1464-1860+) is defined exactly once, never
-- redefined by anything -- 0145's own reading of it stands unchanged.
--
--   Common to BOTH document types (top level): schema_version (integer,
--   always 1), invoice_id (uuid, text-cast in JSON), invoice_document_type
--   (text: 'carrier_freight_invoice' | 'dispatch_service_invoice'),
--   invoice_number, organization_id, issued_at, issued_by, currency (text),
--   payment_terms_days, due_date, subtotal_amount, tax_amount,
--   adjustments_amount, total_amount (numeric), line_items (array),
--   issuer (object), recipient (object), factoring, issuing_user_id.
--
--   carrier_freight_invoice (0145's redefinition of issue_carrier_invoice,
--   NOT 0144's original) ONLY:
--     - carrier id lives at issuer.carrier_id (uuid) -- NOT a top-level
--       carrier_id key, NOT recipient.carrier_id.
--     - recipient.type is 'broker' | 'customer' (never 'carrier'),
--       recipient.broker_id or recipient.customer_id names the payer.
--     - loads (array); dispatch_service is always JSON null -- freight
--       never carries dispatch-service identity.
--     - factoring is ALWAYS a jsonb OBJECT, NEVER JSON null (0145 line
--       ~2200: the 'direct' branch is `jsonb_build_object('factoring_mode',
--       v_carrier.factoring_mode)`, i.e. literally
--       {"factoring_mode":"direct"} -- 0144's original "null for direct"
--       design was REPLACED, not merely reworded, by 0145). factoring_mode
--       is 'direct' or 'factored' (no other value is ever written -- a
--       carrier with factoring_mode='unconfigured' is rejected earlier in
--       the same function, before this payload is ever built, so
--       'unconfigured' never reaches a snapshot). The 'factored' shape
--       (0145 line ~2186) is `{factoring_mode:'factored',
--       factoring_company_legal_name, factoring_relationship_id,
--       noa_approved, submission_method, submission_destination}` --
--       note the key is 'factoring_relationship_id' here, NOT 0144's
--       original 'relationship_id', and 0144's original
--       'factoring_company_id'/remittance_instructions/noa_reference/
--       noa_effective_date/noa_approved_at/noa_document_id/
--       noa_document_snapshot_file_name/integration_id are NOT present in
--       the currently-applied shape at all.
--
--   dispatch_service_invoice (0145, never redefined) ONLY:
--     - carrier id lives at recipient.carrier_id (uuid) -- the dispatch-
--       service invoice's issuer is the DISPATCH ORGANIZATION (issuer.
--       organization_id), never a carrier_id key there.
--     - recipient.type is ALWAYS the literal string 'carrier';
--       recipient.carrier_id names the payer.
--     - agreement (object: agreement_id/version_id/version_number/
--       fee_method/percentage_rate/flat_fee_per_load/minimum_fee/
--       maximum_fee/effective_from/effective_to/approved_by/approved_at),
--       billing_lines (array) -- freight never carries these.
--     - factoring is ALWAYS JSON null (a hardcoded literal -- dispatch-
--       service invoicing has no factoring concept at all, Section A/I's
--       own legal-separation requirement). There is no top-level
--       'dispatch_service' key on this document type (that key exists
--       ONLY on the freight shape, always null there).
--
-- RESOLUTION of the specific mode/factoring_mode question this addendum
-- was asked to settle: the snapshot's factoring object key is, and always
-- has been across both 0144's original and 0145's redefinition, LITERALLY
-- 'factoring_mode', never 'mode', and no other alias is ever written. The
-- PRE-EXISTING record_carrier_invoice_payment() in this same migration
-- already read `snapshot_payload -> 'factoring' ->> 'factoring_mode'`
-- (matching the true contract exactly, coincidentally, for the single
-- narrow purpose it was used for -- detecting 'factored') -- so the
-- originally-reported "mode vs factoring_mode mismatch" is NOT REAL; no
-- key-path bug existed there. What WAS real, and would have been a latent
-- bug the moment any stricter shape-validation was added without this
-- addendum's live re-verification: an implementation that assumed 0144's
-- original field names (relationship_id, factoring_company_id) or 0144's
-- original "null means direct" encoding would have been WRONG against the
-- actually-installed 0145 redefinition. PHASE 6B's validator is built
-- against the VERIFIED-LIVE 0145 shape above, not 0144's superseded one.
-- Also closed here: a NULL/absent snapshot or a malformed/absent
-- 'factoring' object previously fell through the old ad hoc check
-- silently (never failing closed), the check ran ONLY for
-- carrier_freight_invoice (never validating a dispatch_service_invoice
-- snapshot's own shape at all), and no cross-check existed between the
-- snapshot's own invoice_id/invoice_document_type/carrier
-- identity/currency/total and the RELATIONAL carrier_invoices columns of
-- the same row. PHASE 6B below closes all of this with one centralized,
-- schema_version-aware validator (carrier_invoice_payment_snapshot_
-- problem), used by record_carrier_invoice_payment() under the already-
-- locked invoice row, so no second, slightly-different set of JSON-path
-- assumptions can ever drift into a future factoring-funding workflow.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
declare
  v_carrier_invoice_count integer;
  v_issued_count integer;
  v_already_paid_count integer;
  v_anomalous_paid_count integer;
begin
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null then
    raise exception '0146 precondition: 0144 not applied (issue_carrier_invoice missing). STOP.';
  end if;
  if to_regprocedure('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)') is null then
    raise exception '0146 precondition: 0145 (Phase 3B.4.1) not applied (the carrier-scoped effective-dates lock helper is missing). STOP.';
  end if;
  if to_regclass('public.carrier_invoice_lifecycle_idempotency') is null then
    raise exception '0146 precondition: public.carrier_invoice_lifecycle_idempotency (0142/0143) missing. STOP.';
  end if;
  if to_regclass('public.carrier_invoice_payments') is not null then
    raise exception '0146 precondition: public.carrier_invoice_payments already exists. STOP.';
  end if;
  if to_regtype('public.carrier_invoice_payment_status') is not null then
    raise exception '0146 precondition: public.carrier_invoice_payment_status already exists. STOP.';
  end if;
  if to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is not null then
    raise exception '0146 precondition: record_carrier_invoice_payment(...) already exists. STOP.';
  end if;
  if to_regprocedure('public.carrier_invoice_payment_snapshot_problem(uuid)') is not null then
    raise exception '0146 precondition: carrier_invoice_payment_snapshot_problem(uuid) already exists. STOP.';
  end if;
  if to_regprocedure('public._carrier_invoice_payment_external_reference_problem(text)') is not null then
    raise exception '0146 precondition: _carrier_invoice_payment_external_reference_problem(text) already exists. STOP.';
  end if;

  -- Section M: this migration has NEVER been applied anywhere -- do not
  -- assume carrier_invoices is empty. Aggregate diagnostics only; refuse
  -- only on a genuinely anomalous state (amount_paid > 0 with no possible
  -- source -- every write path to amount_paid has zero grant and no RPC
  -- exists before this migration, so this should be structurally
  -- impossible, but this migration does not blindly assume that).
  select count(*) into v_carrier_invoice_count from public.carrier_invoices;
  select count(*) into v_issued_count from public.carrier_invoices where issuance_status in ('issued', 'voided');
  select count(*) into v_already_paid_count from public.carrier_invoices where amount_paid > 0;
  v_anomalous_paid_count := v_already_paid_count;

  if v_anomalous_paid_count > 0 then
    raise exception '0146 precondition: % carrier_invoices row(s) already show amount_paid > 0, but no payment mechanism has existed before this migration (zero write grant, no RPC). Refusing to guess how this happened or to silently adopt it into the new ledger. STOP -- resolve manually.', v_anomalous_paid_count;
  end if;

  raise notice '0146 PHASE 1 preconditions passed. % carrier_invoices row(s) total, % issued/voided, 0 already showing amount_paid > 0 (expected, since no payment mechanism existed before this migration) -- safe to add the payment ledger.', v_carrier_invoice_count, v_issued_count;
end
$mig$;

-- ======================= PHASE 1B -- EXISTING-SNAPSHOT VERSION POLICY =======
-- Phase 3B.5.2, Section D. Because Phase 3 migrations have never been
-- applied to any shared/production database, the expected count of
-- carrier_invoice_issuance_snapshots rows is zero -- but this migration
-- does not assume that. Every EXISTING snapshot row, if any exist, was
-- necessarily written by ONE of the two now-superseded schema_version=1
-- shapes documented in this migration's own SECTION A.1 header (0144's
-- original, or 0145's redefinition) -- schema_version=2 cannot possibly
-- exist yet, since this migration is the first to ever emit it. This
-- phase categorizes every existing row into exactly one of four buckets
-- (0144-shape v1 freight, 0145-shape v1 freight, v1 dispatch-service,
-- unknown/malformed) using only the shape signatures each writer actually
-- produced, reports aggregate counts and a bounded list of affected
-- invoice ids for operator diagnosis, and REFUSES this entire migration
-- if any row exists in ANY bucket -- version-1 snapshots are never
-- silently reinterpreted as version 2, never rewritten in place, never
-- deleted. If version-1 snapshots ever exist in a shared environment,
-- they require a SEPARATE, reviewed compatibility strategy -- explicitly
-- out of scope here.
do $mig$
declare
  v_total integer;
  v_v1_freight_0144 integer;
  v_v1_freight_0145 integer;
  v_v1_dispatch_service integer;
  v_unknown integer;
  v_sample_ids text;
begin
  if to_regclass('public.carrier_invoice_issuance_snapshots') is null then
    raise exception '0146 precondition: public.carrier_invoice_issuance_snapshots (0142) missing. STOP.';
  end if;

  select count(*) into v_total from public.carrier_invoice_issuance_snapshots;

  -- 0144's original shape: direct is encoded as a JSON null 'factoring'
  -- value; factored carries the old 'relationship_id' key (0145 renamed
  -- this to 'factoring_relationship_id' and dropped 'factoring_company_id'
  -- entirely -- see SECTION A.1). This signature is unique to 0144.
  select count(*) into v_v1_freight_0144
  from public.carrier_invoice_issuance_snapshots
  where invoice_document_type = 'carrier_freight_invoice'
    and (snapshot_payload ->> 'schema_version') = '1'
    and (
      jsonb_typeof(snapshot_payload -> 'factoring') = 'null'
      or (snapshot_payload -> 'factoring' ? 'relationship_id')
    );

  -- 0145's redefinition shape: 'factoring' is ALWAYS a jsonb object (never
  -- null), keyed 'factoring_mode', and a factored object carries
  -- 'factoring_relationship_id' (never the old 'relationship_id').
  select count(*) into v_v1_freight_0145
  from public.carrier_invoice_issuance_snapshots
  where invoice_document_type = 'carrier_freight_invoice'
    and (snapshot_payload ->> 'schema_version') = '1'
    and jsonb_typeof(snapshot_payload -> 'factoring') = 'object'
    and (snapshot_payload -> 'factoring' ? 'factoring_mode')
    and not (snapshot_payload -> 'factoring' ? 'relationship_id');

  -- dispatch_service_invoice never had a 0144 shape at all -- 0144's own
  -- dispatch-service path was an unconditional early return that wrote no
  -- snapshot; every dispatch-service snapshot that has ever existed was
  -- written by 0145's _issue_dispatch_service_invoice_internal(), always
  -- schema_version=1, always factoring=null.
  select count(*) into v_v1_dispatch_service
  from public.carrier_invoice_issuance_snapshots
  where invoice_document_type = 'dispatch_service_invoice'
    and (snapshot_payload ->> 'schema_version') = '1';

  v_unknown := v_total - (v_v1_freight_0144 + v_v1_freight_0145 + v_v1_dispatch_service);

  if v_total > 0 then
    select string_agg(invoice_id::text, ', ') into v_sample_ids
    from (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 20) s;
    raise exception '0146 precondition (Section D existing-snapshot policy): % total issuance snapshot(s) already exist -- % 0144-shape v1 freight, % 0145-shape v1 freight, % v1 dispatch-service, % unknown/malformed. schema_version=2 cannot legitimately exist yet (this migration is the first to emit it), so EVERY existing row is necessarily a version-1 (or malformed) snapshot. This migration NEVER silently reinterprets a v1 snapshot as v2, never rewrites or deletes issued financial history. Refusing to proceed. First (up to 20) affected invoice_id(s): %. If version-1 snapshots genuinely exist in this environment, they require a separate, reviewed compatibility strategy before 0146 can be applied here. STOP.',
      v_total, v_v1_freight_0144, v_v1_freight_0145, v_v1_dispatch_service, v_unknown, coalesce(v_sample_ids, '(none)');
  end if;

  raise notice '0146 PHASE 1B: 0 issuance snapshot rows exist (0 0144-shape v1 freight, 0 0145-shape v1 freight, 0 v1 dispatch-service, 0 unknown) -- safe to install schema_version=2 issuance.';
end
$mig$;

-- ======================= PHASE 1C -- CANONICAL VERSION-2 ISSUANCE ===========
-- Phase 3B.5.2, Section C. Because migrations 0144/0145 are already
-- committed and must never be edited, this migration REPLACES the
-- INSTALLED issue_carrier_invoice()/_issue_dispatch_service_invoice_
-- internal() definitions in place (CREATE OR REPLACE FUNCTION, same
-- public signatures) -- exactly the same technique 0145 itself already
-- used to correct 0144's own loads.rate defect without editing 0144.
--
-- Every STEP below is BYTE-IDENTICAL to 0145's own installed body
-- (verified by direct re-read of the committed 0145 source, never
-- reconstructed from memory) -- authorization, the organization+
-- operation+idempotency-key advisory lock, full lock order (loads ->
-- load_stops -> dispatch associations -> factoring_relationships ->
-- carriers -> remittance -> recipient -> line items -> number
-- allocation, freight; loads -> carrier-scoped agreement lock ->
-- agreement version -> carriers -> dispatch org -> per-load fee calc/
-- billing ledger -> number allocation, dispatch-service), numbering,
-- idempotency, agreement fee calculation, factoring readiness
-- re-verification under lock, one audit event, and every 0144/0145
-- concurrency protection (Phase 3B.4.1's carrier-scoped advisory lock
-- included) are UNCHANGED. The ONLY change in either function is the
-- shape of v_snapshot_payload itself: schema_version 1 -> 2, and the
-- canonical field names/structure documented in this migration's own
-- SECTION B header (never 'factoring_mode', never 'relationship_id' --
-- see SECTION A.1's compatibility matrix for exactly what each prior
-- shape called these same facts).
--
-- _issue_dispatch_service_invoice_internal() is replaced FIRST (issue_
-- carrier_invoice() calls it internally at its own STEP 10 -- CREATE OR
-- REPLACE has no ordering requirement between the two since a plpgsql
-- function body is opaque text with no catalog-tracked call dependency,
-- but defining the callee first matches this migration's own established
-- "define what is depended upon before what depends on it" convention).
create or replace function public._issue_dispatch_service_invoice_internal(
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
  v_source_loads jsonb := '[]'::jsonb;
  v_agreement_number text;
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
    -- Phase 3B.5.2 (corrected): 'source_loads' is a required top-level
    -- key on EVERY document type (SECTION C) -- dispatch-service has no
    -- per-load origin/destination/agreed-freight-charge data of its own
    -- (that already lives inside billing_lines, freight-basis-only), so
    -- this is deliberately minimal (load identity only), never inferring
    -- a business value this document type does not itself compute.
    v_source_loads := v_source_loads || jsonb_build_object('load_id', v_load_id, 'load_number', v_load.load_number);
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

  -- agreement_number is immutable once created (no UPDATE path exists on
  -- carrier_dispatch_service_agreements for this column -- confirmed by
  -- direct schema inspection) -- read FOR SHARE anyway, matching this
  -- project's own "lock even an already-immutable row before reading it
  -- into a new snapshot" convention.
  select agreement_number into v_agreement_number
  from public.carrier_dispatch_service_agreements
  where id = v_version.agreement_id
  for share;

  ------------------------------------------------------------------
  -- Snapshot (Phase 3B.5.2, Section B/C, corrected): dispatch
  -- organization identity/remittance, carrier recipient identity,
  -- agreement identity/terms, per-load billing detail -- all nested
  -- under the single required top-level 'dispatch_service' object (never
  -- separate top-level 'agreement'/'billing_lines' keys). Never broker/
  -- customer, never any factoring identity/NOA/integration/
  -- secret_reference/carrier-factoring destination -- Section A/I's
  -- legal-separation requirement, unchanged. schema_version is 2
  -- (canonical, see this migration's own SECTION B/C header) -- 'factoring'
  -- remains the literal JSON value null (the
  -- ONLY value this document type may ever carry, both under v1 and v2);
  -- the sole shape change here vs. 0145's v1 is dropping the now-
  -- redundant issuing-user-id key (identical to issued_by in every row
  -- ever written -- an accidental v1 duplication, not preserved into v2).
  ------------------------------------------------------------------
  v_snapshot_payload := jsonb_build_object(
    'schema_version', 2,
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
    'adjustment_amount', p_row.adjustments_amount,
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
    'line_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', li.id, 'description', li.description, 'quantity', li.quantity,
        'unit_price', li.unit_price, 'amount', li.line_total, 'source_load_id', li.source_load_id
      ) order by li.sort_order, li.created_at), '[]'::jsonb)
      from public.carrier_invoice_line_items li where li.invoice_id = p_invoice_id and li.line_type = 'dispatch_service_fee'
    ),
    'source_loads', v_source_loads,
    'factoring', null,
    'dispatch_service', jsonb_build_object(
      'agreement_id', v_version.agreement_id,
      'agreement_version_id', v_version.id,
      'agreement_number', v_agreement_number,
      'version_number', v_version.version_number,
      'fee_method', v_version.fee_method,
      'percentage_rate', v_version.percentage_rate,
      'flat_fee_per_load', v_version.flat_fee_per_load,
      'minimum_fee', v_version.minimum_fee,
      'maximum_fee', v_version.maximum_fee,
      'effective_from', v_version.effective_from,
      'effective_to', v_version.effective_to,
      'approved_by', v_version.approved_by,
      'approved_at', v_version.approved_at,
      'billing_lines', v_billing_lines
    )
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
  'Phase 3B.4, snapshot shape corrected to schema_version=2 by Phase 3B.5.2: internal-only (EXECUTE revoked from every role) -- the entire dispatch-service-specific issuance body, called exclusively from issue_carrier_invoice()''s own STEP 10 after that function''s fully-shared STEPS 1-9 have already run. Never includes broker/customer/factoring identity; never alters a carrier_freight_invoice; never posts a settlement deduction; never trusts a client-supplied fee -- every fee is computed here, from locked, server-read sources only. factoring is always JSON null (canonical, see this migration''s SECTION B header).';

revoke all on function public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text) from public, anon, authenticated;

-- Redefine issue_carrier_invoice() itself -- STEPS 1-9 UNCHANGED verbatim
-- from the installed 0145 body; STEP 10 dispatches to the function above
-- (now itself replaced, immediately above); the freight-invoice-specific
-- STEPS 11 onward are BYTE-IDENTICAL to 0145's own installed body, with
-- exactly ONE substantive change: the snapshot-build phase now emits
-- schema_version=2 in the canonical shape (SECTION B), replacing 0145's
-- schema_version=1 factoring encoding ('factoring_mode'/
-- 'factoring_relationship_id') with the canonical 'mode'/'relationship_id'/
-- 'company_id'/nested 'noa'/'submission' objects, and drops the redundant
-- 'issuing_user_id' and always-null 'dispatch_service' keys (accidental
-- v1 vestiges, never meaningful on a freight document).
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

  ------------------------------------------------------------------
  -- Phase 3B.5.2 (corrected): canonical schema_version=2 factoring
  -- object. Direct: exactly {"mode":"direct"}. Factored: {"mode":
  -- "factored","relationship_id","company":{"id","legal_name","name"},
  -- "remittance_instructions",
  -- "noa":{"approved","reference","document_id","verified_at"},
  -- "submission":{"method","destination","integration_id"}} -- 'company'
  -- is a NESTED identity object (never flat company_id/company_legal_name
  -- keys) per the corrected canonical contract. factoring_companies.
  -- account_number is DELIBERATELY never included -- this schema's own
  -- established convention (matching carrier_remittance_profiles) is
  -- free-text remittance_instructions only, never a raw bank-account
  -- value, regardless of whether a key name would trip the forbidden-key
  -- guard.
  ------------------------------------------------------------------
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
      'mode', 'factored',
      'relationship_id', v_relationship.id,
      'company', jsonb_build_object(
        'id', v_company.id,
        'legal_name', coalesce(v_company.legal_name, v_company.name),
        'name', v_company.name
      ),
      'remittance_instructions', v_relationship.remittance_instructions,
      'noa', jsonb_build_object(
        'approved', v_relationship.noa_approved,
        'reference', v_relationship.noa_reference,
        'document_id', v_relationship.noa_document_id,
        'verified_at', v_doc.verified_at
      ),
      'submission', jsonb_build_object(
        'method', v_relationship.submission_method,
        'destination',
          case v_relationship.submission_method
            when 'secure_email' then v_relationship.submission_destination_email
            else null -- never a raw destination for API -- integration_id below is the safe pointer.
          end,
        'integration_id', v_integration.id
      )
    );
  else
    v_factoring_payload := jsonb_build_object('mode', 'direct');
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
  -- Phase 3B.5.2 (corrected): schema_version 2, canonical factoring shape
  -- (built above); 'dispatch_service' is now an EXPLICIT required
  -- top-level key, always JSON null on a freight document (the corrected
  -- canonical contract requires its PRESENCE on every document, not its
  -- absence on the ones where it does not apply -- a document-type-
  -- conditional key SET is not the same thing as a key whose VALUE is
  -- always null); the old per-load array key and the old (plural)
  -- adjustments-amount key are both renamed to their corrected canonical
  -- forms below; no redundant issuing-user-id key
  -- (identical to issued_by, dropped as an accidental v1 duplication).
  ------------------------------------------------------------------
  v_snapshot_payload := jsonb_build_object(
    'schema_version', 2,
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
    'adjustment_amount', v_row.adjustments_amount,
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
    'source_loads', v_loads_payload,
    'factoring', v_factoring_payload,
    'dispatch_service', null
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
  'Phase 3B.4, snapshot shape corrected to schema_version=2 by Phase 3B.5.2 (Section C): STEPS 1-9 (auth/org/fingerprint/advisory-lock/invoice-lock/idempotency/status), lock order, numbering, agreement calculation, factoring readiness, and audit behavior are UNCHANGED from the installed 0145 body. The ONLY change is the issuance snapshot shape itself: schema_version=2, canonical factoring object ({"mode":"direct"} or {"mode":"factored","relationship_id","company":{"id","legal_name","name"},"remittance_instructions","noa":{...},"submission":{...}}), no redundant issuing_user_id/dispatch_service keys. dispatch_service_invoice issuance dispatches to _issue_dispatch_service_invoice_internal() (also replaced by this migration, same compatibility correction). Never includes broker/customer identity on a dispatch-service snapshot; never alters a carrier_freight_invoice; never posts a settlement deduction; never trusts a client-supplied fee.';

-- ======================= PHASE 2 -- enums ====================================
-- Section C: required states. Deliberately NOT the legacy public.
-- payment_status (0026) -- a distinct, dedicated type keeps this ledger's
-- own lifecycle independent of the legacy invoices/payments system, per
-- Section B's own separation requirement (isolated concepts, isolated types).
create type public.carrier_invoice_payment_status as enum ('posted', 'voided');

comment on type public.carrier_invoice_payment_status is
  'Phase 3B.5: posted = counts toward carrier_invoices.amount_paid. voided = an auditable reversal, permanently excluded from the rollup but never deleted (Section C: "voiding preserves the original payment row").';

-- Section B/H: deliberately excludes ''factoring'' (contrast public.
-- payment_method, 0001, which includes it) -- a factoring advance/reserve
-- release/fee/chargeback/recourse-repayment is never an ordinary payment
-- recordable through this ledger, structurally, at the type level. A
-- dedicated factoring-funding ledger is reserved for a later phase.
create type public.carrier_invoice_payment_method as enum ('ach', 'wire', 'check', 'credit_card', 'cash', 'other');

comment on type public.carrier_invoice_payment_method is
  'Phase 3B.5: ordinary settlement methods only. Deliberately excludes ''factoring'' -- see public.carrier_invoice_payments'' own table comment (Section B/H).';

-- Section D step 13: the payer is ALWAYS server-derived from the invoice''s
-- own immutable identity, never client-supplied. broker/customer covers a
-- carrier_freight_invoice''s snapshotted recipient; carrier covers a
-- dispatch_service_invoice''s own payer (0145 Section A: "Payer: carrier").
create type public.carrier_invoice_payer_type as enum ('broker', 'customer', 'carrier');

comment on type public.carrier_invoice_payer_type is
  'Phase 3B.5: which party actually pays a given carrier_invoices document type -- always derived server-side from the invoice''s own already-immutable identity (recipient_type for a freight invoice; always ''carrier'' for a dispatch-service invoice), never accepted as RPC input.';

-- ======================= PHASE 3 -- payment number generator =================
-- Section C: "If a payment number is generated, make it concurrency-safe
-- and immutable. Do not use max()+1." Mirrors 0026's own generate_payment_
-- number() shape exactly (a dedicated SEQUENCE + nextval(), wrapped in a
-- SECURITY DEFINER function so the function owner's implicit sequence
-- privilege is used instead of a direct grant) -- a brand-new, dedicated
-- sequence, never shared with the legacy payments table's own sequence.
create sequence public.carrier_invoice_payment_number_seq;

create function public._generate_carrier_invoice_payment_number_internal()
returns text
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  return 'CPAY-' || lpad(nextval('public.carrier_invoice_payment_number_seq')::text, 8, '0');
end;
$fn$;

comment on function public._generate_carrier_invoice_payment_number_internal() is
  'Phase 3B.5: concurrency-safe payment numbering via nextval() on a dedicated sequence (never max()+1/count()+1) -- mirrors 0026''s generate_payment_number() shape, kept fully internal (EXECUTE revoked from every role) since only carrier_invoice_payments'' own DEFAULT expression and record_carrier_invoice_payment() ever need it.';

revoke all on function public._generate_carrier_invoice_payment_number_internal() from public, anon, authenticated;

-- ======================= PHASE 4 -- payment ledger table ====================
-- Section C: an additive, insert-mostly ledger. Financial identity
-- (invoice/amount/currency/method/payer/payment_date/external_reference)
-- is immutable the instant a row is inserted -- see the guard trigger
-- below (PHASE 5) for the enforcement; only status/void_reason/voided_by/
-- voided_at may ever change, exactly once, posted -> voided.
create table public.carrier_invoice_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_invoice_id uuid not null references public.carrier_invoices (id) on delete restrict,

  payment_number text not null default public._generate_carrier_invoice_payment_number_internal(),
  payment_date date not null,
  amount numeric(12, 2) not null check (amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  payment_method public.carrier_invoice_payment_method not null,
  external_reference text,

  -- Section D step 13: exactly one of the three, server-derived only --
  -- see the CHECK constraint below. Real FKs (not a single polymorphic
  -- uuid column) so referential integrity is enforced structurally,
  -- matching carrier_invoices.recipient_broker_id/recipient_customer_id's
  -- own established two-nullable-FK shape (0142) for "one of several
  -- possible party tables."
  payer_type public.carrier_invoice_payer_type not null,
  payer_broker_id uuid references public.brokers (id) on delete restrict,
  payer_customer_id uuid references public.customers (id) on delete restrict,
  payer_carrier_id uuid references public.carriers (id) on delete restrict,

  status public.carrier_invoice_payment_status not null default 'posted',
  void_reason text,
  voided_by uuid references public.profiles (id) on delete set null,
  voided_at timestamptz,

  recorded_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint civp_payment_number_unique unique (payment_number),

  constraint civp_void_fields_iff_voided check (
    (status = 'voided' and voided_at is not null and voided_by is not null and void_reason is not null and btrim(void_reason) <> '')
    or (status = 'posted' and voided_at is null and voided_by is null and void_reason is null)
  ),

  constraint civp_payer_shape check (
    (payer_type = 'broker' and payer_broker_id is not null and payer_customer_id is null and payer_carrier_id is null)
    or (payer_type = 'customer' and payer_customer_id is not null and payer_broker_id is null and payer_carrier_id is null)
    or (payer_type = 'carrier' and payer_carrier_id is not null and payer_broker_id is null and payer_customer_id is null)
  )
);

comment on table public.carrier_invoice_payments is
  'Phase 3B.5: the immutable payment ledger for carrier_invoices (freight AND dispatch-service). One row per posted or voided payment attempt, permanently -- never deleted, never reactivated once voided. Deliberately isolated from the legacy public.payments/public.invoices system (Section A/B). Never records a factoring advance/reserve-release/fee/chargeback/recourse-repayment/broker-to-factor remittance/settlement-deduction/credit-or-debit-memo/refund -- record_carrier_invoice_payment() structurally refuses a factored carrier_freight_invoice (FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW); a dedicated factoring-funding ledger for the genuinely distinct economic events above is reserved for a later phase. No raw bank-account/card/payment-credential data is ever stored here -- external_reference is free text for a check/wire confirmation number only, never a credential.';

create trigger set_updated_at before update on public.carrier_invoice_payments
  for each row execute function public.set_updated_at();

create index idx_civp_carrier_invoice on public.carrier_invoice_payments (carrier_invoice_id);
create index idx_civp_organization_status on public.carrier_invoice_payments (organization_id, status);

-- ======================= PHASE 5 -- immutability guard =======================
-- Section C: "posted payment financial identity is immutable", "voiding
-- preserves the original payment row", "voided payment cannot be
-- reactivated", "payment cannot be deleted". Fires for EVERY role
-- (SECURITY DEFINER, matching carrier_invoice_issuance_snapshots' own
-- guard, 0142) -- not merely a role check, a real invariant no grant can
-- express.
create function public.guard_carrier_invoice_payment_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if tg_op = 'DELETE' then
    raise exception 'carrier_invoice_payments: a payment can never be deleted, posted or voided -- void it instead.' using errcode = '55000';
  end if;

  if tg_op = 'UPDATE' then
    -- Financial identity is immutable from the moment the row exists,
    -- regardless of status -- the ONLY legal changes, ever, are the
    -- status transition itself and its own void_* fields.
    if (new.organization_id is distinct from old.organization_id
        or new.carrier_invoice_id is distinct from old.carrier_invoice_id
        or new.payment_number is distinct from old.payment_number
        or new.payment_date is distinct from old.payment_date
        or new.amount is distinct from old.amount
        or new.currency is distinct from old.currency
        or new.payment_method is distinct from old.payment_method
        or new.external_reference is distinct from old.external_reference
        or new.payer_type is distinct from old.payer_type
        or new.payer_broker_id is distinct from old.payer_broker_id
        or new.payer_customer_id is distinct from old.payer_customer_id
        or new.payer_carrier_id is distinct from old.payer_carrier_id
        or new.recorded_by is distinct from old.recorded_by
        or new.created_at is distinct from old.created_at)
    then
      raise exception 'carrier_invoice_payments: a payment''s financial identity is immutable once recorded -- record a new payment or void this one instead.' using errcode = '55000';
    end if;

    -- Only posted -> voided is a legal status transition. No reactivation,
    -- ever (Section C: "voided payment cannot be reactivated").
    if new.status is distinct from old.status then
      if not (old.status = 'posted' and new.status = 'voided') then
        raise exception 'carrier_invoice_payments: % -> % is not a permitted status transition.', old.status, new.status using errcode = '55000';
      end if;
    end if;
  end if;

  return coalesce(new, old);
end;
$fn$;

comment on function public.guard_carrier_invoice_payment_lifecycle() is
  'Phase 3B.5: financial identity (invoice/amount/currency/method/payer/date/reference) is immutable from the moment a payment row exists; only posted -> voided is a legal status transition (never reactivated); DELETE is always rejected, for every role.';

create trigger a0146_guard_payment_lifecycle
  before update or delete on public.carrier_invoice_payments
  for each row execute function public.guard_carrier_invoice_payment_lifecycle();

-- Section D step 11 / Section G: a real, cross-table backstop for currency
-- consistency -- a CHECK constraint cannot reference another table, so
-- this is the structural enforcement that a payment''s own currency can
-- never drift from its invoice''s currency, regardless of caller. The
-- RPC below derives currency from the invoice directly (never client-
-- supplied) so this should never actually fire through any legitimate
-- path -- kept as defense-in-depth, matching this schema''s own
-- established convention for structurally-should-be-unreachable checks.
create function public.guard_carrier_invoice_payment_currency()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_invoice_currency text;
begin
  select currency into v_invoice_currency from public.carrier_invoices where id = new.carrier_invoice_id;
  if v_invoice_currency is null then
    raise exception 'carrier_invoice_payments: the referenced carrier invoice was not found.' using errcode = '55000';
  end if;
  if new.currency <> v_invoice_currency then
    raise exception 'carrier_invoice_payments: a payment''s currency must equal its invoice''s currency.' using errcode = '55000';
  end if;
  return new;
end;
$fn$;

comment on function public.guard_carrier_invoice_payment_currency() is
  'Phase 3B.5: cross-table backstop -- a payment''s currency must always equal its invoice''s currency. record_carrier_invoice_payment() always derives currency from the invoice directly, so this should be structurally unreachable via any legitimate path; kept as defense-in-depth.';

create trigger a0146_guard_payment_currency before insert on public.carrier_invoice_payments
  for each row execute function public.guard_carrier_invoice_payment_currency();

-- ======================= PHASE 6 -- RLS + grants =============================
-- Section F: owner/admin/accountant/dispatcher may READ (matching
-- carrier_invoice_issuance_snapshots'' own precedent exactly); driver/
-- viewer/anon: zero access; mutation is RPC-only for every role,
-- including owner/admin (no direct grant at all, matching every other
-- guarded financial table in this schema since 0142).
alter table public.carrier_invoice_payments enable row level security;

create policy carrier_invoice_payments_select
  on public.carrier_invoice_payments for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

revoke all on public.carrier_invoice_payments from anon, authenticated;
grant select on public.carrier_invoice_payments to authenticated;

-- ======================= PHASE 6B -- centralized snapshot validation ========
-- Phase 3B.5.1, Section E, superseded/hardened by Phase 3B.5.2, Section E:
-- ONE canonical, VERSION-AWARE validator for the issued-snapshot contract
-- documented in this migration's own SECTION B header -- never duplicated,
-- slightly differently, across this and a future factoring-funding
-- workflow. Internal-only (mirrors compute_financial_request_fingerprint's
-- own established pattern exactly): security invoker, EXECUTE revoked from
-- public/anon/authenticated, callable only by a SECURITY DEFINER function
-- owned by the same role (e.g. record_carrier_invoice_payment(), which
-- runs as that owner for its entire duration). Called under the invoice
-- row's own FOR UPDATE lock (already held by the caller before this is
-- ever invoked) -- this function itself additionally locks the snapshot
-- row FOR SHARE, matching this project's own established "lock even an
-- already-immutable row before reading it" convention.
--
-- Returns problem_code = NULL only when the snapshot is schema_version=2,
-- fully self-consistent, AND consistent with its own invoice's relational
-- columns; otherwise a short, safe, non-sensitive text code (never raw
-- JSON/SQL/snapshot content) identifying WHICH invariant failed, for
-- internal/test use only -- the public-facing RPC never echoes this code,
-- collapsing every non-null result to exactly ONE of two external codes:
-- any code starting with 'VERSION_' means the snapshot is not
-- schema_version=2 at all (SNAPSHOT_VERSION_UNSUPPORTED -- includes every
-- now-superseded schema_version=1 shape, 0144's original AND 0145's own
-- redefinition alike, plus missing/null/non-numeric/unknown version
-- values); every other non-null code means the snapshot IS schema_version=
-- 2 but internally malformed or inconsistent with its own invoice
-- (SNAPSHOT_INTEGRITY_ERROR). A version-1 snapshot is NEVER silently
-- reinterpreted as version 2 -- Section D's existing-snapshot policy (this
-- migration's own PHASE 1B) already guarantees zero such rows can exist at
-- apply time; this validator is the second, independent, always-on
-- guarantee for any snapshot this RPC is ever asked to pay against.
--
-- Canonical field names ONLY -- this validator does not, and must never,
-- accept 'factoring_mode' as an alias for the canonical 'mode' key, nor
-- 'relationship_id'/'factoring_relationship_id' as aliases for 'mode':
-- 'factored''s canonical 'relationship_id', nor any other v1-shaped key as
-- a silent substitute for its v2 equivalent. A payload mixing v1 and v2
-- field names is treated exactly like any other malformed v2 payload
-- (SNAPSHOT_INTEGRITY_ERROR) -- never partially accepted.
--
-- factoring_mode (out param name retained for continuity with Phase
-- 3B.5.1's own call sites) is populated ONLY when problem_code is NULL
-- and the (freight-only) canonical factoring object's 'mode' is
-- 'factored' -- NULL in every other case (direct freight, any dispatch-
-- service invoice, or any problem case).
create function public.carrier_invoice_payment_snapshot_problem(
  p_invoice_id uuid,
  out problem_code text,
  out factoring_mode text
)
returns record
language plpgsql
security invoker
set search_path = pg_catalog, public
as $fn$
declare
  v_row public.carrier_invoices%rowtype;
  v_snapshot jsonb;
  v_factoring jsonb;
  v_recipient jsonb;
  v_issuer jsonb;
begin
  problem_code := null;
  factoring_mode := null;

  select * into v_row from public.carrier_invoices where id = p_invoice_id;
  if v_row.id is null then
    problem_code := 'INVOICE_NOT_FOUND';
    return;
  end if;

  select snapshot_payload into v_snapshot
  from public.carrier_invoice_issuance_snapshots
  where invoice_id = p_invoice_id
  for share;

  if v_snapshot is null then
    problem_code := 'SNAPSHOT_MISSING';
    return;
  end if;
  if jsonb_typeof(v_snapshot) is distinct from 'object' then
    problem_code := 'SNAPSHOT_MALFORMED';
    return;
  end if;

  ------------------------------------------------------------------
  -- Phase 3B.5.2, Section E: version gate FIRST, strictly separate from
  -- shape validation. Every one of these maps externally to
  -- SNAPSHOT_VERSION_UNSUPPORTED (the RPC recognizes the 'VERSION_'
  -- prefix) -- never SNAPSHOT_INTEGRITY_ERROR, so a caller/operator can
  -- always tell "this is an old/unknown format" apart from "this is
  -- version 2 but broken".
  ------------------------------------------------------------------
  if not (v_snapshot ? 'schema_version') then
    problem_code := 'VERSION_MISSING';
    return;
  end if;
  if jsonb_typeof(v_snapshot -> 'schema_version') = 'null' then
    problem_code := 'VERSION_NULL';
    return;
  end if;
  if jsonb_typeof(v_snapshot -> 'schema_version') is distinct from 'number' then
    problem_code := 'VERSION_NOT_NUMBER';
    return;
  end if;
  if (v_snapshot ->> 'schema_version')::numeric is distinct from 2 then
    -- Catches schema_version=1 (both 0144's original and 0145's own
    -- redefinition alike -- neither is ever silently accepted here) and
    -- any schema_version=3+/unknown value.
    problem_code := 'VERSION_UNSUPPORTED';
    return;
  end if;

  if (v_snapshot ->> 'invoice_id') is distinct from p_invoice_id::text then
    problem_code := 'INVOICE_ID_MISMATCH';
    return;
  end if;
  if (v_snapshot ->> 'invoice_document_type') is distinct from v_row.invoice_document_type::text then
    problem_code := 'DOCUMENT_TYPE_MISMATCH';
    return;
  end if;
  if (v_snapshot ->> 'currency') is distinct from v_row.currency then
    problem_code := 'CURRENCY_MISMATCH';
    return;
  end if;
  if (v_snapshot ->> 'total_amount') is null then
    problem_code := 'TOTAL_AMOUNT_MISMATCH';
    return;
  end if;
  begin
    if (v_snapshot ->> 'total_amount')::numeric is distinct from v_row.total_amount then
      problem_code := 'TOTAL_AMOUNT_MISMATCH';
      return;
    end if;
  exception
    when invalid_text_representation then
      problem_code := 'TOTAL_AMOUNT_MISMATCH';
      return;
  end;

  if not (v_snapshot ? 'factoring') then
    problem_code := 'FACTORING_KEY_MISSING';
    return;
  end if;
  v_factoring := v_snapshot -> 'factoring';

  if v_row.invoice_document_type = 'carrier_freight_invoice' then
    v_issuer := v_snapshot -> 'issuer';
    if jsonb_typeof(v_issuer) is distinct from 'object' then
      problem_code := 'ISSUER_MALFORMED';
      return;
    end if;
    if (v_issuer ->> 'carrier_id') is distinct from v_row.carrier_id::text then
      problem_code := 'CARRIER_ID_MISMATCH';
      return;
    end if;

    v_recipient := v_snapshot -> 'recipient';
    if jsonb_typeof(v_recipient) is distinct from 'object' then
      problem_code := 'RECIPIENT_MALFORMED';
      return;
    end if;
    if (v_recipient ->> 'type') not in ('broker', 'customer') then
      problem_code := 'RECIPIENT_TYPE_MISMATCH';
      return;
    end if;
    if (v_recipient ->> 'type') is distinct from v_row.recipient_type::text then
      problem_code := 'RECIPIENT_TYPE_MISMATCH';
      return;
    end if;

    -- SECTION B (canonical v2 contract): a carrier_freight_invoice's
    -- 'factoring' key is ALWAYS a jsonb OBJECT, never JSON null -- direct
    -- is {"mode":"direct"}. The canonical key is 'mode' ONLY -- an object
    -- carrying only the retired (see SECTION A.1) prior mode-key name
    -- instead (an alias attempt, or a mixed old/new payload) has no
    -- 'mode' key at all and is correctly rejected as FACTORING_MODE_
    -- MISSING, never silently accepted as if it had said 'mode'.
    if jsonb_typeof(v_factoring) is distinct from 'object' then
      problem_code := 'FACTORING_OBJECT_MALFORMED';
      return;
    end if;
    if not (v_factoring ? 'mode') then
      problem_code := 'FACTORING_MODE_MISSING';
      return;
    end if;
    if (v_factoring ->> 'mode') not in ('direct', 'factored') then
      problem_code := 'FACTORING_MODE_UNKNOWN';
      return;
    end if;
    if (v_factoring ->> 'mode') = 'factored' then
      -- Canonical identity keys: 'relationship_id' and the nested
      -- company.{id,legal_name} object. The two prior flat key schemes are
      -- deliberately not accepted as substitutes.
      if (v_factoring ->> 'relationship_id') is null
         or jsonb_typeof(v_factoring -> 'company') is distinct from 'object'
         or (v_factoring -> 'company' ->> 'id') is null
         or (v_factoring -> 'company' ->> 'legal_name') is null then
        problem_code := 'FACTORING_OBJECT_MALFORMED';
        return;
      end if;
      factoring_mode := 'factored';
    end if;

  elsif v_row.invoice_document_type = 'dispatch_service_invoice' then
    v_recipient := v_snapshot -> 'recipient';
    if jsonb_typeof(v_recipient) is distinct from 'object' then
      problem_code := 'RECIPIENT_MALFORMED';
      return;
    end if;
    if (v_recipient ->> 'type') is distinct from 'carrier' then
      problem_code := 'RECIPIENT_TYPE_MISMATCH';
      return;
    end if;
    if (v_recipient ->> 'carrier_id') is distinct from v_row.carrier_id::text then
      problem_code := 'CARRIER_ID_MISMATCH';
      return;
    end if;

    -- Section D: "factor object present on dispatch-service invoice" must
    -- fail closed -- 0145's issuance path (as replaced by this migration,
    -- PHASE 1C) never populates it; null is the ONLY value this document
    -- type may ever legitimately carry.
    if jsonb_typeof(v_factoring) is distinct from 'null' then
      problem_code := 'FACTORING_NOT_PERMITTED_FOR_DOCUMENT_TYPE';
      return;
    end if;

  else
    problem_code := 'DOCUMENT_TYPE_UNRECOGNIZED';
    return;
  end if;
end;
$fn$;

revoke all on function public.carrier_invoice_payment_snapshot_problem(uuid) from public, anon, authenticated;

comment on function public.carrier_invoice_payment_snapshot_problem(uuid) is
  'Phase 3B.5.1, Section E, superseded/hardened by Phase 3B.5.2, Section E: the single canonical, VERSION-AWARE validator for the issued-snapshot contract documented in this migration''s own SECTION B header. Requires schema_version=2 -- any other value (missing/null/non-numeric/1/3+, including BOTH now-superseded v1 shapes) yields a problem_code prefixed VERSION_ (the calling RPC maps this to SNAPSHOT_VERSION_UNSUPPORTED, never SNAPSHOT_INTEGRITY_ERROR). Once version-gated: invoice_id/invoice_document_type/carrier identity/currency/total_amount cross-checked against the relational carrier_invoices row, plus document-type-specific canonical factoring shape rules (freight: ALWAYS an object, {mode:''direct''} or {mode:''factored'', relationship_id, company:{id,legal_name,name}, ...} -- JSON null is never valid here, and only the canonical ''mode''/''relationship_id''/nested ''company'' keys are ever accepted, never the retired v1 aliases; dispatch-service: ALWAYS null). Returns problem_code=NULL when consistent, else a short safe text code (internal/test use only -- the public RPC always collapses any non-null result to SNAPSHOT_VERSION_UNSUPPORTED or SNAPSHOT_INTEGRITY_ERROR, never echoing this code or any snapshot content). Internal-only: security invoker, EXECUTE revoked from public/anon/authenticated, invoked only by a SECURITY DEFINER owner function under the invoice row''s own lock. Deliberately does NOT compare against a carrier''s CURRENT live factoring_mode (0136) -- only a snapshot inconsistent with itself, its own version contract, or its own invoice''s relational columns is a problem; policy drift after issuance is normal and must never invalidate an already-issued invoice''s payment eligibility.';

-- ======================= PHASE 6C -- external-reference hygiene =============
-- Phase 3B.5.1, Section F: p_external_reference is a free-text receipt/
-- check/processor CONFIRMATION reference only -- never a place to store a
-- card number, CVV, bank account/routing credential, or API token/secret.
-- credit_card/ach/wire payment_method entries recorded by this ledger are
-- MANUAL ACCOUNTING RECORDS of a payment that happened elsewhere (e.g. a
-- bank wire, a swiped card on a third-party terminal) -- never gateway
-- processing, never a place authorized to receive raw payment credentials.
-- This is a best-effort, defense-in-depth format/heuristic filter (never a
-- substitute for not collecting sensitive data client-side in the first
-- place) -- internal-only, same access pattern as PHASE 6B.
create function public._carrier_invoice_payment_external_reference_problem(
  p_value text,
  out problem_code text,
  out normalized text
)
returns record
language plpgsql
security invoker
immutable
set search_path = pg_catalog, public
as $fn$
declare
  v_stripped text;
begin
  problem_code := null;
  normalized := nullif(btrim(coalesce(p_value, '')), '');
  if normalized is null then
    return; -- optional field; empty/omitted is fine.
  end if;

  if length(normalized) > 100 then
    problem_code := 'EXTERNAL_REFERENCE_TOO_LONG';
    return;
  end if;
  if normalized ~ '[\x00-\x1F\x7F]' then
    problem_code := 'EXTERNAL_REFERENCE_INVALID_CHARACTERS';
    return;
  end if;

  -- A long run of digits (spaces/dashes ignored) is card/account/routing-
  -- number shaped -- reject regardless of formatting.
  v_stripped := regexp_replace(normalized, '[\s-]', '', 'g');
  if v_stripped ~ '^[0-9]{13,34}$' then
    problem_code := 'EXTERNAL_REFERENCE_LOOKS_LIKE_FINANCIAL_ACCOUNT_NUMBER';
    return;
  end if;

  -- Credential-shaped keyword/prefix blocklist (case-insensitive).
  if lower(normalized) ~ '(cvv|cvc|card\s*(number|no)|routing\s*number|account\s*number|social\s*security|ssn\b|pin\s*code|api[_\s]?key|secret[_\s]?key|access[_\s]?token|password|private[_\s]?key)' then
    problem_code := 'EXTERNAL_REFERENCE_LOOKS_LIKE_CREDENTIAL';
    return;
  end if;
  if normalized ~ '^(sk|pk|rk)_(live|test)_' or normalized ~ '^(whsec_|ghp_|gho_|xox)' or normalized ilike 'bearer %' then
    problem_code := 'EXTERNAL_REFERENCE_LOOKS_LIKE_CREDENTIAL';
    return;
  end if;
end;
$fn$;

revoke all on function public._carrier_invoice_payment_external_reference_problem(text) from public, anon, authenticated;

comment on function public._carrier_invoice_payment_external_reference_problem(text) is
  'Phase 3B.5.1, Section F: trims/length-limits (100 chars) p_external_reference, rejects control characters, and heuristically rejects content shaped like a card/bank account/routing number or a labeled/prefixed credential (CVV, API key, bearer token, etc.). Never a substitute for not collecting real payment credentials client-side. Internal-only, same access pattern as carrier_invoice_payment_snapshot_problem().';

-- ======================= PHASE 7 -- record_carrier_invoice_payment ==========
-- Section D's 25-step flow. Reuses carrier_invoice_lifecycle_idempotency
-- (0142/0143) directly -- see this migration''s own header, Section A.
create function public.record_carrier_invoice_payment(
  p_invoice_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_payment_method text,
  p_external_reference text,
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
  v_operation constant text := 'record_carrier_invoice_payment';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_row public.carrier_invoices%rowtype;
  v_method public.carrier_invoice_payment_method;
  v_payment_id uuid;
  v_li_id uuid;
  v_payer_type public.carrier_invoice_payer_type;
  v_payer_broker_id uuid;
  v_payer_customer_id uuid;
  v_payer_carrier_id uuid;
  v_sum_posted numeric(12, 2);
  v_new_amount_paid numeric(12, 2);
  v_new_payment_status public.invoice_payment_status;
  v_result jsonb;
  v_constraint text;
  v_snapshot_problem text;
  v_factoring_mode text;
  v_ext_ref_problem text;
  v_ext_ref_normalized text;
begin
  ------------------------------------------------------------------
  -- STEP 1: authenticate + role. service_role has no auth.uid() of its
  -- own -- structurally cannot pass, exactly like every other guarded
  -- financial RPC in this schema.
  ------------------------------------------------------------------
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  -- Section F: owner/admin/accountant may record.
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to record a carrier invoice payment.');
  end if;

  ------------------------------------------------------------------
  -- STEP 2: derive organization.
  ------------------------------------------------------------------
  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  ------------------------------------------------------------------
  -- STEP 3/4: canonicalize + SHA-256 fingerprint (0143 mechanism).
  ------------------------------------------------------------------
  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'invoice_id', p_invoice_id, 'amount', p_amount, 'payment_date', p_payment_date,
      'payment_method', p_payment_method, 'external_reference', nullif(btrim(coalesce(p_external_reference, '')), ''),
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );

  ------------------------------------------------------------------
  -- STEP 5: organization+operation+idempotency-key advisory lock.
  ------------------------------------------------------------------
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  ------------------------------------------------------------------
  -- STEP 6 (lock order position 2): lock the carrier invoice row.
  ------------------------------------------------------------------
  select * into v_row from public.carrier_invoices where id = p_invoice_id for update;

  ------------------------------------------------------------------
  -- STEP 7: revalidate tenant -- deliberately indistinguishable from
  -- not-found, matching every other guarded RPC in this schema.
  ------------------------------------------------------------------
  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  ------------------------------------------------------------------
  -- STEP 8: resolve idempotency replay/collision (operation-scoped,
  -- reusing carrier_invoice_lifecycle_idempotency directly).
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
  -- STEP 9/10: require issued, reject voided.
  ------------------------------------------------------------------
  if v_row.issuance_status in ('draft', 'ready_for_issue') then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Only an issued invoice can receive a payment.');
  end if;
  if v_row.issuance_status = 'voided' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'A voided invoice cannot receive a new payment.');
  end if;

  ------------------------------------------------------------------
  -- Amount validation (Section C: "amount must be positive"; Section D
  -- never trusts a client-supplied balance/status).
  ------------------------------------------------------------------
  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('success', false, 'code', 'INVALID_AMOUNT', 'message', 'Payment amount must be greater than zero.');
  end if;
  if p_payment_date is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'A payment date is required.');
  end if;
  begin
    v_method := p_payment_method::public.carrier_invoice_payment_method;
  exception
    when invalid_text_representation then
      return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'Unrecognized payment method.');
  end;

  ------------------------------------------------------------------
  -- Phase 3B.5.1, Section F: external-reference hygiene -- trim/length-
  -- limit/control-character/credential-shape validation. Never echoes the
  -- submitted value back in a structured error.
  ------------------------------------------------------------------
  select problem_code, normalized into v_ext_ref_problem, v_ext_ref_normalized
  from public._carrier_invoice_payment_external_reference_problem(p_external_reference);
  if v_ext_ref_problem is not null then
    return jsonb_build_object('success', false, 'code', 'INVALID_EXTERNAL_REFERENCE', 'message', 'The payment reference is invalid. Use only a short receipt/check/processor confirmation reference -- never a card number, bank account/routing number, or API credential.');
  end if;

  if v_row.balance_due <= 0 then
    return jsonb_build_object('success', false, 'code', 'ALREADY_PAID', 'message', 'This invoice is already fully paid.');
  end if;

  ------------------------------------------------------------------
  -- STEP 11: currency consistency -- always server-derived (see PHASE 5's
  -- own cross-table trigger for the real backstop); this explicit check
  -- keeps the step visible/testable even though it is structurally
  -- guaranteed true given p_amount/p_payment_method carry no currency of
  -- their own to disagree with.
  ------------------------------------------------------------------
  if v_row.currency !~ '^[A-Z]{3}$' then
    return jsonb_build_object('success', false, 'code', 'CURRENCY_MISMATCH', 'message', 'The invoice does not carry a valid currency.');
  end if;

  ------------------------------------------------------------------
  -- STEP 12/13: determine document type; derive the payer relationship
  -- from the invoice''s own already-immutable identity -- NEVER client-
  -- supplied (Section D).
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'carrier_freight_invoice' then
    if v_row.recipient_type = 'broker' and v_row.recipient_broker_id is not null then
      v_payer_type := 'broker';
      v_payer_broker_id := v_row.recipient_broker_id;
    elsif v_row.recipient_type = 'customer' and v_row.recipient_customer_id is not null then
      v_payer_type := 'customer';
      v_payer_customer_id := v_row.recipient_customer_id;
    else
      -- Structurally unreachable given cinv_recipient_shape (0142) --
      -- kept as defense-in-depth, never a raw error.
      return jsonb_build_object('success', false, 'code', 'PAYER_MISMATCH', 'message', 'This invoice has no valid recipient to pay it.');
    end if;
  elsif v_row.invoice_document_type = 'dispatch_service_invoice' then
    if v_row.carrier_id is null then
      return jsonb_build_object('success', false, 'code', 'PAYER_MISMATCH', 'message', 'This invoice has no valid payer.');
    end if;
    v_payer_type := 'carrier';
    v_payer_carrier_id := v_row.carrier_id;
  else
    return jsonb_build_object('success', false, 'code', 'PAYER_MISMATCH', 'message', 'Unrecognized invoice document type.');
  end if;

  ------------------------------------------------------------------
  -- STEP 14 (Phase 3B.5.1, Section B/E/H; version-gated by Phase 3B.5.2,
  -- Section E): centralized snapshot-integrity validation for BOTH
  -- document types (never freight-only), using the ONE canonical,
  -- VERSION-AWARE validator (SECTION B/PHASE 6B) -- never a second,
  -- slightly-different set of JSON-path assumptions. Every internal
  -- problem_code prefixed 'VERSION_' (missing/null/non-numeric/
  -- unsupported schema_version -- including BOTH now-superseded v1
  -- shapes) maps to the external code SNAPSHOT_VERSION_UNSUPPORTED; every
  -- other non-null problem_code (a schema_version=2 snapshot that is
  -- internally malformed or inconsistent with its own invoice) maps to
  -- SNAPSHOT_INTEGRITY_ERROR. Neither ever returns raw JSON/snapshot
  -- content, and neither produces any mutation. Only once the snapshot is
  -- confirmed version-2 AND consistent is a factored carrier_freight_
  -- invoice rejected with FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_
  -- WORKFLOW -- three deliberately distinct failure classes (wrong
  -- version, malformed, and factored are never conflated).
  ------------------------------------------------------------------
  select problem_code, factoring_mode into v_snapshot_problem, v_factoring_mode
  from public.carrier_invoice_payment_snapshot_problem(p_invoice_id);

  if v_snapshot_problem is not null then
    if v_snapshot_problem like 'VERSION_%' then
      return jsonb_build_object(
        'success', false, 'code', 'SNAPSHOT_VERSION_UNSUPPORTED',
        'message', 'This invoice''s issuance record uses an unsupported snapshot version and cannot accept a payment through this workflow. Contact support.'
      );
    end if;
    return jsonb_build_object(
      'success', false, 'code', 'SNAPSHOT_INTEGRITY_ERROR',
      'message', 'This invoice''s issuance record failed an internal consistency check and cannot accept a payment. Contact support.'
    );
  end if;

  if v_factoring_mode = 'factored' then
    return jsonb_build_object(
      'success', false, 'code', 'FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW',
      'message', 'This invoice is factored -- ordinary payment posting is not supported. A dedicated factoring-funding workflow is required (not yet implemented).'
    );
  end if;

  ------------------------------------------------------------------
  -- STEP 15 (lock order position 3): lock every existing posted payment
  -- for this invoice, ascending id -- belt-and-suspenders on top of the
  -- invoice row lock already held (which alone already fully serializes
  -- concurrent record/void calls against this SAME invoice), matching
  -- 0144''s own established "explicit locking on top of a parent lock
  -- that already serializes it" convention (its own STEP 16, line items).
  ------------------------------------------------------------------
  for v_li_id in
    select id from public.carrier_invoice_payments
    where carrier_invoice_id = p_invoice_id and status = 'posted'
    order by id
  loop
    perform 1 from public.carrier_invoice_payments where id = v_li_id for update;
  end loop;

  select coalesce(sum(amount), 0) into v_sum_posted
  from public.carrier_invoice_payments
  where carrier_invoice_id = p_invoice_id and status = 'posted';

  ------------------------------------------------------------------
  -- STEP 16/17: recompute the TRUE remaining balance from the locked
  -- ledger itself (never trust the invoice''s own amount_paid alone,
  -- self-healing by construction) and reject overpayment.
  ------------------------------------------------------------------
  v_new_amount_paid := v_sum_posted + p_amount;
  if v_new_amount_paid > v_row.total_amount then
    return jsonb_build_object(
      'success', false, 'code', 'OVERPAYMENT',
      'message', 'This payment would exceed the invoice''s remaining balance.',
      'remaining_balance', v_row.total_amount - v_sum_posted
    );
  end if;

  ------------------------------------------------------------------
  -- STEP 20: derive payment_status, matching cinv_payment_status_
  -- consistency''s own shape exactly.
  ------------------------------------------------------------------
  v_new_payment_status := case
    when v_new_amount_paid = 0 then 'unpaid'
    when v_new_amount_paid >= v_row.total_amount then 'paid'
    else 'partially_paid'
  end;

  begin
    ------------------------------------------------------------------
    -- STEP 18: insert the posted payment.
    ------------------------------------------------------------------
    insert into public.carrier_invoice_payments
      (organization_id, carrier_invoice_id, payment_date, amount, currency, payment_method, external_reference,
       payer_type, payer_broker_id, payer_customer_id, payer_carrier_id, recorded_by)
    values
      (v_org, p_invoice_id, p_payment_date, p_amount, v_row.currency, v_method, v_ext_ref_normalized,
       v_payer_type, v_payer_broker_id, v_payer_customer_id, v_payer_carrier_id, v_uid)
    returning id into v_payment_id;

    ------------------------------------------------------------------
    -- STEP 19/20/21: recalculate amount_paid, set payment_status,
    -- issuance_status untouched.
    ------------------------------------------------------------------
    update public.carrier_invoices
      set amount_paid = v_new_amount_paid, payment_status = v_new_payment_status
      where id = p_invoice_id;

    ------------------------------------------------------------------
    -- STEP 22: one audit event.
    ------------------------------------------------------------------
    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_payment_recorded',
      jsonb_build_object('payment_id', v_payment_id, 'amount', p_amount, 'new_amount_paid', v_new_amount_paid, 'new_payment_status', v_new_payment_status, 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'PAYMENT_RECORDED', 'payment_id', v_payment_id, 'invoice_id', p_invoice_id,
      'amount', p_amount, 'amount_paid', v_new_amount_paid, 'payment_status', v_new_payment_status,
      'balance_due', v_row.total_amount - v_new_amount_paid
    );

    ------------------------------------------------------------------
    -- STEP 23: store idempotency result.
    ------------------------------------------------------------------
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

  ------------------------------------------------------------------
  -- STEP 25: commit atomically (implicit -- caller''s own transaction).
  ------------------------------------------------------------------
  return v_result;
end;
$fn$;

comment on function public.record_carrier_invoice_payment(uuid, numeric, date, text, text, timestamptz, text, text) is
  'Phase 3B.5, hardened in Phase 3B.5.1, version-gated by Phase 3B.5.2: owner/admin/accountant. Atomically records a posted payment against an ISSUED, non-voided carrier_invoices row and rolls up amount_paid/payment_status -- never trusts a client-supplied organization/carrier/payer/recipient/currency/balance/payment_status/amount_paid. Validates the invoice''s own issuance snapshot via the single canonical, version-aware carrier_invoice_payment_snapshot_problem() (SECTION B/PHASE 6B) before ever inserting a payment row -- a snapshot that is not schema_version=2 (any v1 shape, missing/null/non-numeric/unknown version) fails closed with SNAPSHOT_VERSION_UNSUPPORTED; a schema_version=2 snapshot that is internally malformed or inconsistent with its own invoice fails closed with SNAPSHOT_INTEGRITY_ERROR; neither ever returns raw JSON/snapshot content. Only a snapshot confirmed version-2 AND consistent AND carrying factoring mode=''factored'' is rejected with FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW -- factoring funding is never an ordinary payment (Section B/H). p_external_reference is validated/normalized by _carrier_invoice_payment_external_reference_problem() (Section F) -- INVALID_EXTERNAL_REFERENCE on anything control-character-bearing, over 100 chars, or shaped like a card/bank-account/routing number or a labeled credential/API token; never echoed back.';

revoke all on function public.record_carrier_invoice_payment(uuid, numeric, date, text, text, timestamptz, text, text) from public, anon;
grant execute on function public.record_carrier_invoice_payment(uuid, numeric, date, text, text, timestamptz, text, text) to authenticated;

-- ======================= PHASE 8 -- void_carrier_invoice_payment ============
-- Section E's 16-step flow.
create function public.void_carrier_invoice_payment(
  p_payment_id uuid,
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
  v_operation constant text := 'void_carrier_invoice_payment';
  v_schema_version constant integer := 1;
  v_fingerprint text;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_lock_key bigint;
  v_provisional_invoice_id uuid;
  v_row public.carrier_invoices%rowtype;
  v_payment public.carrier_invoice_payments%rowtype;
  v_other_id uuid;
  v_sum_posted numeric(12, 2);
  v_new_amount_paid numeric(12, 2);
  v_new_payment_status public.invoice_payment_status;
  v_result jsonb;
  v_constraint text;
begin
  ------------------------------------------------------------------
  -- STEP 1: authenticate + role (Section F: owner/admin/accountant may
  -- void -- no existing business rule in this schema restricts accountant
  -- from voiding a carrier-invoice payment specifically, so the task''s
  -- own approved default matrix applies).
  ------------------------------------------------------------------
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Authentication required.');
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'An idempotency key is required.');
  end if;
  if not public.has_role(array['owner', 'admin', 'accountant']::public.org_role[]) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to void a carrier invoice payment.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation, 'schema_version', v_schema_version, 'organization_id', v_org,
      'payment_id', p_payment_id, 'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );

  ------------------------------------------------------------------
  -- STEP 3: operation-scoped advisory lock.
  ------------------------------------------------------------------
  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  ------------------------------------------------------------------
  -- STEP 2/4 (lock order position 2, BEFORE the payment row): a
  -- provisional (unlocked) read of the payment''s own carrier_invoice_id
  -- is required to know which invoice to lock first -- carrier_
  -- invoice_id is immutable on this table (PHASE 5''s own guard), so this
  -- provisional read is stable. Organization is revalidated (Section E
  -- step 2: "derive organization through payment/invoice") once BOTH
  -- rows are locked, below.
  ------------------------------------------------------------------
  select carrier_invoice_id into v_provisional_invoice_id from public.carrier_invoice_payments where id = p_payment_id;
  if v_provisional_invoice_id is not null then
    select * into v_row from public.carrier_invoices where id = v_provisional_invoice_id for update;
  end if;

  ------------------------------------------------------------------
  -- STEP 5 (lock order position 3): lock the payment row itself.
  ------------------------------------------------------------------
  select * into v_payment from public.carrier_invoice_payments where id = p_payment_id and organization_id = v_org for update;
  if v_payment.id is null or v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Payment not found.');
  end if;

  ------------------------------------------------------------------
  -- STEP 7: idempotency replay/collision.
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

  if v_payment.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This payment has changed since you loaded it. Reload and try again.');
  end if;

  ------------------------------------------------------------------
  -- STEP 6: revalidate payment still posted.
  ------------------------------------------------------------------
  if v_payment.status = 'voided' then
    return jsonb_build_object('success', false, 'code', 'PAYMENT_ALREADY_VOIDED', 'message', 'This payment has already been voided.');
  end if;

  ------------------------------------------------------------------
  -- STEP 9: require a meaningful void reason.
  ------------------------------------------------------------------
  if p_reason is null or btrim(p_reason) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_STATE', 'message', 'A void reason is required.');
  end if;

  -- Belt-and-suspenders lock on every OTHER posted payment for this same
  -- invoice, ascending id, before recomputing the rollup -- matching
  -- record_carrier_invoice_payment()''s own STEP 15.
  for v_other_id in
    select id from public.carrier_invoice_payments
    where carrier_invoice_id = v_row.id and status = 'posted' and id <> p_payment_id
    order by id
  loop
    perform 1 from public.carrier_invoice_payments where id = v_other_id for update;
  end loop;

  begin
    ------------------------------------------------------------------
    -- STEP 8/10/11/12: mark voided, void_reason = p_reason (the only
    -- reason parameter this RPC''s own signature carries), voided_by
    -- from auth.uid(), voided_at from database time.
    ------------------------------------------------------------------
    update public.carrier_invoice_payments
      set status = 'voided', void_reason = p_reason, voided_by = v_uid, voided_at = now()
      where id = p_payment_id;

    ------------------------------------------------------------------
    -- STEP 13/14: recalculate the rollup from every REMAINING posted
    -- payment (the just-voided one no longer counts).
    ------------------------------------------------------------------
    select coalesce(sum(amount), 0) into v_sum_posted
    from public.carrier_invoice_payments
    where carrier_invoice_id = v_row.id and status = 'posted';

    v_new_amount_paid := v_sum_posted;
    v_new_payment_status := case
      when v_new_amount_paid = 0 then 'unpaid'
      when v_new_amount_paid >= v_row.total_amount then 'paid'
      else 'partially_paid'
    end;

    ------------------------------------------------------------------
    -- STEP 13 (preserve issuance_status + immutable snapshot -- neither
    -- is ever touched here): only amount_paid/payment_status change.
    ------------------------------------------------------------------
    update public.carrier_invoices
      set amount_paid = v_new_amount_paid, payment_status = v_new_payment_status
      where id = v_row.id;

    ------------------------------------------------------------------
    -- STEP 14: one audit event.
    ------------------------------------------------------------------
    perform public.log_activity('invoice'::public.entity_type, v_row.id, 'carrier_invoice_payment_voided',
      jsonb_build_object('payment_id', p_payment_id, 'voided_amount', v_payment.amount, 'new_amount_paid', v_new_amount_paid, 'new_payment_status', v_new_payment_status, 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'PAYMENT_VOIDED', 'payment_id', p_payment_id, 'invoice_id', v_row.id,
      'amount_paid', v_new_amount_paid, 'payment_status', v_new_payment_status,
      'balance_due', v_row.total_amount - v_new_amount_paid
    );

    ------------------------------------------------------------------
    -- STEP 15: store idempotency result.
    ------------------------------------------------------------------
    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, v_row.id, v_operation, v_fingerprint, v_schema_version, v_result, 'completed', v_uid);
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

  ------------------------------------------------------------------
  -- STEP 16: return, commit atomically.
  ------------------------------------------------------------------
  return v_result;
end;
$fn$;

comment on function public.void_carrier_invoice_payment(uuid, timestamptz, text, text) is
  'Phase 3B.5: owner/admin/accountant. Atomically voids a posted payment (never deletes, never reactivates) and rolls up amount_paid/payment_status from every REMAINING posted payment -- voiding the final/full payment on an invoice correctly reopens its balance (payment_status reverts to unpaid/partially_paid as appropriate). issuance_status and the immutable issuance snapshot are never touched.';

revoke all on function public.void_carrier_invoice_payment(uuid, timestamptz, text, text) from public, anon;
grant execute on function public.void_carrier_invoice_payment(uuid, timestamptz, text, text) to authenticated;

-- ======================= PHASE 9 -- POSTCONDITIONS ===========================
do $mig$
begin
  if to_regclass('public.carrier_invoice_payments') is null then
    raise exception '0146 postcondition: carrier_invoice_payments missing.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_invoice_payments' and c.conname = 'civp_payment_number_unique' and c.contype = 'u'
  ) then
    raise exception '0146 postcondition: civp_payment_number_unique missing.';
  end if;
  if not exists (
    select 1 from pg_trigger tg join pg_class t on t.oid = tg.tgrelid
    where t.relname = 'carrier_invoice_payments' and tg.tgname = 'a0146_guard_payment_lifecycle' and not tg.tgisinternal
  ) then
    raise exception '0146 postcondition: a0146_guard_payment_lifecycle trigger missing.';
  end if;
  if not exists (
    select 1 from pg_trigger tg join pg_class t on t.oid = tg.tgrelid
    where t.relname = 'carrier_invoice_payments' and tg.tgname = 'a0146_guard_payment_currency' and not tg.tgisinternal
  ) then
    raise exception '0146 postcondition: a0146_guard_payment_currency trigger missing.';
  end if;
  if to_regprocedure('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)') is null then
    raise exception '0146 postcondition: record_carrier_invoice_payment missing.';
  end if;
  if to_regprocedure('public.void_carrier_invoice_payment(uuid,timestamptz,text,text)') is null then
    raise exception '0146 postcondition: void_carrier_invoice_payment missing.';
  end if;
  if not has_function_privilege('authenticated', 'public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0146 postcondition: authenticated cannot EXECUTE record_carrier_invoice_payment.';
  end if;
  if not has_function_privilege('authenticated', 'public.void_carrier_invoice_payment(uuid,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0146 postcondition: authenticated cannot EXECUTE void_carrier_invoice_payment.';
  end if;
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) not ilike '%FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment does not return FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW.';
  end if;
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) ilike '%factored_invoices%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment appears to reference factored_invoices.';
  end if;
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) ilike '%factoring_events%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment appears to reference factoring_events.';
  end if;

  -- Phase 3B.5.1: the centralized snapshot validator and external-
  -- reference hygiene helper must exist, be internal-only, and actually
  -- be used by record_carrier_invoice_payment().
  if to_regprocedure('public.carrier_invoice_payment_snapshot_problem(uuid)') is null then
    raise exception '0146 postcondition: carrier_invoice_payment_snapshot_problem missing.';
  end if;
  if to_regprocedure('public._carrier_invoice_payment_external_reference_problem(text)') is null then
    raise exception '0146 postcondition: _carrier_invoice_payment_external_reference_problem missing.';
  end if;
  if has_function_privilege('authenticated', 'public.carrier_invoice_payment_snapshot_problem(uuid)', 'EXECUTE') then
    raise exception '0146 postcondition: authenticated must NOT be able to EXECUTE carrier_invoice_payment_snapshot_problem directly.';
  end if;
  if has_function_privilege('anon', 'public.carrier_invoice_payment_snapshot_problem(uuid)', 'EXECUTE') then
    raise exception '0146 postcondition: anon must NOT be able to EXECUTE carrier_invoice_payment_snapshot_problem directly.';
  end if;
  if has_function_privilege('authenticated', 'public._carrier_invoice_payment_external_reference_problem(text)', 'EXECUTE') then
    raise exception '0146 postcondition: authenticated must NOT be able to EXECUTE _carrier_invoice_payment_external_reference_problem directly.';
  end if;
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) not ilike '%carrier_invoice_payment_snapshot_problem%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment does not call carrier_invoice_payment_snapshot_problem.';
  end if;
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) not ilike '%SNAPSHOT_INTEGRITY_ERROR%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment does not return SNAPSHOT_INTEGRITY_ERROR.';
  end if;
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) not ilike '%_carrier_invoice_payment_external_reference_problem%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment does not call _carrier_invoice_payment_external_reference_problem.';
  end if;

  -- Phase 3B.5.2, Section E: version-gating must actually be wired up,
  -- and no v1 field-name alias may survive anywhere in the new code path.
  if (select prosrc from pg_proc where proname = 'record_carrier_invoice_payment' and pronamespace = 'public'::regnamespace) not ilike '%SNAPSHOT_VERSION_UNSUPPORTED%' then
    raise exception '0146 postcondition: record_carrier_invoice_payment does not return SNAPSHOT_VERSION_UNSUPPORTED.';
  end if;
  if (select prosrc from pg_proc where proname = 'carrier_invoice_payment_snapshot_problem' and pronamespace = 'public'::regnamespace) not ilike '%VERSION_%' then
    raise exception '0146 postcondition: carrier_invoice_payment_snapshot_problem does not implement any VERSION_ problem code.';
  end if;
  -- NOTE: these checks match the QUOTED-JSON-KEY form (''factoring_mode'',
  -- including its surrounding quotes) rather than a bare substring --
  -- carriers.factoring_mode (an entirely legitimate, still-current
  -- RELATIONAL column, unrelated to any snapshot JSON key) is referenced
  -- throughout issue_carrier_invoice's own body (e.g. v_carrier.
  -- factoring_mode) and must never trip this check; only actual usage AS
  -- A JSON OBJECT KEY (always single-quoted in this codebase's own
  -- jsonb_build_object/->>/? call style) indicates a real regression.
  if (select prosrc from pg_proc where proname = 'carrier_invoice_payment_snapshot_problem' and pronamespace = 'public'::regnamespace) ilike '%''factoring_mode''%' then
    raise exception '0146 postcondition: carrier_invoice_payment_snapshot_problem still references the retired v1 alias key ''factoring_mode'' as a JSON key.';
  end if;
  if (select prosrc from pg_proc where proname = 'carrier_invoice_payment_snapshot_problem' and pronamespace = 'public'::regnamespace) ilike '%''factoring_relationship_id''%' then
    raise exception '0146 postcondition: carrier_invoice_payment_snapshot_problem still references the retired v1 key ''factoring_relationship_id'' as a JSON key.';
  end if;

  -- Phase 3B.5.2, Section C: both replaced issuance functions must emit
  -- schema_version=2 and must not carry any retired v1 JSON key name
  -- forward (same quoted-key-form matching rationale as above).
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null then
    raise exception '0146 postcondition: issue_carrier_invoice missing (expected to be replaced by this migration).';
  end if;
  if to_regprocedure('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)') is null then
    raise exception '0146 postcondition: _issue_dispatch_service_invoice_internal missing (expected to be replaced by this migration).';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''schema_version'', 2%' then
    raise exception '0146 postcondition: issue_carrier_invoice does not emit schema_version=2.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''schema_version'', 2%' then
    raise exception '0146 postcondition: _issue_dispatch_service_invoice_internal does not emit schema_version=2.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''factoring_mode''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''factoring_relationship_id''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''factoring_company_id''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''issuing_user_id''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''company_id''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%''company_legal_name''%'
  then
    raise exception '0146 postcondition: issue_carrier_invoice still carries a retired v1 JSON key/flat (non-nested) company identity key forward into v2.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''source_loads''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''adjustment_amount''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''dispatch_service''%'
     or (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%''company''%'
  then
    raise exception '0146 postcondition: issue_carrier_invoice does not emit the corrected canonical top-level/company keys (source_loads/adjustment_amount/dispatch_service/company).';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) ilike '%''issuing_user_id''%' then
    raise exception '0146 postcondition: _issue_dispatch_service_invoice_internal still carries the retired v1 ''issuing_user_id'' JSON key forward into v2.';
  end if;
  if (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''source_loads''%'
     or (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''adjustment_amount''%'
     or (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''agreement_number''%'
     or (select prosrc from pg_proc where proname = '_issue_dispatch_service_invoice_internal' and pronamespace = 'public'::regnamespace) not ilike '%''agreement_version_id''%'
  then
    raise exception '0146 postcondition: _issue_dispatch_service_invoice_internal does not emit the corrected canonical keys (source_loads/adjustment_amount/dispatch_service.agreement_number/agreement_version_id).';
  end if;

  if exists (
    select 1 from information_schema.role_table_grants
    where grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
      and table_name = 'carrier_invoice_payments'
  ) then
    raise exception '0146 postcondition: authenticated must have zero direct INSERT/UPDATE/DELETE grant on carrier_invoice_payments.';
  end if;
  if exists (
    select 1 from information_schema.role_table_grants
    where grantee = 'anon' and table_name = 'carrier_invoice_payments'
  ) then
    raise exception '0146 postcondition: anon must have zero grant on carrier_invoice_payments.';
  end if;
  if (select count(*) from public.carrier_invoice_payments) <> 0 then
    raise exception '0146 postcondition: carrier_invoice_payments must be empty immediately after this migration -- it never inserts data.';
  end if;

  raise notice '0146 complete (Phase 3B.5 + 3B.5.1 snapshot-contract hardening + 3B.5.2 canonical version-2 snapshot correction): issue_carrier_invoice()/_issue_dispatch_service_invoice_internal() replaced IN PLACE (CREATE OR REPLACE, same signatures, same auth/lock-order/numbering/idempotency/agreement calculation/factoring readiness/audit behavior) to emit schema_version=2 with ONE canonical, permanent field-naming scheme (factoring: {"mode":"direct"} or {"mode":"factored","relationship_id","company":{"id","legal_name",...},...}; dispatch-service factoring always null) -- both now-superseded schema_version=1 shapes (0144''s original AND 0145''s own redefinition) are never silently reinterpreted, refused outright by PHASE 1B if any exist. carrier_invoice_payments (posted/voided, immutable financial identity, no delete, no reactivation, concurrency-safe payment_number via nextval()) installed; record_carrier_invoice_payment()/void_carrier_invoice_payment() installed (owner/admin/accountant; dispatcher read-only via SELECT policy), atomically rolling up carrier_invoices.amount_paid/payment_status (0142''s own generated balance_due/CHECK invariants enforce the rest); record_carrier_invoice_payment() now validates the issued snapshot via the ONE canonical, VERSION-AWARE carrier_invoice_payment_snapshot_problem() -- a non-version-2 snapshot fails closed with SNAPSHOT_VERSION_UNSUPPORTED, a malformed version-2 snapshot fails closed with SNAPSHOT_INTEGRITY_ERROR, neither ever returning raw content; only a validated, factored freight snapshot is rejected with FACTORED_INVOICE_PAYMENT_REQUIRES_FUNDING_WORKFLOW; p_external_reference is trimmed/length-limited/control-character- and credential-shape-checked (_carrier_invoice_payment_external_reference_problem, INVALID_EXTERNAL_REFERENCE, never echoed); carrier_invoice_lifecycle_idempotency (0142/0143) reused directly for both new operations. No payment-gateway/Stripe/ACH/card integration. No email/WhatsApp/PDF/QuickBooks/factoring-transmission/settlement-deduction logic. factored_invoices/factoring_events untouched. Migrations 0001-0145 untouched (0144/0145 files themselves never edited -- their installed function DEFINITIONS are replaced by this migration, exactly as 0145 itself already replaced 0144''s own issue_carrier_invoice() without editing 0144).';
end
$mig$;

commit;
