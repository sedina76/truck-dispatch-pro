import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PrintInvoiceButton } from "@/components/invoices/print-invoice-button";
import { computePodStatus, POD_STATUS_LABEL } from "@/lib/documents/pod-status";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { formatStopDateTime } from "@/lib/timezone/format";
import { resolveStopTimezone } from "@/lib/timezone/resolve";
import { requireRole, FINANCIAL_ROLES } from "@/lib/auth/require-role";

type LoadStop = {
  stop_type: "pickup" | "delivery";
  facility_name: string | null;
  city: string | null;
  state: string | null;
  scheduled_at: string | null;
  timezone: string | null;
};

export default async function InvoicePdfPage({ params }: { params: Promise<{ id: string }> }) {
  // Phase 2G.7 finding: this route lives outside (app) (see header
  // reasoning in payments/[id]/receipt for why) and was therefore NOT
  // covered by the invoices/layout.tsx guard added in Phase 2G.6 -- any
  // authenticated staff session, any role, could load a full invoice PDF
  // (rate, totals, balance) directly. Guarded here explicitly, the same
  // FINANCIAL_ROLES tier as every other invoice surface.
  await requireRole(FINANCIAL_ROLES);

  const { id } = await params;
  const supabase = await createClient();

  const { data: invoice } = await supabase.from("invoices").select("*").eq("id", id).single();
  if (!invoice) notFound();

  const [{ data: org }, { data: lineItems }, loadRes, dispatchRes] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code, timezone")
      .eq("id", invoice.organization_id)
      .single(),
    supabase.from("invoice_line_items").select("*").eq("invoice_id", id).order("sort_order"),
    invoice.load_id
      ? supabase
          .from("loads")
          .select("load_number, commodity, equipment_type, total_miles, rate_confirmation_number, load_stops(stop_type, facility_name, city, state, scheduled_at, timezone)")
          .eq("id", invoice.load_id)
          .single()
      : Promise.resolve({ data: null }),
    // Never select driver PII (ssn_encrypted etc.) here -- name only, this
    // is a document a customer/broker could conceivably see.
    invoice.dispatch_id
      ? supabase
          .from("dispatches")
          .select("drivers(first_name, last_name), trucks(unit_number), trailers(unit_number)")
          .eq("id", invoice.dispatch_id)
          .single()
      : Promise.resolve({ data: null }),
  ]);

  // Supporting documents note: status only, per the request -- the POD
  // itself is never embedded in this PDF, just whether it's on file. Same
  // canonical "latest document" helper used everywhere else this is
  // computed -- see src/lib/documents/latest-document.ts.
  let podStatus: ReturnType<typeof computePodStatus> = "missing";
  let rateConOnFile = false;
  if (invoice.load_id) {
    const [pod, rateConDoc] = await Promise.all([
      getLatestDocument(supabase, "load", invoice.load_id, "pod"),
      getLatestDocument(supabase, "load", invoice.load_id, "rate_confirmation"),
    ]);
    podStatus = computePodStatus(pod);
    rateConOnFile = rateConDoc !== null;
  }

  const load = loadRes.data as unknown as
    | {
        load_number: string;
        commodity: string | null;
        equipment_type: string | null;
        total_miles: number | null;
        rate_confirmation_number: string | null;
        load_stops: LoadStop[];
      }
    | null;
  const dispatchInfo = dispatchRes.data as unknown as
    | { drivers: { first_name: string; last_name: string } | null; trucks: { unit_number: string } | null; trailers: { unit_number: string } | null }
    | null;

  const pickup = load?.load_stops.find((s) => s.stop_type === "pickup") ?? null;
  const delivery = load?.load_stops.find((s) => s.stop_type === "delivery") ?? null;
  // Stop's own timezone first, falling back to the org's -- never the
  // render-environment's local timezone (see src/lib/timezone/resolve.ts).
  const pickupTz = resolveStopTimezone(pickup?.timezone ?? null, org?.timezone ?? null).timezone;
  const deliveryTz = resolveStopTimezone(delivery?.timezone ?? null, org?.timezone ?? null).timezone;

  return (
    <div className="min-h-screen bg-muted/30 py-8 print:bg-white print:py-0">
      <div className="mx-auto mb-4 flex max-w-3xl justify-end px-4 print:hidden">
        <PrintInvoiceButton />
      </div>

      <div className="pdf-page mx-auto max-w-3xl rounded-xl border border-border bg-white p-10 text-neutral-900 shadow-elevation-2 print:max-w-none">
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
            <p className="text-2xl font-bold tracking-tight text-neutral-800">INVOICE</p>
            <p className="mt-1 text-sm font-medium">{invoice.invoice_number}</p>
            <p className="mt-2 text-xs text-neutral-500">Issued {new Date(invoice.issue_date).toLocaleDateString()}</p>
            {invoice.due_date && <p className="text-xs text-neutral-500">Due {new Date(invoice.due_date).toLocaleDateString()}</p>}
            <p className="mt-1 text-xs font-medium uppercase tracking-wide text-neutral-500">{invoice.status}</p>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-6 border-b border-neutral-200 py-6">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Bill To</p>
            <p className="mt-1 text-sm font-medium">{invoice.bill_to_name}</p>
            {invoice.bill_to_email && <p className="text-xs text-neutral-500">{invoice.bill_to_email}</p>}
            {invoice.bill_to_address && <p className="text-xs text-neutral-500">{invoice.bill_to_address}</p>}
          </div>
          {load && (
            <div>
              <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Load Details</p>
              <div className="mt-1 space-y-0.5 text-xs text-neutral-600">
                <p>Load #: {load.load_number}</p>
                {load.equipment_type && <p>Equipment: {load.equipment_type.replace(/_/g, " ")}</p>}
                {load.total_miles && <p>Miles: {Number(load.total_miles).toLocaleString()}</p>}
                {load.rate_confirmation_number && <p>Rate Con #: {load.rate_confirmation_number}</p>}
                {dispatchInfo?.drivers && (
                  <p>
                    Driver: {dispatchInfo.drivers.first_name} {dispatchInfo.drivers.last_name}
                  </p>
                )}
                {dispatchInfo?.trucks && <p>Truck: {dispatchInfo.trucks.unit_number}</p>}
                {dispatchInfo?.trailers && <p>Trailer: {dispatchInfo.trailers.unit_number}</p>}
                {pickup && (
                  <p>
                    Pickup: {[pickup.facility_name, pickup.city, pickup.state].filter(Boolean).join(", ") || "--"}
                    {pickup.scheduled_at && ` (${formatStopDateTime(pickup.scheduled_at, pickupTz, { dateOnly: true, includeYear: true })})`}
                  </p>
                )}
                {delivery && (
                  <p>
                    Delivery: {[delivery.facility_name, delivery.city, delivery.state].filter(Boolean).join(", ") || "--"}
                    {delivery.scheduled_at && ` (${formatStopDateTime(delivery.scheduled_at, deliveryTz, { dateOnly: true, includeYear: true })})`}
                  </p>
                )}
              </div>
            </div>
          )}
        </div>

        <table className="w-full py-6 text-sm">
          <thead>
            <tr className="border-b border-neutral-200 text-left text-xs font-semibold uppercase tracking-wide text-neutral-400">
              <th className="py-2">Description</th>
              <th className="py-2 text-right">Qty</th>
              <th className="py-2 text-right">Unit Price</th>
              <th className="py-2 text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {(lineItems ?? []).map((li) => (
              <tr key={li.id} className="border-b border-neutral-100">
                <td className="py-2">{li.description}</td>
                <td className="py-2 text-right">{Number(li.quantity)}</td>
                <td className="py-2 text-right">${Number(li.unit_price).toLocaleString()}</td>
                <td className="py-2 text-right font-medium">${Number(li.line_total).toLocaleString()}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div className="flex justify-end border-t border-neutral-200 pt-4">
          <div className="w-56 space-y-1.5 text-sm">
            <div className="flex justify-between">
              <span className="text-neutral-500">Subtotal</span>
              <span>${Number(invoice.subtotal_amount).toLocaleString()}</span>
            </div>
            {Number(invoice.discount_amount) > 0 && (
              <div className="flex justify-between">
                <span className="text-neutral-500">Credits / Deductions</span>
                <span>-${Number(invoice.discount_amount).toLocaleString()}</span>
              </div>
            )}
            {Number(invoice.tax_amount) > 0 && (
              <div className="flex justify-between">
                <span className="text-neutral-500">Tax</span>
                <span>${Number(invoice.tax_amount).toLocaleString()}</span>
              </div>
            )}
            <div className="flex justify-between border-t border-neutral-200 pt-1.5 text-base font-bold">
              <span>Total Due</span>
              <span>${Number(invoice.total_amount).toLocaleString()}</span>
            </div>
            {Number(invoice.amount_paid) > 0 && (
              <>
                <div className="flex justify-between text-xs text-neutral-500">
                  <span>Paid</span>
                  <span>${Number(invoice.amount_paid).toLocaleString()}</span>
                </div>
                <div className="flex justify-between font-semibold">
                  <span>Balance Due</span>
                  <span>${Number(invoice.balance_due).toLocaleString()}</span>
                </div>
              </>
            )}
          </div>
        </div>

        {load && (
          <div className="mt-6 border-t border-neutral-200 pt-4 text-xs text-neutral-500">
            <p className="font-semibold uppercase tracking-wide text-neutral-400">Supporting Documents</p>
            <p className="mt-1">Proof of Delivery: {POD_STATUS_LABEL[podStatus]}</p>
            <p>Rate Confirmation: {rateConOnFile ? "On File" : "Not on File"}</p>
          </div>
        )}

        {invoice.notes && (
          <div className="mt-4 border-t border-neutral-200 pt-4 text-xs text-neutral-500">
            <p className="font-semibold uppercase tracking-wide text-neutral-400">Notes</p>
            <p className="mt-1">{invoice.notes}</p>
          </div>
        )}

        <p className="mt-8 text-center text-[11px] text-neutral-400">
          Payment terms: due {invoice.due_date ? new Date(invoice.due_date).toLocaleDateString() : "upon receipt"}. Thank you for your business.
        </p>
      </div>
    </div>
  );
}
