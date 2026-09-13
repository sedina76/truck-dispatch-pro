-- =============================================================================
-- 0144_atomic_carrier_invoice_issuance.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0001-0143 live. Phase 3B.3C.
--
-- GOAL: one atomic, idempotent issuance workflow for carrier_invoices
-- (0142/0143) that creates a complete, immutable financial snapshot and
-- assigns the correct issuer-scoped invoice number -- carrier_freight_
-- invoice ONLY. dispatch_service_invoice issuance is explicitly DEFERRED
-- (Section E, Option 2 -- see below) rather than guessing a fee basis no
-- authoritative agreement exists for yet.
--
-- ===========================================================================
-- SECTION A -- REINSPECTION FINDINGS (0142-0143 foundation)
-- ===========================================================================
-- carrier_invoices (0142): issuance_status (draft/ready_for_issue/issued/
--   voided) and payment_status (unpaid/partially_paid/paid) are separate
--   columns. cinv_number_iff_issued + guard_carrier_invoice_lifecycle_
--   transition together mean: (a) invoice_number/issued_at/issued_by can
--   exist ONLY once issuance_status leaves draft/ready_for_issue, (b) the
--   'issued' transition itself REQUIRES an existing issuance snapshot row
--   AND a non-null invoice_number to already be present in the SAME
--   UPDATE, (c) the issuance_status state machine permits ONLY
--   draft->{ready_for_issue,voided}, ready_for_issue->{draft,issued,
--   voided}, issued->voided -- there is NO direct draft->issued
--   transition. This RPC therefore performs TWO UPDATEs when starting
--   from draft (draft->ready_for_issue, then ready_for_issue->issued,
--   both inside the same transaction) and ONE when already ready_for_
--   issue -- never exposing prepare_carrier_invoice_for_issue as a
--   separate public RPC (Section H: unnecessary complexity -- the
--   existing trigger already IS the ready_for_issue gate; this RPC just
--   drives both legal transitions atomically, in the same call, when
--   starting from draft).
-- carrier_invoice_line_items (0142): id/organization_id/invoice_id/
--   description/quantity/unit_price/line_total(generated,quantity*
--   unit_price)/sort_order/created_at/updated_at. Already a normalized
--   line-item structure with a recalculation trigger
--   (recalculate_carrier_invoice_totals) that keeps carrier_invoices.
--   subtotal_amount/total_amount in sync on every INSERT/UPDATE/DELETE,
--   and a mutability guard (only while draft/ready_for_issue). RLS
--   already grants owner/admin/accountant/dispatcher direct INSERT/
--   UPDATE/DELETE (Section D's "strict grants" alternative to a guarded
--   RPC -- already satisfied, not duplicated here). MISSING: line_type,
--   source_load_id, source_dispatch_id, and a floor on quantity/
--   unit_price (nothing currently prevents a negative value). This
--   migration ADDS those three columns and a non-negativity constraint to
--   the EXISTING table (Section D: "if an existing normalized structure
--   already satisfies these requirements, reuse it instead of
--   duplicating it") -- no new table.
-- carrier_invoice_loads (0142): invoice<->load join, one row per source
--   load, org/carrier-consistency guarded at INSERT time, immutable once
--   draft/ready_for_issue is left. Does NOT itself re-verify the load's
--   carrier_id at ISSUANCE time (only at attach time) -- a load's own
--   carrier_id could theoretically change between attach and issuance (a
--   future load-carrier-reassignment path). This RPC re-verifies AND
--   locks every attached load at issuance (Section F items 14-15).
-- carrier_invoice_number_counters + _generate_carrier_invoice_number_
--   internal(document_type, issuer_id, prefix) (0142): atomic per-
--   (document_type, issuer_id, year) counter via INSERT...ON CONFLICT...
--   RETURNING -- never max()+1. EXECUTE revoked from every application
--   role including service_role; reachable only from a trusted SECURITY
--   DEFINER caller (this RPC) that has already verified authorization.
--   issuer_id = carrier_id (freight, prefix = carriers.invoice_code) or
--   organization_id (dispatch-service, prefix = platform_settings.
--   dispatch_invoice_prefix) -- the dispatch-service branch is wired for
--   structural completeness but is unreachable in THIS migration (Section
--   E defers all dispatch-service issuance before this step is reached).
-- carrier_invoice_lifecycle_idempotency + compute_financial_request_
--   fingerprint(jsonb) (0143): durable idempotency scope (organization_id,
--   operation, idempotency_key); SHA-256 canonical-payload fingerprint,
--   EXECUTE revoked from every client role (internal primitive only,
--   reachable via this SECURITY DEFINER RPC's ownership). This RPC uses
--   operation='issue_carrier_invoice' -- structurally independent of
--   update_carrier_invoice_draft's own 'update_carrier_invoice_draft' rows
--   in the SAME table (proven by TEST_0143 item 16; re-proven here for
--   this specific pair of operations).
-- carrier_invoice_recipient_problem / carrier_invoice_factoring_
--   readiness_problem / carrier_invoice_issuance_problem (0142): read-only,
--   STABLE, SECURITY DEFINER, EXECUTE revoked from every client role --
--   already the exact classification logic this RPC needs. Reused
--   directly (called AFTER this RPC's own row locks are held, so their
--   own un-locked internal SELECTs observe the same locked, current data)
--   rather than re-implemented, per this project's own DRY precedent.
-- Legacy invoice isolation (0142 Section L / this migration's own
--   baseline): every legacy public.invoices row remains untouched;
--   submit_invoice_to_factor() (0140) remains unconditionally fail-closed
--   for every row (no carrier_invoices-aware snapshot exists there) --
--   this migration adds NO bridge in either direction. A legacy invoice
--   has no carrier_invoices row at all, so issue_carrier_invoice() cannot
--   reach it (NOT_FOUND) by construction, not by a special-cased check.
-- RLS/grants (0142): carrier_invoices has exactly ONE authenticated-
--   writable column (notes); issuance_status/invoice_number/issued_at/
--   issued_by/totals/due_date have zero direct grant for any role --
--   this RPC's SECURITY DEFINER privileges are the ONLY path to those
--   columns, exactly as 0142's own header already promised.
-- Factoring readiness (0138-0141): classify_carrier_factoring_readiness(
--   carrier_id, broker_id, customer_id) is the authoritative 'ready'
--   classifier (integration- and exception-aware); factoring_
--   relationships carries remittance_instructions/noa_*/submission_method/
--   submission_destination_email/submission_integration_id;
--   carrier_factoring_integrations carries secret_reference (NEVER
--   snapshotted) plus configuration_status (text, CHECKed to
--   draft/pending_verification/ready/suspended/revoked/failed, with
--   is_active structurally tied to ='ready'). set_carrier_factoring_
--   policy/set_default_factoring_relationship/approve_factoring_
--   relationship_noa/the 0141 integration-lifecycle RPCs each lock ONLY
--   {carriers} or ONLY {factoring_relationships[, carrier_factoring_
--   integrations]} (in that relative order) -- never both groups
--   together, and never together with carrier_invoices, loads, brokers,
--   or customers. This RPC is the only transaction that ever holds
--   carriers AND factoring_relationships AND carrier_factoring_
--   integrations locks together -- see LOCK_ORDER_0144_INVOICE_ISSUANCE.md
--   for the full proof this introduces no new deadlock cycle.
-- Missing authoritative source identified: NO carrier dispatch-service
--   fee agreement/basis exists anywhere in 0001-0143 (no percentage, flat
--   fee, minimum, or effective-dated agreement identity). Section E
--   requires NOT guessing a default -- see the Option 2 decision below.
--
-- ===========================================================================
-- SECTION E DECISION -- DISPATCH-SERVICE FEE SOURCE: OPTION 2
-- ===========================================================================
-- No authoritative carrier dispatch-service agreement exists (verified
-- above). Building a versioned agreement foundation (Option 1) inside this
-- same migration -- on top of an already-large atomic-issuance RPC --
-- would make 0144 too broad (the task's own stated reason to prefer
-- Option 2). issue_carrier_invoice() therefore determines invoice_
-- document_type EARLY and, for dispatch_service_invoice, returns the
-- structured code DISPATCH_SERVICE_AGREEMENT_REQUIRED immediately --
-- BEFORE locking the carrier, any recipient, any source load, allocating
-- a number, or building a snapshot -- rather than silently using a
-- default percentage/flat fee the carrier never agreed to. A dispatch-
-- service draft may still be CREATED (already possible via 0142) and
-- edited (already possible via update_carrier_invoice_draft, 0143) --
-- only ISSUANCE is blocked, honestly, until a future migration adds the
-- agreement foundation and removes this early return.
--
-- ===========================================================================
-- WHAT THIS MIGRATION DOES
-- ===========================================================================
--   PHASE 1: preconditions (0143 live, 0144 not yet applied).
--   PHASE 2: extends carrier_invoice_line_items additively -- line_type
--     (new enum carrier_invoice_line_item_type: freight_charge,
--     dispatch_service_fee -- adjustment/credit-debit categories are
--     DELIBERATELY NOT added yet, Section D: "reserve future credit/debit
--     adjustments without implementing them incompletely"), source_
--     load_id, source_dispatch_id, and a non-negativity constraint on
--     quantity/unit_price (no negative value of any kind is permitted --
--     this IS the structural way "no negative dispatch fee in a freight
--     invoice" and "no arbitrary negative values simulating undocumented
--     credits" are both satisfied, since nothing here can ever be
--     negative in the first place).
--   PHASE 3: hardens guard_carrier_invoice_line_item_mutability() and
--     guard_carrier_invoice_load_mutability() (both CREATE OR REPLACE --
--     already-committed 0142 migration file itself untouched, exactly the
--     0067->0068->0069 / 0143-on-0142 precedent of a later migration
--     altering an earlier migration's objects) to (a) lock the parent
--     carrier_invoices row (FOR UPDATE) before reading its issuance_
--     status -- closing the race where a concurrent line-item/load-link
--     mutation's own un-locked status read could observe a stale pre-
--     issuance status while this RPC's issuance transaction is in
--     flight (Section L items 7/13); (b) (line items only) enforce that
--     line_type matches the invoice's own document type (freight_charge
--     only on carrier_freight_invoice, dispatch_service_fee only on
--     dispatch_service_invoice) -- the structural half of "no negative
--     dispatch fee is inserted into a freight invoice" (the OTHER half,
--     "no negative value at all", is the Phase 2 CHECK constraint).
--   PHASE 4: issue_carrier_invoice(uuid, timestamptz, text, text) --
--     the atomic issuance RPC (see its own header below for the full
--     30-step contract).
--   PHASE 5: postconditions.
--
-- ===========================================================================
-- PHASE 3B.3C.1 CORRECTION -- lock-order reversal fix (folded into this
-- same, still-uncommitted migration -- 0144 has never been applied, so
-- there is no separate prior boundary to preserve).
-- ===========================================================================
-- The first draft of this migration locked carriers BEFORE factoring_
-- relationships. transition_carrier_factoring_integration_lifecycle()
-- (0141, the function behind activate_/deactivate_/verify_/fail_/
-- revoke_/rotate_carrier_factoring_integration) locks, for its 'ready'
-- (activation) transition: factoring_relationships (line ~634, FOR
-- UPDATE) -> carriers (via a join, "FOR UPDATE OF c") -> factoring_
-- companies (FOR SHARE) -> the NOA document (FOR SHARE) -> the
-- integration row itself (FOR UPDATE). Two transactions acquiring
-- {carriers, factoring_relationships} in opposite order is a textbook
-- AB-BA deadlock: issuance holding carriers and waiting on the
-- relationship, while an activation call holds the relationship and
-- waits on carriers, for the SAME carrier/relationship pair. This
-- migration now locks factoring_relationships BEFORE carriers,
-- matching 0141's own established order exactly (see PHASE 4 below and
-- LOCK_ORDER_0144_INVOICE_ISSUANCE.md for the full trigger-inclusive
-- proof this does not reverse any OTHER existing 0130-0143 path).
--
-- Because the invoice row alone does not reveal which relationship is
-- "the" one to lock until the carrier's policy is known, and locking
-- carriers first to find out would reproduce the exact reversal being
-- fixed, the relationship is discovered PROVISIONALLY (an unlocked read,
-- BEFORE any lock in this chain is taken) and then locked first; every
-- value is re-read and revalidated against the LOCKED, authoritative
-- rows afterward. A mismatch (the carrier's current default relationship
-- turns out to differ from what was provisionally read) returns the new
-- structured STALE_CONFIGURATION code rather than attempting a wrong-
-- order lock or using stale data -- Section A/E's explicit requirement.
--
-- Also corrected in this same pass (Section B): the carrier remittance
-- profile and the NOA document are now genuinely LOCKED (FOR SHARE, not
-- merely read) before being snapshotted -- an immutable invoice must
-- never contain a combination of carrier identity and remittance
-- information, or factoring identity and NOA verification state, that
-- never coexisted at one valid, locked point; and every invoice line
-- item is now explicitly locked (ascending id) before totals are
-- recalculated, not merely protected transitively by the parent
-- invoice-row lock the Phase 3 mutability-guard hardening already
-- provides.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not modify migrations 0001-0143 (their own files)
--   * does not implement dispatch-service issuance (Option 2 above)
--   * does not add a carrier dispatch-service agreement table
--   * does not add void/payment RPCs
--   * does not add email, WhatsApp, PDF, factoring API transmission,
--     portal submission, or QuickBooks sync
--   * does not restore dispatch/load-derived authorization for legacy
--     invoices (public.invoices remains completely untouched and
--     unreachable from this RPC)
--   * does not trust any client-provided total, invoice number, issuer
--     identity, recipient identity, carrier, factor, NOA, remittance, or
--     submission destination -- every one of these is re-derived from
--     already-locked, server-side rows
--   * does not use service_role for any ordinary authenticated action
--
-- ===========================================================================
-- PHASE 3B.3C.2 ADDITION -- route-snapshot lock closure (folded into this
-- same, still-uncommitted migration; migrations 0001-0143 untouched).
-- ===========================================================================
-- Section A finding (test-harness only, NOT a defect in this migration or
-- in committed migration 0141): TEST_CONCURRENCY_0141_integration_
-- lifecycle.sh Scenario 5's final assertion printed a "!! FAIL" line but
-- never set its own FAIL accumulator, so the script exited 0 and printed
-- PASSED despite the marker -- a bash test-harness defect, corrected
-- directly in that shell script (see ASSERT_CONCURRENCY_LOG_INTEGRITY.sh
-- for the static/empirical proof this class of defect cannot recur
-- silently). Root-causing WHY the original assertion could fail also
-- surfaced that the test's own expectation was incomplete (rotate_
-- carrier_factoring_integration()'s p_expected_updated_at is supplied via
-- a LIVE subquery, so rotation's own optimistic-concurrency check can
-- legitimately fire against a racing deactivation -- a second, equally
-- valid final state 0141 itself already handles correctly by design).
-- Neither finding required any change to migration 0141 or to this
-- migration's carrier-factoring-integration logic.
--
-- Section C/D finding (this migration, addressed below): the immutable
-- invoice snapshot's origin/destination/pickup/delivery data is derived
-- from load_stops, but the first draft of issue_carrier_invoice() never
-- locked load_stops at all -- a concurrent stop edit, reorder, or delete
-- could race the snapshot build, and row-locking alone cannot prevent a
-- brand-new stop from being INSERTed into a locked load's stop set mid-
-- issuance (a row lock cannot lock the absence of a row). This migration
-- now (a) installs guard_load_stops_parent_lock(), a BEFORE INSERT OR
-- UPDATE OR DELETE trigger on load_stops that locks the stop's own parent
-- loads row before proceeding -- the same lock, at the same global lock-
-- order position, issue_carrier_invoice() already takes on that row,
-- forcing every stop mutation path (including brand-new inserts) to
-- serialize against issuance; (b) locks every attached load's load_stops
-- rows, ascending (load_id, stop_sequence, id), immediately after locking
-- loads and before any other lock in the chain; (c) rejects, only once
-- every stop is locked, a load missing a pickup or delivery stop
-- (INVOICE_INCOMPLETE), a duplicate/ambiguous stop_sequence, or a
-- malformed route with a delivery sequenced before any pickup (both
-- SOURCE_LOAD_CONFLICT) -- so the snapshot's origin/destination selection
-- (earliest-sequence pickup / latest-sequence delivery) is provably
-- unambiguous and never built from a provisional pre-lock read.
--
-- Section D finding: source_dispatch_id on carrier_invoice_line_items is,
-- across every existing INSERT path in 0001-0144, ALWAYS NULL in practice
-- (added in Phase 3B.3C as a forward-looking nullable column, never
-- populated) -- no mutable dispatch field (status/driver/truck/trailer)
-- is ever read into the snapshot, so there is no mutable dispatch DATA
-- that can go stale. What CAN change is the association itself (which
-- load/carrier a dispatch row belongs to), so this migration still locks
-- (FOR SHARE, ascending id) every distinct non-null source_dispatch_id
-- referenced by the invoice's own line items and re-validates, under
-- that lock, that dispatch.load_id is one of this invoice's own attached
-- (locked) loads and dispatch.carrier_id matches this invoice's own
-- (locked) carrier -- rejecting a mismatch via SOURCE_LOAD_CONFLICT. This
-- code path is a structural no-op against every current fixture (nothing
-- populates source_dispatch_id yet) and is included so the association
-- is provably protected the moment a future migration starts populating
-- it, rather than being silently unimplemented.
--
-- Lock order: loads (ascending id) -> load_stops (ascending load_id,
-- stop_sequence, id) -> dispatches referenced by source_dispatch_id
-- (share, ascending id) -> factoring_relationships (provisional) ->
-- carriers -> ... -- see LOCK_ORDER_0144_INVOICE_ISSUANCE.md for the full,
-- updated proof this introduces no new deadlock cycle against any
-- existing 0001-0143 path (including the new load_stops trigger, which
-- every existing load_stops writer -- the generic RLS-granted INSERT/
-- UPDATE/DELETE paths, there being no dedicated RPC for stop mutation in
-- 0001-0143 -- now transparently participates in).
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
begin
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is null then
    raise exception '0144 precondition: compute_financial_request_fingerprint(jsonb) (0143) missing -- apply 0143 first. STOP.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation') then
    raise exception '0144 precondition: carrier_invoice_lifecycle_idempotency.operation (0143) missing -- apply 0143 first. STOP.';
  end if;
  if to_regclass('public.carrier_invoice_line_items') is null then
    raise exception '0144 precondition: carrier_invoice_line_items (0142) missing. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='line_type') then
    raise exception '0144 precondition: carrier_invoice_line_items.line_type already exists -- 0144 partially applied? STOP.';
  end if;
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is not null then
    raise exception '0144 precondition: issue_carrier_invoice(...) already exists -- 0144 partially applied? STOP.';
  end if;
  if to_regtype('public.carrier_invoice_line_item_type') is not null then
    raise exception '0144 precondition: carrier_invoice_line_item_type already exists -- 0144 partially applied? STOP.';
  end if;

  raise notice '0144 PHASE 1 preconditions passed. carrier_invoice_line_items confirmed to not yet have line_type -- safe to extend.';
