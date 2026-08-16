import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PrintInvoiceButton } from "@/components/invoices/print-invoice-button";
import { AutoPrint } from "@/components/invoices/auto-print";

// Payment receipt. Deliberately OUTSIDE the (app) route group -- same
// reasoning as /invoices/[id]/pdf (src/app/invoices/[id]/pdf/page.tsx):
// a receipt meant to be printed/downloaded standalone has no business
// rendering inside the authenticated app shell (sidebar/nav chrome), and
// nesting it under (app) previously did exactly that.
//
// Company, receipt # (the payment_number), invoice #, load #,
// broker/customer, payment date/method/reference, amount received,
// remaining balance. Deliberately selects only these columns -- never SSN,
// CDL, medical, or any other driver HR data, none of which this query even
// has a path to (invoices/loads/organizations only).
export default async function PaymentReceiptPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ autoprint?: string }>;
}) {
  const { id } = await params;
  const { autoprint } = await searchParams;
  const supabase = await createClient();

  const { data: payment } = await supabase
    .from("payments")
    .select("id, payment_number, amount, method, reference_number, check_number, bank_reference, received_at, status, invoice_id")
    .eq("id", id)
    .single();
  if (!payment) notFound();

  const { data: invoice } = await supabase
    .from("invoices")
    .select("invoice_number, bill_to_name, balance_due, organization_id, load_id")
    .eq("id", payment.invoice_id)
    .single();
  if (!invoice) notFound();

  const [{ data: org }, { data: load }] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code")
      .eq("id", invoice.organization_id)
      .single(),
    invoice.load_id ? supabase.from("loads").select("load_number").eq("id", invoice.load_id).single() : Promise.resolve({ data: null }),
  ]);

  return (
    <div className="min-h-screen bg-muted/30 py-8 print:bg-white print:py-0">
      {autoprint === "1" && <AutoPrint />}
      <div className="mx-auto mb-4 flex max-w-xl justify-end px-4 print:hidden">
        <PrintInvoiceButton />
      </div>

      <div className="pdf-page mx-auto max-w-xl rounded-xl border border-border bg-white p-10 text-neutral-900 shadow-elevation-2 print:max-w-none">
        <div className="flex items-start justify-between border-b border-neutral-200 pb-6">
          <div>
            <h1 className="text-xl font-bold">{org?.name ?? "Your Company"}</h1>
            <div className="mt-1 space-y-0.5 text-xs text-neutral-500">
              {org?.address_line1 && <p>{org.address_line1}</p>}
              {(org?.city || org?.state || org?.postal_code) && (
                <p>{[org?.city, org?.state, org?.postal_code].filter(Boolean).join(", ")}</p>
              )}
              {org?.business_phone && <p>{org.business_phone}</p>}
              {org?.business_email && <p>{org.business_email}</p>}
              {(org?.mc_number || org?.dot_number) && (
                <p>
                  {org?.mc_number && `MC# ${org.mc_number}`}
                  {org?.mc_number && org?.dot_number && " -- "}
                  {org?.dot_number && `DOT# ${org.dot_number}`}
                </p>
              )}
            </div>
          </div>
          <div className="text-right">
            <p className="text-2xl font-bold tracking-tight text-neutral-800">RECEIPT</p>
            <p className="mt-1 text-sm font-medium">{payment.payment_number}</p>
            <p className="mt-2 text-xs text-neutral-500">{new Date(payment.received_at).toLocaleDateString()}</p>
            {payment.status === "voided" && (
              <p className="mt-1 text-xs font-semibold uppercase tracking-wide text-danger">VOIDED -- not valid</p>
            )}
          </div>
        </div>

        <div className="grid grid-cols-2 gap-6 border-b border-neutral-200 py-6">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Received From</p>
            <p className="mt-1 text-sm font-medium">{invoice.bill_to_name}</p>
          </div>
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Applied To</p>
            <div className="mt-1 space-y-0.5 text-xs text-neutral-600">
              <p>Invoice #: {invoice.invoice_number}</p>
              {load && <p>Load #: {load.load_number}</p>}
            </div>
          </div>
        </div>

        <table className="w-full py-6 text-sm">
          <tbody>
            <ReceiptRow label="Payment Date" value={new Date(payment.received_at).toLocaleDateString()} />
            <ReceiptRow label="Payment Method" value={String(payment.method).replace(/_/g, " ")} capitalize />
            {payment.reference_number && <ReceiptRow label="Reference / Confirmation #" value={payment.reference_number} />}
            {payment.check_number && <ReceiptRow label="Check #" value={payment.check_number} />}
            {payment.bank_reference && <ReceiptRow label="Bank Reference" value={payment.bank_reference} />}
          </tbody>
        </table>

        <div className="flex justify-end border-t border-neutral-200 pt-4">
          <div className="w-56 space-y-1.5 text-sm">
            <div className="flex justify-between border-t border-neutral-200 pt-1.5 text-base font-bold">
              <span>Amount Received</span>
              <span>${Number(payment.amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}</span>
            </div>
            <div className="flex justify-between text-xs text-neutral-500">
              <span>Remaining Balance</span>
              <span>${Number(invoice.balance_due).toLocaleString(undefined, { minimumFractionDigits: 2 })}</span>
            </div>
          </div>
        </div>

        <p className="mt-8 text-center text-[11px] text-neutral-400">Thank you for your payment.</p>
      </div>
    </div>
  );
}

function ReceiptRow({ label, value, capitalize }: { label: string; value: string; capitalize?: boolean }) {
  return (
    <tr className="border-b border-neutral-100">
      <td className="py-2 text-neutral-500">{label}</td>
      <td className={"py-2 text-right font-medium" + (capitalize ? " capitalize" : "")}>{value}</td>
    </tr>
  );
}
