"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { MessageSquare, Crosshair } from "lucide-react";
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

  const tiles: { key: FleetFilter; label: string; value: number; tone: string; hint: string }[] = [
    { key: "on_load", label: "On a Load", value: counts.onLoad, tone: "text-desktop-text", hint: `${counts.reportingLive} reporting live` },
    { key: "late", label: "Late", value: counts.late, tone: counts.late ? "text-danger" : "text-desktop-text", hint: "past the appointment" },
    { key: "at_risk", label: "At Risk", value: counts.atRisk, tone: counts.atRisk ? "text-warning" : "text-desktop-text", hint: "cutting it close" },
    { key: "quiet", label: "GPS Quiet", value: counts.quiet, tone: counts.quiet ? "text-warning" : "text-desktop-text", hint: "no update in 15+ min" },
  ];

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4" data-testid="fleet-counts">
        {tiles.map((t) => (
          <button
            key={t.key}
            type="button"
            onClick={() => setFilter(filter === t.key ? "all" : t.key)}
            className={cn(
              "rounded-md border bg-card px-4 py-3 text-left transition-colors hover:border-primary/50",
              filter === t.key ? "border-primary ring-1 ring-primary/30" : "border-desktop-border"
            )}
          >
            <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{t.label}</p>
            <p className={cn("mt-1 text-2xl font-semibold tabular-nums", t.tone)}>{t.value}</p>
            <p className="text-[11px] text-muted-foreground">{t.hint}</p>
          </button>
        ))}
      </div>

      <div id="live-map">
        <LiveMap initialMarkers={markers} organizationId={organizationId} initialDispatchStops={initialDispatchStops} geofenceRadii={geofenceRadii} focus={focus} />
      </div>

      <div className="rounded-md border border-desktop-border bg-card">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-desktop-border px-3 py-2">
          <p className="text-sm font-semibold">Trucks</p>
          <div className="flex flex-wrap gap-1" role="tablist" aria-label="Filter trucks">
            {FILTERS.map((f) => {
              const n = rows.filter((r) => matchesFilter(r, f.key, now)).length;
              return (
                <button
                  key={f.key}
                  type="button"
                  role="tab"
                  aria-selected={filter === f.key}
                  onClick={() => setFilter(f.key)}
                  className={cn(
                    "rounded-full border px-2.5 py-0.5 text-[12px] font-medium",
                    filter === f.key ? "border-primary bg-primary text-primary-foreground" : "border-desktop-border text-muted-foreground hover:bg-muted"
                  )}
                >
                  {f.label} {n}
                </button>
              );
            })}
          </div>
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
                      <td className="px-3 py-2">{r.dispatchId ? r.nextStop ?? "--" : ""}</td>
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
