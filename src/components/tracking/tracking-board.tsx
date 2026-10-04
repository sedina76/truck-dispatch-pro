"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { MessageSquare, Crosshair, CloudLightning } from "lucide-react";
import { cn } from "@/lib/utils";
import { useToast } from "@/components/ui/toast";
import { LiveMap, type DriverMarker, type DispatchStopCoords } from "@/components/tracking/live-map";
import { sendDispatchMessage } from "@/app/(app)/dispatch/board-actions";
import { formatStopDayTime } from "@/lib/timezone/format";
import { formatMiles, formatLateLabel, formatMarginLabel } from "@/lib/routing/risk";
import { sortFleet, matchesFilter, fleetCounts, isGpsQuiet, agoLabel, REOPEN_APP_MESSAGE, type FleetRow, type FleetFilter } from "@/lib/tracking/fleet";

// Live Tracking = status counts + map + a truck list ranked by what needs the
// dispatcher first (late, at risk, GPS quiet, ...). Clicking a row (or a
// count) zooms the map to that truck and opens its ETA panel.

const STATUS_LABEL: Record<string, string> = {
  assigned: "Assigned",
  accepted: "Assigned",
  en_route_to_pickup: "En Route to Pickup",
  at_pickup: "At Pickup",
  loaded: "Loaded",
  in_transit: "In Transit",
  at_delivery: "At Delivery",
  delivered: "Delivered",
};

const FILTERS: { key: FleetFilter; label: string }[] = [
  { key: "all", label: "All" },
  { key: "late", label: "Late" },
  { key: "at_risk", label: "At Risk" },
  { key: "quiet", label: "GPS Quiet" },
  { key: "weather", label: "Weather" },
  { key: "on_load", label: "On a Load" },
  { key: "idle", label: "No Load" },
];

