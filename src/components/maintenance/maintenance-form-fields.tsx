"use client";

import { useState } from "react";
import { resolveEquipmentCarrier } from "@/lib/equipment/carrier-derivation";
export { PaymentResponsibilityFields, type DriverOption } from "@/components/shared/payment-responsibility-fields";

export type TruckOption = { id: string; unit_number: string; carrier_id: string | null; carrier_name: string | null; ownership_type: string | null; status: string; current_odometer: number | null };
export type TrailerOption = { id: string; unit_number: string; carrier_id: string | null; carrier_name: string | null; ownership_type: string | null; status: string };

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const inputClass = selectClass;
const labelClass = "text-[12px] font-medium text-desktop-text";

// EQUIPMENT + SERVICE DETAILS (spec PHASE 3). One component because
// selecting a truck/trailer needs to live-update the contextual info panel
// (Unit #/Carrier/Ownership/Status/Odometer) -- self-contained, no
// dependency on the Payment & Responsibility section below.
export function EquipmentServiceFields({
  trucks,
  trailers,
  defaultTruckId,
  defaultTrailerId,
  defaultCost,
  defaultServiceType,
  defaultVendorName,
  defaultOdometerReading,
  defaultServiceDate,
  defaultNextServiceDueDate,
  defaultNextServiceDueOdometer,
  defaultDescription,
  costDisabled,
}: {
  trucks: TruckOption[];
  trailers: TrailerOption[];
  defaultTruckId?: string | null;
  defaultTrailerId?: string | null;
  defaultCost?: number | null;
  defaultServiceType?: string | null;
  defaultVendorName?: string | null;
  defaultOdometerReading?: number | null;
  defaultServiceDate?: string | null;
  /** Once an expense has been created from this record, cost changes here
   * are silently ignored server-side (actions.ts) -- disabled to avoid a
   * confusing no-op edit. */
  costDisabled?: boolean;
  defaultNextServiceDueDate?: string | null;
  defaultNextServiceDueOdometer?: number | null;
  defaultDescription?: string | null;
}) {
  const [truckId, setTruckId] = useState(defaultTruckId ?? "");
  const [trailerId, setTrailerId] = useState(defaultTrailerId ?? "");

  const selectedTruck = trucks.find((t) => t.id === truckId) ?? null;
  const selectedTrailer = trailers.find((t) => t.id === trailerId) ?? null;
  // Both a truck AND a trailer may be selected together (e.g. one PM visit
  // servicing a tractor and its attached trailer) -- carrier_id itself is
  // never a form field the client submits; it's always re-derived
  // server-side from whichever equipment is selected (guard_maintenance_
  // org(), 0050), so nothing here needs to "pick" a carrier to send.
  // resolveEquipmentCarrier() is the ONE shared derivation rule -- also
  // used by the Maintenance workspace filter bar -- never duplicated.
  const derivation = resolveEquipmentCarrier(selectedTruck, selectedTrailer);
  const carrierMismatch = derivation.kind === "mismatch";
  const resolvedCarrierName = derivation.kind === "resolved" ? derivation.carrierName : null;
  const resolvedFrom = derivation.kind === "resolved" ? (derivation.source === "truck" ? "Truck" : "Trailer") : null;

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <label htmlFor="truck_id" className={labelClass}>Truck</label>
          <select id="truck_id" name="truck_id" value={truckId} onChange={(e) => setTruckId(e.target.value)} className={selectClass}>
            <option value="">None</option>
            {trucks.map((t) => (
              <option key={t.id} value={t.id}>{t.unit_number}</option>
            ))}
          </select>
        </div>
        <div className="space-y-1">
          <label htmlFor="trailer_id" className={labelClass}>Trailer</label>
          <select id="trailer_id" name="trailer_id" value={trailerId} onChange={(e) => setTrailerId(e.target.value)} className={selectClass}>
            <option value="">None</option>
            {trailers.map((t) => (
              <option key={t.id} value={t.id}>{t.unit_number}</option>
            ))}
          </select>
        </div>
      </div>

      {/* Carrier is always auto-selected/derived from the equipment above --
          never a manual field (spec EQUIPMENT -> CARRIER AUTO-SELECTION).
          Shown prominently, separate from the smaller context grid below. */}
      {(selectedTruck || selectedTrailer) && (
        <div className="rounded-sm border border-desktop-border bg-desktop-muted px-3 py-2">
          <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">Carrier</p>
          {carrierMismatch ? (
            <p className="mt-0.5 text-[13px] font-medium text-danger">
              Mismatch -- {selectedTruck?.carrier_name ?? "unassigned"} (truck) vs. {selectedTrailer?.carrier_name ?? "unassigned"} (trailer). Select equipment from a single carrier, or log two separate maintenance records.
            </p>
          ) : (
            <p className="mt-0.5 text-[13px] text-desktop-text">
              {resolvedCarrierName ?? "-- unassigned --"}
              {resolvedFrom && <span className="ml-1.5 text-[11px] text-muted-foreground">(Auto-selected from {resolvedFrom})</span>}
            </p>
          )}
        </div>
      )}

      {(selectedTruck || selectedTrailer) ? (
        <div className="space-y-2">
          {selectedTruck && (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1 rounded-sm border border-desktop-border bg-desktop-muted px-3 py-2 text-[12px] sm:grid-cols-4">
              <ContextField label="Unit #" value={selectedTruck.unit_number} />
              <ContextField label="Ownership" value={selectedTruck.ownership_type ? selectedTruck.ownership_type.replace(/_/g, " ") : "--"} />
              <ContextField label="Status" value={selectedTruck.status.replace(/_/g, " ")} />
              <ContextField label="Current Odometer" value={selectedTruck.current_odometer != null ? selectedTruck.current_odometer.toLocaleString() : "--"} />
            </div>
          )}
          {selectedTrailer && (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1 rounded-sm border border-desktop-border bg-desktop-muted px-3 py-2 text-[12px] sm:grid-cols-4">
              <ContextField label="Unit #" value={selectedTrailer.unit_number} />
              <ContextField label="Ownership" value={selectedTrailer.ownership_type ? selectedTrailer.ownership_type.replace(/_/g, " ") : "--"} />
              <ContextField label="Status" value={selectedTrailer.status.replace(/_/g, " ")} />
              <ContextField label="Current Odometer" value="--" />
            </div>
          )}
        </div>
      ) : (
        <p className="text-[11.5px] text-desktop-text-muted">Select at least one truck or trailer.</p>
      )}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <label className={labelClass}>Service Type <span className="text-danger">*</span></label>
          <input name="service_type" required placeholder="Oil & Filter Change" defaultValue={defaultServiceType ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Vendor</label>
          <input name="vendor_name" defaultValue={defaultVendorName ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Cost ($) <span className="text-danger">*</span></label>
          <input id="maintenance_cost" name="cost" type="number" step="0.01" min="0" required disabled={costDisabled} defaultValue={defaultCost ?? undefined} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Odometer Reading</label>
          <input name="odometer_reading" type="number" defaultValue={defaultOdometerReading ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Service Date <span className="text-danger">*</span></label>
          <input name="service_date" type="date" required defaultValue={defaultServiceDate ?? new Date().toISOString().slice(0, 10)} className={inputClass} />
        </div>
        <div className="space-y-1" />
        <div className="space-y-1">
          <label className={labelClass}>Next Service Due Date</label>
          <input name="next_service_due_date" type="date" defaultValue={defaultNextServiceDueDate ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Next Service Due Odometer</label>
          <input name="next_service_due_odometer" type="number" defaultValue={defaultNextServiceDueOdometer ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1 sm:col-span-2">
          <label className={labelClass}>Description</label>
          <textarea name="description" rows={2} defaultValue={defaultDescription ?? ""} className="w-full rounded-sm border border-desktop-border bg-card px-2.5 py-1.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
        </div>
      </div>
    </div>
  );
}

// PaymentResponsibilityFields now lives in
// src/components/shared/payment-responsibility-fields.tsx (re-exported
// above) -- shared verbatim with Fuel Logs (0051) rather than duplicated.

function ContextField({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="capitalize text-desktop-text">{value}</p>
    </div>
  );
}
