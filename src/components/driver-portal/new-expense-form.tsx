"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { submitDriverExpense } from "@/app/driver-portal/actions";
import { DRIVER_SUBMITTABLE_CATEGORIES, DRIVER_FUEL_PAID_BY } from "@/lib/driver-portal/constants";

const CATEGORY_LABEL: Record<(typeof DRIVER_SUBMITTABLE_CATEGORIES)[number], string> = {
  lumper: "Lumper",
  fuel: "Fuel",
  tolls: "Toll",
  scale_ticket: "Scale Ticket",
  parking: "Parking",
  permit: "Permit",
  washout: "Washout",
  other: "Other",
};

const inputClass = "h-11 w-full rounded-xl border border-border bg-background px-3 text-sm outline-none focus-visible:border-primary";

export function NewExpenseForm({ loadNumber }: { loadNumber: string }) {
  const router = useRouter();
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [category, setCategory] = useState("");
  const isFuel = category === "fuel";

  async function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      const { expenseId, fuelLogId } = await submitDriverExpense(new FormData(e.currentTarget));
      router.push(fuelLogId ? `/driver-portal/expenses/fuel/${fuelLogId}` : `/driver-portal/expenses/${expenseId}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not submit expense.");
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <Field label="Load">
        <div className={`${inputClass} flex items-center bg-muted text-muted-foreground`}>{loadNumber}</div>
      </Field>

      <Field label="Category">
        <select name="category" required className={inputClass} value={category} onChange={(e) => setCategory(e.target.value)}>
          <option value="" disabled>
            Select category
          </option>
          {DRIVER_SUBMITTABLE_CATEGORIES.map((c) => (
            <option key={c} value={c}>
              {CATEGORY_LABEL[c]}
            </option>
          ))}
        </select>
      </Field>

      <Field label={isFuel ? "Total paid ($)" : "Amount ($)"}>
        <input name="amount" type="number" step="0.01" min="0.01" required inputMode="decimal" className={inputClass} placeholder="0.00" />
      </Field>

      {isFuel && (
        <>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Gallons">
              <input name="gallons" type="number" step="0.001" min="0.01" required inputMode="decimal" className={inputClass} placeholder="0.0" />
            </Field>
            <Field label="Price / gal (optional)">
              <input name="price_per_gallon" type="number" step="0.001" min="0" inputMode="decimal" className={inputClass} placeholder="0.000" />
            </Field>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Field label="State">
              <input name="state" type="text" maxLength={2} className={`${inputClass} uppercase`} placeholder="e.g. MN" />
            </Field>
            <Field label="Odometer (optional)">
              <input name="odometer_reading" type="number" min="0" inputMode="numeric" className={inputClass} placeholder="miles" />
            </Field>
          </div>
          <Field label="How did you pay?">
            <select name="paid_by" required className={inputClass} defaultValue="carrier">
              {DRIVER_FUEL_PAID_BY.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </Field>
        </>
      )}

      <Field label="Date">
        <input name="expense_date" type="date" required defaultValue={new Date().toISOString().slice(0, 10)} className={inputClass} />
      </Field>

      <Field label={isFuel ? "Fuel stop" : "Vendor"}>
        <input name="vendor_name" type="text" className={inputClass} placeholder="e.g. Pilot Flying J" />
      </Field>

      <Field label="Reference #">
        <input name="reference_number" type="text" className={inputClass} placeholder="Receipt/ticket number" />
      </Field>

      <Field label="Notes">
        <textarea name="notes" rows={3} className="w-full rounded-xl border border-border bg-background px-3 py-2 text-sm outline-none focus-visible:border-primary" />
      </Field>

      {error && <p className="text-xs text-danger">{error}</p>}

      <button
        type="submit"
        disabled={submitting}
        className="flex h-12 w-full items-center justify-center gap-2 rounded-xl bg-primary text-sm font-semibold text-primary-foreground disabled:opacity-60"
      >
        {submitting && <Loader2 className="size-4 animate-spin" />}
        {isFuel ? "Submit Fuel" : "Submit Expense"}
      </button>
      <p className="text-center text-[11px] text-muted-foreground">You&apos;ll be able to attach a receipt photo on the next screen.</p>
    </form>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <label className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</label>
      {children}
    </div>
  );
}
