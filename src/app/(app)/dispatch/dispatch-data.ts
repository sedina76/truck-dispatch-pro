import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getLatestDocument, type DocumentRow } from "@/lib/documents/latest-document";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

// Shared data-loading for both /dispatch/new and /dispatch/[id] -- same
// Load Summary / Trip / Assignment-options shape either page needs, one
// place to fetch it from rather than duplicating ~8 queries twice.

export type LoadSummary = {
  id: string;
  load_number: string;
  status: string;
  equipment_type: string | null;
  total_miles: number | null;
  broker_name: string | null;
  customer_name: string | null;
};

export type StopSummary = {
  stop_type: string;
  stop_sequence: number;
  facility_name: string | null;
  city: string | null;
  state: string | null;
  scheduled_at: string | null;
  reference_number: string | null;
  timezone: string;
};

export async function getLoadSummary(
  supabase: Awaited<ReturnType<typeof createClient>>,
  loadId: string
): Promise<{ load: LoadSummary; stops: StopSummary[] } | null> {
  const [{ data: load }, { data: stops }, { data: orgRow }] = await Promise.all([
    supabase.from("loads").select("id, load_number, status, equipment_type, total_miles, broker_id, customer_id, organization_id, brokers(company_name), customers(company_name)").eq("id", loadId).maybeSingle(),
    supabase
      .from("load_stops")
      .select("stop_type, stop_sequence, facility_name, city, state, scheduled_at, reference_number, timezone")
      .eq("load_id", loadId)
      .order("stop_sequence"),
    supabase.from("organizations").select("timezone").limit(1).maybeSingle(),
  ]);
  if (!load) return null;
  const organizationTimezone = orgRow?.timezone ?? null;

  const raw = load as unknown as { id: string; load_number: string; status: string; equipment_type: string | null; total_miles: number | null; brokers: { company_name: string } | null; customers: { company_name: string } | null };

  return {
    load: {
      id: raw.id,
      load_number: raw.load_number,
      status: raw.status,
      equipment_type: raw.equipment_type,
      total_miles: raw.total_miles,
      broker_name: raw.brokers?.company_name ?? null,
      customer_name: raw.customers?.company_name ?? null,
    },
    stops: ((stops ?? []) as unknown as (Omit<StopSummary, "timezone"> & { timezone: string | null })[]).map((s) => ({
      ...s,
      timezone: resolveStopTimezone(s.timezone, organizationTimezone).timezone,
    })),
  };
}

export type CarrierOption = { id: string; legal_name: string; dispatch_fee_percentage: number };
// Phase 3A.3 (item 5): `inactiveHistorical` marks an option that was merged
// in ONLY because it is the dispatch's CURRENT assignment and would
// otherwise be entirely absent from the (active-only) list below -- e.g. a
// driver who has since gone inactive. AssignmentFields renders it (so the
// edit form never force-clears a real, already-saved assignment) but never
// offers it as a choice for a NEW reassignment.
export type DriverOption = { id: string; carrier_id: string; first_name: string; last_name: string; inactiveHistorical?: boolean };
export type TruckOption = { id: string; carrier_id: string; unit_number: string; ownership_type: string | null; inactiveHistorical?: boolean };
// ownership_scope (0132): 'carrier' (this carrier's own trailer), '
// organization_shared' (explicitly released to the whole org's pool --
// labeled "Shared Pool" in the UI, selectable regardless of carrier), or
// 'unresolved' (not yet classified by an owner/admin -- reassign_dispatch_
// resources, 0135, refuses these outright; the query below excludes them
// from the general list for the same reason getAssignmentOptions never
// offered inactive equipment).
export type TrailerOption = { id: string; carrier_id: string | null; unit_number: string; ownership_type: string | null; ownership_scope: "carrier" | "organization_shared" | "unresolved"; inactiveHistorical?: boolean };

