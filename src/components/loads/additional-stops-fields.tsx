"use client";

import { useEffect, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { AutoTimezoneSelect } from "@/components/loads/auto-timezone-select";

// Dynamic "+ Add Stop" list for extra pickups/deliveries beyond the main
// Pickup/Delivery sections (spec section 7). Plain uncontrolled inputs with
// array-indexed names (extra_stops[<key>][field]) inside the SAME native
// <form> the rest of the New Load page uses -- no client-side form state
// beyond "how many blocks and in what order," so nothing here can drop a
// value from the eventual FormData submit. Sequencing note (spec: "the
// dispatcher should be able to reorder stops if the schema can safely
// support it"): full drag-and-drop reordering was not built -- stop order
// is Pickup -> these additional stops in the order added -> Delivery,
// which stop_sequence records; see KNOWN LIMITATIONS in the final report.

type ExtraStop = { key: string; type: "pickup" | "delivery"; values?: Record<string, string> };

/** Event the "Fill from rate confirmation" box sends to add filled-in stops. */
export type ExtraStopsEvent = CustomEvent<{ stop_type: "pickup" | "delivery"; values: Record<string, string> }[]>;

const inputClass = "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const labelClass = "text-[12px] font-medium text-desktop-text";

let nextKey = 0;

export function AdditionalStopsFields({ defaultTimezone }: { defaultTimezone: string }) {
  const [stops, setStops] = useState<ExtraStop[]>([]);

  useEffect(() => {
    const onAdd = (e: Event) => {
      const list = (e as ExtraStopsEvent).detail ?? [];
      setStops((s) => [...s.filter((st) => !st.values), ...list.map((x) => ({ key: `extra-${nextKey++}`, type: x.stop_type, values: x.values }))]);
    };
    window.addEventListener("tdp:set-extra-stops", onAdd);
    return () => window.removeEventListener("tdp:set-extra-stops", onAdd);
  }, []);

  function addStop(type: "pickup" | "delivery") {
    setStops((s) => [...s, { key: `extra-${nextKey++}`, type }]);
  }
  function removeStop(key: string) {
    setStops((s) => s.filter((st) => st.key !== key));
  }

  return (
    <div className="space-y-3">
      {stops.length === 0 && <p className="text-[12.5px] text-desktop-text-muted">No additional stops. Use this for multi-stop loads with more than one pickup or delivery.</p>}

      {stops.map((stop, i) => (
        <div key={stop.key} className="rounded-sm border border-desktop-border bg-card p-3">
          <div className="mb-2 flex items-center justify-between">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-desktop-text-muted">
              Additional Stop {i + 1} -- <span className="capitalize">{stop.type}</span>
            </p>
            <button type="button" onClick={() => removeStop(stop.key)} className="flex items-center gap-1 text-[11px] font-medium text-danger hover:underline">
              <Trash2 className="size-3" /> Remove
            </button>
          </div>
          <input type="hidden" name={`extra_stops[${stop.key}][stop_type]`} value={stop.type} />
          <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2">
            <div className="space-y-1 sm:col-span-2">
              <label className={labelClass}>Facility / Company Name</label>
              <input name={`extra_stops[${stop.key}][facility_name]`} defaultValue={stop.values?.facility_name} className={inputClass} />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <label className={labelClass}>Address</label>
              <input name={`extra_stops[${stop.key}][address_line1]`} defaultValue={stop.values?.address_line1} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>City *</label>
              <input name={`extra_stops[${stop.key}][city]`} defaultValue={stop.values?.city} required className={inputClass} />
            </div>
            <div className="grid grid-cols-2 gap-2.5">
              <div className="space-y-1">
                <label className={labelClass}>State *</label>
                <input name={`extra_stops[${stop.key}][state]`} defaultValue={stop.values?.state} required maxLength={2} className={inputClass} />
              </div>
              <div className="space-y-1">
                <label className={labelClass}>ZIP</label>
                <input name={`extra_stops[${stop.key}][postal_code]`} defaultValue={stop.values?.postal_code} className={inputClass} />
              </div>
            </div>
            <div className="space-y-1">
              <label className={labelClass}>{stop.type === "pickup" ? "Pickup" : "Delivery"} Date *</label>
              <input type="date" name={`extra_stops[${stop.key}][date]`} defaultValue={stop.values?.date} required className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Appointment Time</label>
              <input type="time" name={`extra_stops[${stop.key}][time]`} defaultValue={stop.values?.time} className={inputClass} />
            </div>
            <AutoTimezoneSelect
              name={`extra_stops[${stop.key}][timezone]`}
              stateName={`extra_stops[${stop.key}][state]`}
              zipName={`extra_stops[${stop.key}][postal_code]`}
              defaultValue={stop.values?.timezone || defaultTimezone}
              selectClassName={inputClass}
              labelClassName={labelClass}
            />
            <div className="space-y-1">
              <label className={labelClass}>Reference #</label>
              <input name={`extra_stops[${stop.key}][reference_number]`} defaultValue={stop.values?.reference_number} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Contact Name</label>
              <input name={`extra_stops[${stop.key}][contact_name]`} defaultValue={stop.values?.contact_name} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Contact Phone</label>
              <input name={`extra_stops[${stop.key}][contact_phone]`} defaultValue={stop.values?.contact_phone} className={inputClass} />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <label className={labelClass}>Notes</label>
              <input name={`extra_stops[${stop.key}][notes]`} defaultValue={stop.values?.notes} className={inputClass} />
            </div>
          </div>
        </div>
      ))}

      <div className="flex gap-2">
        <button type="button" onClick={() => addStop("pickup")} className="flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border bg-desktop-panel px-2.5 text-[12px] font-medium hover:bg-desktop-muted">
          <Plus className="size-3.5" /> Add Pickup
        </button>
        <button type="button" onClick={() => addStop("delivery")} className="flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border bg-desktop-panel px-2.5 text-[12px] font-medium hover:bg-desktop-muted">
          <Plus className="size-3.5" /> Add Delivery
        </button>
      </div>
    </div>
  );
}
