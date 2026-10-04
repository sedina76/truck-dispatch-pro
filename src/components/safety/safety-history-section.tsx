import Link from "next/link";
import { ShieldAlert } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { StatusBadge } from "@/components/ui/status-badge";
import { incidentTypeLabel, summarizeHistory } from "@/lib/safety/incidents";
import { INCIDENT_SELECT, driverName, money, orgToday, shortDate, type IncidentRow } from "@/app/(app)/safety/safety-data";

// Safety history on a driver's or a truck's page: counts by type, open
// items, cost, and every incident (newest first) linking to its record.
export async function SafetyHistorySection({ driverId, truckId }: { driverId?: string; truckId?: string }) {
  const supabase = await createClient();
  let q = supabase.from("safety_incidents").select(INCIDENT_SELECT).order("occurred_on", { ascending: false }).limit(200);
  if (driverId) q = q.eq("driver_id", driverId);
  if (truckId) q = q.eq("truck_id", truckId);
  const [{ data, error }, today] = await Promise.all([q, orgToday(supabase)]);
  const rows = (data ?? []) as unknown as IncidentRow[];
  const s = summarizeHistory(rows, today);
  const newHref = `/safety/new?${driverId ? `driver_id=${driverId}` : `truck_id=${truckId}`}`;

  return (
    <div className="space-y-2.5 text-[12.5px]" data-testid="safety-history">
      <div className="flex flex-wrap items-center justify-between gap-2">
        {rows.length === 0 ? (
          <p className="flex items-center gap-1.5 text-muted-foreground">
            <ShieldAlert className="size-3.5" /> {error ? "Safety history isn't available yet." : "No incidents on record."}
          </p>
        ) : (
          <p className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <span>
              <strong>{s.total}</strong> incident{s.total === 1 ? "" : "s"}
            </span>
            <span>
              <strong>{s.last12Months}</strong> in the last 12 months
            </span>
            {s.open > 0 && <span className="text-desktop-warning">{s.open} open</span>}
            <span className="text-muted-foreground">{s.byType.map((t) => `${t.count} ${t.label.toLowerCase()}${t.count === 1 ? "" : "s"}`).join(" · ")}</span>
            <span className="text-muted-foreground">Total cost {money(s.totalCost)}</span>
          </p>
        )}
        <Link href={newHref} className="text-[12px] font-medium text-primary hover:underline">
          + Report incident
        </Link>
      </div>
      {rows.length > 0 && (
        <div className="overflow-x-auto rounded-sm border border-desktop-border">
          <table className="w-full min-w-[560px] text-left">
            <thead className="bg-desktop-header text-[11px] uppercase tracking-wide text-desktop-header-text">
              <tr>
                <th className="px-2.5 py-1.5 font-semibold">Date</th>
                <th className="px-2.5 py-1.5 font-semibold">Type</th>
                <th className="px-2.5 py-1.5 font-semibold">{driverId ? "Truck" : "Driver"}</th>
                <th className="px-2.5 py-1.5 font-semibold">Place</th>
                <th className="px-2.5 py-1.5 text-right font-semibold">Cost</th>
                <th className="px-2.5 py-1.5 font-semibold">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-desktop-border">
              {rows.map((r) => (
                <tr key={r.id} className="hover:bg-muted/50">
                  <td className="whitespace-nowrap px-2.5 py-1.5">
                    <Link href={`/safety/${r.id}`} className="font-medium text-primary hover:underline">
                      {shortDate(r.occurred_on)}
                    </Link>
                  </td>
                  <td className="px-2.5 py-1.5">{incidentTypeLabel(r.incident_type)}</td>
                  <td className="px-2.5 py-1.5">{driverId ? (r.trucks?.unit_number ? `Truck ${r.trucks.unit_number}` : "--") : (driverName(r.drivers) ?? "--")}</td>
                  <td className="max-w-[220px] truncate px-2.5 py-1.5" title={r.location ?? undefined}>
                    {r.location ?? "--"}
                  </td>
                  <td className="px-2.5 py-1.5 text-right tabular-nums">{money(r.cost)}</td>
                  <td className="px-2.5 py-1.5">
                    <StatusBadge status={r.status} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
