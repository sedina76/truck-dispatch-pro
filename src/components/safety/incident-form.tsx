"use client";

import Link from "next/link";
import { useActionState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { INCIDENT_TYPES, INCIDENT_TYPE_LABEL } from "@/lib/safety/incidents";
import type { SafetyActionState } from "@/app/(app)/safety/actions";

type Option = { value: string; label: string };

export type IncidentDefaults = {
  incident_type?: string | null;
  occurred_on?: string | null;
  location?: string | null;
  driver_id?: string | null;
  truck_id?: string | null;
  load_id?: string | null;
  description?: string | null;
  cost?: number | string | null;
  status?: string | null;
};

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";

function Field({ label, htmlFor, required, children, wide }: { label: string; htmlFor: string; required?: boolean; children: React.ReactNode; wide?: boolean }) {
  return (
    <div className={`min-w-0 space-y-1 ${wide ? "sm:col-span-2" : ""}`}>
      <label htmlFor={htmlFor} className="text-[12px] font-medium text-desktop-text">
        {label}
        {required && <span className="text-danger"> *</span>}
      </label>
      {children}
    </div>
  );
}

function OptionalSelect({ name, options, defaultValue, none }: { name: string; options: Option[]; defaultValue?: string | null; none: string }) {
  return (
    <select id={name} name={name} defaultValue={defaultValue ?? ""} className={selectClass}>
      <option value="">{none}</option>
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

export function IncidentForm({
  action,
  drivers,
  trucks,
  loads,
  defaults = {},
  today,
  submitLabel,
  cancelHref,
  showStatus = false,
}: {
  action: (prev: SafetyActionState, formData: FormData) => Promise<SafetyActionState>;
  drivers: Option[];
  trucks: Option[];
  loads: Option[];
  defaults?: IncidentDefaults;
  today: string;
  submitLabel: string;
  cancelHref: string;
  showStatus?: boolean;
}) {
  const [state, formAction, pending] = useActionState(action, { error: null });
  return (
    <form action={formAction} className="space-y-4" data-testid="incident-form">
      {state.error && (
        <p role="alert" className="rounded-sm border border-danger/40 bg-danger/5 px-3 py-2 text-[12.5px] text-danger">
          {state.error}
        </p>
      )}
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="What happened" htmlFor="incident_type" required>
          <select id="incident_type" name="incident_type" required defaultValue={defaults.incident_type ?? ""} className={selectClass}>
            <option value="" disabled>
              Select...
            </option>
            {INCIDENT_TYPES.map((t) => (
              <option key={t} value={t}>
                {INCIDENT_TYPE_LABEL[t]}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Date" htmlFor="occurred_on" required>
          <Input id="occurred_on" name="occurred_on" type="date" required max={today} defaultValue={defaults.occurred_on ?? today} />
        </Field>
        <Field label="Place" htmlFor="location" wide>
          <Input id="location" name="location" maxLength={300} placeholder="City, state, highway / mile marker, or facility" defaultValue={defaults.location ?? ""} />
        </Field>
        <Field label="Driver" htmlFor="driver_id">
          <OptionalSelect name="driver_id" options={drivers} defaultValue={defaults.driver_id} none="No driver" />
        </Field>
        <Field label="Truck" htmlFor="truck_id">
          <OptionalSelect name="truck_id" options={trucks} defaultValue={defaults.truck_id} none="No truck" />
        </Field>
        <Field label="Load (optional)" htmlFor="load_id">
          <OptionalSelect name="load_id" options={loads} defaultValue={defaults.load_id} none="No load" />
        </Field>
        <Field label="Cost ($)" htmlFor="cost">
          <Input id="cost" name="cost" type="number" min="0" step="0.01" inputMode="decimal" placeholder="0.00" defaultValue={defaults.cost == null ? "" : String(defaults.cost)} />
        </Field>
        {showStatus && (
          <Field label="Status" htmlFor="status">
            <select id="status" name="status" defaultValue={defaults.status ?? "open"} className={selectClass}>
              <option value="open">Open</option>
              <option value="closed">Closed</option>
            </select>
          </Field>
        )}
        <Field label="What happened (details)" htmlFor="description" wide>
          <textarea
            id="description"
            name="description"
            rows={4}
            maxLength={5000}
            defaultValue={defaults.description ?? ""}
            placeholder="Short account: what happened, who was involved, police report or ticket number, claim number, violation codes..."
            className="w-full rounded-sm border border-desktop-border bg-card px-2.5 py-2 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
          />
        </Field>
      </div>
      <p className="text-[11.5px] text-muted-foreground">Cost: fines, repair or damage amount, claim paid -- whatever this incident cost. Leave blank if none.</p>
      <div className="flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
        <Link href={cancelHref} className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
          Cancel
        </Link>
        {state.saved && !pending && <span className="text-[12px] text-desktop-success" role="status">Saved.</span>}
        <Button type="submit" disabled={pending}>
          {pending ? "Saving..." : submitLabel}
        </Button>
      </div>
    </form>
  );
}
