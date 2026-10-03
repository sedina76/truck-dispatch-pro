"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { canUseBilling } from "@/lib/auth/billing-access";
import { isUuid } from "@/lib/factoring/carrier-invoice-issuance";
import { loadIssuedCarrierInvoice, renderCarrierFactorPackage } from "@/lib/carrier-invoices/pdf";
import { latestCarrierPacket, saveCarrierPacket, signedPacketUrl } from "@/lib/carrier-invoices/packet-storage";

// "Generate Billing Packet" on a carrier's invoice -- same behavior as your
// own invoice: build the packet (cover, invoice, POD, rate con, BOL,
// accessorials), save it, and show Preview / Download on the page. Errors are
// RETURNED (not thrown) so the exact reason reaches the person clicking.

export type CarrierPacketResult = { ok: true; skipped: { label: string; filename: string; reason: string }[] } | { ok: false; error: string };

async function billingSession() {
  const supabase = await createClient();
  const [{ data: role }, { data: org }] = await Promise.all([supabase.rpc("current_role"), supabase.rpc("current_org_id")]);
  if (!canUseBilling(role as string | null) || !org) return null;
  return { supabase, org: String(org) };
}

export async function generateCarrierBillingPacket(invoiceId: string): Promise<CarrierPacketResult> {
  if (!isUuid(invoiceId)) return { ok: false, error: "Invoice not found." };
  const s = await billingSession();
  if (!s) return { ok: false, error: "Only an owner, admin or accountant can generate billing packets." };
  const inv = await loadIssuedCarrierInvoice(s.supabase, invoiceId);
  if (!inv) return { ok: false, error: "Issue the invoice first." };
  let rendered: Awaited<ReturnType<typeof renderCarrierFactorPackage>>;
  try {
    rendered = await renderCarrierFactorPackage(s.supabase, inv);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("[carrier-billing-packet] could not generate:", { invoice_id: invoiceId, error: message });
    return { ok: false, error: message.startsWith("The package is not ready") || message.startsWith("Could not include") ? message : "Could not generate the billing packet. Please try again." };
  }
  const safe = inv.snapshot.invoice_number.replace(/[^A-Za-z0-9-]/g, "");
  const saved = await saveCarrierPacket(s.supabase, s.org, invoiceId, rendered.bytes, `billing-packet-${safe}.pdf`);
  if ("error" in saved) {
    console.error("[carrier-billing-packet] could not save:", { invoice_id: invoiceId, error: saved.error });
    return { ok: false, error: "The packet was built but could not be saved. Please try again." };
  }
  revalidatePath(`/carrier-invoices/${invoiceId}`);
  return { ok: true, skipped: rendered.skipped };
}

/** Short-lived link to the saved packet (Preview / Download). */
export async function getCarrierPacketUrl(invoiceId: string, download: boolean): Promise<string> {
  if (!isUuid(invoiceId)) throw new Error("Invoice not found.");
  const s = await billingSession();
  if (!s) throw new Error("Not allowed.");
  const latest = await latestCarrierPacket(s.supabase, s.org, invoiceId);
  if (!latest) throw new Error("Generate the billing packet first.");
  const url = await signedPacketUrl(s.supabase, latest.path, download);
  if (!url) throw new Error("Could not open the billing packet.");
  return url;
}
