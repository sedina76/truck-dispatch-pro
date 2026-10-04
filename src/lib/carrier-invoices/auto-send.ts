import "server-only";
import { createClient } from "@/lib/supabase/server";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import { resolveEmailForEntity } from "@/lib/email/resolve-entity";
import { sendTenantEmail } from "@/lib/email/send-pipeline";
import { loadIssuedCarrierInvoice, renderCarrierFactorPackage } from "@/lib/carrier-invoices/pdf";
import { packageRecipient } from "@/lib/carrier-invoices/source";
import { liveCarrierInvoicesByLoad } from "@/lib/billing/carrier-paid-loads";
import { shouldAutoSendToFactor } from "@/lib/carrier-invoices/auto-send-rules";

// Until factoring companies are connected by API: the billing packet goes to
// the factor by email automatically, the moment it is complete -- i.e. when
// the carrier's invoice is issued AND every load's POD is verified (whichever
// happens last). Only when we send the paperwork and the factor takes it by
// email (Factoring box: "How the factor takes paperwork" = email, with an
// address). Never twice: skipped once a send to this invoice succeeded.
// Same recipient, text, attachment and email ledger as the "Email to
// Factor" button. Best-effort: never fails the action that triggered it;
// a failed send shows on the invoice ("Last attempt did not send").

export type AutoSendResult = { sent: boolean; reason: string };

export async function autoSendFactorPacket(invoiceId: string): Promise<AutoSendResult> {
  try {
    const supabase = await createClient();
    const inv = await loadIssuedCarrierInvoice(supabase, invoiceId);
    if (!inv) return { sent: false, reason: "not issued" };

    const { data: carrier } = await supabase.from("carriers").select("email, factor_package_sent_by").eq("id", inv.carrierId).maybeSingle();
    const sender = carrier?.factor_package_sent_by === "carrier" ? "carrier" : "dispatcher";
    const dest = packageRecipient(inv.snapshot, sender, carrier?.email ?? null);

    const { data: sends } = await supabase.from("email_send_log").select("status").eq("entity_type", "carrier_invoice").eq("entity_id", invoiceId);
    const decision = shouldAutoSendToFactor({
      issuanceStatus: inv.issuanceStatus,
      who: dest.who,
      to: dest.to,
      alreadySent: (sends ?? []).some((s) => s.status === "sent"),
    });
    if (!decision.send) return { sent: false, reason: decision.reason };

    const resolved = await resolveEmailForEntity("carrier_invoice", invoiceId, supabase);
    if ("error" in resolved) return { sent: false, reason: resolved.error };
    if (resolved.blocked) return { sent: false, reason: "packet not ready" }; // e.g. POD not verified yet

    const auth = await resolveEmailAuthorizationContext();
    if (!auth.ok) return { sent: false, reason: auth.error };

    const pdf = await renderCarrierFactorPackage(supabase, inv);
    const safe = resolved.numberLabel.replace(/[^A-Za-z0-9._-]/g, "_");
    const result = await sendTenantEmail({
      authContext: auth.context,
      emailPurpose: "billing_packet",
      to: [resolved.to],
      subject: resolved.subject,
      text: resolved.message,
      attachments: [{ filename: `${safe}-package.pdf`, content: pdf.bytes }],
      entityType: "carrier_invoice",
      entityId: invoiceId,
      entities: {},
      sentBy: auth.context.actorUserId,
    });
    if (!result.ok) {
      console.warn("[auto-send] factor packet not sent:", { invoiceId, error: result.error });
      return { sent: false, reason: result.error };
    }
    return { sent: true, reason: `sent to ${resolved.to}` };
  } catch (err) {
    console.error("[auto-send] factor packet failed:", { invoiceId, error: err instanceof Error ? err.message : err });
    return { sent: false, reason: "error" };
  }
}

/** After a POD is verified: try every issued carrier invoice that holds this load. */
export async function autoSendFactorPacketsForLoad(loadId: string): Promise<void> {
  const supabase = await createClient();
  const live = await liveCarrierInvoicesByLoad(supabase, [loadId]);
  const inv = live.get(loadId);
  if (inv && inv.issuanceStatus === "issued") await autoSendFactorPacket(inv.invoiceId);
}
