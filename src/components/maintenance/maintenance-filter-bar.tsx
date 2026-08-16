"use client";

import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { useTransition } from "react";
import { resolveEquipmentCarrier, type EquipmentCarrierRef } from "@/lib/equipment/carrier-derivation";

export type EquipmentOption = { id: string; unit_number: string; carrier_id: string | null; carrier_name: string | null };
export type CarrierOption = { id: string; legal_name: string };

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:cursor-not-allowed disabled:bg-desktop-muted disabled:text-muted-foreground";
const labelClass = "text-[12px] font-medium text-desktop-text";

// ONE shared filter bar, rendered identically on all six Maintenance tabs
// (Maintenance / Preventive Maintenance / Repair History / Upcoming
// Service / Out of Service / Recoveries) -- spec SIX-TAB CONSISTENCY.
// Fully URL-driven: every value read here comes straight from
// useSearchParams(), and every change writes straight back via
// router.replace() -- there is no local mirror state to fall out of sync
// with the URL, so refresh/back/forward/shared links all behave
// correctly for free. Carrier derivation reuses resolveEquipmentCarrier()
// -- the exact same rule already live-verified for Log/Edit Maintenance
// -- never a second implementation.
export function MaintenanceFilterBar({
  view,
  trucks,
  trailers,
  carriers,
  showMaintenanceFilters,
}: {
  view: string;
  trucks: EquipmentOption[];
  trailers: EquipmentOption[];
  carriers: CarrierOption[];
  /** Status / Paid By / Recovery Status only apply to maintenance_records-
   * backed tabs -- Out of Service is an equipment-status query with a
   * different shape (spec: "adjusted only if invalid for that tab"). */
  showMaintenanceFilters: boolean;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [, startTransition] = useTransition();

  const truckId = searchParams.get("truck_id") ?? "";
  const trailerId = searchParams.get("trailer_id") ?? "";
  const manualCarrierId = searchParams.get("carrier_id") ?? "";
  const status = searchParams.get("status") ?? "";
  const paidBy = searchParams.get("paid_by") ?? "";
  const recoveryStatus = searchParams.get("recovery_status") ?? "";

  const selectedTruck: EquipmentCarrierRef = trucks.find((t) => t.id === truckId) ?? null;
  const selectedTrailer: EquipmentCarrierRef = trailers.find((t) => t.id === trailerId) ?? null;
  const derivation = resolveEquipmentCarrier(selectedTruck, selectedTrailer);

  // Carrier-first restriction (spec CARRIER -> EQUIPMENT) only applies
  // while NEITHER truck nor trailer is resolving a carrier of its own --
  // once one is, the equipment dropdowns must stay unrestricted so the
  // user can freely swap to a different carrier's unit (spec TRUCK SWAP:
  // "Change Truck to T-102 owned by Carrier B -> Carrier changes
  // automatically") or intentionally create the mismatch state the
  // warning below is meant to catch (spec CASE E).
  const restrictByCarrierId = derivation.kind === "manual" ? manualCarrierId || null : null;
  const truckOptions = restrictByCarrierId ? trucks.filter((t) => t.carrier_id === restrictByCarrierId) : trucks;
  const trailerOptions = restrictByCarrierId ? trailers.filter((t) => t.carrier_id === restrictByCarrierId) : trailers;

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
      // Once a truck is chosen, it (or the trailer) is authoritative --
      // never keep an independently-set carrier_id sitting alongside it
      // (spec CARRIER -> EQUIPMENT: "update Carrier to match the Truck
      // rather than keeping contradictory state"). The server also never
      // trusts a stale carrier_id here regardless (page.tsx), this just
      // keeps the URL itself clean.
      params.delete("carrier_id");
    });
  }
  function onTrailerChange(id: string) {
    updateParams((params) => {
      setOrDelete(params, "trailer_id", id);
      params.delete("carrier_id");
    });
  }
  function onCarrierChange(id: string) {
    updateParams((params) => setOrDelete(params, "carrier_id", id));
  }
  function onStatusChange(v: string) {
    updateParams((params) => setOrDelete(params, "status", v));
  }
  function onPaidByChange(v: string) {
    updateParams((params) => setOrDelete(params, "paid_by", v));
  }
  function onRecoveryStatusChange(v: string) {
    updateParams((params) => setOrDelete(params, "recovery_status", v));
  }
  function onClear() {
    startTransition(() => router.replace(`${pathname}?view=${view}`, { scroll: false }));
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-end gap-2 rounded-md border border-desktop-border bg-desktop-panel p-3">
        <div className="w-40">
          <label htmlFor="filter_truck_id" className={labelClass}>Truck</label>
          <select id="filter_truck_id" className={selectClass} value={truckId} onChange={(e) => onTruckChange(e.target.value)}>
            <option value="">All Trucks</option>
            {truckOptions.map((t) => (
              <option key={t.id} value={t.id}>{t.unit_number}</option>
            ))}
          </select>
        </div>
        <div className="w-40">
          <label htmlFor="filter_trailer_id" className={labelClass}>Trailer</label>
          <select id="filter_trailer_id" className={selectClass} value={trailerId} onChange={(e) => onTrailerChange(e.target.value)}>
            <option value="">All Trailers</option>
            {trailerOptions.map((t) => (
              <option key={t.id} value={t.id}>{t.unit_number}</option>
            ))}
          </select>
        </div>
        <div className="w-52">
          <label htmlFor="filter_carrier_id" className={labelClass}>
            Carrier
            {carrierLocked && <span className="ml-1 font-normal text-muted-foreground">(Auto-selected from {derivation.kind === "resolved" ? (derivation.source === "truck" ? "Truck" : "Trailer") : ""}{derivation.kind === "resolved" && derivation.unitNumber ? ` ${derivation.unitNumber}` : ""})</span>}
          </label>
          <select
            id="filter_carrier_id"
            className={selectClass}
            value={displayCarrierId}
            disabled={carrierLocked}
            onChange={(e) => onCarrierChange(e.target.value)}
          >
            <option value="">All Carriers</option>
            {carriers.map((c) => (
              <option key={c.id} value={c.id}>{c.legal_name}</option>
            ))}
          </select>
        </div>
        {showMaintenanceFilters && (
          <>
            <div className="w-36">
              <label htmlFor="filter_status" className={labelClass}>Status</label>
              <select id="filter_status" className={selectClass} value={status} disabled={view === "history"} onChange={(e) => onStatusChange(e.target.value)}>
                <option value="">{view === "history" ? "Completed" : "All Statuses"}</option>
                <option value="open">Open</option>
                <option value="completed">Completed</option>
                <option value="cancelled">Cancelled</option>
              </select>
            </div>
            <div className="w-44">
              <label htmlFor="filter_paid_by" className={labelClass}>Paid By</label>
              <select id="filter_paid_by" className={selectClass} value={paidBy} onChange={(e) => onPaidByChange(e.target.value)}>
                <option value="">All</option>
                <option value="dispatch_company">Dispatch Company</option>
                <option value="carrier">Carrier / Owner-Operator</option>
                <option value="driver">Driver</option>
                <option value="other">Other</option>
              </select>
            </div>
            <div className="w-44">
              <label htmlFor="filter_recovery_status" className={labelClass}>Recovery Status</label>
              <select id="filter_recovery_status" className={selectClass} value={recoveryStatus} onChange={(e) => onRecoveryStatusChange(e.target.value)}>
                <option value="">{view === "recoveries" ? "All Recovery Statuses" : "All"}</option>
                <option value="not_applicable">Not Applicable</option>
                <option value="pending">Pending</option>
                <option value="partially_recovered">Partially Recovered</option>
                <option value="recovered">Recovered</option>
              </select>
            </div>
          </>
        )}
        <button type="button" onClick={onClear} className="h-8 rounded-sm px-3 text-[13px] font-medium text-muted-foreground hover:underline">Clear</button>
      </div>
      {derivation.kind === "mismatch" && (
        <div className="rounded-sm border border-desktop-danger/40 bg-desktop-danger/10 px-3 py-2 text-[12.5px] text-desktop-danger">
          <span className="font-medium">Truck/Trailer carrier mismatch:</span> the selected truck belongs to {derivation.truckCarrierName ?? "an unassigned carrier"} and the selected trailer belongs to {derivation.trailerCarrierName ?? "an unassigned carrier"}. Change one selection to a matching carrier -- results are not shown for a contradictory combination.
        </div>
      )}
    </div>
  );
}
