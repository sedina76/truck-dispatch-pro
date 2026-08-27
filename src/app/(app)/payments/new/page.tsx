import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { getBillingParty } from "@/lib/billing/party";
import { InvoicePicker, type InvoicePaymentCandidate } from "@/components/payments/invoice-picker";
import { recordPayment } from "../actions";

const PAYMENT_METHODS = [
  { value: "ach", label: "ACH" },
  { value: "wire", label: "Wire Transfer" },
  { value: "check", label: "Check" },
  { value: "credit_card", label: "Credit Card" },
  { value: "cash", label: "Cash" },
  { value: "factoring", label: "Factoring" },
  { value: "other", label: "Other" },
];

export default async function NewPaymentPage({
  searchParams,
}: {
  searchParams: Promise<{ invoice_id?: string; broker_id?: string; customer_id?: string; error?: string }>;
}) {
  const { invoice_id, broker_id, customer_id, error } = await searchParams;
  const supabase = await createClient();

  // Party preselected but no specific invoice yet (Broker/Customer profile
  // -> Record Payment, spec section 5): show ONLY that party's own
  // eligible invoices via the canonical get_ar_invoices() RPC -- the same
  // function A/R and Collections already use, so "eligible" means exactly
  // the same thing here as everywhere else. RLS on the underlying
  // invoices/brokers/customers tables means a cross-org id here simply
  // yields zero rows, never another organization's data.
  if (!invoice_id && (broker_id || customer_id)) {
    const { data: party } = broker_id
      ? await supabase.from("brokers").select("id, company_name").eq("id", broker_id).maybeSingle()
      : await supabase.from("customers").select("id, company_name").eq("id", customer_id!).maybeSingle();

    const { data: rows } = await supabase.rpc("get_ar_invoices", {
      p_broker_id: broker_id ?? null,
      p_customer_id: customer_id ?? null,
    });
    const outstanding = ((rows ?? []) as { id: string; invoice_number: string; load_number: string | null; balance_due: number; due_date: string | null }[]).filter(
      (r) => Number(r.balance_due) > 0
    );

    return (
      <DesktopPanel>
        <DesktopPanelHeader title={party ? `Record Payment -- ${party.company_name}` : "Record Payment"} />
        <DesktopPanelBody className="space-y-3">
          {!party ? (
            <p className="text-sm text-muted-foreground">That broker/customer could not be found.</p>
          ) : outstanding.length === 0 ? (
            <p className="text-sm text-muted-foreground">{party.company_name} has no outstanding invoices.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-[13px]">
                <thead>
                  <tr className="border-b border-desktop-border text-left text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                    <th className="py-1.5 pr-3">Invoice #</th>
                    <th className="py-1.5 pr-3">Load #</th>
                    <th className="py-1.5 pr-3 text-right">Balance Due</th>
                    <th className="py-1.5 pr-3">Due Date</th>
                    <th className="py-1.5"></th>
                  </tr>
                </thead>
                <tbody>
                  {outstanding.map((row) => (
                    <tr key={row.id} className="border-b border-desktop-border last:border-0">
                      <td className="py-1.5 pr-3 font-medium">{row.invoice_number}</td>
                      <td className="py-1.5 pr-3">{row.load_number ?? "--"}</td>
                      <td className="py-1.5 pr-3 text-right font-medium">
                        ${Number(row.balance_due).toLocaleString(undefined, { minimumFractionDigits: 2 })}
                      </td>
                      <td className="py-1.5 pr-3">{row.due_date ? new Date(row.due_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                      <td className="py-1.5 text-right">
                        <Link href={`/payments/new?invoice_id=${row.id}`} className="text-xs font-medium text-primary hover:underline">
                          Select
                        </Link>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </DesktopPanelBody>
      </DesktopPanel>
    );
  }

  // Invoice preselected (Invoice Detail / A/R / Collections / a party's
  // outstanding-invoices list above): the normal path. Locked to a
  // read-only summary + hidden field -- not a re-editable dropdown -- so
  // the user only ever fills in Amount/Date/Method/Reference/Notes.
  if (invoice_id) {
    const { data: invoice } = await supabase
      .from("invoices")
      .select(
        "id, invoice_number, load_id, broker_id, customer_id, bill_to_name, total_amount, amount_paid, balance_due, issue_date, due_date, status, " +
          "loads(load_number), brokers(company_name), customers(company_name)"
      )
      .eq("id", invoice_id)
      .maybeSingle();

    if (!invoice) {
      // RLS-scoped select: a cross-org (or nonexistent) invoice_id lands
      // here as "not found", never a leaked row.
      return (
        <DesktopPanel>
          <DesktopPanelBody>
            <p className="flex items-start gap-2 text-sm text-warning">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              That invoice could not be found.{" "}
              <Link href="/payments/new" className="ml-1 text-primary hover:underline">
                Choose an invoice
              </Link>
              .
            </p>
          </DesktopPanelBody>
        </DesktopPanel>
      );
    }

    const row = invoice as unknown as {
      id: string;
      invoice_number: string;
      broker_id: string | null;
      customer_id: string | null;
      bill_to_name: string;
      total_amount: number;
      amount_paid: number;
      balance_due: number;
      issue_date: string;
      due_date: string | null;
      status: string;
      loads: { load_number: string } | null;
      brokers: { company_name: string } | null;
      customers: { company_name: string } | null;
    };
    const party = getBillingParty(row);
    const partyName = party.type === "broker" ? row.brokers?.company_name : party.type === "customer" ? row.customers?.company_name : row.bill_to_name;
    const balance = Number(row.balance_due);
    const terms =
      row.issue_date && row.due_date
        ? `Net ${Math.round((new Date(row.due_date).getTime() - new Date(row.issue_date).getTime()) / 86400000)}`
        : "--";

    if (balance <= 0) {
      return (
        <DesktopPanel>
          <DesktopPanelBody>
            <p className="flex items-start gap-2 text-sm text-desktop-text">
              <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
              Invoice {row.invoice_number} has a $0 balance due -- there is nothing left to record a payment against.
            </p>
            <Link href={`/invoices/${row.id}`} className="mt-2 inline-block text-xs font-medium text-primary hover:underline">
              View invoice &rarr;
            </Link>
          </DesktopPanelBody>
        </DesktopPanel>
      );
    }

    return (
      <div className="space-y-3">
        <DesktopPanel>
          <DesktopPanelHeader
            title="Record Payment"
            actions={
              <Link
                href="/payments/new"
                className="rounded border border-desktop-header-text/30 px-2 py-0.5 text-[11px] text-desktop-header-text/90 hover:bg-desktop-header-text/10"
              >
                Change
              </Link>
            }
          />
          <DesktopPanelBody>
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px] sm:grid-cols-4">
              <Field label="Invoice" value={row.invoice_number} />
              <Field label="Load" value={row.loads?.load_number ?? "--"} />
              <Field label="Received From" value={partyName ?? "--"} />
              <Field label="Status" value={row.status.replace(/_/g, " ")} />
              <Field label="Invoice Total" value={`$${Number(row.total_amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}`} />
              <Field label="Previously Paid" value={`$${Number(row.amount_paid).toLocaleString(undefined, { minimumFractionDigits: 2 })}`} />
              <Field label="Balance Due" value={`$${balance.toLocaleString(undefined, { minimumFractionDigits: 2 })}`} strong />
              <Field label="Due Date" value={row.due_date ? new Date(row.due_date + "T00:00:00").toLocaleDateString() : "--"} />
              <Field label="Terms" value={terms} />
            </div>
          </DesktopPanelBody>
        </DesktopPanel>

        <FormCard
          title="Payment Details"
          description="Amount defaults to the full balance due -- reduce it for a partial payment."
          action={recordPayment}
          cancelHref={`/invoices/${row.id}`}
          submitLabel="Record Payment"
        >
          {error && (
            <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              <span>{error}</span>
            </div>
          )}
          <FormGrid>
            <input type="hidden" name="invoice_id" value={row.id} />
            <FormField
              label={`Payment Amount ($) -- max $${balance.toLocaleString(undefined, { minimumFractionDigits: 2 })}`}
              name="amount"
              type="number"
              step="0.01"
              defaultValue={balance}
              required
            />
            <FormField label="Payment Date" name="payment_date" type="date" defaultValue={new Date().toISOString().slice(0, 10)} required />
            <FormSelect label="Method" name="method" defaultValue="ach" options={PAYMENT_METHODS} />
            <FormField label="Reference / Confirmation #" name="reference_number" />
            <FormField label="Check #" name="check_number" />
            <FormField label="Bank Reference" name="bank_reference" />
            <FormTextarea label="Notes" name="notes" />
          </FormGrid>
        </FormCard>
      </div>
    );
  }

  // Fully manual fallback: no invoice/party preselected.
  //
  // Collectible-status repair: the previous "status <> void/paid" rule
  // still let draft and disputed invoices through -- both have a real
  // guard_payment_amount() gap of their own (that trigger only ever
  // excludes 'void', so a forged/direct request could record a payment
  // against a draft or disputed invoice, bypassing this picker entirely).
  // Narrowed to the exact four collectible statuses per the confirmed
  // business rule, matching migration 0113 (invoice_collectible_status_
  // guard.sql, authored but NOT applied)'s own authoritative allow-list
  // exactly -- this query and that trigger must never drift apart.
  //
  // Test/demo invoices are NOT filtered out by name pattern here -- doing
  // so was explicitly out of scope for this repair; if any exist among
  // eligible invoices they will appear like any other, and their cleanup
  // is a separate, deliberate decision.
  const { data: invoicesRaw } = await supabase
    .from("invoices")
    .select("id, invoice_number, bill_to_name, total_amount, balance_due, due_date, status, loads(load_number)")
    .in("status", ["sent", "viewed", "overdue", "partially_paid"])
    .gt("balance_due", 0)
    .order("due_date", { ascending: true, nullsFirst: false });

  const pickerInvoices: InvoicePaymentCandidate[] = (invoicesRaw ?? []).map((i) => ({
    id: i.id,
    invoiceNumber: i.invoice_number,
    billToName: i.bill_to_name ?? "",
    loadNumber: (i.loads as unknown as { load_number: string } | null)?.load_number ?? null,
    totalAmount: Number(i.total_amount),
    balanceDue: Number(i.balance_due),
    dueDate: i.due_date,
  }));

  return (
    <FormCard title="Record Payment" description="Log a payment received against an invoice." action={recordPayment} cancelHref="/payments" submitLabel="Record Payment">
      {error && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>{error}</span>
        </div>
      )}
      <FormGrid>
        {/* Selecting an invoice navigates to /payments/new?invoice_id=<id>
            -- the "invoice preselected" branch above -- rather than
            submitting invoice_id as part of THIS form at all, so there is
            no invoice_id field here to forge or leave stale. */}
        <div className="sm:col-span-2">
          <InvoicePicker invoices={pickerInvoices} />
        </div>
        <FormField label="Payment Date" name="payment_date" type="date" defaultValue={new Date().toISOString().slice(0, 10)} required />
        <FormField label="Amount ($)" name="amount" type="number" step="0.01" required />
        <FormSelect label="Method" name="method" defaultValue="ach" options={PAYMENT_METHODS} />
        <FormField label="Reference / Confirmation #" name="reference_number" />
        <FormField label="Check #" name="check_number" />
        <FormField label="Bank Reference" name="bank_reference" />
        <FormTextarea label="Notes" name="notes" />
      </FormGrid>
    </FormCard>
  );
}

function Field({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={strong ? "font-semibold text-primary" : "font-medium capitalize text-desktop-text"}>{value}</p>
    </div>
  );
}
