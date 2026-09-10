-- ---------------------------------------------------------------------------
-- PRE-APPLY -- Mileage Concept Separation (Contracted / Route / Actual).
--
-- DO NOT APPLY WITHOUT APPROVAL.
--
-- INCIDENT THAT PROMPTED THIS (LD-100023): a dispatcher entered 1200 miles
-- at load booking; "New Dispatch" later showed 1189.8. Full discovery (see
-- this phase's own report) traced every read/write of mileage in this
-- codebase and found:
--   * loads.total_miles (0004_operations.sql) is the ONLY mileage value
--     "New Dispatch" (LoadSummaryPanel, shared by /dispatch/new and
--     /dispatch/[id]) has ever displayed -- there is no second,
--     calculated-route number rendered anywhere on load/dispatch creation
--     today.
--   * loads.total_miles is written in exactly two places: the load-creation
--     RPC (create_load_with_stops(), 0047/0061/0068/0114) and updateLoad()
--     (loads/actions.ts, the generic Edit Load form) -- both store
--     whatever numeric string was submitted VERBATIM (toNumber(),
--     src/lib/utils/form.ts, does no rounding/coercion beyond
--     Number(str)). Nothing else -- no trigger, no dispatch-creation code,
--     no routing/ETA code -- has ever written to this column.
--   * The ONLY calculated-distance system in this schema,
--     dispatch_route_intelligence (0060_route_intelligence.sql), was
--     ALREADY, by its own original design, forbidden from ever touching
--     loads.total_miles ("Booked miles ... NEVER written by anything in
--     this migration") -- and it represents a fundamentally different
--     quantity besides: CURRENT-LEG remaining distance (truck's live GPS
--     position -> next stop), which only exists once a dispatch has GPS
--     data, not a stable, full pickup-to-delivery planned distance.
-- CONCLUSION: no code anywhere silently recalculated or overwrote
-- LD-100023's mileage. The 1189.8 figure, wherever it currently lives, can
-- only be explained by (a) a later manual edit through the Edit Load
-- form's plain "Total miles" field, or (b) the value stored at booking
-- time never actually having been 1200 to begin with (human recall vs.
-- what was truly submitted). Both require reading LD-100023's actual
-- current data and its activity_logs history to distinguish -- this
-- author has no live database access (standing rule for this entire
-- engagement), so LD-100023 itself is NOT touched by this migration; see
-- this phase's own VERIFY_LD100023_MILEAGE_AUDIT.sql (read-only) for the
-- exact diagnostic query to run before any repair is even considered.
-- GENUINE GAP FOUND, reported honestly rather than silently worked
-- around: updateLoad()'s own log_activity() call
-- (src/app/(app)/loads/actions.ts) passes no changes/diff payload at all
-- ("updated" with p_changes left at its default null) -- so even a
-- confirmed manual edit of total_miles leaves NO stored before/after
-- value to inspect after the fact. This migration does not fix that gap
-- (out of this phase's scope -- it would touch every field on the form,
-- not just mileage), but it is worth this schema's attention separately.
--
-- TARGET MODEL: three genuinely distinct mileage concepts, kept genuinely
-- separate, per product decision --
--   contracted_miles: dispatcher/rate-confirmation mileage, entered by a
--     human at booking. loads.total_miles (0004_operations.sql) ALREADY
--     is this concept exactly, per 0060's own original design comment
--     ("Booked miles ... the mileage entered when the load was booked") --
--     NOT renamed here (a rename would touch >20 already-correct
--     consuming files across invoices, settlements, profitability,
--     driver/dispatch pages, exports, and PDFs, for zero behavioral gain,
--     and risks exactly the kind of silent-reinterpretation this phase
--     was asked to avoid) -- only its UI LABEL changes, to "Contracted
--     Miles", on the two pages this phase's spec names.
--   route_miles: calculated, stop-to-stop routing distance -- genuinely
--     NEW; no existing column represents this (dispatch_route_intelligence
--     is a different quantity, as established above, and is deliberately
--     left untouched -- it remains the live ETA/risk engine's own
--     current-leg data, never repurposed as "the" route-miles figure).
--   actual_miles: GPS/ELD-derived mileage once a trip is complete --
--     genuinely NEW; no ELD integration or completed-trip GPS-distance
--     aggregation exists anywhere in this codebase today (confirmed by
--     search) to populate it. Added for the concept to exist and be
--     displayable, per instruction; POPULATING it is a separate, larger
--     feature (aggregating driver_locations/GPS pings into a per-dispatch
--     total) explicitly OUT OF SCOPE for this phase -- reported as a
--     follow-up, not built here.
--
-- Both new columns are nullable, additive, and never written by anything
-- in this migration or by any existing application code -- they read as
-- NULL ("--" in the UI) until a future calculation feature populates
-- them. No historical loads row is read, modified, or reinterpreted.
-- RLS: purely additive columns on an already-RLS-covered table (the
-- existing loads_select/loads_insert/loads_update policies, 0010, are
-- ROW-level and apply to these columns automatically -- no new policy is
-- needed or added).
-- ---------------------------------------------------------------------------

alter table public.loads
  add column route_miles numeric(8, 2) check (route_miles is null or route_miles >= 0),
  add column route_miles_calculated_at timestamptz,
  add column actual_miles numeric(8, 2) check (actual_miles is null or actual_miles >= 0),
  add column actual_miles_recorded_at timestamptz;

comment on column public.loads.total_miles is
  'CONTRACTED miles -- dispatcher/rate-confirmation mileage, entered by a human at booking (0004_operations.sql). Never written by anything except the load-creation RPC and the Edit Load form -- see 0115''s own header comment for the full audit trail. Drives contracted rate-per-mile display, per-mile driver pay (calculate_driver_load_pay(), 0069), and profitability revenue/profit-per-mile -- all by established convention, unchanged by 0115.';

comment on column public.loads.route_miles is
  'ROUTE miles -- calculated, stop-to-stop routing distance (0115). Distinct from dispatch_route_intelligence.route_distance_meters (0060), which is a live dispatch''s CURRENT-LEG remaining distance to its next stop, not a stable planned total -- the two are never conflated or auto-derived from each other. NULL until a route-calculation feature populates it (not built by 0115 -- see this phase''s own report). Intended to drive routing/ETA displays going forward; never overwrites or is overwritten by total_miles (contracted_miles).';

comment on column public.loads.actual_miles is
  'ACTUAL miles -- GPS/ELD-derived mileage once a trip is complete (0115). NULL until a completed-trip GPS-distance aggregation feature exists (none does today -- see this phase''s own report); for post-trip operational reporting only, never for contracted rate-per-mile or driver/carrier compensation.';