end
$mig$;

-- ======================= PHASE 2 -- extend carrier_invoice_line_items ======
create type public.carrier_invoice_line_item_type as enum ('freight_charge', 'dispatch_service_fee');

comment on type public.carrier_invoice_line_item_type is
  'Phase 3B.3C (Section D): freight_charge is used on carrier_freight_invoice line items; dispatch_service_fee is reserved for a FUTURE dispatch-service issuance path (0144 itself never inserts a dispatch_service_fee row -- dispatch-service issuance is deferred, DISPATCH_SERVICE_AGREEMENT_REQUIRED). Adjustment/credit/debit categories are DELIBERATELY not added yet (Section D: reserve without implementing incompletely) -- a future migration that adds them must also decide their sign/validation rules explicitly, not inherit this enum''s current all-non-negative invariant by accident.';

alter table public.carrier_invoice_line_items
  add column line_type public.carrier_invoice_line_item_type not null default 'freight_charge',
  add column source_load_id uuid references public.loads (id) on delete restrict,
  add column source_dispatch_id uuid references public.dispatches (id) on delete restrict;

alter table public.carrier_invoice_line_items
  add constraint civli_amounts_nonnegative check (quantity >= 0 and unit_price >= 0);

comment on column public.carrier_invoice_line_items.line_type is
  'Phase 3B.3C: which invoice document type this line legitimately belongs to -- enforced (matches the parent invoice''s invoice_document_type) by guard_carrier_invoice_line_item_mutability(), not merely by convention.';
