"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { updateRecord, getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Phase 2G.10 writer cutover: dispatch_fee_percentage/payment_terms_days
// go to carrier_financials, not carriers, written BEFORE the generic
// insertRecord()/updateRecord() helpers below (which redirect() -- nothing
// can run after them). factoring_company_name is not part of
// carrierValues() at all -- confirmed by inspection that no form in this
// app has ever written it; nothing to cut over for that field.
function carrierValues(formData: FormData) {
  return {
    legal_name: String(formData.get("legal_name")),
    dba_name: emptyToNull(formData.get("dba_name")),
    mc_number: emptyToNull(formData.get("mc_number")),
    dot_number: emptyToNull(formData.get("dot_number")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
  };
}

// NOTE: requires 0067 applied (carrier_financials must exist) -- ships in
// the same deploy as 0067/0068, never before.
async function writeCarrierFinancials(carrierId: string, organizationId: string, formData: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("carrier_financials").upsert(
    {
      carrier_id: carrierId,
      organization_id: organizationId,
      dispatch_fee_percentage: toNumber(formData.get("dispatch_fee_percentage")) ?? 10,
      payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 7,
    },
    { onConflict: "carrier_id" }
  );
  if (error) throw new Error(error.message);
}

// Bespoke rather than the generic insertRecord() helper (which redirects
// internally, so nothing could run after it) -- replicates its exact
// insert/log_activity/revalidatePath/redirect sequence, plus the
// carrier_financials write in between.
export async function createCarrier(formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data, error } = await supabase.from("carriers").insert({ ...carrierValues(formData), organization_id: organizationId }).select("id").single();
  if (error) throw new Error(error.message);
  await writeCarrierFinancials(data.id, organizationId, formData);
  await supabase.rpc("log_activity", { p_entity_type: "carrier", p_entity_id: data.id, p_action: "created" });
  revalidatePath("/carriers");
  redirect("/carriers");
}

export async function updateCarrier(id: string, formData: FormData) {
  const organizationId = await getCurrentOrgId();
  await writeCarrierFinancials(id, organizationId, formData);
  await updateRecord("carriers", id, carrierValues(formData), "/carriers");
}
