"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { updateRecord, getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Phase 2G.10 writer cutover: payment_terms_days goes to
// broker_financials, not brokers. credit_rating/average_days_to_pay are
// not part of brokerValues() at all -- confirmed by inspection that no
// form in this app has ever written them; nothing to cut over for those
// two fields. brokers.notes is a plain general-notes field, unrelated to
// this financial-isolation work, and stays on brokers untouched.
function brokerValues(formData: FormData) {
  return {
    company_name: String(formData.get("company_name")),
    mc_number: emptyToNull(formData.get("mc_number")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    is_blacklisted: formData.get("is_blacklisted") === "on",
    notes: emptyToNull(formData.get("notes")),
  };
}

// NOTE: requires 0067 applied (broker_financials must exist) -- ships in
// the same deploy as 0067/0068, never before.
async function writeBrokerFinancials(brokerId: string, organizationId: string, formData: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("broker_financials").upsert(
    { broker_id: brokerId, organization_id: organizationId, payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 30 },
    { onConflict: "broker_id" }
  );
  if (error) throw new Error(error.message);
}

// Bespoke rather than insertRecord() -- see carriers/actions.ts.
export async function createBroker(formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data, error } = await supabase.from("brokers").insert({ ...brokerValues(formData), organization_id: organizationId }).select("id").single();
  if (error) throw new Error(error.message);
  await writeBrokerFinancials(data.id, organizationId, formData);
  await supabase.rpc("log_activity", { p_entity_type: "broker", p_entity_id: data.id, p_action: "created" });
  revalidatePath("/brokers");
  redirect("/brokers");
}

export async function updateBroker(id: string, formData: FormData) {
  const organizationId = await getCurrentOrgId();
  await writeBrokerFinancials(id, organizationId, formData);
  await updateRecord("brokers", id, brokerValues(formData), "/brokers");
}
