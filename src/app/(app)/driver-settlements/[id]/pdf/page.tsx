import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PrintInvoiceButton } from "@/components/invoices/print-invoice-button";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Driver Settlement Statement -- same browser-print pattern as
// /invoices/[id]/pdf and /payments/[id]/receipt (outside the (app) route
// group's sidebar chrome, printed/saved via the browser's own dialog).
// Selects only settlement/load/org columns -- no path to SSN, CDL,
// medical, or any other driver HR data (spec section 23).
export default async function DriverSettlementPdfPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: settlement } = await supabase
    .from("driver_settlements")
    .select(
      "id, settlement_number, period_start, period_end, status, gross_pay, adjustments_amount, deductions_amount, advances_amount, net_pay, amount_paid, balance_due, created_at, drivers(first_name, last_name), carriers(legal_name), organization_id"
    )
    .eq("id", id)
    .single();
  if (!settlement) notFound();

  const settlementRow = settlement as unknown as typeof settlement & {
    drivers: { first_name: string; last_name: string } | null;
    carriers: { legal_name: string } | null;
  };

  const [{ data: org }, { data: items }, { data: adjustments }, { data: payments }] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code")
      .eq("id", settlement.organization_id)
      .single(),
    supabase.from("driver_settlement_items").select("*").eq("driver_settlement_id", id).order("delivery_date"),
    supabase.from("driver_settlement_adjustments").select("*").eq("driver_settlement_id", id).order("effective_date"),
    supabase.from("driver_settlement_payments").select("*").eq("driver_settlement_id", id).eq("status", "posted").order("paid_date"),
  ]);

  const driverName = settlementRow.drivers ? `${settlementRow.drivers.first_name} ${settlementRow.drivers.last_name}` : "--";

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
              {(org?.city || org?.state || org?.postal_code) && <p>{[org?.city, org?.state, org?.postal_code].filter(Boolean).join(", ")}</p>}
              {org?.business_phone && <p>{org.business_phone}</p>}
              {(org?.mc_number || org?.dot_number) && (
                <p>{org?.mc_number && `MC# ${org.mc_number}`}{org?.mc_number && org?.dot_number && " -- "}{org?.dot_number && `DOT# ${org.dot_number}`}</p>
              )}
            </div>
          </div>
          <div className="text-right">
            <p className="text-2xl font-bold tracking-tight text-neutral-800">DRIVER SETTLEMENT</p>
            <p className="mt-1 text-sm font-medium">{settlement.settlement_number}</p>
            <p className="mt-2 text-xs text-neutral-500">
              {new Date(settlement.period_start + "T00:00:00").toLocaleDateString()} - {new Date(settlement.period_end + "T00:00:00").toLocaleDateString()}
            </p>
            <p className="mt-1 text-xs font-medium uppercase tracking-wide text-neutral-500">{settlement.status.replace("_", " ")}</p>
          </div>
        </div>

        <div className="border-b border-neutral-200 py-6">
          <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Driver</p>
          <p className="mt-1 text-sm font-medium">{driverName}</p>
          <p className="text-xs text-neutral-500">{settlementRow.carriers?.legal_name}</p>
        </div>

        <table className="w-full py-6 text-sm">
          <thead>
            <tr className="border-b border-neutral-200 text-left text-xs font-semibold uppercase tracking-wide text-neutral-400">
              <th className="py-2">Load #</th>
              <th className="py-2">Delivery</th>
              <th className="py-2 text-right">Miles</th>
              <th className="py-2 text-right">Load Rate</th>
              <th className="py-2 text-right">Driver Rate</th>
              <th className="py-2 text-right">Gross Pay</th>
            </tr>
          </thead>
          <tbody>
            {(items ?? []).map((it) => (
              <tr key={it.id} className="border-b border-neutral-100">
                <td className="py-2">{it.load_number}</td>
                <td className="py-2">{it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                <td className="py-2 text-right">{it.miles ? Number(it.miles).toLocaleString() : "--"}</td>
                <td className="py-2 text-right">{money(it.load_rate)}</td>
                <td className="py-2 text-right">{it.pay_method === "percentage" ? `${it.pay_rate}%` : money(it.pay_rate)}</td>
                <td className="py-2 text-right font-medium">{money(it.gross_pay)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        {(adjustments ?? []).length > 0 && (
          <div className="border-t border-neutral-200 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Deductions / Advances / Adjustments</p>
            <table className="mt-2 w-full text-sm">
              <tbody>
                {(adjustments ?? []).map((a) => (
                  <tr key={a.id} className="border-b border-neutral-100">
                    <td className="py-1.5 capitalize text-neutral-500">{a.bucket}</td>
                    <td className="py-1.5">{a.category}</td>
                    <td className="py-1.5 text-right">{a.bucket === "adjustment" && a.amount >= 0 ? "+" : "-"}{money(Math.abs(a.amount))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        <div className="flex justify-end border-t border-neutral-200 pt-4">
          <div className="w-64 space-y-1.5 text-sm">
            <div className="flex justify-between"><span className="text-neutral-500">Gross Pay</span><span>{money(settlement.gross_pay)}</span></div>
            <div className="flex justify-between"><span className="text-neutral-500">Adjustments</span><span>{money(settlement.adjustments_amount)}</span></div>
            <div className="flex justify-between"><span className="text-neutral-500">Deductions</span><span>-{money(settlement.deductions_amount)}</span></div>
            <div className="flex justify-between"><span className="text-neutral-500">Advances</span><span>-{money(settlement.advances_amount)}</span></div>
            <div className="flex justify-between border-t border-neutral-200 pt-1.5 text-base font-bold"><span>NET PAY</span><span>{money(settlement.net_pay)}</span></div>
            <div className="flex justify-between text-xs text-neutral-500"><span>Paid</span><span>{money(settlement.amount_paid)}</span></div>
            <div className="flex justify-between font-semibold"><span>Balance Due</span><span>{money(settlement.balance_due)}</span></div>
          </div>
        </div>

        {(payments ?? []).length > 0 && (
          <div className="mt-4 border-t border-neutral-200 pt-4 text-xs text-neutral-500">
            <p className="font-semibold uppercase tracking-wide text-neutral-400">Payment History</p>
            {(payments ?? []).map((p) => (
              <p key={p.id} className="mt-1">{p.payment_number} -- {new Date(p.paid_date + "T00:00:00").toLocaleDateString()} -- {p.method} -- {money(p.amount)}</p>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
