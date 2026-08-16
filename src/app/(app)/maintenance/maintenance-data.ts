import "server-only";
import { createClient } from "@/lib/supabase/server";

// Shared data-loading for the Maintenance workspace/detail/new pages. Every
// KPI here is computed from real maintenance_records/equipment rows --
// nothing fabricated (spec PHASE 2: "Every number must come from real
// database data").

// Mirrors get_preventive_maintenance_status() (0050) exactly -- same
// thresholds, same rule -- kept here so list/detail/KPI pages can compute
// this client-side without an RPC round trip per record. The DB function
// remains the source of truth for anything computed inside SQL (e.g. a
// future report); this is a deliberate, commented duplication of a single
// pure calculation, not a second implementation of a stateful concept.
export type PreventiveMaintenanceStatus = "not_scheduled" | "ok" | "due_soon" | "due" | "overdue";

export function computePreventiveMaintenanceStatus(
  nextDueDate: string | null,
  nextDueOdometer: number | null,
  currentOdometer: number | null
): PreventiveMaintenanceStatus {
  if (!nextDueDate && !nextDueOdometer) return "not_scheduled";
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const dueDate = nextDueDate ? new Date(nextDueDate + "T00:00:00") : null;

  const overdueByDate = dueDate ? dueDate.getTime() < today.getTime() : false;
  const overdueByOdometer = nextDueOdometer != null && currentOdometer != null && currentOdometer > nextDueOdometer;
  if (overdueByDate || overdueByOdometer) return "overdue";

  const dueByDate = dueDate ? dueDate.getTime() === today.getTime() : false;
  const dueByOdometer = nextDueOdometer != null && currentOdometer != null && currentOdometer === nextDueOdometer;
  if (dueByDate || dueByOdometer) return "due";

  const dueSoonCutoff = new Date(today);
  dueSoonCutoff.setDate(dueSoonCutoff.getDate() + 14);
  const dueSoonByDate = dueDate ? dueDate.getTime() <= dueSoonCutoff.getTime() : false;
  const dueSoonByOdometer = nextDueOdometer != null && currentOdometer != null && currentOdometer >= nextDueOdometer - 1000;
  if (dueSoonByDate || dueSoonByOdometer) return "due_soon";

  return "ok";
}

export type MaintenanceKpis = {
  dueSoon: number;
  overdue: number;
  outOfService: number;
  openRepairs: number;
  spendThisMonth: number;
  pendingRecoveries: number;
};