comment on column public.carrier_invoice_line_items.source_load_id is
  'Phase 3B.3C: the specific load this freight-charge line derives from, where applicable. Nullable -- not every line item needs to trace to one load (e.g. a flat/period-based line).';
comment on column public.carrier_invoice_line_items.source_dispatch_id is
  'Phase 3B.3C: the specific dispatch a dispatch-service-fee line derives from, where applicable (reserved -- unused until dispatch-service issuance exists). Nullable.';

-- ======================= PHASE 3 -- harden the mutability guards ===========
-- Section L items 7/13: a concurrent draft line-item/load-link mutation
-- must not be able to observe a stale pre-issuance status while this
-- RPC's own transaction is mid-flight. Both guards now lock the SAME
-- carrier_invoices row (FOR UPDATE) issue_carrier_invoice() itself locks
-- first -- whichever transaction gets there first proceeds; the loser
-- waits, then re-reads the (possibly now 'issued') status and correctly
-- rejects if it is no longer draft/ready_for_issue. This is the SAME
-- single-table lock issue_carrier_invoice() already needs for itself --
-- no new lock resource, no new deadlock surface (see
-- LOCK_ORDER_0144_INVOICE_ISSUANCE.md).
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
  v_doc_type public.invoice_document_type;
begin
  select organization_id, issuance_status, invoice_document_type into v_org, v_status, v_doc_type
  from public.carrier_invoices where id = v_invoice_id
  for update;
  if v_status is null then
    raise exception 'carrier_invoice_line_items: invoice not found.' using errcode = '23503';
  end if;
  if v_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoice_line_items: line items are immutable once the invoice has left draft/ready_for_issue (current status: %).', v_status using errcode = '55000';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.organization_id <> v_org then
    raise exception 'carrier_invoice_line_items: organization_id must match the invoice''s own organization.' using errcode = '23514';
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    if new.line_type = 'freight_charge' and v_doc_type <> 'carrier_freight_invoice' then
      raise exception 'carrier_invoice_line_items: a freight_charge line can only belong to a carrier_freight_invoice.' using errcode = '23514';
    end if;
    if new.line_type = 'dispatch_service_fee' and v_doc_type <> 'dispatch_service_invoice' then
      raise exception 'carrier_invoice_line_items: a dispatch_service_fee line can only belong to a dispatch_service_invoice.' using errcode = '23514';
    end if;
  end if;
  return coalesce(new, old);
end;
$fn$;

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
  from public.carrier_invoices where id = coalesce(new.invoice_id, old.invoice_id)
  for update;
  if v_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoice_loads: load links are immutable once the invoice has left draft/ready_for_issue (current status: %).', v_status using errcode = '55000';
  end if;
  return coalesce(new, old);
end;
$fn$;

comment on function public.guard_carrier_invoice_line_item_mutability() is
  'Phase 3B.3A/3B.3C: line items are mutable only while the parent invoice is draft/ready_for_issue (checked under a FOR UPDATE lock on the parent row, serializing against issue_carrier_invoice()''s own lock on the same row -- Phase 3B.3C hardening), organization_id must match, and line_type must match the parent''s invoice_document_type.';
comment on function public.guard_carrier_invoice_load_mutability() is
  'Phase 3B.3A/3B.3C: load links are mutable only while the parent invoice is draft/ready_for_issue (checked under a FOR UPDATE lock on the parent row, serializing against issue_carrier_invoice()''s own lock on the same row -- Phase 3B.3C hardening).';

