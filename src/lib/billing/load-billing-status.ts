// What a load's billing looks like when the broker pays the carrier: the
// carrier's invoice (if made) and whether your dispatch fee was billed to
// the carrier yet. Read through the caller's RLS-scoped session; a role that
// cannot see carrier invoices just gets nulls.

import type { createClient } from "@/lib/supabase/server";
import { carrierPaidLoadIds, liveCarrierInvoicesByLoad, type LiveCarrierInvoiceForLoad } from "./carrier-paid-loads";

type Supabase = Awaited<ReturnType<typeof createClient>>;

export type CarrierPaidLoadBilling = {
  carrierInvoice: LiveCarrierInvoiceForLoad | null;
  feeInvoice: { id: string; invoiceNumber: string; status: string } | null;
};

/** Null when the load is billed by you ("Broker pays us"). */
export async function carrierPaidBillingForLoad(supabase: Supabase, loadId: string): Promise<CarrierPaidLoadBilling | null> {
  const carrierPaid = await carrierPaidLoadIds(supabase, [loadId]);
  if (!carrierPaid.has(loadId)) return null;
  const [onInvoice, { data: feeLines }] = await Promise.all([
    liveCarrierInvoicesByLoad(supabase, [loadId]),
    supabase
      .from("carrier_fee_invoice_lines")
      .select("invoice_id, carrier_fee_invoices!inner(invoice_number, status)")
      .eq("load_id", loadId)
      .eq("line_type", "dispatch_fee")
      .eq("voided", false)
      .neq("carrier_fee_invoices.status", "void")
      .limit(1),
  ]);
  const fee = ((feeLines ?? []) as unknown as { invoice_id: string; carrier_fee_invoices: { invoice_number: string; status: string } | null }[])[0];
  return {
    carrierInvoice: onInvoice.get(loadId) ?? null,
    feeInvoice: fee?.carrier_fee_invoices ? { id: String(fee.invoice_id), invoiceNumber: fee.carrier_fee_invoices.invoice_number, status: fee.carrier_fee_invoices.status } : null,
  };
}
