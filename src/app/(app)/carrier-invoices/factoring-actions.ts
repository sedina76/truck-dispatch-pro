"use server";

import { isCarrierInvoicePilotOperator } from "@/lib/factoring/carrier-invoice-issuance";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { checkOperationalAccess } from "@/lib/billing/operational-access";
import { isValidIdempotencyKey, outcomeFromRpc, GENERIC_FAILURE, type FactoringPreview, type FactoringSubmitResult, type SubmitOutcome } from "@/lib/factoring/carrier-invoice-submission";

// Proposal 0157 (F-08, carrier invoices). Both actions call the SECURITY DEFINER RPCs through the CALLER'S OWN session (never service-role): the database derives the
// organization, the role, the carrier access and the factoring relationship from auth.uid(). The client supplies ONLY the carrier-invoice id (and, for the submit, an
// idempotency key) -- there is no relationship, factor or carrier parameter anywhere in this file, so nothing here can be substituted. Hiding the button is not security.

export async function getCarrierInvoiceFactoringPreview(carrierInvoiceId: string): Promise<FactoringPreview | null> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const { data, error } = await supabase.rpc("preview_carrier_invoice_factoring", { p_carrier_invoice_id: carrierInvoiceId });
  if (error) return null;
  return (data ?? null) as FactoringPreview | null;
}

export async function submitCarrierInvoiceToFactor(carrierInvoiceId: string, idempotencyKey: string): Promise<SubmitOutcome> {
  if (!isValidIdempotencyKey(idempotencyKey)) return { ok: false, code: "INVALID_REQUEST", error: GENERIC_FAILURE };
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, code: "FORBIDDEN", error: "Not authenticated." };
  const { data: invoice } = await supabase.from("carrier_invoices").select("id").eq("id", carrierInvoiceId).maybeSingle();
  if (!invoice) return { ok: false, code: "NOT_FOUND", error: "Carrier invoice not found." };
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!isCarrierInvoicePilotOperator(profile?.role)) return { ok: false, code: "FORBIDDEN", error: "Only owners and admins may submit invoices for factoring." };
  const billingAccess = await checkOperationalAccess(); // D.2.11 SaaS paywall, as every factoring mutation.
  if (!billingAccess.ok) return { ok: false, code: "FORBIDDEN", error: "Your organization's subscription does not permit this action." };

  const { data, error } = await supabase.rpc("submit_carrier_invoice_to_factor", { p_carrier_invoice_id: carrierInvoiceId, p_idempotency_key: idempotencyKey });
  const outcome = outcomeFromRpc(data as FactoringSubmitResult | null, error);
  if (outcome.ok) {
    revalidatePath(`/carrier-invoices/${carrierInvoiceId}`);
    revalidatePath("/carrier-invoices");
  }
  return outcome;
}
