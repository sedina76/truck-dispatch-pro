"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createCarrierInvoiceDraft } from "@/app/(app)/carrier-invoices/issuance-actions";
import { isUuid, newWorkflowKey } from "@/lib/factoring/carrier-invoice-issuance";

// Invoices -> Create Invoice for a "broker pays the carrier" load: the invoice
// to the broker is the CARRIER's invoice (carrier_invoices), so this starts
// that invoice through the same reviewed draft action the carrier-invoice
// workflow uses (it re-checks the role, the carrier, the broker link and the
// load in the database). The user never picks the carrier, broker or amount:
// they come from the load. Refusals return to the form with the reason
// instead of the generic error screen.
function back(loadId: string, message: string): never {
  redirect(`/invoices/new?load_id=${encodeURIComponent(loadId)}&error=${encodeURIComponent(message)}`);
}

export async function createCarrierInvoiceForLoad(formData: FormData): Promise<void> {
  const loadId = String(formData.get("load_id") ?? "");
  if (!isUuid(loadId)) redirect("/invoices/new?error=" + encodeURIComponent("Choose a load first."));

  const supabase = await createClient();
  const { data: load } = await supabase.from("loads").select("id, carrier_id, broker_id, customer_id").eq("id", loadId).maybeSingle();
  if (!load) back(loadId, "That load could not be found.");
  if (!load.carrier_id) back(loadId, "This load has no carrier. Assign the carrier on the load first.");
  const recipientId = load.broker_id ?? load.customer_id;
  if (!recipientId) back(loadId, "This load has no broker or customer. Add one on the load first.");

  const outcome = await createCarrierInvoiceDraft(
    { carrierId: String(load.carrier_id), loadIds: [loadId], recipientType: load.broker_id ? "broker" : "customer", recipientId: String(recipientId) },
    newWorkflowKey()
  );
  if (!outcome.ok) back(loadId, outcome.error);
  redirect(`/carrier-invoices/${outcome.invoiceId}`);
}
