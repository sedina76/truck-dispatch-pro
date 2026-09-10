import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { createAdvance } from "../actions";

const EXPENSE_TYPES = ["fuel", "lumper", "toll", "parking", "scale", "repair", "driver_advance", "hotel", "other"];

export default async function NewAdvancePage({
  searchParams,
}: {
  searchParams: Promise<{ carrier_id?: string; dispatch_id?: string; load_id?: string }>;
}) {
  const { carrier_id, dispatch_id, load_id } = await searchParams;
  const supabase = await createClient();
  const [{ data: carriers }, { data: drivers }, { data: trucks }, { data: loads }, { data: dispatches }] =
    await Promise.all([
      supabase.from("carriers").select("id, legal_name").order("legal_name"),
      supabase.from("drivers").select("id, first_name, last_name").order("last_name"),
      supabase.from("trucks").select("id, unit_number").order("unit_number"),
      supabase.from("loads").select("id, load_number").order("load_number"),
      supabase.from("dispatches").select("id, loads:loads!dispatches_load_id_fkey(load_number)").order("dispatched_at", { ascending: false }),
    ]);

  return (
    <FormCard
      title="Add Advance"
      description="Record an expense the dispatch company paid upfront on a carrier's behalf."
      action={createAdvance}
      cancelHref="/advances"
      submitLabel="Add Advance"
    >
      <FormGrid>
        <FormSelect
          label="Carrier"
          name="carrier_id"
          required
          defaultValue={carrier_id}
          options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
        />
        <FormSelect
          label="Expense type"
          name="expense_type"
          required
          options={EXPENSE_TYPES.map((t) => ({ value: t, label: t.replace(/_/g, " ") }))}
        />
        <FormSelect
          label="Driver (optional)"
          name="driver_id"
          options={(drivers ?? []).map((d) => ({ value: d.id, label: `${d.first_name} ${d.last_name}` }))}
        />
        <FormSelect
          label="Truck (optional)"
          name="truck_id"
          options={(trucks ?? []).map((t) => ({ value: t.id, label: t.unit_number }))}
        />
        <FormSelect
          label="Load (optional)"
          name="load_id"
          defaultValue={load_id}
          options={(loads ?? []).map((l) => ({ value: l.id, label: l.load_number }))}
        />
        <FormSelect
          label="Dispatch (optional)"
          name="dispatch_id"
          defaultValue={dispatch_id}
          options={(dispatches ?? []).map((d) => ({
            value: d.id,
            label: (d as unknown as { loads: { load_number: string } | null }).loads?.load_number ?? d.id.slice(0, 8),
          }))}
        />
        <FormField label="Amount ($)" name="amount" type="number" step="0.01" required />
        <FormField label="Paid date" name="paid_date" type="date" required defaultValue={new Date().toISOString().slice(0, 10)} />
        <FormSelect
          label="Payment method"
          name="payment_method"
          options={[
            { value: "ach", label: "ACH" },
            { value: "wire", label: "Wire" },
            { value: "check", label: "Check" },
            { value: "credit_card", label: "Credit Card" },
            { value: "cash", label: "Cash" },
            { value: "other", label: "Other" },
          ]}
        />
        <FormField label="Receipt URL" name="receipt_url" placeholder="https://..." />
        <FormTextarea label="Description" name="description" />
        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}
