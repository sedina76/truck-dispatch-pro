"use client";

import { useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { COMMON_TIMEZONES } from "@/lib/timezone/iana";

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

type ExtraStop = { key: string; type: "pickup" | "delivery" };

const inputClass = "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const labelClass = "text-[12px] font-medium text-desktop-text";

let nextKey = 0;

export function AdditionalStopsFields({ defaultTimezone }: { defaultTimezone: string }) {
  const [stops, setStops] = useState<ExtraStop[]>([]);

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
              <input name={`extra_stops[${stop.key}][facility_name]`} className={inputClass} />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <label className={labelClass}>Address</label>
              <input name={`extra_stops[${stop.key}][address_line1]`} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>City *</label>
              <input name={`extra_stops[${stop.key}][city]`} required className={inputClass} />
            </div>
            <div className="grid grid-cols-2 gap-2.5">
              <div className="space-y-1">
                <label className={labelClass}>State *</label>
                <input name={`extra_stops[${stop.key}][state]`} required maxLength={2} className={inputClass} />
              </div>
              <div className="space-y-1">
                <label className={labelClass}>ZIP</label>
                <input name={`extra_stops[${stop.key}][postal_code]`} className={inputClass} />
              </div>
            </div>
            <div className="space-y-1">
              <label className={labelClass}>{stop.type === "pickup" ? "Pickup" : "Delivery"} Date *</label>
              <input type="date" name={`extra_stops[${stop.key}][date]`} required className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Appointment Time</label>
              <input type="time" name={`extra_stops[${stop.key}][time]`} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Timezone</label>
              <select name={`extra_stops[${stop.key}][timezone]`} defaultValue={defaultTimezone} className={inputClass}>
                {COMMON_TIMEZONES.map((tz) => (
                  <option key={tz.value} value={tz.value}>{tz.label}</option>
                ))}
              </select>
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Reference #</label>
              <input name={`extra_stops[${stop.key}][reference_number]`} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Contact Name</label>
              <input name={`extra_stops[${stop.key}][contact_name]`} className={inputClass} />
            </div>
            <div className="space-y-1">
              <label className={labelClass}>Contact Phone</label>
              <input name={`extra_stops[${stop.key}][contact_phone]`} className={inputClass} />
            </div>
            <div className="space-y-1 sm:col-span-2">
              <label className={labelClass}>Notes</label>
              <input name={`extra_stops[${stop.key}][notes]`} className={inputClass} />
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
