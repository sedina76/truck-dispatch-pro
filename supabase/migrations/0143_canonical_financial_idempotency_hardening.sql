-- =============================================================================
-- 0143_canonical_financial_idempotency_hardening.sql
--
-- PRE-APPLY -- DO NOT APPLY WITHOUT MANUAL REVIEW. APPLY AS ONE TRANSACTION.
-- REQUIRES 0001-0142 live. Phase 3B.3B.
--
-- GOAL: replace the ambiguous MD5 concatenation fingerprint 0142 introduced
-- (md5(invoice_id || patch::text || reason || expected_updated_at::text))
-- with a canonical, explicitly-framed, SHA-256 request fingerprint, and
-- close a real durable-scope gap 0142 left open, BEFORE any other
-- financial RPC builds on the same idempotency pattern. Migration 0142
-- itself is NOT modified (it is already committed) -- this migration
-- ALTERS what 0142 created, exactly the way 0067->0068->0069 or
-- 0136->0138->0139 already alter earlier migrations' tables/functions in
-- this same schema's own history.
--
-- WHAT WAS WRONG WITH 0142's FINGERPRINT (found in review, Phase 3B.3B):
--   1. MD5 is not the right primitive for financial request identity --
--      not because it is "crackable" here (the input is not secret), but
--      because it gives no canonical framing: `md5(a || '|' || b || ...)`
--      is a bare concatenation with an ad-hoc delimiter. Two DIFFERENT
--      logical inputs could theoretically produce the same concatenated
--      string if a field's own text ever contained the literal '|'
--      delimiter (patch::text cannot today, since jsonb text never
--      contains an unescaped '|' outside a string value in a position
--      that could shift field boundaries -- but relying on "cannot today"
--      is exactly the ambiguity this migration removes structurally,
--      rather than by argument).
--   2. Every field must have an EXPLICIT JSON key (operation,
--      schema_version, organization_id, invoice_id, patch, reason,
--      expected_updated_at) so the fingerprint is self-describing and
--      extensible, not a positional string blob.
--   3. THE DURABLE SCOPE GAP: the advisory lock 0142 added was already
--      scoped to (organization_id, 'update_draft', idempotency_key), but
--      the TABLE's own unique constraint (civ_idempotency_unique) was
--      only (organization_id, idempotency_key) -- narrower than the lock.
--      A future RPC reusing this same table with a different `action`
--      value could have its own idempotency row collide with an
--      unrelated operation's row at the raw constraint level, and 0142's
--      own lookup query never filtered by action/operation at all. This
--      migration closes that gap by widening the constraint to
--      (organization_id, operation, idempotency_key) and having every
--      lookup/insert filter by operation explicitly.
--
-- WHAT THIS MIGRATION DOES:
--   A. Verifies pgcrypto is already installed (0001 already creates it;
--      this is a defensive re-assertion, `create extension if not
--      exists`, never a hard new dependency -- see the precondition
--      block below for what happens if it is somehow missing).
--   B. public.compute_financial_request_fingerprint(jsonb) -- a tiny,
--      deliberately generic SHA-256 hashing primitive: SHA-256(canonical
--      jsonb payload, serialized to text). The CALLER builds its own
--      fully-keyed canonical payload (operation/schema_version/
--      organization_id/... plus whatever fields THAT operation's request
--      identity actually depends on) and passes the whole object here --
--      this is the reusable "pattern" future financial RPCs (0144's
--      atomic issuance included) are meant to build on, per this phase's
--      own stated goal.
--   C. Hardens public.carrier_invoice_lifecycle_idempotency (0142):
--        * `action` renamed to `operation` (same data preserved,
--          clearer name matching the canonical scope requirement) --
--          existing rows (there should be none; see Guard 2 below) keep
--          their exact original value.
--        * `fingerprint_version integer not null default 1` added --
--          reserved so a FUTURE fingerprint-algorithm change can follow
--          this same migration's own precedent (classify existing rows
--          by shape, refuse to guess, refuse to proceed if ambiguous)
--          without ever silently reinterpreting a stored hash's meaning.
--        * `state text not null default 'completed'`, `created_by uuid`,
--          `updated_at timestamptz not null default now()` added -- this
--          table only ever stores a SUCCESSFUL, already-completed result
--          today (0142's own function only INSERTs on success), so
--          'completed' is the only value that will ever appear in
--          practice unless a future operation introduces an interim
--          state; created_by is populated from auth.uid() at insert time
--          going forward (nullable -- historical/legacy rows, if any
--          were ever grandfathered in by a future migration, may not
--          have one).
--        * civ_idempotency_unique widened from (organization_id,
--          idempotency_key) to (organization_id, operation,
--          idempotency_key) -- the Preferred, future-compatible scope
--          Section B calls for.
--   D. Redefines public.update_carrier_invoice_draft(uuid, jsonb,
--      timestamptz, text, text) -- SAME public signature, preserving
--      every behavioral guarantee 0142 established (role authorization,
--      strict patch allowlist, organization derivation, advisory-lock-
--      before-row-lock ordering, optimistic concurrency, structured
--      failures, audit behavior, exact replay semantics, no service_role,
--      no protected direct column grants) -- ONLY the fingerprint
--      computation and the idempotency table's column/constraint usage
--      change.
--
-- EXISTING-ROW COMPATIBILITY POLICY (Section C):
--   Because 0142 has never been applied to Supabase, the ONLY legitimate
--   state of carrier_invoice_lifecycle_idempotency at the moment 0143
--   applies is EMPTY. This migration does NOT assume that -- it counts
--   and classifies every existing row first, and REFUSES outright
--   (raises, whole transaction rolls back) if even one row is found,
--   rather than guessing a compatibility mapping for a situation that is
--   not supposed to be possible. This is the explicitly-offered simpler
--   alternative in Section C ("refuse migration if such rows exist
--   because 0142 is supposed to be unapplied") -- chosen over building a
--   permanent dual-fingerprint-version replay path for a scenario this
--   phase's own baseline guarantees cannot occur here. No MD5 string is
--   ever reinterpreted as SHA-256; no row is ever deleted or rewritten.
--
-- PHASE 3B.3B.1 CORRECTIONS (folded into this same, still-uncommitted
-- migration -- 0143 has never been applied, so there is no separate prior
-- boundary to preserve):
--   B. compute_financial_request_fingerprint(jsonb) is an internal
--      financial primitive -- EXECUTE is revoked from public, anon, AND
--      authenticated (the first draft left it grantable to
--      authenticated). Only the function's OWNER may call it directly;
--      update_carrier_invoice_draft() (SECURITY DEFINER, same owner)
--      keeps working unmodified, since a SECURITY DEFINER function's
--      body runs as its owner for its whole duration, including any
--      SECURITY INVOKER call it makes internally. No fingerprint or
--      canonical payload is ever returned in a client-facing response.
--   C. The fingerprint now covers the NORMALIZED patch, not the raw one.
--      The first draft fingerprinted raw p_patch verbatim, ahead of any
--      of this function's own normalization (due_date/payment_terms_days
--      type casts, uuid canonicalization) -- meaning two requests that
--      normalize to the IDENTICAL stored mutation (e.g. the same uuid in
--      a different letter case, or the same date in a different valid
--      spelling) could have fingerprinted DIFFERENTLY, an ambiguity
--      exactly as real as the one Section A already closed for MD5.
--      Fixed by reordering: reject unknown keys, then normalize every
--      permitted/present field exactly as it will be stored, build
--      normalized_patch from only the present keys, THEN fingerprint
--      that -- all before any lock is acquired. Fields this function
--      does not otherwise transform (notes, currency -- currency is
--      validated to already be canonical, never upper-cased) are
--      fingerprinted byte-for-byte identical to their raw form, which is
--      provably identical to what gets stored (see TEST_0143 items 4/6).
--
-- WHAT THIS MIGRATION DOES NOT DO
--   * does not modify migration 0142's own file (already committed)
--   * does not touch carrier_invoices, carrier_invoice_issuance_snapshots,
--     legacy_invoice_carrier_migration_review, or any other 0142 object
--     beyond carrier_invoice_lifecycle_idempotency and
--     update_carrier_invoice_draft()
--   * does not implement atomic invoice issuance (0144)
--   * does not add void, ready-for-issue, or payment RPCs
--   * does not add email, WhatsApp, factoring API, PDF, or QuickBooks logic
--   * does not use service_role for any ordinary authenticated action
--   * does not modify migrations 0001-0142
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent.
-- =============================================================================

begin;

-- ======================= PHASE 1 -- PRECONDITIONS ===========================
do $mig$
declare
  v_row_count integer;
  v_bad_shape_count integer;
begin
  if to_regclass('public.carrier_invoice_lifecycle_idempotency') is null then
    raise exception '0143 precondition: public.carrier_invoice_lifecycle_idempotency (0142) missing -- apply 0142 first. STOP.';
  end if;
  if to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is null then
    raise exception '0143 precondition: public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) (0142) missing. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='fingerprint_version') then
    raise exception '0143 precondition: fingerprint_version column already exists -- 0143 partially applied? STOP.';
  end if;
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is not null then
    raise exception '0143 precondition: compute_financial_request_fingerprint(jsonb) already exists -- 0143 partially applied? STOP.';
  end if;

  -- Section A: pgcrypto must be present before this migration relies on
  -- digest()/encode(). 0001 already creates it for every real
  -- environment; this is a defensive re-assertion for any disposable
  -- test harness that (deliberately) skips migrations 0001-0129 and
  -- bootstraps only a faithful pre-0130 stub schema instead. Never drops
  -- it on rollback (see ROLLBACK_0143's own header) -- 0001 already
  -- depends on it (gen_random_uuid() usage predates any assumption this
  -- migration makes), so it must never be removed regardless of which
  -- migration happened to be the one that physically created it.
  create extension if not exists pgcrypto;
  if to_regprocedure('public.digest(text, text)') is null and to_regprocedure('extensions.digest(text, text)') is null then
    raise exception '0143 precondition: pgcrypto''s digest(text,text) function is not reachable after CREATE EXTENSION -- refusing to proceed rather than silently fail later inside a SECURITY DEFINER function. STOP.';
  end if;

  -- Section C: the existing-row compatibility policy. Count first
  -- (informational + safety), classify by fingerprint SHAPE (never by
  -- guessing), then refuse outright if the table is not provably empty.
  select count(*) into v_row_count from public.carrier_invoice_lifecycle_idempotency;
  if v_row_count > 0 then
    select count(*) into v_bad_shape_count from public.carrier_invoice_lifecycle_idempotency
    where request_fingerprint !~ '^[0-9a-f]{32}$' and request_fingerprint !~ '^[0-9a-f]{64}$';
    raise exception '0143 precondition: carrier_invoice_lifecycle_idempotency is not empty (% row(s), % of unrecognized fingerprint shape) -- 0142 is documented as never applied to production, so this is unexpected. Refusing to guess a legacy-MD5-vs-SHA-256 classification or reinterpret any existing fingerprint. STOP -- resolve manually (see this migration''s own header, "EXISTING-ROW COMPATIBILITY POLICY").', v_row_count, v_bad_shape_count;
  end if;

  raise notice '0143 PHASE 1 preconditions passed. carrier_invoice_lifecycle_idempotency confirmed empty (0 rows) -- safe to harden its schema without any compatibility mapping.';
end
$mig$;

-- ======================= PHASE 2 -- canonical fingerprint primitive ========
-- Section A: a tiny, deliberately generic SHA-256 hashing primitive.
-- IMMUTABLE (pure function of its input, no table access) + SECURITY
-- INVOKER (no elevated privilege needed for a pure computation). The
-- CALLER is responsible for building a fully-keyed canonical payload --
-- this function only hashes whatever jsonb it is given, consistently.
-- Every field the caller includes has an explicit JSON key by
-- construction (jsonb_build_object requires it); jsonb's own storage
-- format canonicalizes key order at every nesting level (verified
-- empirically before relying on it: {"b":1,"a":2} and {"a":2,"b":1}
-- serialize identically, including inside nested objects), so logically
-- identical payloads always fingerprint identically regardless of how
-- the caller happened to order its jsonb_build_object() arguments.
-- search_path includes `extensions` defensively: on this project's own
-- disposable test clusters pgcrypto lands in `public` (verified
-- empirically), but a real Supabase-hosted project commonly provisions
-- pgcrypto into a dedicated `extensions` schema instead -- an unused
-- schema name in search_path is simply skipped, never an error, so this
-- is safe either way and correct in both environments.
create function public.compute_financial_request_fingerprint(p_canonical_payload jsonb)
returns text
language sql
immutable
security invoker
set search_path = pg_catalog, public, extensions
as $fn$
  select encode(digest(p_canonical_payload::text, 'sha256'), 'hex');
$fn$;

-- Phase 3B.3B.1 (Section B): this is an internal financial primitive --
-- no client role needs to call it directly, and it must never become a
-- place a client-supplied fingerprint could sneak in "for convenience".
-- EXECUTE is revoked from public, anon, AND authenticated -- only the
-- function's OWNER (the role that ran this migration) may execute it
-- directly. update_carrier_invoice_draft() -- SECURITY DEFINER, owned by
-- that SAME role -- keeps working: a SECURITY DEFINER function's body
-- runs as its owner for its entire duration, so a SECURITY INVOKER call
-- it makes internally (this one) is evaluated as that SAME owner, not as
-- the original calling session's role. Ownership itself always confers
-- EXECUTE regardless of any REVOKE FROM PUBLIC/anon/authenticated (a
-- REVOKE only removes a granted privilege from the named grantee; it
-- never removes the privileges inherent to ownership) -- proven by
-- VERIFY_0143_POST_APPLY and TEST_0143 (direct authenticated invocation
-- fails; the secured RPC still succeeds end-to-end).
revoke all on function public.compute_financial_request_fingerprint(jsonb) from public, anon, authenticated;

comment on function public.compute_financial_request_fingerprint(jsonb) is
  'Phase 3B.3B, privilege-hardened in Phase 3B.3B.1 (Section B): the canonical SHA-256 request-fingerprint primitive every financial RPC''s idempotency mechanism should build on. Hashes encode(digest(p_canonical_payload::text, ''sha256''), ''hex'') -- the caller builds its OWN fully-keyed canonical payload (operation, schema_version, organization_id, and whatever operation-specific fields determine request identity) via jsonb_build_object() and passes the whole object here. jsonb''s own storage format canonicalizes key order at every nesting level, so this is safe against key-order variation without any extra normalization step. Output is always 64 lowercase hex characters. EXECUTE is revoked from public/anon/authenticated -- this is an internal primitive, never called directly by a client role. Only the owning role (and any SECURITY DEFINER function it owns, such as update_carrier_invoice_draft()) may invoke it; a client-supplied fingerprint is never accepted anywhere, and no fingerprint or canonical payload is ever returned in a client-facing response.';

-- ======================= PHASE 3 -- harden the idempotency table ===========
alter table public.carrier_invoice_lifecycle_idempotency rename column action to operation;

alter table public.carrier_invoice_lifecycle_idempotency
  add column fingerprint_version integer,
  add column state text,
  add column created_by uuid references public.profiles (id) on delete set null,
  add column updated_at timestamptz;

-- The table is proven empty by Phase 1's own guard -- these defaults
-- apply only to rows inserted from this point forward; there is nothing
-- to backfill.
alter table public.carrier_invoice_lifecycle_idempotency
  alter column fingerprint_version set default 1,
  alter column fingerprint_version set not null,
  alter column state set default 'completed',
  alter column state set not null,
  alter column updated_at set default now(),
  alter column updated_at set not null;

comment on column public.carrier_invoice_lifecycle_idempotency.operation is
  'Renamed from `action` (0142) -- the operation name this idempotency record belongs to (e.g. ''update_carrier_invoice_draft''). Part of the durable uniqueness scope (organization_id, operation, idempotency_key) -- a key reused for a DIFFERENT operation is structurally a different row, never a collision, never a cross-operation cache hit.';
comment on column public.carrier_invoice_lifecycle_idempotency.fingerprint_version is
  'Reserved for a FUTURE fingerprint-algorithm change to follow this same migration''s own precedent: classify existing rows by fingerprint shape, refuse to guess, refuse to proceed if any row is ambiguous. Every row written by this schema''s current code is version 1 (SHA-256, compute_financial_request_fingerprint). Version 0 is reserved for the (never actually applied) legacy MD5 shape 0142 originally used.';
comment on column public.carrier_invoice_lifecycle_idempotency.state is
  'Currently always ''completed'' -- this table only ever stores an already-successful result (the owning RPC INSERTs only after its own mutation+audit succeed). Reserved for a future operation that might need an interim state (e.g. ''in_progress'') before this pattern is reused by a longer-running financial RPC.';
comment on column public.carrier_invoice_lifecycle_idempotency.created_by is
  'The authenticated actor (auth.uid()) who performed the original request, where available. Nullable -- never required, never client-supplied as an override.';

-- Section B: the Preferred, future-compatible durable scope. A key
-- reused for a DIFFERENT operation must never collide with, or return,
-- another operation's cached result -- proven by TEST_0143 (item 16).
alter table public.carrier_invoice_lifecycle_idempotency drop constraint civ_idempotency_unique;
alter table public.carrier_invoice_lifecycle_idempotency add constraint civ_idempotency_unique unique (organization_id, operation, idempotency_key);

comment on table public.carrier_invoice_lifecycle_idempotency is
  'Phase 3B.3B hardening of 0142''s carrier_invoice_lifecycle_idempotency: durable idempotency scope is (organization_id, operation, idempotency_key) -- never organization+key alone. This table is, today, permanently dedicated to update_carrier_invoice_draft() (operation=''update_carrier_invoice_draft'' for every row) -- proven by VERIFY_0143_POST_APPLY and TEST_0143 that no other function references it; any FUTURE financial RPC that reuses this table must use its own distinct operation string, which the widened unique constraint already protects against colliding with. No client INSERT/UPDATE/DELETE policy -- writable only via a SECURITY DEFINER RPC.';

-- ======================= PHASE 4 -- replace update_carrier_invoice_draft() =
-- SAME public signature as 0142 (uuid, jsonb, timestamptz, text, text) --
-- every behavioral guarantee preserved (role authorization, strict patch
-- allowlist, organization derivation, advisory-lock-before-row-lock
-- ordering, optimistic concurrency, structured failures, audit behavior,
-- exact replay semantics, no service_role, no protected direct column
-- grants).
--
-- Phase 3B.3B.1 (Section C) reorders and extends the fingerprinting
-- itself: the fingerprint must represent the CANONICAL, already-
-- normalized logical mutation, never the ambiguous raw request. Preferred
-- order, implemented exactly:
--   1. validate p_patch is a JSON object (already true on entry);
--   2. reject unknown keys (and reject an empty/all-unrecognized patch);
--   3. normalize every PERMITTED, PRESENT value exactly as it will be
--      stored -- this is pure syntax (type casts, trimming-equivalents,
--      uuid canonicalization), never dependent on the invoice row or the
--      caller's role, so it can safely run before any lock is taken;
--   4. build normalized_patch from ONLY the keys actually present (an
--      absent key never appears in normalized_patch -- absence still
--      means "leave unchanged", distinct from an explicit JSON null);
--   5. build the explicitly-keyed canonical payload from normalized_patch
--      (never raw p_patch);
--   6. calculate SHA-256;
--   7. acquire the organization+operation+idempotency-key advisory lock;
--   8. lock and revalidate the invoice;
--   9. resolve idempotency (operation-scoped);
--   10. perform role/business validation -- INCLUDING whatever genuinely
--       requires the now-locked row (the dispatch-service-invoice
--       recipient rejection, and resolving an OMITTED recipient half
--       against the row's current value -- see v_apply_broker_id/
--       v_apply_customer_id below, which stay separate from the
--       fingerprinted, presence-only v_new_broker_id/v_new_customer_id);
--   11. apply the already-normalized patch;
--   12. audit and store the result atomically.
--
-- Concretely, per field:
--   * notes: NOT trimmed or otherwise transformed -- stored byte-for-byte
--     as submitted (including any leading/trailing whitespace, or JSON
--     null). The fingerprint already matches this exactly, since
--     normalized_patch carries the identical value that gets stored --
--     proven, not assumed, by TEST_0143 (item 6).
--   * due_date: nullif('','')::date normalization (empty string -> NULL;
--     any valid date-string spelling -> the SAME `date` value) now feeds
--     the fingerprint via to_jsonb(v_new_due_date), which always renders
--     as the canonical 'YYYY-MM-DD' JSON string (or JSON null) --
--     independent of which equivalent date-string spelling the client
--     originally sent.
--   * payment_terms_days: (...)::integer normalization now feeds the
--     fingerprint via to_jsonb(v_new_payment_terms_days) -- a canonical
--     JSON number, independent of the raw JSON number's original text
--     representation (e.g. 15 vs 15.0).
--   * currency: NOT normalized -- already required to arrive pre-
--     canonicalized (^[A-Z]{3}$); a non-canonical value (e.g. lowercase)
--     is rejected outright as INVALID_INPUT, never silently upper-cased.
--     The fingerprint already matches the stored value exactly. Proven,
--     not assumed, by TEST_0143 (item 4).
--   * broker_id/customer_id: nullif('','')::uuid normalization now feeds
--     the fingerprint via to_jsonb(v_new_broker_id)/to_jsonb(v_new_
--     customer_id) -- Postgres's own canonical lowercase uuid text
--     representation, independent of the input string's original casing
--     (e.g. "A0B0..." and "a0b0..." -- the SAME uuid value -- now
--     fingerprint identically, closing a real ambiguity 0143's first
--     draft left open). Only the PRESENT key's own parsed value is
--     fingerprinted -- never the "left unchanged, defaulted from the
--     locked row" resolution (v_apply_broker_id/v_apply_customer_id),
--     which is business logic requiring the row, not part of the
--     caller's own logical request.
--   * unknown keys: rejected in step 2, before fingerprinting, locking,
--     or touching the idempotency table at all.
create or replace function public.update_carrier_invoice_draft(
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
  -- Presence-gated, purely SYNTACTIC parse -- fingerprint-safe, computed
  -- before any lock or row access.
  v_new_broker_id uuid;
  v_has_broker_id boolean := false;
  v_new_customer_id uuid;
  v_has_customer_id boolean := false;
  -- Row-resolved (an omitted half of the recipient pair defaults to the
  -- LOCKED row's current value) -- business logic, computed only after
  -- the row is locked, used for validation/eligibility and the actual
  -- UPDATE, never fingerprinted.
  v_apply_broker_id uuid;
  v_apply_customer_id uuid;
  v_normalized_patch jsonb := '{}'::jsonb;
  v_party_status public.carrier_party_status;
  v_changed_fields text[] := '{}';
  v_result jsonb;
  v_operation constant text := 'update_carrier_invoice_draft';
  v_schema_version constant integer := 1;
begin
  ------------------------------------------------------------------
  -- STEP 1-4: request-shape validation, unknown-key rejection, and
  -- SYNTACTIC normalization of every permitted, present value -- pure
  -- functions of p_patch alone, no row access, no role check, nothing
  -- written yet.
  ------------------------------------------------------------------
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'p_patch must be a JSON object.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  -- Step 2: reject unknown keys BEFORE fingerprinting, locking, or ever
  -- touching the idempotency table.
  select array_agg(k) into v_patch_keys from jsonb_object_keys(p_patch) k;
  v_patch_keys := coalesce(v_patch_keys, '{}');
  if not (v_patch_keys <@ v_master_keys) then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Unknown field in patch.');
  end if;
  if array_length(v_patch_keys, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'No recognized field was provided to change.');
  end if;

  -- Step 3: normalize each PERMITTED, PRESENT value exactly as it will
  -- be stored (still no writes, no row access).
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

  if p_patch ? 'broker_id' then
    if jsonb_typeof(p_patch->'broker_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id must be a uuid string or null.');
    end if;
    begin
      v_new_broker_id := nullif(p_patch->>'broker_id', '')::uuid;
      v_has_broker_id := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id/customer_id must be valid uuids.');
    end;
  end if;
  if p_patch ? 'customer_id' then
    if jsonb_typeof(p_patch->'customer_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'customer_id must be a uuid string or null.');
    end if;
    begin
      v_new_customer_id := nullif(p_patch->>'customer_id', '')::uuid;
      v_has_customer_id := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id/customer_id must be valid uuids.');
    end;
  end if;
  v_touches_recipient := v_has_broker_id or v_has_customer_id;

  -- Step 4: normalized_patch carries ONLY the keys actually present,
  -- each holding its canonical, as-will-be-stored value -- an absent key
  -- never appears here (absence still means "leave unchanged"), and an
  -- explicit JSON null is never conflated with a missing key.
  if p_patch ? 'notes' then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('notes', v_new_notes);
  end if;
  if v_has_due_date then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('due_date', to_jsonb(v_new_due_date));
  end if;
  if v_has_payment_terms then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('payment_terms_days', to_jsonb(v_new_payment_terms_days));
  end if;
  if p_patch ? 'currency' then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('currency', v_new_currency);
  end if;
  if v_has_broker_id then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('broker_id', to_jsonb(v_new_broker_id));
  end if;
  if v_has_customer_id then
    v_normalized_patch := v_normalized_patch || jsonb_build_object('customer_id', to_jsonb(v_new_customer_id));
  end if;

  ------------------------------------------------------------------
  -- STEP 5-9: build the canonical payload from normalized_patch (never
  -- raw p_patch), fingerprint, acquire the advisory lock, lock and
  -- revalidate the invoice, resolve idempotency.
  ------------------------------------------------------------------
  v_fingerprint := public.compute_financial_request_fingerprint(
    jsonb_build_object(
      'operation', v_operation,
      'schema_version', v_schema_version,
      'organization_id', v_org,
      'invoice_id', p_invoice_id,
      'patch', v_normalized_patch,
      'reason', nullif(btrim(coalesce(p_reason, '')), ''),
      'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    )
  );

  v_lock_key := hashtextextended(v_org::text || '|' || v_operation || '|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select id, organization_id, invoice_document_type, issuance_status, updated_at, carrier_id,
         recipient_type, recipient_broker_id, recipient_customer_id
    into v_row
  from public.carrier_invoices where id = p_invoice_id for update;

  -- "Not found" and "belongs to another organization" are deliberately
  -- indistinguishable.
  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_invoice_lifecycle_idempotency
  where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
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

  ------------------------------------------------------------------
  -- STEP 10: role/business validation -- including whatever genuinely
  -- requires the now-locked row. Nothing here changes the fingerprint;
  -- it can only REJECT a request the fingerprint has already committed
  -- to representing.
  ------------------------------------------------------------------
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

  if v_touches_recipient then
    if v_row.invoice_document_type = 'dispatch_service_invoice' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A dispatch-service invoice cannot receive a broker/customer recipient.');
    end if;

    -- An OMITTED half of the recipient pair defaults to the LOCKED row's
    -- current value -- this is business resolution requiring the row,
    -- deliberately kept separate from the fingerprinted, presence-only
    -- v_new_broker_id/v_new_customer_id above.
    v_apply_broker_id := case when v_has_broker_id then v_new_broker_id else v_row.recipient_broker_id end;
    v_apply_customer_id := case when v_has_customer_id then v_new_customer_id else v_row.recipient_customer_id end;

    if (v_apply_broker_id is not null) = (v_apply_customer_id is not null) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Exactly one of broker_id or customer_id must be set for a freight invoice.');
    end if;
    v_new_recipient_type := case when v_apply_broker_id is not null then 'broker' else 'customer' end;

    -- Cross-organization / never-existed is deliberately indistinguishable.
    if v_apply_broker_id is not null then
      if not exists (select 1 from public.brokers where id = v_apply_broker_id and organization_id = v_org and not is_blacklisted) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected broker is not available.');
      end if;
      select status into v_party_status from public.carrier_brokers where carrier_id = v_row.carrier_id and broker_id = v_apply_broker_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected broker.');
      end if;
    else
      if not exists (select 1 from public.customers where id = v_apply_customer_id and organization_id = v_org and is_active) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected customer is not available.');
      end if;
      select status into v_party_status from public.carrier_customers where carrier_id = v_row.carrier_id and customer_id = v_apply_customer_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected customer.');
      end if;
    end if;
  end if;

  ------------------------------------------------------------------
  -- STEP 11-12: APPLY the already-normalized patch; audit and store the
  -- result atomically. The mutation, the audit event, and the
  -- idempotency-record insert are wrapped in ONE nested block (plpgsql
  -- BEGIN/EXCEPTION implicitly opens a savepoint) so a collision at the
  -- final INSERT rolls back the WHOLE block together -- a collision
  -- produces zero mutation and zero audit event, never a partial success
  -- behind a reported failure.
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
        set recipient_type = v_new_recipient_type, recipient_broker_id = v_apply_broker_id, recipient_customer_id = v_apply_customer_id
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

    insert into public.carrier_invoice_lifecycle_idempotency
      (organization_id, idempotency_key, invoice_id, operation, request_fingerprint, fingerprint_version, result, state, created_by)
    values
      (v_org, p_idempotency_key, p_invoice_id, v_operation, v_fingerprint, v_schema_version, v_result, 'completed', auth.uid());
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
      where organization_id = v_org and operation = v_operation and idempotency_key = p_idempotency_key;
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
  'Phase 3B.3A.2/3B.3A.3, hardened in Phase 3B.3B (Section A/B: canonical SHA-256 fingerprint, operation-scoped idempotency) and Phase 3B.3B.1 (Section C: the fingerprint now covers the NORMALIZED patch, not the raw one). SAME public signature and EVERY behavioral guarantee preserved from the prior phase (role authorization, strict patch allowlist, organization derivation, advisory-lock-before-row-lock ordering, optimistic concurrency, structured failures, audit behavior, exact replay semantics, no service_role, no protected direct column grants). The request fingerprint is SHA-256 of a canonical, fully-keyed jsonb payload (operation, schema_version, organization_id, invoice_id, patch, reason, expected_updated_at) via compute_financial_request_fingerprint() -- never MD5, never an ambiguous string concatenation. `patch` in that payload is the NORMALIZED patch (each permitted, present field cast/canonicalized exactly as it will be stored -- e.g. due_date/payment_terms_days/broker_id/customer_id each pass through the SAME type cast used at mutation time), built and fingerprinted BEFORE any lock is acquired, so two requests that normalize to the identical stored mutation always fingerprint identically regardless of superficial raw-text differences (uuid casing, date-string spelling, JSON number formatting). Unknown patch keys are rejected before fingerprinting, locking, or touching the idempotency table at all. The durable idempotency scope is (organization_id, operation, idempotency_key), matching the advisory lock''s own scope exactly -- a key reused for a different operation is structurally a different row. compute_financial_request_fingerprint() itself has EXECUTE revoked from public/anon/authenticated -- only this function''s own owner (unaffected by that revoke) can invoke it, directly or via this SECURITY DEFINER wrapper.';

-- ======================= PHASE 5 -- POSTCONDITIONS ==========================
do $mig$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation') then
    raise exception '0143 postcondition: carrier_invoice_lifecycle_idempotency.operation column missing (rename from action failed?).';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='action') then
    raise exception '0143 postcondition: carrier_invoice_lifecycle_idempotency.action still exists -- rename to operation did not take effect.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='fingerprint_version') then
    raise exception '0143 postcondition: fingerprint_version column missing.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='state') then
    raise exception '0143 postcondition: state column missing.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='created_by') then
    raise exception '0143 postcondition: created_by column missing.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='updated_at') then
    raise exception '0143 postcondition: updated_at column missing.';
  end if;
  -- Set-based comparison (a UNIQUE constraint's semantics never depend
  -- on column declaration order) -- exactly the 3 named columns, no more
  -- and no fewer.
  if not exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_invoice_lifecycle_idempotency' and c.conname = 'civ_idempotency_unique'
      and (
        select array_agg(a.attname::text order by a.attname)
        from unnest(c.conkey) ck(attnum)
        join pg_attribute a on a.attrelid = t.oid and a.attnum = ck.attnum
      ) = array['idempotency_key','operation','organization_id']
  ) then
    raise exception '0143 postcondition: civ_idempotency_unique is not scoped to exactly (organization_id, operation, idempotency_key).';
  end if;
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is null then
    raise exception '0143 postcondition: compute_financial_request_fingerprint(jsonb) missing.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%md5(%' then
    raise exception '0143 postcondition: update_carrier_invoice_draft() still references md5() -- the MD5 fingerprint was not fully removed.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%compute_financial_request_fingerprint%' then
    raise exception '0143 postcondition: update_carrier_invoice_draft() does not call compute_financial_request_fingerprint().';
  end if;
  if (select count(*) from public.carrier_invoice_lifecycle_idempotency) <> 0 then
    raise exception '0143 postcondition: carrier_invoice_lifecycle_idempotency must still be empty -- this migration never inserts data.';
  end if;

  -- Phase 3B.3B.1 (Section B): compute_financial_request_fingerprint(jsonb)
  -- must be unreachable directly by any client role -- only the owning
  -- role (and a SECURITY DEFINER function it owns) may invoke it.
  if has_function_privilege('public', 'public.compute_financial_request_fingerprint(jsonb)', 'EXECUTE') then
    raise exception '0143 postcondition: compute_financial_request_fingerprint(jsonb) is still EXECUTE-able by public.';
  end if;
  if has_function_privilege('anon', 'public.compute_financial_request_fingerprint(jsonb)', 'EXECUTE') then
    raise exception '0143 postcondition: compute_financial_request_fingerprint(jsonb) is still EXECUTE-able by anon.';
  end if;
  if has_function_privilege('authenticated', 'public.compute_financial_request_fingerprint(jsonb)', 'EXECUTE') then
    raise exception '0143 postcondition: compute_financial_request_fingerprint(jsonb) is still EXECUTE-able by authenticated -- it must be internal-only.';
  end if;
  -- update_carrier_invoice_draft() (SECURITY DEFINER, same owner) must
  -- still be able to reach it -- a structural proxy (the live RPC call
  -- tests in TEST_0143/VERIFY_0143_POST_APPLY prove this end-to-end).
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%compute_financial_request_fingerprint%' then
    raise exception '0143 postcondition: update_carrier_invoice_draft() no longer calls compute_financial_request_fingerprint().';
  end if;
  -- Phase 3B.3B.1 (Section C): the fingerprint must cover the NORMALIZED
  -- patch, never raw p_patch, and unknown keys must be rejected before
  -- any of that -- a structural proxy on the source text.
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%''patch'', p_patch%' then
    raise exception '0143 postcondition: update_carrier_invoice_draft() still fingerprints raw p_patch instead of the normalized patch.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%''patch'', v_normalized_patch%' then
    raise exception '0143 postcondition: update_carrier_invoice_draft() does not fingerprint v_normalized_patch.';
  end if;

  raise notice '0143 complete: carrier_invoice_lifecycle_idempotency hardened -- action renamed to operation; fingerprint_version/state/created_by/updated_at added; civ_idempotency_unique widened to (organization_id, operation, idempotency_key), matching the advisory lock''s own scope exactly. compute_financial_request_fingerprint(jsonb) -- a reusable SHA-256 canonical-payload hashing primitive, EXECUTE revoked from public/anon/authenticated (internal-only) -- installed for future financial RPCs to build on. update_carrier_invoice_draft() redefined with the SAME public signature and every behavioral guarantee preserved, now fingerprinting via a canonical, fully-keyed jsonb payload over the NORMALIZED patch (operation/schema_version/organization_id/invoice_id/patch/reason/expected_updated_at) instead of an ambiguous MD5 concatenation or a raw, pre-normalization patch; unknown keys are rejected before fingerprinting/locking/idempotency-table access. Table confirmed still empty -- no data was migrated, converted, or reinterpreted (the existing-row compatibility policy REFUSES this migration outright if any row is ever found -- see Phase 1). Migrations 0001-0142 untouched. No issuance RPC. No void/ready-for-issue/payment RPC. No delivery. No QuickBooks. No PDF.';
end
$mig$;

commit;
