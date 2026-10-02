"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRole, OWNER_ADMIN_ROLES } from "@/lib/auth/require-role";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { brokerPaysResultMessage, type BrokerPaysResult } from "@/lib/carriers/broker-pays";

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
  revalidatePath(here);
  revalidatePath("/dispatch-fee-invoices");
  revalidatePath("/billing/ready-to-bill");
  redirect(`${here}?bp_saved=${encodeURIComponent(brokerPaysResultMessage(data as BrokerPaysResult))}`);
}