// One fetch of every org-scoped carrier/driver/truck/trailer, tagged with
// carrier_id so the client can cascade Carrier -> Driver/Truck/Trailer
// without a page reload per selection. This is UX filtering only -- the
// real enforcement is guard_dispatch_org() (0048, server-side) plus the
// conflict/relationship checks in actions.ts, so a crafted request can't
// bypass this by skipping the client-side filter.
// POST-0069 finding: dispatch_fee_percentage dropped from this select --
// it doesn't exist on `carriers` at all anymore (moved to
// carrier_financials by the 2G.10 writer cutover). Left unfixed, this
// query throws (42703, confirmed live) on EVERY call, which the
// unchecked `data ?? []` below silently turned into an always-empty
// carrier dropdown -- New Dispatch and Dispatch Detail's Assignment
// section could no longer assign or reassign a carrier to ANY dispatch
// at all. Merged in from carrier_financials below -- same "org-scoped
// list, no per-role gate" shape as before (this function has never been
// role-gated; the fee value here is only ever used as an operational
// default suggestion for the Dispatch Fee % input, not a financial
// disclosure surface -- unchanged by this fix).
// `current`: the dispatch being EDITED's own assignment (omit entirely for
// the create form, where nothing is "currently assigned" yet). Phase 3A.3
// (item 5): when supplied, a currently-assigned driver/truck/trailer that
// the active-only queries below would otherwise drop (gone inactive, or --
// for a trailer -- reclassified) is fetched individually and merged back in
// with `inactiveHistorical: true`, so the edit form can keep showing it as
// the selected value without ever offering it for a NEW pick.
export async function getAssignmentOptions(
  supabase: Awaited<ReturnType<typeof createClient>>,
  current?: { driverId?: string | null; truckId?: string | null; trailerId?: string | null }
) {
  const [{ data: carriers }, { data: drivers }, { data: trucks }, { data: trailers }, { data: carrierFinancials }] = await Promise.all([
    supabase.from("carriers").select("id, legal_name").eq("is_active", true).order("legal_name"),
    supabase.from("drivers").select("id, carrier_id, first_name, last_name").eq("status", "active").order("last_name"),
    supabase.from("trucks").select("id, carrier_id, unit_number, ownership_type").eq("status", "active").order("unit_number"),
    // Phase 3A.3 (item 5): 'unresolved' trailers are excluded here -- never
    // selectable for a new reassignment (reassign_dispatch_resources, 0135,
    // refuses them outright); 'carrier' and 'organization_shared' both
    // remain, distinguished in the UI via ownership_scope.
    supabase.from("trailers").select("id, carrier_id, unit_number, ownership_type, ownership_scope").eq("status", "active").neq("ownership_scope", "unresolved").order("unit_number"),
    supabase.from("carrier_financials").select("carrier_id, dispatch_fee_percentage"),
  ]);
  const feeByCarrierId = new Map((carrierFinancials ?? []).map((r) => [r.carrier_id, Number(r.dispatch_fee_percentage)]));

  let driverList = (drivers ?? []) as DriverOption[];
  let truckList = (trucks ?? []) as TruckOption[];
  let trailerList = (trailers ?? []) as TrailerOption[];

  if (current?.driverId && !driverList.some((d) => d.id === current.driverId)) {
    const { data } = await supabase.from("drivers").select("id, carrier_id, first_name, last_name").eq("id", current.driverId).maybeSingle();
    if (data) driverList = [...driverList, { ...(data as Omit<DriverOption, "inactiveHistorical">), inactiveHistorical: true }];
  }
  if (current?.truckId && !truckList.some((t) => t.id === current.truckId)) {
    const { data } = await supabase.from("trucks").select("id, carrier_id, unit_number, ownership_type").eq("id", current.truckId).maybeSingle();
    if (data) truckList = [...truckList, { ...(data as Omit<TruckOption, "inactiveHistorical">), inactiveHistorical: true }];
  }
  if (current?.trailerId && !trailerList.some((t) => t.id === current.trailerId)) {
    const { data } = await supabase.from("trailers").select("id, carrier_id, unit_number, ownership_type, ownership_scope").eq("id", current.trailerId).maybeSingle();
    if (data) trailerList = [...trailerList, { ...(data as Omit<TrailerOption, "inactiveHistorical">), inactiveHistorical: true }];
  }

  return {
    carriers: ((carriers ?? []) as { id: string; legal_name: string }[]).map((c) => ({ ...c, dispatch_fee_percentage: feeByCarrierId.get(c.id) ?? 10 })) as CarrierOption[],
    drivers: driverList,
    trucks: truckList,
    trailers: trailerList,
  };
}

export async function getRateConfirmation(supabase: Awaited<ReturnType<typeof createClient>>, loadId: string): Promise<DocumentRow | null> {
  return getLatestDocument(supabase, "load", loadId, "rate_confirmation");
}
