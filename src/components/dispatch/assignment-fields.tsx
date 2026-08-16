"use client";

import { useEffect, useMemo, useState } from "react";
import type { CarrierOption, DriverOption, TruckOption, TrailerOption } from "@/app/(app)/dispatch/dispatch-data";
import { useDispatchFormState } from "./dispatch-form-state";

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const labelClass = "text-[12px] font-medium text-desktop-text";

// Carrier -> Driver/Truck/Trailer cascading selects (spec section 3). Pure
// UX filtering -- every option rendered here was already fetched through
// the caller's own RLS-scoped query (getAssignmentOptions), so there is no
// cross-org data in these lists to begin with; this component only
// narrows which of THOSE options are shown once a carrier is picked. Real
// enforcement (org + carrier-relationship consistency) happens server-side
// in guard_dispatch_org() (0048) and actions.ts regardless of what this
// component renders.
export function AssignmentFields({
  carriers,
  drivers,
  trucks,
  trailers,
  defaultCarrierId,
  defaultDriverId,
  defaultTruckId,
  defaultTrailerId,
  defaultFeePercentage,
}: {
  carriers: CarrierOption[];
  drivers: DriverOption[];
  trucks: TruckOption[];
  trailers: TrailerOption[];
  defaultCarrierId?: string | null;
  defaultDriverId?: string | null;
  defaultTruckId?: string | null;
  defaultTrailerId?: string | null;
  defaultFeePercentage?: number | null;
}) {
  // One canonical error result, not duplicated conflict logic (spec section
  // 8) -- this just reads which field (if any) the last submit's
  // DispatchActionState flagged, from the same context DispatchConflictAlert
  // reads, and marks that one field.
  const conflictState = useDispatchFormState();
  const conflictField = conflictState.field;
  const conflictNote = conflictState.conflictLoadNumber
    ? `Already assigned to ${conflictState.conflictLoadNumber}`
    : conflictState.code === "TRUCK_OUT_OF_SERVICE" || conflictState.code === "TRAILER_OUT_OF_SERVICE"
      ? "Currently out of service"
      : "Unavailable";

  // React 19 resets a <form>'s own (uncontrolled) fields back to their
  // original mount-time default right after a form-action submission
  // completes -- by design, so a form is "clean" for the next entry. That
  // also visibly clears this DOM's already-rendered carrier <select>
  // between commits. A defaultValue/value prop change alone can't undo
  // that (defaultValue only ever applies once, at mount -- this component
  // never remounts across a submission), so the two effects below
  // explicitly re-apply exactly what the user just submitted (echoed back
  // via DispatchActionState.values, spec section 7/9/10) right after
  // React's own reset -- restoring it rather than fighting to prevent it.
  const v = conflictState.values;
  const effectiveDefaultCarrierId = v?.carrierId ?? defaultCarrierId ?? "";
  const effectiveDefaultDriverId = v?.driverId ?? defaultDriverId ?? "";
  const effectiveDefaultTruckId = v?.truckId ?? defaultTruckId ?? "";
  const effectiveDefaultTrailerId = v?.trailerId ?? defaultTrailerId ?? "";
  const effectiveDefaultFeePercentage = v?.feePercentage ?? (defaultFeePercentage != null ? String(defaultFeePercentage) : "");

  const [carrierId, setCarrierId] = useState(effectiveDefaultCarrierId);

  // Stage 1: restore the carrier selection. Both the React state (so the
  // driver/truck/trailer option lists below are filtered correctly again)
  // AND the DOM value directly -- carrier_id is controlled, but the native
  // reset described above can still visibly clear it after React's last
  // commit for this update, so the state write alone isn't reliably enough
  // to win.
  useEffect(() => {
    if (!v) return;
    setCarrierId(v.carrierId);
    const el = document.getElementById("carrier_id") as HTMLSelectElement | null;
    if (el) el.value = v.carrierId;
    // Only re-run when a new submission result arrives, not on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conflictState]);

  // Stage 2: once carrierId (and therefore the option lists) reflect that
  // restored carrier, re-apply the driver/truck/trailer/fee values -- must
  // run AFTER stage 1's re-render so the matching <option> elements exist
  // to select.
  useEffect(() => {
    if (!v) return;
    const setVal = (id: string, val: string) => {
      const el = document.getElementById(id) as HTMLSelectElement | HTMLInputElement | null;
      if (el && val) el.value = val;
    };
    setVal("driver_id", v.driverId);
    setVal("truck_id", v.truckId);
    setVal("trailer_id", v.trailerId);
    setVal("dispatch_fee_percentage", v.feePercentage);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [carrierId, v]);

  const carrierDrivers = useMemo(() => drivers.filter((d) => d.carrier_id === carrierId), [drivers, carrierId]);
  const carrierTrucks = useMemo(() => trucks.filter((t) => t.carrier_id === carrierId), [trucks, carrierId]);
  // Trailers may be an unassigned/shared pool (carrier_id null, 0003) --
  // those stay selectable alongside the carrier's own trailers.
  const carrierTrailers = useMemo(() => trailers.filter((t) => t.carrier_id === carrierId || t.carrier_id === null), [trailers, carrierId]);

  const selectedTruck = trucks.find((t) => t.id === effectiveDefaultTruckId);
  const selectedTrailer = trailers.find((t) => t.id === effectiveDefaultTrailerId);
  // Assignment Type is derived, never stored -- spec section 1: no new
  // enum/column, since ownership_type on trucks/trailers ('owned',
  // 'leased', 'owner_operator', 0003) already carries this signal
  // reliably for the one case that actually matters operationally
  // (owner-operator pay routes through Carrier Settlement, never Driver
  // Settlement -- see the INTERNAL FINANCIALS section's note). "Company
  // Driver" vs "Outside Carrier" are NOT distinguishable in this schema
  // (both are just carrier+driver+truck with ownership_type != 'owner_
  // operator') so this never claims to tell them apart.
  const isOwnerOperator = selectedTruck?.ownership_type === "owner_operator" || selectedTrailer?.ownership_type === "owner_operator";

  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <div className="space-y-1">
        <label htmlFor="carrier_id" className={labelClass}>
          Carrier <span className="text-danger">*</span>
        </label>
        <select id="carrier_id" name="carrier_id" required value={carrierId} onChange={(e) => setCarrierId(e.target.value)} className={selectClass}>
          <option value="" disabled>
            Select...
          </option>
          {carriers.map((c) => (
            <option key={c.id} value={c.id}>
              {c.legal_name}
            </option>
          ))}
        </select>
      </div>

      <div className="space-y-1">
        <label className={labelClass}>Assignment Type</label>
        <div className="flex h-8 items-center rounded-sm border border-desktop-border bg-desktop-muted px-2.5 text-[13px] text-desktop-text-muted">
          {!carrierId ? "-- select a carrier --" : isOwnerOperator ? "Owner-Operator" : "Carrier Assignment"}
        </div>
      </div>

      <div className="space-y-1">
        <label htmlFor="driver_id" className={labelClass}>
          Driver <span className="text-danger">*</span>
        </label>
        <select
          id="driver_id"
          name="driver_id"
          required
          defaultValue={effectiveDefaultDriverId}
          disabled={!carrierId}
          className={conflictField === "driver" ? `${selectClass} border-danger` : selectClass}
        >
          <option value="" disabled>
            {carrierId ? "Select..." : "Select a carrier first"}
          </option>
          {carrierDrivers.map((d) => (
            <option key={d.id} value={d.id}>
              {d.first_name} {d.last_name}
            </option>
          ))}
        </select>
        {conflictField === "driver" && <p className="text-[11.5px] text-danger">⚠ {conflictNote}</p>}
      </div>

      <div className="space-y-1">
        <label htmlFor="truck_id" className={labelClass}>
          Truck <span className="text-danger">*</span>
        </label>
        <select
          id="truck_id"
          name="truck_id"
          required
          defaultValue={effectiveDefaultTruckId}
          disabled={!carrierId}
          className={conflictField === "truck" ? `${selectClass} border-danger` : selectClass}
        >
          <option value="" disabled>
            {carrierId ? "Select..." : "Select a carrier first"}
          </option>
          {carrierTrucks.map((t) => (
            <option key={t.id} value={t.id}>
              {t.unit_number}
              {t.ownership_type === "owner_operator" ? " (Owner-Operator)" : ""}
            </option>
          ))}
        </select>
        {conflictField === "truck" && <p className="text-[11.5px] text-danger">⚠ {conflictNote}</p>}
      </div>

      <div className="space-y-1">
        <label htmlFor="trailer_id" className={labelClass}>
          Trailer
        </label>
        <select
          id="trailer_id"
          name="trailer_id"
          defaultValue={effectiveDefaultTrailerId}
          disabled={!carrierId}
          className={conflictField === "trailer" ? `${selectClass} border-danger` : selectClass}
        >
          <option value="">{carrierId ? "None" : "Select a carrier first"}</option>
          {carrierTrailers.map((t) => (
            <option key={t.id} value={t.id}>
              {t.unit_number}
            </option>
          ))}
        </select>
        {conflictField === "trailer" && <p className="text-[11.5px] text-danger">⚠ {conflictNote}</p>}
      </div>

      <div className="space-y-1">
        <label htmlFor="dispatch_fee_percentage" className={labelClass}>
          Dispatch Fee % <span className="text-danger">*</span>
        </label>
        <input
          id="dispatch_fee_percentage"
          name="dispatch_fee_percentage"
          type="number"
          step="0.01"
          min="0"
          max="100"
          required
          defaultValue={effectiveDefaultFeePercentage || carriers.find((c) => c.id === carrierId)?.dispatch_fee_percentage || 10}
          className={selectClass}
        />
      </div>
    </div>
  );
}
