import "server-only";
import { getCurrentOrgId } from "@/lib/actions/records";
import { isValidIanaTimezone } from "@/lib/timezone/iana";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Supabase = any;

export type IncidentRow = {
  id: string;
  incident_type: string;
  occurred_on: string;
  location: string | null;
  description: string | null;
  cost: number | string;
  status: string;
  driver_id: string | null;
  truck_id: string | null;
  load_id: string | null;
  drivers: { first_name: string | null; last_name: string | null } | null;
  trucks: { unit_number: string | null } | null;
  loads: { load_number: string | null } | null;
};

export const INCIDENT_SELECT =
  "id, incident_type, occurred_on, location, description, cost, status, driver_id, truck_id, load_id, drivers(first_name, last_name), trucks(unit_number), loads(load_number)";

export function driverName(d: { first_name: string | null; last_name: string | null } | null): string | null {
  if (!d) return null;
  return [d.first_name, d.last_name].filter(Boolean).join(" ") || null;
}

/** Today's date (YYYY-MM-DD) in the organization's time zone. */
export async function orgToday(supabase: Supabase): Promise<string> {
  let tz = "America/Chicago";
  try {
    const orgId = await getCurrentOrgId();
    const { data: org } = await supabase.from("organizations").select("timezone").eq("id", orgId).maybeSingle();
    if (org?.timezone && isValidIanaTimezone(org.timezone)) tz = org.timezone;
  } catch {
    // keep the fallback
  }
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}

type Option = { value: string; label: string };

/** Drivers, trucks and recent loads for the incident form. Keeps an inactive one selected if the incident already points at it. */
export async function incidentFormOptions(supabase: Supabase, keep: { driver_id?: string | null; truck_id?: string | null; load_id?: string | null } = {}) {
  const [{ data: drivers }, { data: trucks }, { data: loads }] = await Promise.all([
    supabase.from("drivers").select("id, first_name, last_name, status").order("last_name"),
    supabase.from("trucks").select("id, unit_number, status").order("unit_number"),
    supabase.from("loads").select("id, load_number, status").neq("status", "cancelled").order("created_at", { ascending: false }).limit(300),
  ]);
  const driverOpts: Option[] = ((drivers ?? []) as { id: string; first_name: string | null; last_name: string | null; status: string }[])
    .filter((d) => d.status === "active" || d.id === keep.driver_id)
    .map((d) => ({ value: d.id, label: driverName(d) ?? "Unnamed driver" }));
  const truckOpts: Option[] = ((trucks ?? []) as { id: string; unit_number: string; status: string }[])
    .filter((t) => t.status !== "inactive" || t.id === keep.truck_id)
    .map((t) => ({ value: t.id, label: `Truck ${t.unit_number}` }));
  const loadRows = (loads ?? []) as { id: string; load_number: string }[];
  if (keep.load_id && !loadRows.some((l) => l.id === keep.load_id)) {
    const { data: kept } = await supabase.from("loads").select("id, load_number").eq("id", keep.load_id).maybeSingle();
    if (kept) loadRows.unshift(kept);
  }
  const loadOpts: Option[] = loadRows.map((l) => ({ value: l.id, label: l.load_number }));
  return { drivers: driverOpts, trucks: truckOpts, loads: loadOpts };
}

export function money(n: number | string | null | undefined): string {
  return `$${Number(n ?? 0).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function shortDate(day: string): string {
  return new Date(`${day}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
}
