import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { updateAdvance, markAdvanceReimbursed, markAdvanceWaived } from "../actions";

const EXPENSE_TYPES = ["fuel", "lumper", "toll", "parking", "scale", "repair", "driver_advance", "hotel", "other"];

export default async function AdvanceDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: advance }, { data: carriers }, { data: drivers }, { data: trucks }, { data: loads }] =
    await Promise.all([
      supabase
        .from("dispatch_advances")
        .select("*, invoices!deducted_invoice_id(invoice_number), settlements!deducted_settlement_id(settlement_number)")
        .eq("id", id)
        .single(),
      supabase.from("carriers").select("id, legal_name").order("legal_name"),
      supabase.from("drivers").select("id, first_name, last_name").order("last_name"),
      supabase.from("trucks").select("id, unit_number").order("unit_number"),
      supabase.from("loads").select("id, load_number").order("load_number"),
    ]);
  if (!advance) notFound();

  const deductedInvoice = (advance as unknown as { invoices: { invoice_number: string } | null }).invoices;
  const deductedSettlement = (advance as unknown as { settlements: { settlement_number: string } | null }).settlements;

  return (
    <div className="space-y-6">
      {advance.status === "deducted" && (
        <div className="rounded-xl border border-success/30 bg-success/5 px-4 py-3 text-sm">
          This advance was deducted{" "}
          {deductedSettlement && (
            <>
              from settlement{" "}
              <Link href={`/settlements/${advance.deducted_settlement_id}`} className="font-medium text-primary hover:underline">
                {deductedSettlement.settlement_number}
              </Link>
            </>
          )}
          {deductedInvoice && (
            <>
              from invoice{" "}
              <Link href={`/invoices/${advance.deducted_invoice_id}`} className="font-medium text-primary hover:underline">
                {deductedInvoice.invoice_number}
              </Link>
            </>
          )}
          .
        </div>
      )}

      {advance.status === "pending" && (
        <div className="flex items-center justify-between rounded-xl border border-warning/30 bg-warning/5 px-4 py-3">
          <div className="flex items-center gap-2 text-sm">
            <StatusBadge status="pending" />
            <span>Not yet recouped. Deduct it from the carrier&apos;s next settlement, or resolve it manually.</span>
          </div>
          <div className="flex items-center gap-2">
            <form action={markAdvanceReimbursed.bind(null, id)}>
              <Button type="submit" variant="ghost" size="sm">
                Mark Reimbursed
              </Button>
            </form>
            <form action={markAdvanceWaived.bind(null, id)}>
              <Button type="submit" variant="ghost" size="sm">
                Waive
              </Button>
            </form>
          </div>
        </div>
      )}

      <FormCard
        title={`Advance -- ${advance.expense_type.replace(/_/g, " ")}`}
        description="Advance details. Changes save immediately."
        action={updateAdvance.bind(null, id)}
        cancelHref="/advances"
        deleteAction={deleteRecord.bind(null, "dispatch_advances", id, "/advances")}
      >
        <FormGrid>
          <FormSelect
            label="Carrier"
            name="carrier_id"
            required
            defaultValue={advance.carrier_id}
            options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))}
          />
          <FormSelect
            label="Expense type"
            name="expense_type"
            required
            defaultValue={advance.expense_type}
            options={EXPENSE_TYPES.map((t) => ({ value: t, label: t.replace(/_/g, " ") }))}
          />
          <FormSelect
            label="Driver"
            name="driver_id"
            defaultValue={advance.driver_id}
            options={(drivers ?? []).map((d) => ({ value: d.id, label: `${d.first_name} ${d.last_name}` }))}
          />
          <FormSelect
            label="Truck"
            name="truck_id"
            defaultValue={advance.truck_id}
            options={(trucks ?? []).map((t) => ({ value: t.id, label: t.unit_number }))}
          />
          <FormSelect
            label="Load"
            name="load_id"
            defaultValue={advance.load_id}
            options={(loads ?? []).map((l) => ({ value: l.id, label: l.load_number }))}
          />
          <FormField label="Amount ($)" name="amount" type="number" step="0.01" defaultValue={advance.amount} required />
          <FormField label="Paid date" name="paid_date" type="date" defaultValue={advance.paid_date} required />
          <FormSelect
            label="Payment method"
            name="payment_method"
            defaultValue={advance.payment_method}
            options={[
              { value: "ach", label: "ACH" },
              { value: "wire", label: "Wire" },
              { value: "check", label: "Check" },
              { value: "credit_card", label: "Credit Card" },
              { value: "cash", label: "Cash" },
              { value: "other", label: "Other" },
            ]}
          />
          <FormField label="Receipt URL" name="receipt_url" defaultValue={advance.receipt_url} />
          <FormTextarea label="Description" name="description" defaultValue={advance.description} />
          <FormTextarea label="Notes" name="notes" defaultValue={advance.notes} />
        </FormGrid>
      </FormCard>
    </div>
  );
}
