import "server-only";
import { createClient } from "@/lib/supabase/server";

/**
 * The carrier's billing link with the broker/customer (carrier_brokers /
 * carrier_customers) is required before invoicing. If there is none yet it
 * is created and activated here from the broker's own email and payment
 * terms, so nobody has to set it up by hand first. An existing link (or a
 * deliberately inactive one) is left alone. Returns a message when it can't.
 */
export async function ensureCarrierPartyLink(supabase: Awaited<ReturnType<typeof createClient>>, input: { carrierId: string; recipientType: "broker" | "customer"; recipientId: string }): Promise<string | null> {
  const isBroker = input.recipientType === "broker";
  const table = isBroker ? "carrier_brokers" : "carrier_customers";
  const col = isBroker ? "broker_id" : "customer_id";
  const { data: link } = await supabase.from(table).select("status").eq("carrier_id", input.carrierId).eq(col, input.recipientId).maybeSingle();
  if (link?.status === "active") return null;
  if (link?.status === "inactive") return `This carrier's billing link with that ${isBroker ? "broker" : "customer"} is turned off. Turn it back on under "Brokers this carrier invoices" on the carrier page.`;
  const party = isBroker
    ? await supabase.from("brokers").select("company_name, email").eq("id", input.recipientId).maybeSingle()
    : await supabase.from("customers").select("company_name, email").eq("id", input.recipientId).maybeSingle();
  const terms = isBroker
    ? await supabase.from("broker_financials").select("payment_terms_days").eq("broker_id", input.recipientId).maybeSingle()
    : await supabase.from("customer_financials").select("payment_terms_days").eq("customer_id", input.recipientId).maybeSingle();
  const email = (party.data?.email ?? "").trim();
  if (!email) return `${party.data?.company_name ?? "This broker"} has no email on file. Add its billing email on its page (or under "Brokers this carrier invoices" on the carrier page), then try again.`;
  const { data, error } = await supabase.rpc("activate_carrier_party", {
    p_carrier_id: input.carrierId,
    p_broker_id: isBroker ? input.recipientId : null,
    p_customer_id: isBroker ? null : input.recipientId,
    p_settings: { billing_email: email, payment_terms_days: Number(terms.data?.payment_terms_days ?? 30), factoring_eligible: true },
  });
  const r = data as { success?: boolean; message?: string } | null;
  if (error || r?.success === false) return error?.message ?? r?.message ?? "Could not set up the carrier's billing link with this broker.";
  return null;
}
