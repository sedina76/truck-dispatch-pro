// Billing Overview work queue for "Broker pays the carrier" loads. These
// loads never show in Ready to Bill (no broker invoice from us), so without
// this they would drop out of the Billing workspace once delivered. Each one
// still needs two things:
//   1. our dispatch fee billed to the carrier (a Dispatch Fee Invoice), and
//   2. the carrier's own invoice to the broker / factoring company
//      (a Carrier Invoice).
// Pure counting only; the database decides what is billable.

export type CarrierPaidDispatch = { id: string; load_id: string };

export function carrierPaidQueue(
  delivered: CarrierPaidDispatch[],
  feeInvoicedDispatchIds: Iterable<string>,
  carrierInvoicedLoadIds: Iterable<string>
): { needFeeInvoice: number; needCarrierInvoice: number } {
  const fee = new Set(feeInvoicedDispatchIds);
  const carrier = new Set(carrierInvoicedLoadIds);
  let needFeeInvoice = 0;
  const loadsNeedingCarrierInvoice = new Set<string>();
  for (const d of delivered) {
    if (!fee.has(d.id)) needFeeInvoice += 1;
    if (!carrier.has(d.load_id)) loadsNeedingCarrierInvoice.add(d.load_id);
  }
  return { needFeeInvoice, needCarrierInvoice: loadsNeedingCarrierInvoice.size };
}
