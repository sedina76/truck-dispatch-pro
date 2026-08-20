-- =============================================================================
-- 0064_multi_tenant_email.sql
-- Phase 2F: Multi-Tenant Outgoing Email Infrastructure. Purely additive on
-- top of 0001-0063. Does not modify, drop, or rename anything from those
-- migrations. No historical email_send_log rows are rewritten.
--
-- REVISED after architecture review: the initial draft of this migration
-- renamed email_send_log -> outbound_emails. A full repo + migration search
-- (see the Phase 2F revised report) found zero functional SQL dependencies
-- on the name (no views/triggers/functions reference it, only comments),
-- so the rename itself would have been technically safe -- but it bought
-- nothing functionally and this project's whole migration history has
-- stayed additive-only by discipline, not just by necessity. email_send_log
-- KEEPS ITS NAME. It is extended in place and treated architecturally as
-- the outbound email ledger (see src/lib/email/send-pipeline.ts's own
-- header comment) without a physical rename.
--
-- REVISED AGAIN (twice) after two real failed-apply attempts against a
-- live database.
--
-- Attempt 1: PostgreSQL 55P04 ("unsafe use of new value of enum type").
-- The partial unique index below on email_send_log originally read
-- `where status in ('queued', 'sent')` -- comparing the `status` column
-- (type email_send_status) against the literal 'queued' forces Postgres to
-- resolve 'queued' AS AN email_send_status VALUE, which is unsafe in the
-- same transaction as the ADD VALUE just above it.
--
-- Attempt 2 (the first repair): changed the predicate to
-- `status::text in ('queued', 'sent')`, avoiding 55P04 -- but PostgreSQL
-- then rejected THAT with 42P17 ("functions in index predicate must be
-- marked IMMUTABLE"), because an enum-to-text cast is STABLE, not
-- IMMUTABLE (Postgres deliberately withholds IMMUTABLE from it, since
-- ALTER TYPE ADD VALUE can alter the type's catalog state later -- the
-- exact same fact pattern this migration was already exercising). A cast
-- was a superficial fix for the first error that ran straight into a
-- second, structural one.
--
-- FINAL FIX: stop comparing the `status` enum column in the index
-- predicate at all. Added `idempotency_active boolean` (see below) --
-- a plain column the APPLICATION (send-pipeline.ts) sets to true exactly
-- when status is 'queued' or 'sent', and to null/false when it's
-- 'failed'/'blocked'. The partial index predicate references only this
-- boolean column: `where idempotency_active`. A bare column reference is
-- always valid in an index predicate (no function, no cast, nothing for
-- Postgres to evaluate immutability of) -- this avoids 55P04 AND 42P17
-- structurally, not by working around either symptom, and preserves the
-- exact same business invariant (queued-or-sent rows are unique per
-- idempotency key; failed/blocked rows are not) the enum comparison was
-- expressing. See the Phase 2F second repair report for the full
-- evaluation of alternatives (a migration-split approach was also viable
-- but unnecessary once the predicate no longer needs the enum at all).
--
-- Attempt 3 (the second repair, this one against a database already left
-- partially applied by attempts 1-2): PostgreSQL 42703 ("column
-- 'created_at' does not exist"). email_send_log_org_created_at_idx
-- (a plain, un-guarded CREATE INDEX referencing `created_at`) had been
-- placed BEFORE the `alter table ... add column if not exists created_at
-- ...` statement that creates it -- a genuine statement-ordering bug from
-- the first repair, which added the created_at/updated_at columns near
-- the end of the email_send_log block without moving this index (added
-- earlier in the same block) below them. Root-caused by reading the
-- REAL pre-0064 email_send_log schema in 0039_print_export_email.sql
-- (id, organization_id, entity_type, entity_id, recipient, cc, subject,
-- attachment_type, status, error, sent_by, sent_at -- no created_at/
-- updated_at ever existed) rather than assuming the column pre-existed.
-- FIX: created_at/updated_at are now added as part of the SAME, single,
-- upfront ALTER TABLE statement as every other new email_send_log column
-- (see below), which runs before every index in this file, unconditionally.
--
-- The same audit also found a second, not-yet-triggered bug: the
-- pre-existing email_send_log_failure_requires_error CHECK constraint
-- (from 0039: `status = 'sent' or error is not null`) would reject every
-- 'queued' reservation insert (error is null by definition for a fresh
-- reservation) the first time the repaired pipeline actually ran -- fixed
-- proactively below, before it could cause a fourth failed live attempt.
--
-- All three failed attempts left the live database PARTIALLY applied:
-- 'queued' is a committed enum value (confirmed via direct introspection
-- after attempts 1-2; re-confirmed after attempt 3 -- see the Phase 2F
-- third repair report). Every statement in this file remains
-- idempotent/guarded (IF NOT EXISTS on tables/columns/indexes/enum
-- values; DROP ... IF EXISTS immediately before CREATE for triggers,
-- policies, and the one CHECK constraint that needed relaxing, since
-- Postgres has no native IF NOT EXISTS for any of those) so this ONE file
-- can be re-run as-is against either a fresh database or this exact
-- partially-applied one, with identical, correct end state either way.
--
-- Reuses, rather than duplicates:
--   - email_send_log (0039_print_export_email.sql, extended by
--     0053_email_send_log_resend.sql) as the outbound email ledger.
--   - current_org_id() / has_role() (0002) for RLS, identical to every
--     other Phase 2A-2E table's policy shape.
--   - the SAME single platform Resend account/API key (RESEND_API_KEY) --
--     this migration adds tenant-owned SENDING DOMAINS under that one
--     account, never a second Resend credential.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- email_send_status: add 'queued', a genuine reservation state (spec
-- review item 5) used to make a send attempt safely retryable. A row is
-- inserted as 'queued' BEFORE the provider is ever called; only once the
-- provider call resolves does it move to 'sent'/'failed'. This closes the
-- "provider accepted the email but the app crashed before recording it"
-- gap: on retry, the pipeline finds the still-'queued' row (not a fresh
-- insert) and, combined with Resend's OWN idempotency key (also passed on
-- every send -- see send-pipeline.ts), the provider itself recognizes a
-- retried request rather than sending twice.
-- ALTER TYPE ... ADD VALUE is additive/non-destructive -- existing
-- sent/blocked/failed rows and every existing query against this enum are
-- completely unaffected.
-- ---------------------------------------------------------------------------
alter type public.email_send_status add value if not exists 'queued';

-- ---------------------------------------------------------------------------
-- Org-level feature/settings columns, sender/domain schema, unchanged in
-- spirit from the original draft -- see below.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- organization_email_domains: a tenant's own verified sending domain(s) in
-- the ONE central Resend account. sending_domain is what's actually
-- registered with Resend (spec section 6: prefer a dedicated subdomain,
-- e.g. mail.kalifreights.com, over the tenant's root domain) -- kept
-- distinct from the human-facing `domain` (kalifreights.com) so Settings
-- can show both without re-deriving one from the other.
--
-- sending_domain is GLOBALLY unique (spec section 39), not just per-org:
-- Resend itself will not let the same domain be registered twice under one
-- account, and this app deliberately uses only one account, so the DB
-- constraint mirrors that reality up front rather than surfacing it only
-- as a confusing provider-side error.
-- ---------------------------------------------------------------------------
create table if not exists public.organization_email_domains (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,

  domain text not null,              -- human-facing root domain, e.g. "kalifreights.com"
  sending_domain text not null,      -- actually registered with Resend, e.g. "mail.kalifreights.com"
  region text not null default 'us-east-1',

  resend_domain_id text,             -- Resend's own domain id -- the correlation key for verify/remove/get
  -- Mirrors Resend's own DomainStatus values exactly (pending, verified,
  -- failed, not_started, partially_verified, partially_failed) plus one
  -- local-only value, 'disabled', for a tenant-initiated removal that
  -- keeps the row (and any email_send_log rows that reference it) around
  -- for history (spec section 38) without claiming it's still usable.
  status text not null default 'not_started'
    check (status in ('not_started', 'pending', 'verified', 'failed', 'partially_verified', 'partially_failed', 'disabled')),
  dns_records jsonb not null default '[]'::jsonb, -- raw array of {type,name,value,ttl,priority,status} from Resend -- never an API key

  -- Sender eligibility (spec review item 2): mirrors Resend's OWN
  -- capabilities.sending field ('enabled'/'disabled'), which is the
  -- actual authority on whether outbound sending is authorized right
  -- now -- deliberately NOT inferred from `status` alone, since a domain
  -- can legitimately be 'partially_verified' overall (e.g. a tracking
  -- CNAME still pending) while sending is already enabled (SPF+DKIM
  -- alone are what sending requires). resolveEmailSender()
  -- (sender-resolver.ts) gates ONLY on this column, never on `status`.
  -- See src/lib/email/domains.ts's extractSendingEnabled() for the exact
  -- extraction rule.
  sending_enabled boolean not null default false,

  is_default boolean not null default false,
  -- Set ONLY by a real provider-confirmed 'verified' status (spec section
  -- 8/review item 8) -- never merely because a verify()/get() API call
  -- itself returned without error. See checkEmailDomainVerification() in
  -- settings/email/actions.ts, which reads result.data.status, not
  -- result.ok, to decide this.
  verified_at timestamptz,
  disabled_at timestamptz,

  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint organization_email_domains_domain_format check (domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
  constraint organization_email_domains_sending_domain_format check (sending_domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
);

create unique index if not exists organization_email_domains_sending_domain_key on public.organization_email_domains (sending_domain);
create index if not exists organization_email_domains_org_idx on public.organization_email_domains (organization_id);
create unique index if not exists organization_email_domains_one_default_per_org on public.organization_email_domains (organization_id) where is_default and disabled_at is null;

alter table public.organization_email_domains enable row level security;

-- Postgres has no CREATE POLICY IF NOT EXISTS -- drop-then-create is safe
-- (a policy is a definition, not data) and makes this statement
-- idempotent for the re-run case, same pattern used for every trigger
-- below.
drop policy if exists "org staff can view their own email domains" on public.organization_email_domains;
create policy "org staff can view their own email domains"
  on public.organization_email_domains for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin']::public.org_role[]));

-- No client insert/update/delete policy -- domain creation/verification/
-- removal always go through server actions using the service-role client,
-- after independently verifying organization ownership + owner/admin role
-- server-side (spec sections 10/45).

comment on table public.organization_email_domains is
  'A tenant''s own verified sending domain(s), registered under the ONE central platform Resend account (never a per-tenant Resend credential). See src/lib/email/domains.ts.';

-- Postgres has no CREATE TRIGGER IF NOT EXISTS -- drop-then-create is safe
-- here (a trigger is just a definition, dropping/recreating it touches no
-- data) and makes this statement idempotent for the re-run case.
drop trigger if exists organization_email_domains_set_updated_at on public.organization_email_domains;
create trigger organization_email_domains_set_updated_at
  before update on public.organization_email_domains
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- organization_email_senders: named From identities under a verified
-- domain (billing@mail.kalifreights.com, dispatch@mail.kalifreights.com).
-- Deliberately NOT a per-address Resend API object (spec section 8) --
-- once a domain is verified, Resend authorizes sending from ANY address on
-- it, so a sender row here is purely this app's own display-name/reply-to
-- configuration layered on top, never re-registered with the provider.
-- ---------------------------------------------------------------------------
create table if not exists public.organization_email_senders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  email_domain_id uuid not null references public.organization_email_domains (id) on delete cascade,

  display_name text not null,
  email_address text not null,
  reply_to text, -- may be external to the sending domain (spec section 41) -- e.g. accounting@kalifreights.com (root domain, not the subdomain)

  sender_type text not null default 'general' check (sender_type in ('billing', 'dispatch', 'accounting', 'general')),
  is_default boolean not null default false,
  is_active boolean not null default true,

  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint organization_email_senders_email_format check (email_address ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

create unique index if not exists organization_email_senders_org_address_key on public.organization_email_senders (organization_id, email_address);
create index if not exists organization_email_senders_org_idx on public.organization_email_senders (organization_id);
create index if not exists organization_email_senders_domain_idx on public.organization_email_senders (email_domain_id);
create unique index if not exists organization_email_senders_one_default_per_org on public.organization_email_senders (organization_id) where is_default and is_active;

alter table public.organization_email_senders enable row level security;

drop policy if exists "org staff can view their own email senders" on public.organization_email_senders;
create policy "org staff can view their own email senders"
  on public.organization_email_senders for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin']::public.org_role[]));

-- No client write policy -- see organization_email_domains above; same
-- server-action + service-role + independently-verified-ownership pattern.

comment on table public.organization_email_senders is
  'Named From identities under a tenant''s verified sending domain (billing@, dispatch@, ...). Not a provider-side object -- domain verification alone authorizes sending from any address on it; this table is purely this app''s display-name/reply-to/purpose configuration. See src/lib/email/sender-resolver.ts.';

drop trigger if exists organization_email_senders_set_updated_at on public.organization_email_senders;
create trigger organization_email_senders_set_updated_at
  before update on public.organization_email_senders
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- email_send_log: additive columns for sender resolution, historical
-- snapshot, richer entity linkage, two-layer idempotency, safe-retry
-- reservation, and webhook-driven delivery tracking with out-of-order
-- protection.
-- ---------------------------------------------------------------------------
alter table public.email_send_log
  -- Which sender/domain (if any) was actually used -- nullable because a
  -- platform-fallback send (spec section 14) uses neither.
  add column if not exists sender_id uuid references public.organization_email_senders (id) on delete set null,
  add column if not exists domain_id uuid references public.organization_email_domains (id) on delete set null,
  -- 'platform' | 'tenant_verified' (spec section 15) -- which path
  -- resolveEmailSender() actually took, independent of whether sender_id
  -- happens to still exist later.
  add column if not exists sender_source text check (sender_source in ('platform', 'tenant_verified')),

  -- Historical snapshot (spec section 20) -- the EXACT values used at
  -- send time, never re-derived from today's sender/recipient records.
  add column if not exists from_name text,
  add column if not exists from_email text,
  add column if not exists reply_to text,
  add column if not exists to_addresses text[],
  add column if not exists cc_addresses text[],
  add column if not exists bcc_addresses text[],

  -- Purpose, distinct from entity_type (which stays as the generic
  -- "kind of record this is about" the old toolbar-email call sites
  -- already populate -- e.g. "invoice"). email_purpose is Phase 2F's own,
  -- slightly finer-grained classification (spec section 36) used for
  -- sender-purpose resolution (e.g. a "billing" sender for
  -- email_purpose='invoice'/'billing_packet').
  add column if not exists email_purpose text,
  add column if not exists template_key text,

  -- Typed entity linkage (spec sections 18/19) alongside the existing
  -- generic entity_type/entity_id -- nullable, a business email links to
  -- whichever of these are actually relevant; platform/system email may
  -- have none. Independently RE-VERIFIED server-side against
  -- organization_id before being written -- see
  -- src/lib/email/authorization.ts's verifyEntityOwnership() -- never
  -- trusted from caller input alone (spec review item 2).
  add column if not exists load_id uuid references public.loads (id) on delete set null,
  add column if not exists invoice_id uuid references public.invoices (id) on delete set null,
  add column if not exists customer_id uuid references public.customers (id) on delete set null,
  add column if not exists broker_id uuid references public.brokers (id) on delete set null,
  add column if not exists dispatch_id uuid references public.dispatches (id) on delete set null,
  add column if not exists driver_id uuid references public.drivers (id) on delete set null,

  -- Webhook-driven delivery lifecycle (spec section 21), separate from the
  -- existing `status` (sent/blocked/failed/queued -- the SEND ATTEMPT
  -- outcome). Starts null for pre-Phase-2F rows and for blocked/failed
  -- attempts that never reached the provider. 'uncertain' (spec review
  -- item 1) marks a 'queued' reservation whose age has exceeded Resend's
  -- own 24h idempotency window with no provider_message_id ever
  -- recorded -- the app genuinely does not know whether the provider
  -- accepted the original send, so it is never auto-retried; see
  -- send-pipeline.ts's reserveLedgerRow().
  add column if not exists delivery_status text
    check (delivery_status is null or delivery_status in ('queued', 'sending', 'sent', 'delivered', 'delayed', 'bounced', 'failed', 'complained', 'uncertain')),
  add column if not exists delivered_at timestamptz,
  add column if not exists delivery_delayed_at timestamptz,
  add column if not exists bounced_at timestamptz,
  add column if not exists delivery_failed_at timestamptz,
  add column if not exists complained_at timestamptz,
  add column if not exists error_code text,

  -- Out-of-order webhook protection (spec review item 6): the occurred_at
  -- of the most recent webhook event actually APPLIED to this row. A new
  -- incoming event only updates delivery_status if its own occurred_at is
  -- >= this value -- see the webhook route's applyDeliveryEvent(), which
  -- is the ONLY place delivery_status/*_at columns are written.
  add column if not exists last_event_at timestamptz,

  -- Two-layer idempotency (spec review item 4). idempotency_key is the
  -- FULL key including its resend-sequence suffix (":0", ":1", ...) --
  -- see send-pipeline.ts's buildIdempotencyKey(). provider_idempotency_key
  -- is the (usually identical) value also sent to Resend itself as the
  -- Idempotency-Key header, so even a retried request that never reached
  -- this app's own ledger update is deduplicated AT THE PROVIDER.
  add column if not exists idempotency_key text,
  add column if not exists provider_idempotency_key text,

  -- Structural fix for the index-predicate problem above -- see this
  -- file's header comment. true exactly when this row's `status` is
  -- 'queued' or 'sent' (i.e. holds/held an active reservation); null
  -- (never re-set to false -- treated identically to null by `where
  -- idempotency_active`) once it's 'failed'/'blocked'. Written by
  -- send-pipeline.ts alongside every `status` write -- never read or
  -- derived independently, so it can never drift from `status` as long
  -- as that single write path is the only one touching either column
  -- (true today: the pipeline is the only writer of email_send_log rows
  -- with a non-null idempotency_key).
  add column if not exists idempotency_active boolean,

  add column if not exists metadata jsonb not null default '{}'::jsonb,

  -- email_send_log had no created_at/updated_at columns before this
  -- migration -- add both HERE, inside the same ALTER TABLE statement as
  -- every other new column, so they exist before any later statement in
  -- this file (indexes included) can reference them. (Repair 3: the
  -- previous revision of this file added these two columns in a SEPARATE,
  -- later ALTER TABLE statement, positioned AFTER
  -- email_send_log_org_created_at_idx's CREATE INDEX -- Postgres executes
  -- statements in file order, so that index's `created_at desc` column
  -- reference failed with 42703 ("column does not exist") because the
  -- column genuinely did not exist yet at that point in the script. Moving
  -- both columns into this single upfront ALTER TABLE, ahead of every
  -- index in this file, fixes the ordering unconditionally.)
  -- created_at is when the attempt/reservation was FIRST made (always
  -- populated, unlike sent_at, which stays null until a real send
  -- succeeds); updated_at (with the trigger below) is when the row was
  -- last touched by a retry or a webhook event.
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

-- Repair 3, second finding: email_send_log_failure_requires_error
-- (0039_print_export_email.sql) reads `check (status = 'sent' or error is
-- not null)`. Every 'queued' reservation row this pipeline inserts has
-- error = null by definition (a reservation is written BEFORE the
-- provider is ever called, so there is nothing to report an error about
-- yet) -- so the very first real reservation insert after 0064 applies
-- would violate this pre-existing constraint. This was not yet triggered
-- by any live apply attempt (0064 has never successfully reached this
-- point), but it is a real, certain failure the moment it does, so it is
-- fixed proactively here rather than waiting for a fifth failed attempt.
--
-- Same precedent as 0053_email_send_log_resend.sql, which relaxed a
-- constraint on this exact table (sent_at's not-null/default) for the
-- analogous reason: a genuinely new, valid row shape didn't fit the
-- original constraint, so the constraint -- not the row -- was widened,
-- with no data rewritten.
--
-- `status::text = 'queued'` (NOT a bare `status = 'queued'`) is
-- deliberate, for the same reason explained in this file's header
-- comment under "FINAL FIX": 'queued' is a value added earlier in this
-- same file via `alter type ... add value if not exists 'queued'`, and a
-- direct enum-literal comparison against a same-transaction new value is
-- exactly what raised 55P04 on the index predicate above. A CHECK
-- constraint has no IMMUTABLE requirement (that restriction is specific
-- to index predicates / generated columns, which is what turned the
-- text-cast into a NEW error, 42P17, for the index specifically) -- so
-- `status::text = 'queued'` here safely avoids 55P04 with no follow-on
-- 42P17 risk, since this is a plain CHECK, not an index predicate.
alter table public.email_send_log
  drop constraint if exists email_send_log_failure_requires_error;
alter table public.email_send_log
  add constraint email_send_log_failure_requires_error
  check (status = 'sent' or status::text = 'queued' or error is not null);

-- Idempotency (spec review item 5 -- must not permanently block retries):
-- a given (organization, idempotency_key) may be RESERVED ('queued') or
-- CONFIRMED ('sent') at most once -- but a 'failed'/'blocked' row does NOT
-- hold the constraint, so a genuine retry of a failed attempt is never
-- permanently blocked. A retry REUSES the existing row (transitions it
-- back to 'queued', see send-pipeline.ts) rather than inserting a new one,
-- so this partial index is never violated by a legitimate retry.
--
-- `idempotency_active` -- NOT `status in (...)` or `status::text in
-- (...)` -- is deliberate (see this file's header comment, "FINAL FIX"):
-- a bare boolean column reference needs no function/cast to evaluate, so
-- it is trivially IMMUTABLE-safe in an index predicate (fixes 42P17), and
-- it never resolves the string 'queued' as an email_send_status value at
-- all, so it's equally safe in the same transaction as the ADD VALUE
-- above on a fresh install (fixes 55P04). The application (send-
-- pipeline.ts) is solely responsible for keeping this column truthful
-- alongside every `status` write.
create unique index if not exists email_send_log_org_idempotency_key
  on public.email_send_log (organization_id, idempotency_key)
  where idempotency_key is not null and idempotency_active;

create index if not exists email_send_log_load_idx on public.email_send_log (load_id) where load_id is not null;
create index if not exists email_send_log_invoice_idx on public.email_send_log (invoice_id) where invoice_id is not null;
create index if not exists email_send_log_dispatch_idx on public.email_send_log (dispatch_id) where dispatch_id is not null;
create index if not exists email_send_log_org_sent_at_idx on public.email_send_log (organization_id, sent_at desc nulls last);
create index if not exists email_send_log_org_created_at_idx on public.email_send_log (organization_id, created_at desc);
create index if not exists email_send_log_provider_message_id_idx on public.email_send_log (provider_message_id) where provider_message_id is not null;

-- created_at/updated_at are now added above, in the main ALTER TABLE
-- block, ahead of email_send_log_org_created_at_idx -- see the repair-3
-- comment there. This trigger only needs updated_at to exist by the time
-- it FIRES (on a later UPDATE), not by the time it's CREATED, but it's
-- kept here, immediately after the column and its index, for readability.
drop trigger if exists email_send_log_set_updated_at on public.email_send_log;
create trigger email_send_log_set_updated_at
  before update on public.email_send_log
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- email_send_log_events: provider webhook event history (spec section 26),
-- named to match the parent table it belongs to (email_send_log), not the
-- earlier draft's "outbound_email_events" -- consistent naming now that
-- the parent table itself keeps its original name.
--
-- A dedicated child table, not folded into the parent row, for two
-- reasons: (1) idempotency -- a UNIQUE constraint on provider_event_id
-- lets "have I already processed this exact webhook delivery" be answered
-- by the database itself (insert, ON CONFLICT DO NOTHING), rather than
-- re-deriving it from timestamps that a retried event could legitimately
-- repeat; (2) audit -- a single outbound email can legitimately receive
-- MULTIPLE distinct events over its lifetime (sent -> delivered ->
-- complained), and collapsing them onto one row would silently lose
-- earlier state transitions. provider_event_id is always the verified
-- Svix/Resend delivery id (the `svix-id` header on a signature-verified
-- request) -- never a locally synthesized approximation (spec review item
-- 6). payload_metadata stores only a small, safe, curated subset (event
-- type, bounce/complaint reason if present) -- never the full raw webhook
-- body, which could carry recipient PII beyond what this table already
-- needs.
-- ---------------------------------------------------------------------------
create table if not exists public.email_send_log_events (
  id uuid primary key default gen_random_uuid(),
  email_send_log_id uuid not null references public.email_send_log (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,

  provider_event_id text not null,
  event_type text not null,
  occurred_at timestamptz not null,
  payload_metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

create unique index if not exists email_send_log_events_provider_event_id_key on public.email_send_log_events (provider_event_id);
create index if not exists email_send_log_events_parent_idx on public.email_send_log_events (email_send_log_id, occurred_at);
create index if not exists email_send_log_events_org_idx on public.email_send_log_events (organization_id);

alter table public.email_send_log_events enable row level security;

drop policy if exists "org staff can view their own email events" on public.email_send_log_events;
create policy "org staff can view their own email events"
  on public.email_send_log_events for select
  using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]));

-- No client write policy -- only the webhook route (service-role, after
-- verifying the Resend/Svix signature) ever inserts here.

comment on table public.email_send_log_events is
  'Individual Resend webhook delivery events for a sent email (sent/delivered/bounced/...), one row per distinct provider event id -- the UNIQUE index on provider_event_id is what makes webhook processing idempotent against provider retries. See src/app/api/webhooks/resend/route.ts.';