export async function getMaintenanceKpis(supabase: Awaited<ReturnType<typeof createClient>>): Promise<MaintenanceKpis> {
  const monthStart = new Date();
  monthStart.setDate(1);
  monthStart.setHours(0, 0, 0, 0);

  const [{ data: pmRows }, { data: statusCounts }, { data: monthSpend }, { data: pendingRecoveryRows }, { data: outOfServiceTrucks }, { data: outOfServiceTrailers }] = await Promise.all([
    supabase.from("maintenance_records").select("id, next_service_due_date, next_service_due_odometer, truck_id, trailer_id, status").eq("status", "open"),
    supabase.from("maintenance_records").select("status", { count: "exact", head: true }).eq("status", "open"),
    supabase.from("maintenance_records").select("cost, paid_by, service_date").gte("service_date", monthStart.toISOString().slice(0, 10)),
    supabase.from("maintenance_records").select("recoverable_amount, recovered_amount").in("recovery_status", ["pending", "partially_recovered"]),
    supabase.from("trucks").select("id", { count: "exact", head: true }).eq("status", "out_of_service"),
    supabase.from("trailers").select("id", { count: "exact", head: true }).eq("status", "out_of_service"),
  ]);
  void statusCounts;

  // Preventive-maintenance status needs each unit's CURRENT odometer -- one
  // batch fetch, not N+1 (spec: "Do not fabricate current mileage").
  // Trailers have no odometer column in this schema (0003) -- only
  // date-based PM status applies to trailer-only records.
  const truckIds = Array.from(new Set((pmRows ?? []).map((r) => r.truck_id).filter((v): v is string => !!v)));
  const [{ data: trucks }] = await Promise.all([
    truckIds.length > 0 ? supabase.from("trucks").select("id, current_odometer").in("id", truckIds) : Promise.resolve({ data: [] }),
  ]);
  const odometerByTruck = new Map((trucks ?? []).map((t) => [t.id, t.current_odometer as number | null]));

  // Same pure logic as get_preventive_maintenance_status() (SQL, immutable)
  // -- computed client-side here to avoid one RPC round-trip per record.
  let dueSoon = 0;
  let overdue = 0;
  for (const r of pmRows ?? []) {
    if (!r.next_service_due_date && !r.next_service_due_odometer) continue;
    const currentOdometer = r.truck_id ? (odometerByTruck.get(r.truck_id) ?? null) : null;
    const status = computePreventiveMaintenanceStatus(r.next_service_due_date, r.next_service_due_odometer, currentOdometer);
    if (status === "overdue") overdue++;
    // "Due Soon" KPI covers both due_soon and due (due today/at mileage) --
    // the strip has one box for "needs attention before it's overdue,"
    // not a separate one for the single-day/single-mile "due" band.
    if (status === "due_soon" || status === "due") dueSoon++;
  }

  // "Company-paid" spend only, matching the accounting rule (spec CORE
  // ACCOUNTING RULE): carrier/driver-direct-paid records were never a
  // company expense, so they don't belong in a company spend KPI.
  const spendThisMonth = (monthSpend ?? []).filter((r) => r.paid_by === "dispatch_company").reduce((sum, r) => sum + Number(r.cost), 0);
  const pendingRecoveries = (pendingRecoveryRows ?? []).reduce((sum, r) => sum + (Number(r.recoverable_amount) - Number(r.recovered_amount)), 0);

  const { count: openRepairs } = await supabase.from("maintenance_records").select("id", { count: "exact", head: true }).eq("status", "open");

  return {
    dueSoon,
    overdue,
    outOfService: (outOfServiceTrucks?.length ?? 0) + (outOfServiceTrailers?.length ?? 0),
    openRepairs: openRepairs ?? 0,
    spendThisMonth,
    pendingRecoveries,
  };
}

export type EquipmentContext = {
  id: string;
  unit_number: string;
  carrier_id: string | null;
  carrier_name: string | null;
  ownership_type: string | null;
  status: string;
  current_odometer: number | null;
};

export async function getEquipmentContext(
  supabase: Awaited<ReturnType<typeof createClient>>,
  truckId: string | null,
  trailerId: string | null
): Promise<EquipmentContext | null> {
  if (truckId) {
    const { data } = await supabase.from("trucks").select("id, unit_number, carrier_id, ownership_type, status, current_odometer, carriers(legal_name)").eq("id", truckId).maybeSingle();
    if (!data) return null;
    const row = data as unknown as { id: string; unit_number: string; carrier_id: string | null; ownership_type: string | null; status: string; current_odometer: number | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null, ownership_type: row.ownership_type, status: row.status, current_odometer: row.current_odometer };
  }
  if (trailerId) {
    const { data } = await supabase.from("trailers").select("id, unit_number, carrier_id, ownership_type, status, carriers(legal_name)").eq("id", trailerId).maybeSingle();
    if (!data) return null;
    const row = data as unknown as { id: string; unit_number: string; carrier_id: string | null; ownership_type: string | null; status: string; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null, ownership_type: row.ownership_type, status: row.status, current_odometer: null };
  }
  return null;
}

export type RecoverySummary = { recoverableAmount: number; recoveredAmount: number; remainingAmount: number; recoveryStatus: string };

export async function getRecoveryStatus(supabase: Awaited<ReturnType<typeof createClient>>, maintenanceId: string): Promise<RecoverySummary | null> {
  const { data } = await supabase.rpc("get_maintenance_recovery_status", { p_maintenance_id: maintenanceId }).maybeSingle();
  if (!data) return null;
  const row = data as unknown as { recoverable_amount: number; recovered_amount: number; remaining_amount: number; recovery_status: string };
  return { recoverableAmount: Number(row.recoverable_amount), recoveredAmount: Number(row.recovered_amount), remainingAmount: Number(row.remaining_amount), recoveryStatus: row.recovery_status };
}
