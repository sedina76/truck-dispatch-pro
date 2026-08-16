"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { insertRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

function loadValues(formData: FormData) {
  return {
    load_number: String(formData.get("load_number")),
    broker_id: emptyToNull(formData.get("broker_id")),
    customer_id: emptyToNull(formData.get("customer_id")),
    status: String(formData.get("status") || "draft"),
    commodity: emptyToNull(formData.get("commodity")),
    weight_lbs: toNumber(formData.get("weight_lbs")),
    equipment_type: emptyToNull(formData.get("equipment_type")),
    total_miles: toNumber(formData.get("total_miles")),
    rate: toNumber(formData.get("rate")) ?? 0,
    rate_confirmation_number: emptyToNull(formData.get("rate_confirmation_number")),
    special_instructions: emptyToNull(formData.get("special_instructions")),
  };
}

export async function createLoad(formData: FormData) {
  await insertRecord("loads", loadValues(formData), "/loads");
}

// Bespoke rather than the generic updateRecord() helper: this needs to know
// whether the save just transitioned the load into 'delivered' (to route
// back to the load's own page and surface the auto-generated invoice)
// versus a routine edit (which keeps the existing redirect-to-list
// behavior every other entity in this app uses). The invoice itself is
// created by the auto_generate_invoice_from_delivered_load() trigger
// (0022_auto_invoice_on_delivery.sql) as part of the same update statement
// -- this action never creates the invoice itself, only detects that the
// trigger's condition was just met so it can route somewhere useful.
export async function updateLoad(id: string, formData: FormData) {
  const supabase = await createClient();
  const { data: before } = await supabase.from("loads").select("status").eq("id", id).single();

  const values = loadValues(formData);
  const { error } = await supabase.from("loads").update(values).eq("id", id);
  if (error) throw new Error(error.message);

  await supabase.rpc("log_activity", { p_entity_type: "load", p_entity_id: id, p_action: "updated" });
  revalidatePath("/loads");
  revalidatePath(`/loads/${id}`);

  const justDelivered = before?.status !== "delivered" && values.status === "delivered";
  redirect(justDelivered ? `/loads/${id}?delivered=1` : "/loads");
}
