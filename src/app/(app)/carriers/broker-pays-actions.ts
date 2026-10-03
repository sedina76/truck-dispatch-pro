"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRole, OWNER_ADMIN_ROLES, BILLING_ROLES } from "@/lib/auth/require-role";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { brokerPaysResultMessage, type BrokerPaysResult } from "@/lib/carriers/broker-pays";
import { suggestInvoiceCode, uniqueInvoiceCode } from "@/lib/carriers/invoice-code";

// Saves the carrier's "Who does the broker pay?" setting through
// set_carrier_broker_pays (0167), which also moves the carrier's open loads
// and refuses anyone but an owner or admin.
export async function setCarrierBrokerPays(carrierId: string, formData: FormData) {
  await requireRole(OWNER_ADMIN_ROLES);
  await requireOperationalAccess();
  const model = String(formData.get("broker_pays") ?? "");
  const here = `/carriers/${carrierId}`;
  if (model !== "carrier_paid_directly" && model !== "dispatcher_receives_funds") {
    redirect(`${here}?bp_error=${encodeURIComponent("Choose who the broker pays.")}`);
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_carrier_broker_pays", { p_carrier_id: carrierId, p_model: model });
  if (error) redirect(`${here}?bp_error=${encodeURIComponent(error.message)}`);
  // Carrier invoices need an invoice-number prefix: set one from the name if missing.
  if (model === "carrier_paid_directly") await ensureInvoiceCode(supabase, carrierId);
  revalidatePath(here);
  revalidatePath("/dispatch-fee-invoices");
  revalidatePath("/billing/ready-to-bill");
  redirect(`${here}?bp_saved=${encodeURIComponent(brokerPaysResultMessage(data as BrokerPaysResult))}${model === "carrier_paid_directly" ? "#billing-setup" : ""}`);
}

// "Who sends the paperwork?" for carriers the broker pays directly (0169):
// we send the invoice package to the factor/broker, or the carrier does.
export async function setCarrierFactorPackageSender(carrierId: string, formData: FormData) {
  await requireRole(BILLING_ROLES);
  await requireOperationalAccess();
  const sender = String(formData.get("factor_package_sent_by") ?? "");
  const here = `/carriers/${carrierId}`;
  if (sender !== "dispatcher" && sender !== "carrier") redirect(`${here}?bp_error=${encodeURIComponent("Choose who sends the paperwork.")}`);
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_carrier_factor_package_sender", { p_carrier_id: carrierId, p_sender: sender });
  if (error) redirect(`${here}?bp_error=${encodeURIComponent(error.message)}`);
  revalidatePath(here);
  redirect(`${here}?bp_saved=${encodeURIComponent(sender === "carrier" ? "The carrier sends the paperwork; billing packets are emailed to the carrier." : "We send the paperwork to the carrier's factor (or the broker).")}`);
}

// "Brokers this carrier invoices": the carrier's billing relationship with a
// broker (where the carrier's invoice goes, terms, whether its factor buys
// invoices on this broker). Required before a carrier invoice can be issued.
// activate_carrier_party (0131) creates or updates it and activates it.
export async function saveCarrierBroker(carrierId: string, formData: FormData) {
  await requireRole(BILLING_ROLES);
  await requireOperationalAccess();
  const here = `/carriers/${carrierId}`;
  const brokerId = String(formData.get("broker_id") ?? "");
  const billingEmail = String(formData.get("billing_email") ?? "").trim();
  const terms = Number(String(formData.get("payment_terms_days") ?? "").trim());
  if (!brokerId) redirect(`${here}?bp_error=${encodeURIComponent("Choose a broker.")}#carrier-brokers`);
  if (!billingEmail || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(billingEmail)) redirect(`${here}?bp_error=${encodeURIComponent("Enter the broker's billing email.")}#carrier-brokers`);
  if (!Number.isInteger(terms) || terms < 0 || terms > 365) redirect(`${here}?bp_error=${encodeURIComponent("Payment terms must be 0 to 365 days.")}#carrier-brokers`);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("activate_carrier_party", {
    p_carrier_id: carrierId,
    p_broker_id: brokerId,
    p_customer_id: null,
    p_settings: { billing_email: billingEmail, payment_terms_days: terms, factoring_eligible: formData.get("factoring_eligible") === "on" },
  });
  const result = data as { success?: boolean; message?: string } | null;
  if (error || result?.success === false) redirect(`${here}?bp_error=${encodeURIComponent(error?.message ?? result?.message ?? "Could not save.")}#carrier-brokers`);
  revalidatePath(here);
  redirect(`${here}?bp_saved=${encodeURIComponent("Broker billing details saved.")}#carrier-brokers`);
}

type Supabase = Awaited<ReturnType<typeof createClient>>;

/** Gives the carrier an invoice code (e.g. "RRT") from its name when it has none. Best-effort. */
async function ensureInvoiceCode(supabase: Supabase, carrierId: string): Promise<void> {
  const { data: carrier } = await supabase.from("carriers").select("legal_name, dba_name, invoice_code").eq("id", carrierId).maybeSingle();
  if (!carrier || carrier.invoice_code) return;
  const { data: others } = await supabase.from("carriers").select("invoice_code").not("invoice_code", "is", null);
  const code = uniqueInvoiceCode(suggestInvoiceCode(carrier.dba_name || carrier.legal_name), (others ?? []).map((o) => String(o.invoice_code)));
  await supabase.from("carriers").update({ invoice_code: code }).eq("id", carrierId).is("invoice_code", null);
}

// "This carrier doesn't factor": sets the carrier's billing policy to Direct
// (the broker pays the carrier itself) through set_carrier_factoring_policy.
export async function setCarrierDoesNotFactor(carrierId: string) {
  await requireRole(OWNER_ADMIN_ROLES);
  await requireOperationalAccess();
  const here = `/carriers/${carrierId}`;
  const supabase = await createClient();
  const { data: carrier } = await supabase.from("carriers").select("updated_at").eq("id", carrierId).maybeSingle();
  if (!carrier) redirect(`${here}?bp_error=${encodeURIComponent("Carrier not found.")}#billing-setup`);
  const { data, error } = await supabase.rpc("set_carrier_factoring_policy", {
    p_carrier_id: carrierId,
    p_mode: "direct",
    p_reason: "Carrier does not factor (set from the carrier page).",
    p_expected_updated_at: carrier.updated_at,
    p_idempotency_key: null,
  });
  const result = data as { success?: boolean; message?: string } | null;
  if (error || result?.success === false) redirect(`${here}?bp_error=${encodeURIComponent(error?.message ?? result?.message ?? "Could not save.")}#billing-setup`);
  revalidatePath(here);
  redirect(`${here}?bp_saved=${encodeURIComponent("Set: this carrier doesn't factor (the broker pays the carrier directly).")}#billing-setup`);
}
