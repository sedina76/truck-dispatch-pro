import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PrintInvoiceButton } from "@/components/invoices/print-invoice-button";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}
function route(pickupCity: string | null, pickupState: string | null, deliveryCity: string | null, deliveryState: string | null): string {
  const pickup = [pickupCity, pickupState].filter(Boolean).join(", ") || "--";
  const delivery = [deliveryCity, deliveryState].filter(Boolean).join(", ") || "--";
  return `${pickup} -> ${delivery}`;
}
// Same short, stable, non-fabricated display-id convention used on the
// Settlement Detail page and the Fuel Log Detail page -- no schema change
// for a display label (maintenance_records/fuel_logs/dispatch_advances have
// no dedicated number sequence, unlike expenses.expense_number).
function shortId(prefix: string, id: string): string {
  return `${prefix}-${id.slice(0, 8).toUpperCase()}`;
}

// Carrier Settlement Statement -- same browser-print pattern as
// /driver-settlements/[id]/pdf and /invoices/[id]/pdf, reused unchanged.
//
// CARRIER-FACING DATA BOUNDARY (spec sections 22-26/40/55): this document
// is treated as potentially handed directly to the carrier (it's also the
// exact attachment the Send Carrier Settlement email path uses, spec
// section 38). It must NEVER show customer/broker revenue, dispatch fee %,
// company margin, or an invoice total -- those are staff-only figures that
// live on the Detail workspace's clearly-marked "Internal Revenue -- Staff
// Only" section instead. A prior version of this page showed a Revenue
// column and a Customer Revenue total; both are removed here. No SSN/CDL/
// medical/HR data has ever had a path into this query.
export default async function CarrierSettlementPdfPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: settlement } = await supabase
    .from("settlements")
    .select(
      "id, settlement_number, period_start, period_end, status, gross_amount, adjustments_amount, deductions_amount, advances_amount, quick_pay_enabled, quick_pay_rate_percent, quick_pay_fee_amount, net_amount, amount_paid, balance_due, organization_id, carrier_id, payee_name, carriers(legal_name, dba_name, mc_number, dot_number, phone, email)"
    )
    .eq("id", id)
    .single();
  if (!settlement) notFound();

  const settlementRow = settlement as unknown as typeof settlement & { carriers: { legal_name: string; dba_name: string | null; mc_number: string | null; dot_number: string | null; phone: string | null; email: string | null } | null };

  const [{ data: org }, { data: loadItemsRaw }, { data: otherItemsRaw }, { data: payments }] = await Promise.all([
    supabase
      .from("organizations")
      .select("name, mc_number, dot_number, business_phone, business_email, address_line1, city, state, postal_code")
      .eq("id", settlement.organization_id)
      .single(),
    supabase
      .from("settlement_line_items")
      .select("*, dispatches(trucks(unit_number))")
      .eq("settlement_id", id)
      .eq("item_type", "load_pay")
      .order("delivery_date"),
    supabase.from("settlement_line_items").select("*").eq("settlement_id", id).neq("item_type", "load_pay").order("created_at"),
    supabase.from("carrier_settlement_payments").select("*").eq("settlement_id", id).eq("status", "posted").order("paid_date"),
  ]);

  type LoadItem = { id: string; load_number: string | null; delivery_date: string | null; carrier_rate: number | null; amount: number; pickup_city: string | null; pickup_state: string | null; delivery_city: string | null; delivery_state: string | null; dispatches: { trucks: { unit_number: string } | null } | null };
  type OtherItem = { id: string; item_type: string; description: string; amount: number; linked_fuel_log_id: string | null; linked_maintenance_id: string | null; linked_advance_id: string | null };
  const loadItems = (loadItemsRaw ?? []) as unknown as LoadItem[];
  const otherItems = (otherItemsRaw ?? []) as unknown as OtherItem[];

  // Itemized deduction rows (spec section 25): Fuel/Maintenance/Other
  // deductions listed individually under DEDUCTIONS with a real total;
  // Advances kept as their own section (spec section 10/13) -- never
  // silently merged.
  const deductionItems = otherItems.filter((it) => it.item_type === "deduction");
  const advanceItems = otherItems.filter((it) => it.item_type === "advance" || it.linked_advance_id);
  const adjustmentItems = otherItems.filter((it) => it.item_type === "adjustment");
  const totalDeductions = deductionItems.reduce((sum, it) => sum + Number(it.amount), 0);

  const totalPaid = (payments ?? []).reduce((sum, p) => sum + Number(p.amount), 0);
  const isPaidInFull = settlement.status === "paid";
  const lastPayment = (payments ?? []).length > 0 ? [...(payments ?? [])].sort((a, b) => new Date(b.paid_date).getTime() - new Date(a.paid_date).getTime())[0] : null;

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
            <p className="text-2xl font-bold tracking-tight text-neutral-800">CARRIER SETTLEMENT</p>
            <p className="mt-1 text-sm font-medium">{settlement.settlement_number}</p>
            <p className="mt-2 text-xs text-neutral-500">
              {new Date(settlement.period_start + "T00:00:00").toLocaleDateString()} - {new Date(settlement.period_end + "T00:00:00").toLocaleDateString()}
            </p>
            <p className="mt-1 text-xs font-medium uppercase tracking-wide text-neutral-500">{settlement.status.replace(/_/g, " ")}</p>
          </div>
        </div>

        <div className="border-b border-neutral-200 py-6">
          <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Carrier</p>
          <p className="mt-1 text-sm font-medium">{settlementRow.carriers?.dba_name || settlementRow.carriers?.legal_name || "--"}</p>
          <div className="mt-0.5 space-y-0.5 text-xs text-neutral-500">
            {(settlementRow.carriers?.mc_number || settlementRow.carriers?.dot_number) && (
              <p>{settlementRow.carriers?.mc_number && `MC# ${settlementRow.carriers.mc_number}`}{settlementRow.carriers?.mc_number && settlementRow.carriers?.dot_number && " -- "}{settlementRow.carriers?.dot_number && `DOT# ${settlementRow.carriers.dot_number}`}</p>
            )}
            {(settlementRow.carriers?.phone || settlementRow.carriers?.email) && <p>{[settlementRow.carriers?.phone, settlementRow.carriers?.email].filter(Boolean).join(" -- ")}</p>}
          </div>
          {settlement.payee_name && <p className="mt-1 text-xs text-neutral-500">Paid to: {settlement.payee_name}</p>}
        </div>

        <table className="w-full py-6 text-sm">
          <thead>
            <tr className="border-b border-neutral-200 text-left text-xs font-semibold uppercase tracking-wide text-neutral-400">
              <th className="py-2">Load #</th>
              <th className="py-2">Pickup -&gt; Delivery</th>
              <th className="py-2">Delivery Date</th>
              <th className="py-2">Truck</th>
              <th className="py-2 text-right">Carrier Pay</th>
            </tr>
          </thead>
          <tbody>
            {loadItems.map((it) => (
              <tr key={it.id} className="border-b border-neutral-100">
                <td className="py-2">{it.load_number}</td>
                <td className="py-2 text-neutral-500">{route(it.pickup_city, it.pickup_state, it.delivery_city, it.delivery_state)}</td>
                <td className="py-2">{it.delivery_date ? new Date(it.delivery_date + "T00:00:00").toLocaleDateString() : "--"}</td>
                <td className="py-2 text-neutral-500">{it.dispatches?.trucks?.unit_number ?? "--"}</td>
                <td className="py-2 text-right font-medium">{money(it.carrier_rate ?? it.amount)}</td>
              </tr>
            ))}
            {loadItems.length === 0 && (
              <tr><td colSpan={5} className="py-3 text-center text-neutral-400">No loads in this settlement.</td></tr>
            )}
          </tbody>
        </table>

        <div className="border-t border-neutral-200 py-4">
          <div className="flex justify-between text-sm font-semibold">
            <span>GROSS CARRIER PAY</span>
            <span>{money(settlement.gross_amount)}</span>
          </div>
        </div>

        {adjustmentItems.length > 0 && (
          <div className="border-t border-neutral-200 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Adjustments</p>
            {adjustmentItems.map((it) => (
              <div key={it.id} className="mt-1 flex justify-between text-sm">
                <span className="text-neutral-500">{it.description}</span>
                <span>{it.amount >= 0 ? "+" : ""}{money(it.amount)}</span>
              </div>
            ))}
          </div>
        )}

        {deductionItems.length > 0 && (
          <div className="border-t border-neutral-200 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Deductions</p>
            {deductionItems.map((it) => {
              const label = it.linked_fuel_log_id
                ? `Fuel ${shortId("FL", it.linked_fuel_log_id)}`
                : it.linked_maintenance_id
                  ? `Maintenance ${shortId("MNT", it.linked_maintenance_id)}`
                  : it.description;
              return (
                <div key={it.id} className="mt-1 flex justify-between text-sm">
                  <span className="text-neutral-500">{label}{it.description && (it.linked_fuel_log_id || it.linked_maintenance_id) ? ` -- ${it.description.replace(/^Fuel -- |^Maintenance -- /, "")}` : ""}</span>
                  <span>-{money(Math.abs(it.amount))}</span>
                </div>
              );
            })}
            <div className="mt-2 flex justify-between border-t border-neutral-200 pt-1.5 text-sm font-semibold">
              <span>TOTAL DEDUCTIONS</span>
              <span>-{money(totalDeductions)}</span>
            </div>
          </div>
        )}

        {advanceItems.length > 0 && (
          <div className="border-t border-neutral-200 py-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Advances</p>
            {advanceItems.map((it) => (
              <div key={it.id} className="mt-1 flex justify-between text-sm">
                <span className="text-neutral-500">{it.linked_advance_id ? shortId("ADV", it.linked_advance_id) : it.description} -- {it.description}</span>
                <span>-{money(Math.abs(it.amount))}</span>
              </div>
            ))}
          </div>
        )}

        {settlement.quick_pay_enabled && (
          <div className="border-t border-neutral-200 py-4">
            <div className="flex justify-between text-sm">
              <span className="text-neutral-500">Quick Pay Fee ({settlement.quick_pay_rate_percent}%)</span>
              <span>-{money(settlement.quick_pay_fee_amount)}</span>
            </div>
          </div>
        )}

        <div className="flex justify-end border-t border-neutral-200 pt-4">
          <div className="w-64 space-y-1.5 text-sm">
            <div className="flex justify-between border-t border-neutral-200 pt-1.5 text-base font-bold"><span>NET CARRIER PAY</span><span>{money(settlement.net_amount)}</span></div>
          </div>
        </div>

        {(payments ?? []).length > 0 && (
          <div className="mt-4 border-t border-neutral-200 pt-4">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Payment History</p>
            <table className="mt-2 w-full text-sm">
              <tbody>
                {(payments ?? []).map((p) => (
                  <tr key={p.id} className="border-b border-neutral-100">
                    <td className="py-1.5">{p.payment_number}</td>
                    <td className="py-1.5 text-neutral-500">{new Date(p.paid_date + "T00:00:00").toLocaleDateString()}</td>
                    <td className="py-1.5 text-neutral-500 capitalize">{p.method.replace(/_/g, " ")}</td>
                    <td className="py-1.5 text-right">{money(p.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="mt-2 flex justify-between text-sm font-semibold">
              <span>Total Paid</span>
              <span>{money(totalPaid)}</span>
            </div>
          </div>
        )}

        <div className="mt-4 flex justify-end border-t border-neutral-200 pt-4">
          {isPaidInFull ? (
            <div className="text-right">
              <p className="text-lg font-bold tracking-tight text-desktop-success">PAID IN FULL</p>
              {lastPayment && <p className="text-xs text-neutral-500">{new Date(lastPayment.paid_date + "T00:00:00").toLocaleDateString()}</p>}
            </div>
          ) : (
            <div className="w-64 space-y-1.5 text-sm">
              <div className="flex justify-between"><span className="text-neutral-500">Paid</span><span>{money(settlement.amount_paid)}</span></div>
              <div className="flex justify-between border-t border-neutral-200 pt-1.5 text-base font-bold"><span>BALANCE DUE</span><span>{money(settlement.balance_due)}</span></div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
