import { ArrowDown } from "lucide-react";
import { StatusBadge } from "@/components/ui/status-badge";
import type { LoadSummary, StopSummary } from "@/app/(app)/dispatch/dispatch-data";

function fmtDateTime(iso: string | null): string {
  if (!iso) return "-- no date set";
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

// Read-only, load_stops/loads only -- no duplicate pickup/delivery columns
// anywhere. Same component renders for New Dispatch and the existing
// dispatch's own load, so the two pages can't drift in what they show.
export function LoadSummaryPanel({ load }: { load: LoadSummary }) {
  return (
    <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
      <Field label="Load #" value={load.load_number} />
      <Field label="Status" value={<StatusBadge status={load.status} />} />
      <Field label="Broker / Customer" value={load.broker_name ?? load.customer_name ?? "--"} />
      <Field label="Equipment" value={load.equipment_type ? load.equipment_type.replace(/_/g, " ") : "--"} />
      <Field label="Miles" value={load.total_miles != null ? Number(load.total_miles).toLocaleString() : "--"} />
    </div>
  );
}

export function TripStopsPanel({ stops }: { stops: StopSummary[] }) {
  if (stops.length === 0) {
    return <p className="text-[12.5px] text-desktop-text-muted">No pickup/delivery stops on this load yet.</p>;
  }

  return (
    <div className="space-y-2">
      {stops.map((stop, i) => (
        <div key={`${stop.stop_type}-${stop.stop_sequence}`}>
          <div className="rounded-sm border border-desktop-border bg-card p-2.5">
            <div className="flex items-center gap-2">
              <span
                className={`rounded-sm px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                  stop.stop_type === "pickup" ? "bg-primary/10 text-primary" : "bg-desktop-success/15 text-desktop-success"
                }`}
              >
                {stop.stop_type}
              </span>
              <span className="text-[13px] font-medium text-desktop-text">{stop.facility_name ?? "Unnamed facility"}</span>
            </div>
            <p className="mt-1 text-[12.5px] text-desktop-text-muted">
              {[stop.city, stop.state].filter(Boolean).join(", ") || "-- no location set"} &middot; {fmtDateTime(stop.scheduled_at)}
            </p>
            {stop.reference_number && <p className="text-[11.5px] text-desktop-text-muted">{stop.stop_type === "pickup" ? "Pickup #" : "Ref #"}: {stop.reference_number}</p>}
          </div>
          {i < stops.length - 1 && (
            <div className="flex justify-center py-0.5">
              <ArrowDown className="size-3.5 text-desktop-text-muted" />
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-desktop-text-muted">{label}</p>
      <p className="text-desktop-text">{value}</p>
    </div>
  );
}