-- ======================= PHASE 3b -- load_stops parent-row lock ============
-- Phase 3B.3C.2, Section C requirement 7: "ensure a new stop cannot be
-- inserted into the locked load's stop set during issuance." A row lock
-- taken inside issue_carrier_invoice() on the EXISTING load_stops rows
-- (STEP 11a below) cannot, by definition, lock the ABSENCE of a row --
-- nothing stops a brand-new INSERT from proceeding concurrently unless
-- that INSERT is itself forced to contend for a lock issuance already
-- holds.
--
-- load_stops had NO guard trigger anywhere in migrations 0001-0144 before
-- this: it only received generic RLS-based CRUD via the standard_tables
-- policy-generation loop in 0010_rls_policies.sql. This trigger is a
-- pure lock-ordering device -- it enforces no business rule of its own
-- and has no knowledge of invoices/issuance -- it simply forces EVERY
-- load_stops INSERT/UPDATE/DELETE (on any load, at any time, from any
-- calling path) to first acquire a FOR UPDATE lock on that stop's own
-- parent loads row, i.e. the exact same lock resource, at the exact
-- same global lock-order position (position 3 -- see
-- LOCK_ORDER_0144_INVOICE_ISSUANCE.md), that issue_carrier_invoice()
-- already acquires in STEP 11 before it ever inspects load_stops. A
-- concurrent stop INSERT therefore either: (a) acquires the parent lock
-- first and commits/rolls back before issuance's own STEP 11 parent
-- lock is granted, so issuance's subsequent load_stops read in STEP 11a
-- correctly observes the fully-committed new stop and validates against
-- it; or (b) blocks on the parent lock until issuance's transaction
-- ends, so the new stop is never observed mid-issuance and never
-- silently missing from the snapshot either -- both are safe, and no
-- third interleaving is possible because both paths serialize on the
-- identical lock.
--
-- Phase 3B.3C.3 CORRECTION (Section A): the original body locked
-- `coalesce(new.load_id, old.load_id)` for every operation. For INSERT
-- and DELETE that is exactly right (there is only ever one candidate
-- parent -- NEW for an insert, OLD for a delete). For an UPDATE that
-- changes load_id (moving a stop from one load to another), `coalesce`
-- evaluates to NEW.load_id ONLY -- OLD.load_id's own parent is NEVER
-- locked at all. That leaves the SOURCE load's stop set exposed: an
-- issuance transaction already mid-flight against the OLD load could
-- observe the stop still present (pre-lock read) or already gone
-- (post-move read) with NO serialization against the move on that side
-- -- a genuine unlocked-parent gap, not merely a race with two safe
-- outcomes. Two ways to close it were available: (a) reject the
-- cross-load move outright, forcing a delete-then-insert through this
-- SAME trigger (each half independently, correctly locks its own single
-- parent); or (b) lock BOTH OLD.load_id and NEW.load_id, in ascending
-- id order, before allowing the move. Option (a) is chosen: no
-- application code, RPC, service job, or test in this codebase (0001-
-- 0144, re-verified directly for this correction -- see
-- LOAD_STOPS_MUTATION_AUDIT_0144.md, Section B's caller matrix) ever
-- changes load_stops.load_id, so rejecting it costs nothing today and
-- removes an entire dual-lock-ordering surface (and its own deadlock-
-- proof obligation) for a capability nothing exercises. A future
-- migration that needs a real "move a stop to another load" workflow
-- should add a dedicated, guarded RPC that performs the delete+insert as
-- one transaction -- not silently permit a raw UPDATE of load_id.
--
-- Phase 3B.3C.3 CORRECTION #2 (Section C -- a genuine deadlock, not a
-- hypothetical): the version above (INSERT/DELETE/same-load-UPDATE all
-- explicitly lock the parent loads row) has a real AB-BA deadlock
-- against issue_carrier_invoice() for UPDATE and DELETE specifically,
-- reliably reproduced once the race is deterministically forced (never
-- observed under plain wall-clock racing, which only wins the ordering
-- that happens not to deadlock often enough to hide it -- exactly why
-- Section C requires forcing both orderings). For UPDATE/DELETE on an
-- EXISTING row, PostgreSQL ALWAYS locks that row's own tuple (implicitly,
-- via the UPDATE/DELETE statement's own row-fetch) BEFORE this BEFORE
-- ROW trigger ever runs -- a BEFORE trigger cannot avoid or reorder this;
-- it is fundamental to how MVCC row locking and triggers interact. So
-- when this trigger THEN tried to also lock the parent `loads` row, the
-- session's own acquisition order became load_stops-row -> loads-row --
-- the EXACT REVERSE of issue_carrier_invoice()'s own loads (STEP 11) ->
-- load_stops (STEP 11a) order. Two sessions acquiring {loads-row,
-- load_stops-row} in opposite order is a textbook AB-BA deadlock:
-- issuance holds loads, waits on load_stops; the racing UPDATE/DELETE
-- holds load_stops (implicitly, before its own trigger even ran), waits
-- on loads. Fix: UPDATE (same load_id) and DELETE no longer lock `loads`
-- from this trigger AT ALL -- the row's own already-held implicit lock
-- is BY ITSELF fully sufficient serialization against issuance's own
-- STEP 11a explicit `FOR UPDATE` on that identical row (a single shared
-- resource, one acquisition order, no cycle possible -- deadlock-free by
-- construction). Only INSERT still locks `loads` from this trigger: a
-- brand-new row has no pre-existing tuple for anything to lock first, so
-- INSERT's only lock IS the loads-row, taken in the same relative
-- position issuance itself uses -- no reversal, no cycle, and this is
-- the ONLY mechanism that can close the "row locks can't lock the
-- absence of a row" INSERT gap in the first place (see the header
-- comment above). Live-proven via TEST_CONCURRENCY_0144 scenarios
-- 20A/22A/23A (forced issuance-first ordering, the exact interleaving
-- that used to deadlock, now clean) and 20B/21A/21B/22B/23B (the
-- remaining forced orderings, unaffected either way).
create or replace function public.guard_load_stops_parent_lock()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
begin
  if tg_op = 'INSERT' then
    perform 1 from public.loads where id = new.load_id for update;
    return new;
  elsif tg_op = 'DELETE' then
    -- No loads lock here -- see "CORRECTION #2" above. The target row's
    -- own implicit lock (already held by the time this trigger runs) is
    -- already sufficient; issue_carrier_invoice()'s STEP 11a locks this
    -- SAME row explicitly.
    return old;
  else -- UPDATE
    if new.load_id is distinct from old.load_id then
      raise exception 'load_stops.load_id cannot be changed by UPDATE -- move a stop to a different load by deleting it and inserting a new row instead (each half independently locks and validates its own single parent load; a raw cross-load UPDATE cannot safely lock both parents in one trigger firing without a dedicated, guarded workflow).' using errcode = '55000';
    end if;
    -- No loads lock here either -- same reasoning as DELETE.
    return new;
  end if;
end;
$fn$;

comment on function public.guard_load_stops_parent_lock() is
  'Phase 3B.3C.2, corrected twice in Phase 3B.3C.3 (Section A: per-operation locking instead of a single coalesce(new.load_id,old.load_id) shortcut that left OLD''s parent unlocked on a cross-load move, now rejected outright; Section C: removed a genuine AB-BA deadlock against issue_carrier_invoice() by no longer locking the parent loads row for UPDATE/DELETE -- the row''s own implicit lock, already held before this trigger runs, is already sufficient there). Only INSERT still explicitly locks its one parent (NEW.load_id) -- the sole case where locking loads from this trigger is both necessary (closing the "new row invisible to a row-only lock" gap) and safe (no pre-existing tuple lock to reverse against). A cross-load load_id UPDATE is REJECTED outright (55000). Enforces no other business rule and knows nothing about invoices.';

drop trigger if exists a0144_guard_load_stops_parent_lock on public.load_stops;
create trigger a0144_guard_load_stops_parent_lock
  before insert or update or delete on public.load_stops
  for each row execute function public.guard_load_stops_parent_lock();