export function TrackingBoard({
  rows,
  markers,
  organizationId,
  initialDispatchStops,
  geofenceRadii,
  renderedAt,
}: {
  rows: FleetRow[];
  markers: DriverMarker[];
  organizationId: string;
  initialDispatchStops: Record<string, DispatchStopCoords>;
  geofenceRadii: { pickup: number; delivery: number };
  /** Server time the rows were built (keeps "ago" labels stable on first paint). */
  renderedAt: number;
}) {
  const [filter, setFilter] = useState<FleetFilter>("all");
  const [focus, setFocus] = useState<{ driverId: string; dispatchId: string | null; nonce: number } | null>(null);
  const [sending, startSending] = useTransition();
  const [asked, setAsked] = useState<Set<string>>(new Set());
  const toast = useToast();
  const router = useRouter();
  const now = renderedAt;

  // The map moves with every GPS update on its own; the counts and the list
  // (ETA, late / at risk) refresh from the server once a minute.
  useEffect(() => {
    const id = setInterval(() => router.refresh(), 60_000);
    return () => clearInterval(id);
  }, [router]);

  const counts = useMemo(() => fleetCounts(rows, now), [rows, now]);
  const visible = useMemo(() => sortFleet(rows, now).filter((r) => matchesFilter(r, filter, now)), [rows, filter, now]);

  function focusRow(r: FleetRow) {
    setFocus({ driverId: r.driverId, dispatchId: r.dispatchId, nonce: Date.now() });
    document.getElementById("live-map")?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  function askToReopen(r: FleetRow) {
    if (!r.dispatchId) return;
    const dispatchId = r.dispatchId;
    startSending(async () => {
      const result = await sendDispatchMessage(dispatchId, REOPEN_APP_MESSAGE);
      if (result.ok) {
        setAsked((s) => new Set(s).add(dispatchId));
        toast.show("success", `Message sent to ${r.driverName}.`);
      } else {
        toast.show("error", result.error);
      }
    });
  }

  // One slim row of status pills (the counts AND the list filter) -- the map
  // gets the space four big cards used to take.
  const TONE: Partial<Record<FleetFilter, string>> = {
    late: counts.late ? "text-danger" : "",
    at_risk: counts.atRisk ? "text-warning" : "",
    quiet: counts.quiet ? "text-warning" : "",
    weather: counts.weather ? "text-danger" : "",
  };
  const DOT: Partial<Record<FleetFilter, string>> = { late: "bg-danger", at_risk: "bg-warning", quiet: "bg-warning", weather: "bg-danger", on_load: "bg-success", idle: "bg-muted-foreground" };
  const activeLabel = FILTERS.find((f) => f.key === filter)?.label ?? "All";

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-1.5" role="tablist" aria-label="Filter trucks" data-testid="fleet-counts">
        {FILTERS.map((f) => {
          const n = rows.filter((r) => matchesFilter(r, f.key, now)).length;
          const on = filter === f.key;
          return (
            <button
              key={f.key}
              type="button"
              role="tab"
              aria-selected={on}
              onClick={() => setFilter(on && f.key !== "all" ? "all" : f.key)}
              className={cn(
                "inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-[12.5px] font-medium transition-colors",
                on ? "border-primary bg-primary text-primary-foreground" : "border-desktop-border bg-card hover:bg-muted"
              )}
            >
              {DOT[f.key] && <span className={cn("size-2 rounded-full", on ? "bg-primary-foreground" : DOT[f.key])} />}
              {f.label}
              <span className={cn("font-semibold tabular-nums", !on && TONE[f.key])}>{n}</span>
            </button>
          );
        })}
        <span className="ml-auto text-[12px] text-muted-foreground">
          {counts.reportingLive} of {rows.length} reporting live
        </span>
      </div>

      <div id="live-map">
        <LiveMap initialMarkers={markers} organizationId={organizationId} initialDispatchStops={initialDispatchStops} geofenceRadii={geofenceRadii} focus={focus} />
      </div>

      <div className="rounded-md border border-desktop-border bg-card">
        <div className="flex items-center justify-between gap-2 border-b border-desktop-border px-3 py-2">
          <p className="text-sm font-semibold">
            Trucks <span className="font-normal text-muted-foreground">· {activeLabel} ({visible.length})</span>
          </p>
          {filter !== "all" && (
            <button type="button" onClick={() => setFilter("all")} className="text-[12px] font-medium text-primary hover:underline">
              Show all
            </button>
          )}
        </div>

        {visible.length === 0 ? (
          <p className="px-3 py-6 text-center text-sm text-muted-foreground">No trucks in this view.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[860px] text-[13px]" data-testid="fleet-list">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[11px] uppercase tracking-wide text-muted-foreground">
                  <th className="px-3 py-2 font-semibold">Truck / Driver</th>
                  <th className="px-3 py-2 font-semibold">Load</th>
                  <th className="px-3 py-2 font-semibold">Next Stop</th>
                  <th className="px-3 py-2 text-right font-semibold">Miles Left</th>
                  <th className="px-3 py-2 font-semibold">ETA</th>
                  <th className="px-3 py-2 font-semibold">Status</th>
                  <th className="px-3 py-2 font-semibold">Last GPS</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody>
                {visible.map((r) => {
                  const quiet = isGpsQuiet(r, now);
                  return (
                    <tr key={r.driverId} onClick={() => focusRow(r)} className="cursor-pointer border-b border-desktop-border last:border-0 hover:bg-muted/50">
                      <td className="px-3 py-2">
                        <p className="font-semibold">{r.truckUnit ?? "No truck"}</p>
                        <p className="text-[12px] text-muted-foreground">{r.driverName}</p>
                      </td>
                      <td className="px-3 py-2">
                        {r.dispatchId ? (
                          <>
                            <p className="font-medium">{r.loadNumber ?? "--"}</p>
                            <p className="text-[12px] text-muted-foreground">{r.dispatchStatus ? STATUS_LABEL[r.dispatchStatus] ?? r.dispatchStatus : ""}</p>
                          </>
                        ) : (
                          <span className="text-muted-foreground">No active load</span>
                        )}
                      </td>
                      <td className="px-3 py-2">
                        {r.dispatchId ? r.nextStop ?? "--" : ""}
                        {r.dispatchId && r.weather && r.weather.length > 0 && (
                          <p className="mt-0.5 flex items-center gap-1 text-[11.5px] font-medium text-danger" title={r.weather.map((w) => `${w.event} -- ${w.where}${w.area ? `, ${w.area}` : ""}`).join("\n")}>
                            <CloudLightning className="size-3 shrink-0" /> {r.weather[0].event}
                            {r.weather.length > 1 ? ` +${r.weather.length - 1}` : ""}
                          </p>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">{r.dispatchId ? formatMiles(r.milesLeftMeters) : ""}</td>
                      <td className="px-3 py-2">{r.dispatchId ? (r.calcStatus === "no_coordinates" ? <span className="text-muted-foreground">Stop not on map</span> : formatStopDayTime(r.etaAt, r.stopTimezone)) : ""}</td>
                      <td className="px-3 py-2">
                        <RiskPill row={r} />
                      </td>
                      <td className={cn("px-3 py-2", quiet && "font-medium text-warning")}>
                        {agoLabel(r.recordedAt, now)}
                        {r.speedMph != null && !quiet && <span className="text-muted-foreground"> · {r.speedMph} mph</span>}
                      </td>
                      <td className="px-3 py-2 text-right" onClick={(e) => e.stopPropagation()}>
                        <div className="flex items-center justify-end gap-1.5">
                          {quiet && r.dispatchId && (
                            <button
                              type="button"
                              disabled={sending || asked.has(r.dispatchId)}
                              onClick={() => askToReopen(r)}
                              title="Send the driver a message asking them to reopen the driver app"
                              className="inline-flex items-center gap-1 rounded-sm border border-desktop-border px-2 py-1 text-[12px] font-medium hover:bg-muted disabled:opacity-50"
                            >
                              <MessageSquare className="size-3.5" /> {asked.has(r.dispatchId) ? "Asked" : "Ask to reopen app"}
                            </button>
                          )}
                          <button type="button" onClick={() => focusRow(r)} title="Show on map" className="rounded-sm p-1 text-muted-foreground hover:bg-muted hover:text-desktop-text">
                            <Crosshair className="size-4" />
                          </button>
                          {r.dispatchId && (
                            <Link href={`/dispatch/${r.dispatchId}`} className="text-[12px] font-medium text-primary hover:underline">
                              Open
                            </Link>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}

function RiskPill({ row }: { row: FleetRow }) {
  if (!row.dispatchId) return <span className="text-muted-foreground">--</span>;
  const base = "inline-block rounded-full px-2 py-0.5 text-[11.5px] font-semibold";
  switch (row.risk) {
    case "late":
      return <span className={cn(base, "bg-danger/10 text-danger")}>Late {formatLateLabel(row.varianceMinutes)}</span>;
    case "at_risk":
      return <span className={cn(base, "bg-warning/10 text-warning")}>At Risk</span>;
    case "on_time":
      return <span className={cn(base, "bg-success/10 text-success")}>On Time{formatMarginLabel(row.varianceMinutes) ? ` · ${formatMarginLabel(row.varianceMinutes)}` : ""}</span>;
    case "arrived":
      return <span className={cn(base, "bg-success/10 text-success")}>Arrived</span>;
    default:
      return <span className={cn(base, "bg-muted text-muted-foreground")}>{row.calcStatus === "no_coordinates" ? "No ETA" : "Waiting for GPS"}</span>;
  }
}
