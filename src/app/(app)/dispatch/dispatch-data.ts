import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getLatestDocument, type DocumentRow } from "@/lib/documents/latest-document";

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
};

export async function getLoadSummary(
  supabase: Awaited<ReturnType<typeof createClient>>,
  loadId: string
): Promise<{ load: LoadSummary; stops: StopSummary[] } | null> {
  const [{ data: load }, { data: stops }] = await Promise.all([
    supabase.from("loads").select("id, load_number, status, equipment_type, total_miles, broker_id, customer_id, brokers(company_name), customers(company_name)").eq("id", loadId).maybeSingle(),
    supabase
      .from("load_stops")
      .select("stop_type, stop_sequence, facility_name, city, state, scheduled_at, reference_number")
      .eq("load_id", loadId)
      .order("stop_sequence"),
  ]);
  if (!load) return null;

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
    stops: stops ?? [],
  };
}

export type CarrierOption = { id: string; legal_name: string; dispatch_fee_percentage: number };
export type DriverOption = { id: string; carrier_id: string; first_name: string; last_name: string };
export type TruckOption = { id: string; carrier_id: string; unit_number: string; ownership_type: string | null };
export type TrailerOption = { id: string; carrier_id: string | null; unit_number: string; ownership_type: string | null };

// One fetch of every org-scoped carrier/driver/truck/trailer, tagged with
// carrier_id so the client can cascade Carrier -> Driver/Truck/Trailer
// without a page reload per selection. This is UX filtering only -- the
// real enforcement is guard_dispatch_org() (0048, server-side) plus the
// conflict/relationship checks in actions.ts, so a crafted request can't
// bypass this by skipping the client-side filter.
export async function getAssignmentOptions(supabase: Awaited<ReturnType<typeof createClient>>) {
  const [{ data: carriers }, { data: drivers }, { data: trucks }, { data: trailers }] = await Promise.all([
    supabase.from("carriers").select("id, legal_name, dispatch_fee_percentage").eq("is_active", true).order("legal_name"),
    supabase.from("drivers").select("id, carrier_id, first_name, last_name").eq("status", "active").order("last_name"),
    supabase.from("trucks").select("id, carrier_id, unit_number, ownership_type").eq("status", "active").order("unit_number"),
    supabase.from("trailers").select("id, carrier_id, unit_number, ownership_type").eq("status", "active").order("unit_number"),
  ]);
  return {
    carriers: (carriers ?? []) as CarrierOption[],
    drivers: (drivers ?? []) as DriverOption[],
    trucks: (trucks ?? []) as TruckOption[],
    trailers: (trailers ?? []) as TrailerOption[],
  };
}

export async function getRateConfirmation(supabase: Awaited<ReturnType<typeof createClient>>, loadId: string): Promise<DocumentRow | null> {
  return getLatestDocument(supabase, "load", loadId, "rate_confirmation");
}
