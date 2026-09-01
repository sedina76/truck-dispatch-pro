"use client";

import { useEffect, useMemo, useState } from "react";
import { resolveEquipmentCarrier } from "@/lib/equipment/carrier-derivation";
import { RecordPicker, type RecordOption } from "@/components/ui/record-picker";

export type FuelTruckOption = { id: string; unit_number: string; carrier_id: string | null; carrier_name: string | null; ownership_type: string | null; current_odometer: number | null };
export type FuelDriverOption = { id: string; first_name: string; last_name: string; carrier_id: string | null; carrier_name?: string | null };

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const inputClass = selectClass;
const labelClass = "text-[12px] font-medium text-desktop-text";

// FUEL PURCHASE DETAILS (spec sections 3/16/17/18). Truck -> Carrier
// derivation reuses resolveEquipmentCarrier() (src/lib/equipment/
// carrier-derivation.ts) -- the SAME rule already live-verified for
// Maintenance -- called with trailer=null since fuel_logs has no
// trailer_id at all (spec section 3: no second derivation rule).
//
// Driver integrity repair: the "Driver" field here is "who purchased the
// fuel" (attribution only -- it never drives recovery/settlement, which is
// the separate Responsible Driver field). It is now scoped to drivers of
// the SELECTED TRUCK'S CARRIER (drivers.carrier_id = trucks.carrier_id --
// both real NOT NULL FKs, 0003), replacing the previous org-wide list.
// createFuelLog()/updateFuelLog() re-enforce this server-side; this filter
// is the UI half, never the authority. The separate Responsible Driver
// field (payment-responsibility-fields.tsx) is intentionally left org-wide
// per its own design comment and is NOT touched here.
export function FuelPurchaseFields({
  trucks,
  drivers,
  defaultTruckId,
  defaultDriverId,
  defaultGallons,
  defaultPricePerGallon,
  defaultTotalAmount,
  defaultOdometerReading,
  defaultState,
  defaultStationName,
  defaultPurchasedAt,
  totalDisabled,
  truckDisabled,
}: {
  trucks: FuelTruckOption[];
  drivers: FuelDriverOption[];
  defaultTruckId?: string | null;
  defaultDriverId?: string | null;
  defaultGallons?: number | null;
  defaultPricePerGallon?: number | null;
  defaultTotalAmount?: number | null;
  defaultOdometerReading?: number | null;
  defaultState?: string | null;
  defaultStationName?: string | null;
  defaultPurchasedAt?: string | null;
  /** Once an expense has been created from this fuel log, total_amount
   * changes here are silently ignored server-side (actions.ts) --
   * disabled to avoid a confusing no-op edit. */
  totalDisabled?: boolean;
  /** Once an expense and/or recovery already exists, the truck (and the
   * carrier it derives) is frozen server-side (actions.ts/guard_fuel_log_
   * org, spec section 13 RECOVERY SAFETY: "Do not silently rewrite
   * historical recovered fuel to another carrier") -- disabled here too so
   * the UI doesn't suggest an edit that won't apply. A hidden input keeps
   * submitting the real value, since a disabled <select> never submits
   * its own value. */
  truckDisabled?: boolean;
}) {
  const [truckId, setTruckId] = useState(defaultTruckId ?? "");
  const [driverId, setDriverId] = useState(defaultDriverId ?? "");
  const [gallons, setGallons] = useState(defaultGallons != null ? String(defaultGallons) : "");
  const [pricePerGallon, setPricePerGallon] = useState(defaultPricePerGallon != null ? String(defaultPricePerGallon) : "");
  const [odometerReading, setOdometerReading] = useState(defaultOdometerReading != null ? String(defaultOdometerReading) : "");

  const selectedTruck = trucks.find((t) => t.id === truckId) ?? null;
  const derivation = resolveEquipmentCarrier(selectedTruck, null);
  const resolvedCarrierName = derivation.kind === "resolved" ? derivation.carrierName : null;
  const truckCarrierId = selectedTruck?.carrier_id ?? null;

  // Eligible = drivers whose own carrier is this truck's carrier. Plus, on
  // an edit where the truck is unchanged, the already-saved driver even if
  // its carrier no longer matches (a pre-existing mismatch) -- so editing
  // an unrelated field never silently drops that historical value. The
  // server only re-checks carrier alignment when driver_id actually
  // changes, so leaving it pinned is safe.
  const eligibleDrivers = useMemo(
    () => (truckCarrierId ? drivers.filter((d) => d.carrier_id === truckCarrierId) : []),
    [drivers, truckCarrierId]
  );
  const pinnedHistorical = useMemo(() => {
    if (!defaultDriverId || truckId !== (defaultTruckId ?? "")) return null;
    if (eligibleDrivers.some((d) => d.id === defaultDriverId)) return null;
    return drivers.find((d) => d.id === defaultDriverId) ?? null;
  }, [defaultDriverId, defaultTruckId, truckId, drivers, eligibleDrivers]);

  const driverOptions: RecordOption[] = useMemo(() => {
    const base: RecordOption[] = eligibleDrivers.map((d) => ({
      id: d.id,
      primary: `${d.first_name} ${d.last_name}`.trim(),
      secondary: d.carrier_name ?? resolvedCarrierName ?? null,
      searchText: `${d.first_name} ${d.last_name} ${d.carrier_name ?? ""}`.toLowerCase(),
    }));
    if (pinnedHistorical) {
      base.unshift({
        id: pinnedHistorical.id,
        primary: `${pinnedHistorical.first_name} ${pinnedHistorical.last_name}`.trim(),
        secondary: `${pinnedHistorical.carrier_name ?? "Other carrier"} — currently on file`,
        searchText: `${pinnedHistorical.first_name} ${pinnedHistorical.last_name}`.toLowerCase(),
      });
    }
    return base;
  }, [eligibleDrivers, pinnedHistorical, resolvedCarrierName]);

  // Reconcile the driver selection whenever the truck's carrier changes:
  // drop a now-ineligible pick, and auto-select when exactly one eligible
  // driver exists. Keyed on truckCarrierId only (not driverId) so it
  // reacts to truck changes, not to the user's own driver choice.
  useEffect(() => {
    const validIds = new Set(driverOptions.map((o) => o.id));
    setDriverId((current) => {
      if (current && !validIds.has(current)) {
        return eligibleDrivers.length === 1 ? eligibleDrivers[0].id : "";
      }
      if (!current && eligibleDrivers.length === 1) {
        return eligibleDrivers[0].id;
      }
      return current;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [truckCarrierId]);

  const gallonsNum = Number(gallons);
  const priceNum = Number(pricePerGallon);
  const hasCalc = gallons !== "" && pricePerGallon !== "" && !Number.isNaN(gallonsNum) && !Number.isNaN(priceNum);
  const calculatedTotal = hasCalc ? gallonsNum * priceNum : null;

  const odometerNum = Number(odometerReading);
  const showOdometerWarning =
    odometerReading !== "" && !Number.isNaN(odometerNum) && selectedTruck?.current_odometer != null && odometerNum < selectedTruck.current_odometer;

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <label htmlFor="truck_id" className={labelClass}>Truck <span className="text-danger">*</span></label>
          <select
            id="truck_id"
            name={truckDisabled ? undefined : "truck_id"}
            required
            disabled={truckDisabled}
            value={truckId}
            onChange={(e) => setTruckId(e.target.value)}
            className={selectClass}
          >
            <option value="" disabled>Select...</option>
            {trucks.map((t) => (
              <option key={t.id} value={t.id}>{t.unit_number}</option>
            ))}
          </select>
          {truckDisabled && <input type="hidden" name="truck_id" value={truckId} />}
        </div>
        <div className="space-y-1">
          <label htmlFor="driver_id" className={labelClass}>Driver</label>
          <input type="hidden" name="driver_id" value={driverId} />
          {!selectedTruck ? (
            <div className={`${selectClass} flex items-center text-muted-foreground`}>Select a truck first</div>
          ) : driverOptions.length === 0 ? (
            <div className={`${selectClass} flex items-center text-muted-foreground`}>
              No eligible drivers are linked to {resolvedCarrierName ?? "this carrier"}.
            </div>
          ) : (
            <RecordPicker
              id="driver_id"
              options={driverOptions}
              value={driverId || null}
              onChange={setDriverId}
              placeholder={`Search & select a ${resolvedCarrierName ?? "carrier"} driver...`}
              searchPlaceholder="Search driver name..."
              emptyLabel={`No eligible drivers are linked to ${resolvedCarrierName ?? "this carrier"}.`}
              ariaLabel="Driver who purchased the fuel"
            />
          )}
          <p className="text-[11px] text-desktop-text-muted">
            Who purchased the fuel -- for reporting/attribution only. Only drivers of this truck&apos;s carrier are listed.
            Does not determine who financially owes for it.
          </p>
        </div>
      </div>

      {/* Carrier is always auto-selected/derived from the truck above --
          never a manual field (spec TRUCK -> CARRIER AUTO-SELECTION).
          Owner-Operator equipment is called out explicitly (spec section
          4) so staff can see at a glance that any carrier-settlement
          recovery targets this truck's real owner, not a generic
          fleet carrier. */}
      {selectedTruck && (
        <div className="rounded-sm border border-desktop-border bg-desktop-muted px-3 py-2">
          <p className="text-[10px] font-medium uppercase tracking-wide text-muted-foreground">Carrier / Owner</p>
          <p className="mt-0.5 text-[13px] text-desktop-text">
            {resolvedCarrierName ?? "-- unassigned --"}
            {selectedTruck.ownership_type === "owner_operator" && (
              <span className="ml-1.5 rounded-sm bg-desktop-warning/15 px-1.5 py-0.5 text-[10.5px] font-medium text-desktop-warning">Owner-Operator</span>
            )}
          </p>
          {resolvedCarrierName && <p className="text-[11px] text-muted-foreground">Auto-selected from Truck {selectedTruck.unit_number}</p>}
        </div>
      )}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <label className={labelClass}>Gallons <span className="text-danger">*</span></label>
          <input name="gallons" type="number" step="0.01" min="0" required value={gallons} onChange={(e) => setGallons(e.target.value)} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Price per Gallon</label>
          <input name="price_per_gallon" type="number" step="0.001" min="0" value={pricePerGallon} onChange={(e) => setPricePerGallon(e.target.value)} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Total Amount ($) <span className="text-danger">*</span></label>
          <input name="total_amount" type="number" step="0.01" min="0" required disabled={totalDisabled} defaultValue={defaultTotalAmount ?? undefined} className={inputClass} />
          {calculatedTotal != null && (
            <p className="text-[11px] text-desktop-text-muted">
              Calculated: {gallonsNum} gal x ${priceNum.toFixed(3)} = ${calculatedTotal.toFixed(2)}
              {defaultTotalAmount != null && Math.abs(calculatedTotal - Number(defaultTotalAmount)) > 0.01 && " -- differs from Total Amount above (taxes/fees, or check for a typo)."}
            </p>
          )}
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Odometer Reading</label>
          <input name="odometer_reading" type="number" min="0" value={odometerReading} onChange={(e) => setOdometerReading(e.target.value)} className={inputClass} />
          {showOdometerWarning && (
            <p className="text-[11px] text-desktop-danger">
              Lower than this truck&apos;s last known odometer ({selectedTruck!.current_odometer!.toLocaleString()}) -- double-check before saving.
            </p>
          )}
        </div>
        <div className="space-y-1">
          <label className={labelClass}>State</label>
          <input name="state" placeholder="IL" defaultValue={defaultState ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Station Name</label>
          <input name="station_name" defaultValue={defaultStationName ?? ""} className={inputClass} />
        </div>
        <div className="space-y-1">
          <label className={labelClass}>Purchased At</label>
          <input name="purchased_at" type="datetime-local" defaultValue={defaultPurchasedAt ?? ""} className={inputClass} />
        </div>
      </div>
    </div>
  );
}
