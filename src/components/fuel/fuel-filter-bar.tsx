"use client";

import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { useTransition } from "react";
import { resolveEquipmentCarrier, type EquipmentCarrierRef } from "@/lib/equipment/carrier-derivation";

export type FuelEquipmentOption = { id: string; unit_number: string; carrier_id: string | null; carrier_name: string | null };
export type FuelCarrierOption = { id: string; legal_name: string };

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:bg-desktop-muted disabled:text-muted-foreground";
const labelClass = "text-[12px] font-medium text-desktop-text";

// Fuel Logs' Truck/Carrier filter pair -- same URL-driven, dependent-
// derivation approach already proven on the Maintenance workspace filter
// bar (maintenance-filter-bar.tsx), reused as a small PARALLEL component
// rather than sharing code directly with it: Fuel has no tabs/Status/
// Paid By/Recovery Status controls, no trailer, and no truck/trailer
// mismatch case, so wiring it through MaintenanceFilterBar's props would
// mean threading a pile of fuel-shaped no-ops through a component that's
// already live-verified for Maintenance -- unnecessary regression risk
// for the six already-verified Maintenance tabs (spec section 11: "A
// small parallel helper is acceptable if sharing would destabilize
// verified Maintenance behavior"). The actual derivation RULE is still
// the single shared resolveEquipmentCarrier() -- never reimplemented.
//
// Fully URL-driven, no local mirror state: every value read here comes
// from useSearchParams(), every change writes back via router.replace()
// wrapped in startTransition -- identical idiom to MaintenanceFilterBar
// and to SearchBar (which still owns the separate Station search field on
// this page, unchanged).
export function FuelFilterBar({ trucks, carriers }: { trucks: FuelEquipmentOption[]; carriers: FuelCarrierOption[] }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();

  const truckId = searchParams.get("truck_id") ?? "";
  const manualCarrierId = searchParams.get("carrier_id") ?? "";

  const selectedTruck: EquipmentCarrierRef = trucks.find((t) => t.id === truckId) ?? null;
  const derivation = resolveEquipmentCarrier(selectedTruck, null);

  // Carrier-first restriction (spec CARRIER -> TRUCK) only while no truck
  // is selected -- once one is, the Truck dropdown must stay unrestricted
  // so staff can freely swap to a different carrier's truck (spec TRUCK
  // SWAP), matching the identical rule already verified for Maintenance.
  const restrictByCarrierId = derivation.kind === "manual" ? manualCarrierId || null : null;
  const truckOptions = restrictByCarrierId ? trucks.filter((t) => t.carrier_id === restrictByCarrierId) : trucks;

  const carrierLocked = derivation.kind === "resolved";
  const displayCarrierId = derivation.kind === "resolved" ? derivation.carrierId : manualCarrierId;

  function updateParams(mutate: (params: URLSearchParams) => void) {
    const params = new URLSearchParams(searchParams.toString());
    mutate(params);
    startTransition(() => {
      router.replace(`${pathname}?${params.toString()}`, { scroll: false });
    });
  }
  function setOrDelete(params: URLSearchParams, key: string, value: string) {
    if (value) params.set(key, value);
    else params.delete(key);
  }

  function onTruckChange(id: string) {
    updateParams((params) => {
      setOrDelete(params, "truck_id", id);
      // Truck becomes authoritative the moment it's chosen -- never leave
      // an independently-set carrier_id sitting alongside it (spec CARRIER
      // -> TRUCK: truck's canonical carrier becomes authoritative).
      params.delete("carrier_id");
    });
  }
  function onCarrierChange(id: string) {
    updateParams((params) => setOrDelete(params, "carrier_id", id));
  }
  function onClear() {
    updateParams((params) => {
      params.delete("truck_id");
      params.delete("carrier_id");
    });
  }

  return (
    <>
      <div className="w-40">
        <label htmlFor="filter_truck_id" className={labelClass}>Truck</label>
        <select id="filter_truck_id" className={selectClass} value={truckId} onChange={(e) => onTruckChange(e.target.value)}>
          <option value="">All Trucks</option>
          {truckOptions.map((t) => (
            <option key={t.id} value={t.id}>{t.unit_number}</option>
          ))}
        </select>
      </div>
      <div className="w-52">
        <label htmlFor="filter_carrier_id" className={labelClass}>
          Carrier
          {carrierLocked && <span className="ml-1 font-normal text-muted-foreground">(Auto-selected from Truck)</span>}
        </label>
        <select id="filter_carrier_id" className={selectClass} value={displayCarrierId} disabled={carrierLocked} onChange={(e) => onCarrierChange(e.target.value)}>
          <option value="">All Carriers</option>
          {carriers.map((c) => (
            <option key={c.id} value={c.id}>{c.legal_name}</option>
          ))}
        </select>
      </div>
      {(truckId || manualCarrierId) && (
        <button type="button" onClick={onClear} className="h-8 rounded-sm px-3 text-[13px] font-medium text-muted-foreground hover:underline">Clear</button>
      )}
    </>
  );
}
