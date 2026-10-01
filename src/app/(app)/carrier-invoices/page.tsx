import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

// Proposal 0157 (D-57): carrier invoices of the caller's organization (RLS-scoped). Carrier invoices are a different table from the LEGACY `invoices`.
export default async function CarrierInvoicesPage() {
  const supabase = await createClient();
  const { data: invoices } = await supabase
    .from("carrier_invoices")
    .select("id, invoice_number, invoice_document_type, issuance_status, payment_status, currency, total_amount, created_at")
    .order("created_at", { ascending: false })
    .limit(100);
  return (
    <div className="mx-auto max-w-4xl space-y-4 p-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-semibold">Carrier invoices</h1>
        <Link href="/carrier-invoices/new" className="rounded-md border px-3 py-1.5 text-sm font-medium">
          New carrier invoice
        </Link>
      </div>
      <ul className="divide-y text-sm">
        {(invoices ?? []).map((i) => (
          <li key={i.id} className="flex items-center justify-between py-2">
            <Link href={`/carrier-invoices/${i.id}`} className="underline">
              {i.invoice_number ?? "(draft)"}
            </Link>
            <span className="text-muted-foreground">
              {String(i.invoice_document_type)} -- {String(i.issuance_status)} / {String(i.payment_status)}
            </span>
            <span>
              {String(i.currency)} {Number(i.total_amount).toFixed(2)}
            </span>
          </li>
        ))}
      </ul>
      {(invoices ?? []).length === 0 ? <p className="text-sm text-muted-foreground">No carrier invoices yet.</p> : null}
    </div>
  );
}
