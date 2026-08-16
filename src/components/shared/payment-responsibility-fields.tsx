"use client";

import { useState } from "react";

export type DriverOption = { id: string; carrier_id: string; first_name: string; last_name: string };

const selectClass =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20";
const inputClass = selectClass;
const labelClass = "text-[12px] font-medium text-desktop-text";

// PAYMENT & RESPONSIBILITY -- shared, verbatim, across every module that
// distinguishes "who paid" from "who ultimately owes for it": Maintenance
// (0050, live-verified) and Fuel Logs (0051). Originally lived in
// maintenance-form-fields.tsx; moved here once Fuel needed the exact same
// section rather than a second copy of it (spec, both modules: "Do not
// duplicate... logic"). Nothing about this component is maintenance- or
// fuel-specific -- the field names (paid_by/recovery_type/
// recoverable_amount/responsible_driver_id) and the "cost"/"amount"
// language below are the only per-caller variable, via `amountLabel`/
// `amountCapLabel`.
//
// Deliberately self-contained -- Responsible Driver lists every active
// driver org-wide (not filtered to the selected equipment's carrier)
// specifically so this section never needs to know what equipment was
// selected above it, and so staff's choice is always a real, explicit
// selection rather than anything derived/pre-filtered from ownership
// (spec: "Ownership may influence defaults, but staff makes the final
// decision" / "Never automatically charge Driver 1/Driver 2/split 50-50").
export function PaymentResponsibilityFields({
  drivers,
  defaultPaidBy,
  defaultRecoveryType,
  defaultRecoverableAmount,
  defaultResponsibleDriverId,
  formId,
  disabled,
  amountCapLabel = "the cost",
}: {
  drivers: DriverOption[];
  defaultPaidBy?: string;
  defaultRecoveryType?: string;
  defaultRecoverableAmount?: number | null;
  defaultResponsibleDriverId?: string | null;
  /** Associates every field with a <form> this component isn't a DOM
   * descendant of (HTML5 form="..." attribute) -- used on Detail pages,
   * where Payment & Responsibility lives in its own collapsible section,
   * separate from the actual <form> wrapping the record's other fields,
   * so the two sections submit together as one update without nesting a
   * second <form> inside the first. */
  formId?: string;
  /** Once an expense/recovery already exists the server-side action
   * silently ignores changes to these fields (actions.ts) -- disabling
   * them here avoids the confusing appearance of an edit that won't apply. */
  disabled?: boolean;
  /** What the Recoverable Amount cap is described as -- "the repair cost"
   * (Maintenance) vs. "the fuel purchase total" (Fuel). */
  amountCapLabel?: string;
}) {
  const [recoveryType, setRecoveryType] = useState(defaultRecoveryType ?? "none");

  const needsRecoverableAmount = recoveryType === "carrier_settlement" || recoveryType === "driver_settlement";
  const needsResponsibleDriver = recoveryType === "driver_settlement";

  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <div className="space-y-1">
        <label htmlFor="paid_by" className={labelClass}>Paid By</label>
        <select id="paid_by" name="paid_by" form={formId} disabled={disabled} defaultValue={defaultPaidBy ?? "dispatch_company"} className={selectClass}>
          <option value="dispatch_company">Dispatch Company</option>
          <option value="carrier">Carrier / Owner-Operator</option>
          <option value="driver">Driver</option>
          <option value="other">Other</option>
        </select>
      </div>
      <div className="space-y-1">
        <label htmlFor="recovery_type" className={labelClass}>Recovery</label>
        <select id="recovery_type" name="recovery_type" form={formId} disabled={disabled} value={recoveryType} onChange={(e) => setRecoveryType(e.target.value)} className={selectClass}>
          <option value="none">Company Expense -- No Recovery</option>
          <option value="carrier_settlement">Recover From Carrier Settlement</option>
          <option value="driver_settlement">Recover From Driver Settlement</option>
          <option value="carrier_direct">Paid Directly By Carrier -- No Company Expense</option>
          <option value="driver_direct">Paid Directly By Driver -- No Company Expense</option>
        </select>
      </div>

      {needsRecoverableAmount && (
        <div className="space-y-1">
          <label className={labelClass}>Recoverable Amount ($)</label>
          <input name="recoverable_amount" form={formId} disabled={disabled} type="number" step="0.01" min="0" defaultValue={defaultRecoverableAmount ?? ""} className={inputClass} />
          <p className="text-[11px] text-desktop-text-muted">Cannot exceed {amountCapLabel} -- enforced when you save.</p>
        </div>
      )}

      {needsResponsibleDriver && (
        <div className="space-y-1">
          <label htmlFor="responsible_driver_id" className={labelClass}>
            Responsible Driver <span className="text-danger">*</span>
          </label>
          <select id="responsible_driver_id" name="responsible_driver_id" form={formId} disabled={disabled} required defaultValue={defaultResponsibleDriverId ?? ""} className={selectClass}>
            <option value="" disabled>Select...</option>
            {drivers.map((d) => (
              <option key={d.id} value={d.id}>{d.first_name} {d.last_name}</option>
            ))}
          </select>
          <p className="text-[11px] text-desktop-text-muted">
            Staff must explicitly choose who is responsible -- never auto-selected from the dispatch, and never split automatically between team drivers.
          </p>
        </div>
      )}
    </div>
  );
}
