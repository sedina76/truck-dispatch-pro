import "server-only";
import { createClient } from "@/lib/supabase/server";
import { resolveStopTimezone } from "@/lib/timezone/resolve";

// Driver-Safe Load Sheet (spec section 12) -- Phase 2 will build the
// actual PDF/print view and a "Send to Driver" action on top of this, but
// the safe-field selection is real, working code now, not a placeholder.
// This is the ONLY thing that should ever be sent to a driver in place of
// the original Rate Confirmation -- it has no query path to broker rate,
// carrier rate, dispatch fee, profit, customer billing, settlement data,
// or internal notes, so there is no field here that could ever leak one by
// accident (same "the type can't carry what it never selected" guarantee
// used by src/lib/profile-share/generate.ts).

export type DriverLoadSheet = {
  loadNumber: string;
  commodity: string | null;
  weightLbs: number | null;
  totalMiles: number | null;
  equipmentType: string | null;
  specialInstructions: string | null;
  pickup: LoadSheetStop | null;
  delivery: LoadSheetStop | null;
};

export type LoadSheetStop = {
  companyName: string | null;
  addressLine1: string | null;
  city: string | null;
  state: string | null;
  scheduledAt: string | null;
  referenceNumber: string | null;
  timezone: string;
};

export async function getDriverLoadSheetData(loadId: string): Promise<DriverLoadSheet | null> {
  const supabase = await createClient();

  const [{ data: load }, { data: stops }, { data: orgRow }] = await Promise.all([
    supabase.from("loads").select("load_number, commodity, weight_lbs, total_miles, equipment_type, special_instructions").eq("id", loadId).maybeSingle(),
    supabase
      .from("load_stops")
      .select("stop_type, stop_sequence, facility_name, address_line1, city, state, scheduled_at, reference_number, timezone")
      .eq("load_id", loadId)
      .order("stop_sequence"),
    supabase.from("organizations").select("timezone").limit(1).maybeSingle(),
  ]);
  if (!load) return null;
  const organizationTimezone = orgRow?.timezone ?? null;

  const toStop = (row: (typeof stops extends (infer T)[] | null ? T : never) | undefined): LoadSheetStop | null =>
    row
      ? {
          companyName: row.facility_name,
          addressLine1: row.address_line1,
          city: row.city,
          state: row.state,
          scheduledAt: row.scheduled_at,
          // Pickup/delivery reference numbers are operational (dock
          // scheduling), never a rate or billing reference -- safe to
          // show a driver ("when allowed" per spec; always allowed here
          // since this field never carries a dollar amount).
          referenceNumber: row.reference_number,
          timezone: resolveStopTimezone(row.timezone, organizationTimezone).timezone,
        }
      : null;

  const pickup = (stops ?? []).filter((s) => s.stop_type === "pickup")[0];
  const delivery = (stops ?? []).filter((s) => s.stop_type === "delivery").slice(-1)[0];

  return {
    loadNumber: load.load_number,
    commodity: load.commodity,
    weightLbs: load.weight_lbs,
    totalMiles: load.total_miles,
    equipmentType: load.equipment_type,
    specialInstructions: load.special_instructions,
    pickup: toStop(pickup),
    delivery: toStop(delivery),
  };
}
