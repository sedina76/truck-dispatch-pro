import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth/require-role";
import { PageHeader } from "@/components/ui/page-header";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmptyState } from "@/components/ui/empty-state";
import { INCIDENT_TYPES, INCIDENT_TYPE_LABEL, incidentTypeLabel, summarizeHistory } from "@/lib/safety/incidents";
import { INCIDENT_SELECT, driverName, incidentFormOptions, money, orgToday, shortDate, type IncidentRow } from "./safety-data";

type SP = { type?: string; status?: string; driver_id?: string; truck_id?: string };

const selectClass = "h-8 rounded-sm border border-desktop-border bg-card px-2 text-[12.5px] shadow-elevation-1";

export default async function SafetyPage({ searchParams }: { searchParams: Promise<SP> }) {
  await requireRole(["owner", "admin", "dispatcher", "accountant", "viewer"]);
  const sp = await searchParams;
  const supabase = await createClient();

  let q = supabase.from("safety_incidents").select(INCIDENT_SELECT).order("occurred_on", { ascending: false }).order("created_at", { ascending: false }).limit(500);
  if (sp.type && (INCIDENT_TYPES as readonly string[]).includes(sp.type)) q = q.eq("incident_type", sp.type);
  if (sp.status === "open" || sp.status === "closed") q = q.eq("status", sp.status);
  if (sp.driver_id) q = q.eq("driver_id", sp.driver_id);
  if (sp.truck_id) q = q.eq("truck_id", sp.truck_id);

  const [{ data, error }, today, options, { data: openCountRows }] = await Promise.all([
    q,
    orgToday(supabase),
    incidentFormOptions(supabase),
    supabase.from("safety_incidents").select("id").eq("status", "open"),
  ]);
  const rows = (data ?? []) as unknown as IncidentRow[];
  const s = summarizeHistory(rows, today);
  const filtered = Boolean(sp.type || sp.status || sp.driver_id || sp.truck_id);
  const yearStart = `${today.slice(0, 4)}-01-01`;
  const costThisYear = rows.filter((r) => r.occurred_on >= yearStart).reduce((sum, r) => sum + Number(r.cost || 0), 0);

  return (
    <div className="space-y-4">
      <PageHeader
        title="Safety Incidents"
        description="Accidents, citations, cargo claims and inspection violations -- one record each, with photos. Every driver and truck page shows its safety history."
        primaryAction={{ label: "Report Incident", href: "/safety/new" }}
      />

      {error ? (
        <EmptyState title="Safety incidents aren't set up yet" description="The database update for safety incidents (0170) hasn't been run yet." />
      ) : (
        <>
          <DesktopKpiStrip>
            <DesktopKpiBox label={filtered ? "Last 12 months (filtered)" : "Last 12 months"} value={s.last12Months} sub={`${s.total} on record`} />
            <DesktopKpiBox label="Open" value={(openCountRows ?? []).length} tone={(openCountRows ?? []).length > 0 ? "warning" : "neutral"} href="/safety?status=open" />
            {INCIDENT_TYPES.map((t) => (
              <DesktopKpiBox key={t} label={`${INCIDENT_TYPE_LABEL[t]}s`.replace(/^./, (c) => c.toUpperCase())} value={rows.filter((r) => r.incident_type === t).length} href={`/safety?type=${t}`} />
            ))}
            <DesktopKpiBox label={`Cost ${today.slice(0, 4)}`} value={money(costThisYear)} />
          </DesktopKpiStrip>

          <form method="get" className="flex flex-wrap items-end gap-2 text-[12.5px]" data-testid="safety-filters">
            <select name="type" defaultValue={sp.type ?? ""} className={selectClass} aria-label="Type">
              <option value="">All types</option>
              {INCIDENT_TYPES.map((t) => (
                <option key={t} value={t}>
                  {INCIDENT_TYPE_LABEL[t]}
                </option>
              ))}
            </select>
            <select name="status" defaultValue={sp.status ?? ""} className={selectClass} aria-label="Status">
              <option value="">Open and closed</option>
              <option value="open">Open</option>
              <option value="closed">Closed</option>
            </select>
            <select name="driver_id" defaultValue={sp.driver_id ?? ""} className={selectClass} aria-label="Driver">
              <option value="">All drivers</option>
              {options.drivers.map((d) => (
                <option key={d.value} value={d.value}>
                  {d.label}
                </option>
              ))}
            </select>
            <select name="truck_id" defaultValue={sp.truck_id ?? ""} className={selectClass} aria-label="Truck">
              <option value="">All trucks</option>
              {options.trucks.map((t) => (
                <option key={t.value} value={t.value}>
                  {t.label}
                </option>
              ))}
            </select>
            <button type="submit" className="h-8 rounded-sm border border-desktop-border px-3 font-medium hover:bg-muted">
              Filter
            </button>
            {filtered && (
              <Link href="/safety" className="h-8 px-2 leading-8 text-primary hover:underline">
                Clear
              </Link>
            )}
          </form>

          {rows.length === 0 ? (
            <EmptyState
              title={filtered ? "No incidents match these filters" : "No incidents on record"}
              description={filtered ? "Try different filters." : "When something happens -- an accident, a ticket, a cargo claim or a roadside inspection violation -- record it here."}
              action={{ label: "Report Incident", href: "/safety/new" }}
            />
          ) : (
            <div className="overflow-x-auto rounded-md border border-desktop-border bg-card shadow-elevation-1">
              <table className="w-full min-w-[760px] text-left text-[12.5px]">
                <thead className="bg-desktop-header text-[11px] uppercase tracking-wide text-desktop-header-text">
                  <tr>
                    <th className="px-3 py-1.5 font-semibold">Date</th>
                    <th className="px-3 py-1.5 font-semibold">Type</th>
                    <th className="px-3 py-1.5 font-semibold">Driver</th>
                    <th className="px-3 py-1.5 font-semibold">Truck</th>
                    <th className="px-3 py-1.5 font-semibold">Place</th>
                    <th className="px-3 py-1.5 font-semibold">Load</th>
                    <th className="px-3 py-1.5 text-right font-semibold">Cost</th>
                    <th className="px-3 py-1.5 font-semibold">Status</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-desktop-border">
                  {rows.map((r) => (
                    <tr key={r.id} className="hover:bg-muted/50">
                      <td className="whitespace-nowrap px-3 py-1.5">
                        <Link href={`/safety/${r.id}`} className="font-medium text-primary hover:underline">
                          {shortDate(r.occurred_on)}
                        </Link>
                      </td>
                      <td className="px-3 py-1.5">{incidentTypeLabel(r.incident_type)}</td>
                      <td className="px-3 py-1.5">{r.driver_id ? <Link href={`/drivers/${r.driver_id}`} className="hover:underline">{driverName(r.drivers) ?? "--"}</Link> : "--"}</td>
                      <td className="px-3 py-1.5">{r.truck_id ? <Link href={`/trucks/${r.truck_id}`} className="hover:underline">{r.trucks?.unit_number ?? "--"}</Link> : "--"}</td>
                      <td className="max-w-[240px] truncate px-3 py-1.5" title={r.location ?? undefined}>
                        {r.location ?? "--"}
                      </td>
                      <td className="px-3 py-1.5">{r.load_id ? <Link href={`/loads/${r.load_id}`} className="hover:underline">{r.loads?.load_number ?? "--"}</Link> : "--"}</td>
                      <td className="px-3 py-1.5 text-right tabular-nums">{money(r.cost)}</td>
                      <td className="px-3 py-1.5">
                        <StatusBadge status={r.status} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
