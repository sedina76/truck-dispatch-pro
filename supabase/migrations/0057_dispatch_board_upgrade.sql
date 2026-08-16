-- =============================================================================
-- 0057_dispatch_board_upgrade.sql
-- Dispatch Board Phase 1: operational per-status timestamps, detention
-- free-time settings, and document visibility. Purely additive -- no
-- column dropped/renamed, no enum value added/removed/reused for a
-- different meaning, no existing data touched. dispatch_status itself is
-- NOT modified: every value this feature needs already exists on it
-- (assigned, accepted, en_route_to_pickup, at_pickup, loaded,
-- en_route_to_delivery, at_delivery, delivered, completed, cancelled).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Per-status operational timestamps on dispatches.
--
-- Deliberately NOT added: an "assigned_at" column. dispatched_at
-- (0004_operations.sql, `not null default now()`) is already set at the
-- exact moment a dispatch is created, and every dispatch is always created
-- with status='assigned' (see createDispatch() in dispatch/actions.ts) --
-- it already IS the assigned timestamp. Adding a second column for the
-- same fact would be exactly the "duplicating meaning unnecessarily" this
-- migration is told to avoid.
--
-- Deliberately NOT reused: completed_at. It looks like an obvious fit for
-- "delivered_at", but it is a load-bearing field for real accounting
-- logic today: get_carrier_settlement_line_items(), get_driver_settlement
-- _items(), and the profitability functions (0031/0033/0034/0035/0036/
-- 0037/0038/0040) all key their settlement/profitability period off
-- `coalesce(completed_at, dispatched_at)::date`. No application code
-- currently writes to completed_at (confirmed by inspection), so today
-- that coalesce always falls back to dispatched_at. Starting to populate
-- it here would silently change which settlement/profitability period
-- every future delivered dispatch lands in -- a real accounting behavior
-- change nobody asked for in this pass. delivered_at below is therefore a
-- distinct, new, purely-operational column; completed_at is left exactly
-- as-is.
--
-- Also deliberately NOT added: arrived_pickup_at/departed_pickup_at/
-- arrived_delivery_at/departed_delivery_at on dispatches. Their exact
-- equivalents already exist on load_stops (arrived_at, departed_at --
-- 0003_load_management.sql), already read by Driver Profile's trip
-- history (src/components/drivers/trip-history-section.tsx) but never
-- written by any code path today. Detention/arrival tracking for this
-- feature writes to those existing per-stop columns instead of creating a
-- second, competing set of timestamps on dispatches.
alter table public.dispatches
  add column if not exists en_route_pickup_at timestamptz,
  add column if not exists loaded_at timestamptz,
  add column if not exists in_transit_at timestamptz,
  add column if not exists delivered_at timestamptz,
  add column if not exists cancelled_at timestamptz;

comment on column public.dispatches.en_route_pickup_at is 'Set once, first time status becomes en_route_to_pickup. Never overwritten by a later transition.';
comment on column public.dispatches.loaded_at is 'Set once, first time status becomes loaded. Also the moment load_stops.departed_at is set for the pickup stop (truck leaving with freight).';
comment on column public.dispatches.in_transit_at is 'Set once, first time status becomes en_route_to_delivery ("In Transit" in the UI).';
comment on column public.dispatches.delivered_at is 'Set once, first time status becomes delivered. Operational only -- NOT the field settlement/profitability math reads (that remains completed_at, see the note above); intentionally kept separate. Also the moment load_stops.departed_at is set for the delivery stop.';
comment on column public.dispatches.cancelled_at is 'Set once, first time status becomes cancelled.';

-- ---------------------------------------------------------------------------
-- Detention free-time settings, per organization (configurable, spec
-- section 13). Defaults match the spec's own example (120/120) and apply
-- to every existing organization automatically via the column default.
-- ---------------------------------------------------------------------------
alter table public.organizations
  add column if not exists pickup_detention_free_minutes integer not null default 120,
  add column if not exists delivery_detention_free_minutes integer not null default 120;

alter table public.organizations
  add constraint organizations_detention_minutes_check
    check (pickup_detention_free_minutes >= 0 and delivery_detention_free_minutes >= 0);

comment on column public.organizations.pickup_detention_free_minutes is 'Minutes of free time at pickup before detention accrues. Display/calculation only -- no automatic billing yet.';
comment on column public.organizations.delivery_detention_free_minutes is 'Minutes of free time at delivery before detention accrues. Display/calculation only -- no automatic billing yet.';

-- ---------------------------------------------------------------------------
-- Document visibility. Every document defaults to internal_only, including
-- every existing row (the column default applies retroactively) -- nothing
-- that was previously reachable only by staff becomes newly exposed by
-- this migration. Enforcement of this happens in the query layer
-- (src/lib/documents/*) -- this column is the source of truth those
-- queries filter on, not a UI-only label.
-- ---------------------------------------------------------------------------
create type public.document_visibility as enum (
  'internal_only', 'driver_visible', 'customer_visible', 'carrier_visible', 'shared'
);

alter table public.documents
  add column if not exists visibility public.document_visibility not null default 'internal_only';

comment on column public.documents.visibility is 'Who this document may be shown to beyond staff. Defaults to internal_only for every row, including pre-existing ones -- rate confirmations must never be set to anything else by application code.';