-- ======================= PHASE 4 -- issue_carrier_invoice() =================
-- Section F: one atomic, idempotent issuance RPC. carrier_freight_invoice
-- only -- a dispatch_service_invoice is rejected early with
-- DISPATCH_SERVICE_AGREEMENT_REQUIRED (Section E, Option 2) before any
-- lock beyond the invoice row itself is taken.
--
-- CORRECTED global lock order (Phase 3B.3C.1 -- see
-- LOCK_ORDER_0144_INVOICE_ISSUANCE.md for the full, trigger-inclusive
-- proof):
--   1. advisory(org, operation, idempotency_key)
--   2. carrier_invoices (FOR UPDATE)
--   3. loads (FOR UPDATE, ascending id -- the only place this schema
--      ever locks more than one loads row together)
--   4. factoring_relationships (FOR UPDATE) -- PROVISIONALLY discovered
--      (unlocked read) before this lock, then revalidated after
--   5. carriers (FOR UPDATE)
--   6. factoring_companies (FOR SHARE)
--   7. the NOA document, if any (FOR SHARE)
--   8. carrier_factoring_integrations, if submission_method='api' (FOR
--      SHARE)
--   9. carrier_remittance_profiles (FOR SHARE)
--   10. recipient: brokers OR customers, then carrier_brokers OR
--       carrier_customers (both FOR UPDATE)
--   11. carrier_invoice_line_items (FOR UPDATE, ascending id)
--   12. the number counter (atomic internally, no separate lock)
--   13. snapshot insert + invoice status transition(s)
-- This EXACTLY matches activate_carrier_factoring_integration()'s own
-- order (0141: factoring_relationships -> carriers -> factoring_
-- companies -> NOA document -> integration) for positions 4-8, closing
-- the carrier/relationship reversal the first draft of this migration
-- had.
--
-- Any failure below this point returns a structured jsonb result and
-- performs ZERO writes (every check happens before the single APPLY
-- block); the APPLY block itself (number allocation + snapshot insert +
-- status transition(s) + audit + idempotency insert) is one savepoint-
-- scoped nested block, so a same-key collision at the final idempotency
-- INSERT rolls back the WHOLE block together -- no snapshot, no number
-- consumption, no status transition, no total mutation, no audit event,
-- no successful idempotency record survives a losing call.
create function public.issue_carrier_invoice(
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
  -- STEP 1: authenticate + role. service_role has no auth.uid() /
  -- current_org_id() context of its own -- it structurally cannot pass
  -- this check, exactly as required ("must not function as an ordinary
  -- user substitute").
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
  -- STEP 3: canonical SHA-256 fingerprint (0143 mechanism). No patch
  -- object exists for this RPC -- expected_updated_at alone pins the
  -- exact row version a genuine retry must resend.
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
  -- STEP 6: revalidate organization / not-found (deliberately
  -- indistinguishable, matching update_carrier_invoice_draft's own
  -- convention).
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
  -- STEP 9: payment_status unpaid and amount_paid zero (already
  -- structurally guaranteed by cinv_payment_requires_issued for a draft/
  -- ready_for_issue row -- re-asserted here explicitly and defensively).
  ------------------------------------------------------------------
  if v_row.payment_status <> 'unpaid' or v_row.amount_paid <> 0 then
    return jsonb_build_object('success', false, 'code', 'PAYMENT_STATE_INVALID', 'message', 'This invoice has payment activity recorded and cannot be issued through this path.');
  end if;

  ------------------------------------------------------------------
  -- STEP 10: determine invoice document type. dispatch_service_invoice
  -- is rejected NOW, before locking the carrier, any recipient, or any
  -- source load (Section E, Option 2) -- never a silently-guessed fee.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'dispatch_service_invoice' then
    return jsonb_build_object('success', false, 'code', 'DISPATCH_SERVICE_AGREEMENT_REQUIRED', 'message', 'Dispatch-service invoice issuance requires an authoritative fee agreement that does not exist yet. This invoice remains a draft.');
  end if;

  ------------------------------------------------------------------
  -- STEP 11 (global lock-order position 3): lock every source load,
  -- ascending id, BEFORE any carrier/factoring lock. Proven safe against
  -- every existing 0130-0143 load/dispatch-mutating path (guard_dispatch_
  -- carrier_scope, guard_load_carrier_change, reassign_dispatch_
  -- resources, transition_dispatch_status): none of them ever ALSO locks
  -- carriers/factoring_relationships/factoring_companies/carrier_
  -- factoring_integrations in the same transaction, so there is no
  -- existing path this ordering could reverse against -- see
  -- LOCK_ORDER_0144_INVOICE_ISSUANCE.md (Phase 3B.3C.1 revision) and
  -- Section C's dedicated two-session source-load-carrier race.
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
  -- that gap structurally: every load_stops INSERT/UPDATE/DELETE must
  -- itself lock the SAME parent loads row this RPC already holds (step
  -- 11), so a concurrent insert attempt blocks here until this
  -- transaction commits or rolls back -- never observed mid-issuance,
  -- never silently racing the snapshot.
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
  -- source_dispatch_id is currently stored ONLY as an opaque historical
  -- reference -- no mutable dispatch field (status/driver_id/truck_id/
  -- trailer_id) is ever read into the snapshot, so there is no mutable
  -- dispatch DATA to go stale. What this validates is narrower and
  -- structural: that the dispatch a line item points to still belongs
  -- to one of this invoice's own attached loads and to this invoice's
  -- own carrier -- i.e. the reference itself has not become orphaned or
  -- cross-carrier since the line item was created. No column of
  -- `dispatches` is populated by this migration's own line-item
  -- creation path (line items are created via direct RLS grant, not by
  -- this RPC), so this loop is a structural no-op today and only
  -- becomes load-bearing once a future phase starts populating
  -- source_dispatch_id -- documented here rather than left unimplemented.
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
  -- STEP 12 (global lock-order positions 4-5): PROVISIONAL (unlocked)
  -- discovery of the carrier's current default+active factoring
  -- relationship, REGARDLESS of the carrier's own factoring_mode -- a
  -- relationship can remain flagged default+active even after the
  -- carrier reverts to 'direct' (set_carrier_factoring_policy() never
  -- clears is_default/is_active), so this is the reliable way to find
  -- the correct row to lock BEFORE carriers, matching 0141's own
  -- established order (factoring_relationships -> carriers -> ...) --
  -- see this migration's own header, "PHASE 3B.3C.1 CORRECTION".
  --
  -- This read is provisional ONLY: every value is re-read and
  -- revalidated against the LOCKED, authoritative rows below. If the
  -- carrier's current default relationship turns out to differ from
  -- what was provisionally read (a genuine identity change, not merely
  -- a policy flip), STALE_CONFIGURATION is returned -- never a wrong-
  -- order lock attempt, never stale data used in the snapshot.
  ------------------------------------------------------------------
  select id into v_provisional_relationship_id
  from public.factoring_relationships
  where carrier_id = v_row.carrier_id and is_default and is_active;

  if v_provisional_relationship_id is not null then
    select * into v_relationship from public.factoring_relationships where id = v_provisional_relationship_id for update;
  end if;

  select * into v_carrier from public.carriers where id = v_row.carrier_id for update;
  if v_carrier.id is null or v_carrier.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'CARRIER_MISMATCH', 'message', 'The carrier on this invoice is not available.');
  end if;
  if not v_carrier.is_active then
    return jsonb_build_object('success', false, 'code', 'CARRIER_MISMATCH', 'message', 'This carrier is inactive.');
  end if;
  if v_carrier.invoice_code is null then
    return jsonb_build_object('success', false, 'code', 'INVOICE_INCOMPLETE', 'message', 'This carrier has no invoice numbering code configured yet.');
  end if;

  ------------------------------------------------------------------
  -- STEP 13 (global lock-order positions 5-8): direct vs factored
  -- policy, re-derived entirely from the now-LOCKED carrier row.
  -- Section E: every factoring input is locked and explicitly
  -- re-verified -- carrier remains factored; the relationship remains
  -- the carrier's current default, active, and effective; the company
  -- remains active; the NOA remains approved (and its document, if any,
  -- remains verified); the API integration (if used) remains attached
  -- to this same carrier/relationship/company and ready; and finally
  -- the authoritative readiness classifier is re-evaluated under lock.
  ------------------------------------------------------------------
  if v_carrier.factoring_mode = 'unconfigured' then
    return jsonb_build_object('success', false, 'code', 'FACTORING_POLICY_UNCONFIGURED', 'message', 'This carrier has no factoring policy configured yet (direct or factored).');
  end if;

  if v_carrier.factoring_mode = 'direct' then
    -- Section F: a concurrent factored->direct transition is always
    -- safe to just follow here -- the FINAL decision is this freshly-
    -- locked carrier row, and no data from any provisionally-locked
    -- relationship is ever used when direct. No factor identity ever
    -- enters the snapshot for a direct carrier.
    v_factoring_payload := null;
  else
    -- factored: the relationship this call must use is whatever was
    -- provisionally locked above -- carriers is already locked, so this
    -- is the last point at which the CORRECT relationship could still
    -- be acquired in-order.
    if v_relationship.id is null then
      -- Nothing was provisionally locked. Two DISTINCT situations look
      -- identical this far, and deserve DIFFERENT codes: (a) this
      -- carrier genuinely has no default+active relationship at all --
      -- a permanent configuration gap, retrying changes nothing --
      -- FACTORING_NOT_READY; (b) one was created/defaulted AFTER our
      -- provisional read -- a genuine race, a retry will now discover
      -- and lock it correctly -- STALE_CONFIGURATION. A second,
      -- still-unlocked existence check (not a new lock -- just a read,
      -- so this cannot reintroduce the carrier-before-relationship
      -- reversal) is enough to tell them apart.
      if exists (select 1 from public.factoring_relationships where carrier_id = v_carrier.id and is_default and is_active) then
        return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while processing. Please retry.');
      else
        return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier has no active default factoring relationship.');
      end if;
    end if;
    if v_relationship.carrier_id <> v_carrier.id or not v_relationship.is_default or not v_relationship.is_active then
      -- We DID lock something, but it is no longer the current default
      -- -- a genuine identity change between the provisional read and
      -- the lock. Always a race, never a permanent gap.
      return jsonb_build_object('success', false, 'code', 'STALE_CONFIGURATION', 'message', 'This carrier''s factoring configuration changed while processing. Please retry.');
    end if;
    if v_relationship.effective_from > current_date
       or (v_relationship.effective_to is not null and v_relationship.effective_to < current_date) then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s default factoring relationship is not currently effective.');
    end if;

    select * into v_company from public.factoring_companies where id = v_relationship.factoring_company_id for share;
    if v_company.id is null or not v_company.is_active then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s factoring company is not active.');
    end if;

    if v_relationship.noa_document_id is not null then
      select * into v_doc from public.documents where id = v_relationship.noa_document_id for share;
      if v_doc.id is null or not coalesce(v_doc.is_verified, false) then
        return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s Notice of Assignment document is no longer verified.');
      end if;
    end if;
    if not v_relationship.noa_approved then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s Notice of Assignment is not approved.');
    end if;

    if v_relationship.submission_method = 'api' then
      select * into v_integration
      from public.carrier_factoring_integrations
      where factoring_relationship_id = v_relationship.id and is_active
      for share;
      if v_integration.id is null
         or v_integration.carrier_id <> v_carrier.id
         or v_integration.factoring_company_id <> v_company.id
         or v_integration.configuration_status <> 'ready' then
        return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s API factoring integration is not ready.');
      end if;
    end if;

    -- Final confirmation: the SAME authoritative classifier this schema
    -- already established (0138/0139/0141), now evaluated entirely
    -- under lock.
    v_classification := public.classify_carrier_factoring_readiness(v_carrier.id, v_row.recipient_broker_id, v_row.recipient_customer_id);
    if not (v_classification->>'success')::boolean or v_classification->>'classification' <> 'ready' then
      return jsonb_build_object('success', false, 'code', 'FACTORING_NOT_READY', 'message', 'This carrier''s factoring configuration is not ready for issuance.', 'classification', v_classification->>'classification');
    end if;

    v_factoring_payload := jsonb_build_object(
      'factoring_mode', 'factored',
      'relationship_id', v_relationship.id,
      'factoring_company_id', v_company.id,
      'factoring_company_legal_name', coalesce(v_company.legal_name, v_company.name),
      'remittance_instructions', v_relationship.remittance_instructions,
      'noa_reference', v_relationship.noa_reference,
      'noa_effective_date', v_relationship.noa_effective_date,
      'noa_approved', v_relationship.noa_approved,
      'noa_approved_at', v_relationship.noa_approved_at,
      'noa_document_id', v_relationship.noa_document_id,
      'noa_document_snapshot_file_name', v_relationship.noa_document_snapshot_file_name,
      'submission_method', v_relationship.submission_method,
      'submission_destination',
        case v_relationship.submission_method
          when 'secure_email' then v_relationship.submission_destination_email
          when 'api' then null -- never a raw destination for API -- the integration_id below is the safe pointer.
          else v_relationship.submission_notes
        end,
      'integration_id', v_integration.id
    );
  end if;

  ------------------------------------------------------------------
  -- STEP 14 (global lock-order position 9): carrier remittance profile.
  -- LOCKED (FOR SHARE), not merely read -- Section B: an immutable
  -- invoice must never contain a combination of carrier identity and
  -- remittance information that never coexisted at one valid, locked
  -- serialization point. No client write path exists for this table
  -- (only a direct, owner/admin-gated RLS UPDATE) -- FOR SHARE correctly
  -- conflicts with that concurrent UPDATE.
  ------------------------------------------------------------------
  select * into v_remit from public.carrier_remittance_profiles where carrier_id = v_carrier.id for share;

  ------------------------------------------------------------------
  -- STEP 15 (global lock-order position 10): resolve + lock exactly one
  -- recipient, validate the carrier-party relationship and active
  -- eligibility.
  ------------------------------------------------------------------
  if v_row.recipient_type = 'broker' then
    if v_row.recipient_broker_id is null then
      return jsonb_build_object('success', false, 'code', 'RECIPIENT_REQUIRED', 'message', 'A broker or customer recipient is required before issuance.');
    end if;
    select * into v_broker from public.brokers where id = v_row.recipient_broker_id for update;
    select status, billing_email, payment_terms_days
      into v_party_status, v_party_billing_email, v_party_payment_terms
    from public.carrier_brokers where carrier_id = v_row.carrier_id and broker_id = v_row.recipient_broker_id
    for update;
  elsif v_row.recipient_type = 'customer' then
    if v_row.recipient_customer_id is null then
      return jsonb_build_object('success', false, 'code', 'RECIPIENT_REQUIRED', 'message', 'A broker or customer recipient is required before issuance.');
    end if;
    select * into v_customer from public.customers where id = v_row.recipient_customer_id for update;
    select status, billing_email, payment_terms_days
      into v_party_status, v_party_billing_email, v_party_payment_terms
    from public.carrier_customers where carrier_id = v_row.carrier_id and customer_id = v_row.recipient_customer_id
    for update;
  else
    return jsonb_build_object('success', false, 'code', 'RECIPIENT_REQUIRED', 'message', 'A broker or customer recipient is required before issuance.');
  end if;

  -- Re-derive eligibility with the SAME classification logic
  -- carrier_invoice_recipient_problem already implements -- now safely
  -- observing the rows THIS transaction has already locked above.
  v_problem := public.carrier_invoice_recipient_problem(p_invoice_id);
  if v_problem is not null then
    return jsonb_build_object('success', false, 'code', 'RECIPIENT_INELIGIBLE', 'message', 'The recipient is not eligible for this invoice.', 'reason', v_problem);
  end if;

  ------------------------------------------------------------------
  -- STEP 16 (global lock-order position 11): lock every line item row,
  -- ascending id, THEN recalculate totals from the now-locked set
  -- (never from any client-supplied value -- this RPC's own signature
  -- accepts no total/subtotal parameter at all); validate currency and
  -- payment terms. Explicit locking here is deliberate belt-and-
  -- suspenders on top of the Phase 3 mutability-guard hardening (which
  -- already serializes any concurrent line-item mutation behind this
  -- same transaction's carrier_invoices lock) -- it keeps this
  -- function's own correctness self-contained rather than depending
  -- entirely on a trigger defined elsewhere.
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
  -- issuer/year invoice number. Freight only is reachable here
  -- (dispatch-service already returned at STEP 10) -- the dispatch-
  -- service branch is retained for structural completeness/
  -- documentation only.
  ------------------------------------------------------------------
  if v_row.invoice_document_type = 'carrier_freight_invoice' then
    v_number := public._generate_carrier_invoice_number_internal('carrier_freight_invoice'::public.invoice_document_type, v_carrier.id, v_carrier.invoice_code);
  else
    -- Unreachable in this migration (STEP 10 already returned) -- kept
    -- so a future migration that removes the STEP 10 early return does
    -- not also have to reinvent this branch.
    v_number := public._generate_carrier_invoice_number_internal(
      'dispatch_service_invoice'::public.invoice_document_type, v_org,
      (select dispatch_invoice_prefix from public.platform_settings limit 1));
  end if;

  ------------------------------------------------------------------
  -- STEP 15 (recipient identity) + STEP 11 (loads) payloads, built from
  -- already-locked rows only.
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
      'load_id', l.id, 'load_number', l.load_number, 'agreed_freight_charge', l.rate,
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
  from public.loads l where l.id = any(v_load_ids);

  ------------------------------------------------------------------
  -- STEP 13 (build phase): build the complete server-generated immutable snapshot
  -- payload; reject forbidden secret/credential keys (defense-in-depth --
  -- civs_no_forbidden_keys on the target table is the structural
  -- backstop; this is the RPC's own explicit check of its own intent).
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
  -- STEP 13 (apply phase): insert exactly one snapshot; set invoice_number/
  -- issued_at/issued_by/issuance_status='issued'/totals/due_date; write
  -- exactly one audit event; store the idempotency result -- all in ONE
  -- savepoint-scoped block (mirrors update_carrier_invoice_draft's own
  -- established pattern), so a same-key collision at the final INSERT
  -- rolls back everything above together.
  ------------------------------------------------------------------
  begin
    -- draft -> issued requires the intermediate ready_for_issue step
    -- (the lifecycle trigger's state machine has no direct draft->issued
    -- transition -- see this migration's own header, Section A).
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
      -- The whole block above (status transition + snapshot + number
      -- allocation + audit + this same INSERT attempt) has already been
      -- rolled back to the savepoint -- structurally unreachable in
      -- practice (the advisory lock already serializes every caller
      -- sharing this exact org+operation+key tuple); defense-in-depth
      -- only, matching update_carrier_invoice_draft's own precedent.
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
  'Phase 3B.3C, lock-order-corrected in Phase 3B.3C.1, route-snapshot-locked in Phase 3B.3C.2: the ONE atomic, idempotent issuance path for carrier_freight_invoice (dispatch_service_invoice returns DISPATCH_SERVICE_AGREEMENT_REQUIRED -- Section E Option 2, no authoritative fee agreement exists yet). Owner/admin/accountant only. Locks carrier_invoices -> loads (ascending id) -> load_stops (ascending load_id, stop_sequence, id; a BEFORE trigger on load_stops itself, guard_load_stops_parent_lock(), forces every INSERT/UPDATE/DELETE on any load''s stops to first lock that same parent loads row, so a stop cannot be inserted into, edited on, or removed from a locked load mid-issuance without blocking on this same lock -- see LOCK_ORDER_0144_INVOICE_ISSUANCE.md) -> dispatches referenced by source_dispatch_id (share, ascending id) -> factoring_relationships (provisionally discovered, unlocked, before this lock) -> carriers -> factoring_companies (share) -> NOA document (share) -> carrier_factoring_integrations (share, api only) -> carrier_remittance_profiles (share) -> recipient (broker/customer + carrier-party row) -> carrier_invoice_line_items (ascending id) -- see LOCK_ORDER_0144_INVOICE_ISSUANCE.md. This EXACT relationship-before-carrier-before-company-before-NOA-before-integration order matches activate_carrier_factoring_integration() (0141) precisely, closing a carrier/relationship lock-order reversal found in the first draft of this migration. A provisional (unlocked) read discovers which relationship to lock before carriers is known to be lockable in order; every value is re-validated under lock afterward, and a genuine identity change (the carrier''s current default relationship differs from what was provisionally read) returns STALE_CONFIGURATION rather than a wrong-order lock or stale data. Once every attached load''s stops are locked, rejects a missing pickup/delivery (INVOICE_INCOMPLETE), an ambiguous duplicate stop_sequence, or a malformed/inverted route (delivery sequenced before pickup) (both SOURCE_LOAD_CONFLICT) -- only then are origin/destination read for the snapshot, so the snapshot route is always either wholly pre-change or wholly post-change, never a mixture. Recalculates totals from carrier_invoice_line_items only (never a client-supplied total); allocates the invoice number via the private, per-(document_type,issuer,year) counter; builds and inserts one immutable snapshot from entirely LOCKED rows (carrier, remittance profile, recipient, factoring identity, NOA document verification, load_stops-derived route, line items); performs draft->ready_for_issue->issued (or ready_for_issue->issued) in the same transaction; writes exactly one audit event; stores one idempotency result -- all inside one savepoint-scoped block so any failure leaves no snapshot, no number consumption, no status transition, no total mutation, no audit event, and no successful idempotency record. Never trusts a client-provided total, invoice number, issuer identity, recipient identity, carrier, factor, NOA, remittance, route/stop data, dispatch association, or submission destination -- every one is re-derived from rows this same call has already locked. Never returns secret_reference or a raw fingerprint.';

-- ======================= PHASE 5 -- POSTCONDITIONS ==========================
do $mig$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='line_type') then
    raise exception '0144 postcondition: carrier_invoice_line_items.line_type missing.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='source_load_id') then
    raise exception '0144 postcondition: carrier_invoice_line_items.source_load_id missing.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name='source_dispatch_id') then
    raise exception '0144 postcondition: carrier_invoice_line_items.source_dispatch_id missing.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_invoice_line_items' and c.conname = 'civli_amounts_nonnegative'
  ) then
    raise exception '0144 postcondition: civli_amounts_nonnegative constraint missing.';
  end if;
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null then
    raise exception '0144 postcondition: issue_carrier_invoice(...) missing.';
  end if;
  if not has_function_privilege('authenticated', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0144 postcondition: authenticated should be able to EXECUTE issue_carrier_invoice (its own internal role check gates actual use).';
  end if;
  if has_function_privilege('anon', 'public.issue_carrier_invoice(uuid,timestamptz,text,text)', 'EXECUTE') then
    raise exception '0144 postcondition: anon should not be able to EXECUTE issue_carrier_invoice.';
  end if;
  if (select prosrc from pg_proc where proname = 'guard_carrier_invoice_line_item_mutability' and pronamespace = 'public'::regnamespace) not ilike '%for update%' then
    raise exception '0144 postcondition: guard_carrier_invoice_line_item_mutability() no longer locks the parent invoice row.';
  end if;
  if (select prosrc from pg_proc where proname = 'guard_carrier_invoice_load_mutability' and pronamespace = 'public'::regnamespace) not ilike '%for update%' then
    raise exception '0144 postcondition: guard_carrier_invoice_load_mutability() no longer locks the parent invoice row.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) ilike '%request_fingerprint''%,%v_fingerprint%' then
    raise exception '0144 postcondition: issue_carrier_invoice appears to leak request_fingerprint in a client-facing object literal.';
  end if;
  if (select count(*) from public.carrier_invoice_issuance_snapshots) <> 0 then
    raise exception '0144 postcondition: carrier_invoice_issuance_snapshots must still be empty -- this migration never inserts data.';
  end if;
  if (select count(*) from public.carrier_invoices where issuance_status = 'issued') <> 0 then
    raise exception '0144 postcondition: no carrier_invoices row should be issued by this migration itself.';
  end if;

  -- Phase 3B.3C.1: structural proof of the corrected lock order --
  -- the factoring_relationships lock (source position of the FIRST
  -- "from public.factoring_relationships ... for update" occurrence)
  -- must appear BEFORE the carriers lock (source position of "from
  -- public.carriers where id = v_row.carrier_id for update") in this
  -- function's own source text, matching activate_carrier_factoring_
  -- integration()'s (0141) established relationship-before-carrier
  -- order and closing the reversal this correction fixes.
  if (
    select position('from public.factoring_relationships where id = v_provisional_relationship_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) = 0 then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer locks factoring_relationships via the provisional-discovery path.';
  end if;
  if (
    select position('from public.factoring_relationships where id = v_provisional_relationship_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) >= (
    select position('from public.carriers where id = v_row.carrier_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) then
    raise exception '0144 postcondition: issue_carrier_invoice() locks carriers before factoring_relationships -- this is the exact reversal Phase 3B.3C.1 fixes, against activate_carrier_factoring_integration() (0141).';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%STALE_CONFIGURATION%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer returns STALE_CONFIGURATION for a changed factoring identity.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%carrier_remittance_profiles where carrier_id = v_carrier.id for share%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer locks the carrier remittance profile.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%carrier_invoice_line_items where id = v_li_id for update%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer explicitly locks invoice line item rows.';
  end if;

  -- Phase 3B.3C.2, Section C: the load_stops parent-lock guard trigger
  -- exists, is a BEFORE trigger firing on all three mutation ops.
  if not exists (
    select 1 from pg_trigger tg
    join pg_class t on t.oid = tg.tgrelid
    join pg_proc p on p.oid = tg.tgfoid
    where t.relname = 'load_stops'
      and tg.tgname = 'a0144_guard_load_stops_parent_lock'
      and p.proname = 'guard_load_stops_parent_lock'
      and not tg.tgisinternal
  ) then
    raise exception '0144 postcondition: a0144_guard_load_stops_parent_lock trigger missing on public.load_stops.';
  end if;

  -- Phase 3B.3C.3, Section A: the trigger must lock NEW.load_id on
  -- INSERT and reject (never silently allow) a cross-load UPDATE --
  -- never the single `coalesce(new.load_id, old.load_id)` shortcut,
  -- which leaves OLD's parent unlocked on a cross-load move.
  if (select prosrc from pg_proc where proname = 'guard_load_stops_parent_lock' and pronamespace = 'public'::regnamespace) ilike '%coalesce(new.load_id, old.load_id) for update%' then
    raise exception '0144 postcondition: guard_load_stops_parent_lock() still uses the single coalesce(new.load_id, old.load_id) lock shortcut -- Phase 3B.3C.3 requires per-operation locking.';
  end if;
  if (select prosrc from pg_proc where proname = 'guard_load_stops_parent_lock' and pronamespace = 'public'::regnamespace) not ilike '%from public.loads where id = new.load_id for update%' then
    raise exception '0144 postcondition: guard_load_stops_parent_lock() no longer locks NEW.load_id on INSERT.';
  end if;
  if (select prosrc from pg_proc where proname = 'guard_load_stops_parent_lock' and pronamespace = 'public'::regnamespace) not ilike '%new.load_id is distinct from old.load_id%' then
    raise exception '0144 postcondition: guard_load_stops_parent_lock() no longer rejects a cross-load_id UPDATE.';
  end if;
  -- Phase 3B.3C.3, Section C: DELETE/same-load UPDATE must NOT also lock
  -- `loads` -- that additional lock is exactly the AB-BA deadlock this
  -- correction removes (see the function's own header comment). The only
  -- `from public.loads where id = ... for update` in this function's
  -- source must be the INSERT branch's `new.load_id` lock -- verified by
  -- counting occurrences of the lock pattern: exactly one.
  if (
    select length(prosrc) - length(replace(prosrc, 'from public.loads where id =', ''))
    from pg_proc where proname = 'guard_load_stops_parent_lock' and pronamespace = 'public'::regnamespace
  ) / length('from public.loads where id =') <> 1 then
    raise exception '0144 postcondition: guard_load_stops_parent_lock() does not lock public.loads EXACTLY once (INSERT only) -- DELETE/same-load UPDATE must never also lock it (AB-BA deadlock risk).';
  end if;

  -- Phase 3B.3C.2, Section C: issue_carrier_invoice() locks load_stops
  -- (ascending load_id, stop_sequence, id) strictly AFTER locking loads
  -- and strictly BEFORE the provisional factoring_relationships lookup
  -- -- i.e. the route snapshot can only ever be built from rows locked
  -- at global lock-order position 3, never from a pre-lock read.
  if (
    select position('from public.loads where id = v_load_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) = 0
  or (
    select position('order by load_id, stop_sequence, id' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) = 0
  or (
    select position('from public.loads where id = v_load_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) >= (
    select position('order by load_id, stop_sequence, id' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer locks load_stops (ascending load_id, stop_sequence, id) after locking loads.';
  end if;
  if (
    select position('order by load_id, stop_sequence, id' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) >= (
    select position('from public.factoring_relationships where id = v_provisional_relationship_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) then
    raise exception '0144 postcondition: issue_carrier_invoice() locks load_stops after (rather than before) the factoring_relationships lock -- wrong global lock order.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%INVOICE_INCOMPLETE%One or more attached loads is missing a pickup or delivery stop%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer rejects loads missing a pickup or delivery stop.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%ambiguous stop sequencing%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer rejects duplicate/ambiguous stop_sequence values.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%malformed route%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer rejects a malformed/inverted route.';
  end if;

  -- Phase 3B.3C.2, Section D: source_dispatch_id association is locked
  -- and re-validated under lock, strictly AFTER load_stops and strictly
  -- BEFORE the factoring_relationships lookup.
  if (
    select position('from public.dispatches where id = v_dispatch_id for share' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) = 0 then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer locks dispatches referenced by source_dispatch_id.';
  end if;
  if (
    select position('order by load_id, stop_sequence, id' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) >= (
    select position('from public.dispatches where id = v_dispatch_id for share' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) then
    raise exception '0144 postcondition: issue_carrier_invoice() locks dispatches before load_stops -- wrong global lock order.';
  end if;
  if (
    select position('from public.dispatches where id = v_dispatch_id for share' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) >= (
    select position('from public.factoring_relationships where id = v_provisional_relationship_id for update' in prosrc)
    from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace
  ) then
    raise exception '0144 postcondition: issue_carrier_invoice() locks dispatches after (rather than before) the factoring_relationships lock -- wrong global lock order.';
  end if;
  if (select prosrc from pg_proc where proname = 'issue_carrier_invoice' and pronamespace = 'public'::regnamespace) not ilike '%d.load_id <> all(v_load_ids) or d.carrier_id is distinct from v_row.carrier_id%' then
    raise exception '0144 postcondition: issue_carrier_invoice() no longer revalidates locked dispatches'' load/carrier association.';
  end if;

  raise notice '0144 complete: carrier_invoice_line_items extended with line_type/source_load_id/source_dispatch_id + a non-negativity constraint; guard_carrier_invoice_line_item_mutability()/guard_carrier_invoice_load_mutability() now lock the parent invoice row (closing the draft-mutation-races-issuance gap) and (line items) enforce line_type/document_type consistency; guard_load_stops_parent_lock() installed as a BEFORE trigger on load_stops (Phase 3B.3C.2, Section C) forcing every stop insert/update/delete to lock its parent loads row, closing the "new stop inserted mid-issuance" gap that row-locking the existing stops alone cannot close; issue_carrier_invoice(uuid,timestamptz,text,text) installed -- atomic, idempotent carrier_freight_invoice issuance (SHA-256 fingerprint, organization+operation+idempotency-key advisory lock, full lock-ordered validation including load_stops (ascending load_id/stop_sequence/id, rejecting missing/duplicate/malformed route structure) and source_dispatch_id association (locked, ascending id, re-validated against the locked load/carrier), server-recalculated totals, immutable route-locked snapshot, private numbering, one audit event). dispatch_service_invoice issuance returns DISPATCH_SERVICE_AGREEMENT_REQUIRED (no authoritative fee agreement exists -- Section E Option 2). No email/WhatsApp/PDF/factoring-transmission/QuickBooks logic added. Migrations 0001-0143 untouched.';
end
$mig$;

commit;
