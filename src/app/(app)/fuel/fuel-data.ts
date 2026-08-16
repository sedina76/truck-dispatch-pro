import "server-only";
import { createClient } from "@/lib/supabase/server";

// Shared data-loading/reporting for the Fuel workspace/detail pages (spec
// section 20 REPORTING). Every number here comes from a real fuel_logs/
// expenses/settlement query -- nothing fabricated, same rule already
// established for Maintenance (maintenance-data.ts).

export type FuelKpis = {
  grossFuelSpend: number;
  carrierFuelRecovery: number;
  driverFuelRecovery: number;
  netFuelCost: number;
  gallonsPurchased: number;
  avgPricePerGallon: number;
  fleetAvgMpg: number | null;
};

export async function getFuelKpis(supabase: Awaited<ReturnType<typeof createClient>>): Promise<FuelKpis> {
  const { data: logs } = await supabase
    .from("fuel_logs")
    .select("truck_id, gallons, total_amount, paid_by, recovery_type, recovered_amount, odometer_reading, purchased_at");
  const rows = logs ?? [];

  // Gross Fuel Spend: real company cash outflow only -- carrier/driver-
  // direct-paid fuel was never a company expense, so it doesn't belong in
  // a company spend KPI (same rule as Maintenance's Spend This Month).
  const companyPaid = rows.filter((r) => r.paid_by === "dispatch_company");
  const grossFuelSpend = companyPaid.reduce((sum, r) => sum + Number(r.total_amount), 0);

  // Recovery totals split by lane -- recovered_amount is the real,
  // trigger-synced cache (0051), summed per recovery_type rather than
  // re-derived here (spec section 7: "Prefer deriving recovered_amount
  // from linked settlement rows").
  const carrierFuelRecovery = rows.filter((r) => r.recovery_type === "carrier_settlement").reduce((sum, r) => sum + Number(r.recovered_amount), 0);
  const driverFuelRecovery = rows.filter((r) => r.recovery_type === "driver_settlement").reduce((sum, r) => sum + Number(r.recovered_amount), 0);
  const netFuelCost = grossFuelSpend - carrierFuelRecovery - driverFuelRecovery;

  const gallonsPurchased = rows.reduce((sum, r) => sum + Number(r.gallons), 0);
  const avgPricePerGallon = gallonsPurchased > 0 ? rows.reduce((sum, r) => sum + Number(r.total_amount), 0) / gallonsPurchased : 0;

  const fleetAvgMpg = computeFleetAverageMpg(rows as FuelLogForMpg[]);

  return { grossFuelSpend, carrierFuelRecovery, driverFuelRecovery, netFuelCost, gallonsPurchased, avgPricePerGallon, fleetAvgMpg };
}

type FuelLogForMpg = { truck_id: string; gallons: number; odometer_reading: number | null; purchased_at: string };

// MPG = miles between two consecutive fill-ups for the SAME truck / gallons
// burned to cover that distance -- only computed from real, consecutive,
// non-decreasing odometer readings (spec section 20/26: "Do not fabricate
// MPG when mileage intervals are unreliable"). A truck with fewer than two
// odometer-tagged fuel logs, or where a "later" purchase has a lower or
// equal odometer reading than the one before it (data entry error, or
// simply no odometer recorded), contributes nothing rather than a guessed
// number.
function computeFleetAverageMpg(rows: FuelLogForMpg[]): number | null {
  const byTruck = new Map<string, FuelLogForMpg[]>();
  for (const r of rows) {
    if (r.odometer_reading == null) continue;
    if (!byTruck.has(r.truck_id)) byTruck.set(r.truck_id, []);
    byTruck.get(r.truck_id)!.push(r);
  }

  let totalMiles = 0;
  let totalGallons = 0;
  for (const truckRows of byTruck.values()) {
    const sorted = [...truckRows].sort((a, b) => new Date(a.purchased_at).getTime() - new Date(b.purchased_at).getTime());
    for (let i = 1; i < sorted.length; i++) {
      const prev = sorted[i - 1];
      const cur = sorted[i];
      const miles = cur.odometer_reading! - prev.odometer_reading!;
      if (miles <= 0 || cur.gallons <= 0) continue; // rollback/duplicate/bad data -- skip, never guess
      totalMiles += miles;
      totalGallons += Number(cur.gallons);
    }
  }
  return totalGallons > 0 ? totalMiles / totalGallons : null;
}

export type FuelBreakdownRow = { label: string; gallons: number; totalAmount: number; count: number };

// Generic "group real fuel_logs rows by a label" reducer -- one
// implementation for Spend by Truck/Carrier/Driver/State/Station rather
// than five near-identical hand-rolled loops.
export function groupFuelSpend<T extends { gallons: number; total_amount: number }>(rows: T[], labelOf: (row: T) => string | null): FuelBreakdownRow[] {
  const map = new Map<string, FuelBreakdownRow>();
  for (const r of rows) {
    const label = labelOf(r) ?? "-- unassigned --";
    const existing = map.get(label) ?? { label, gallons: 0, totalAmount: 0, count: 0 };
    existing.gallons += Number(r.gallons);
    existing.totalAmount += Number(r.total_amount);
    existing.count += 1;
    map.set(label, existing);
  }
  return [...map.values()].sort((a, b) => b.totalAmount - a.totalAmount);
}

export type FuelRecoverySummary = { recoverableAmount: number; recoveredAmount: number; remainingAmount: number; recoveryStatus: string };

export async function getFuelRecoveryStatus(supabase: Awaited<ReturnType<typeof createClient>>, fuelLogId: string): Promise<FuelRecoverySummary | null> {
  const { data } = await supabase.rpc("get_fuel_recovery_status", { p_fuel_log_id: fuelLogId }).maybeSingle();
  if (!data) return null;
  const row = data as unknown as { recoverable_amount: number; recovered_amount: number; remaining_amount: number; recovery_status: string };
  return { recoverableAmount: Number(row.recoverable_amount), recoveredAmount: Number(row.recovered_amount), remainingAmount: Number(row.remaining_amount), recoveryStatus: row.recovery_status };
}
