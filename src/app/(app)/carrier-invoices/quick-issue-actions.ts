"use server";

import { createClient } from "@/lib/supabase/server";
import { issueCarrierInvoice, markCarrierInvoiceReady } from "./issuance-actions";
import { isValidWorkflowKey, newWorkflowKey, type WorkflowOutcome } from "@/lib/factoring/carrier-invoice-issuance";

// One "Issue invoice" click for an owner/admin on a draft: the two reviewed
// steps (mark ready, then issue) run back to back through the same actions,
// so every database check still applies to each. If the second step is
// refused, the invoice is simply left "ready to issue" and the button stays.
export async function issueDraftCarrierInvoice(invoiceId: string, expectedUpdatedAt: string, reason: string, idempotencyKey: string): Promise<WorkflowOutcome> {
  if (!isValidWorkflowKey(idempotencyKey)) return { ok: false, code: "INVALID_REQUEST", error: "Please try again." };
  const ready = await markCarrierInvoiceReady(invoiceId, expectedUpdatedAt, idempotencyKey);
  if (!ready.ok) return ready;
  let updatedAt = ready.updatedAt;
  if (!updatedAt) {
    const supabase = await createClient();
    const { data } = await supabase.from("carrier_invoices").select("updated_at").eq("id", invoiceId).maybeSingle();
    updatedAt = data?.updated_at ? String(data.updated_at) : undefined;
  }
  if (!updatedAt) return { ok: false, code: "UNKNOWN", error: "The invoice is ready to issue. Refresh the page and click Issue invoice again." };
  return issueCarrierInvoice(invoiceId, updatedAt, reason, newWorkflowKey());
}
