"use server";

import { revalidatePath } from "next/cache";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { redirect } from "next/navigation";
import { updateRecord, getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { emptyToNull, toNumber } from "@/lib/utils/form";

// Phase 2G.10 writer cutover: payment_terms_days goes to
// customer_financials, not customers, written BEFORE/around the base-table
// write below (same reasoning as carriers/actions.ts).
function customerValues(formData: FormData) {
  return {
    company_name: String(formData.get("company_name")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    is_active: formData.get("is_active") === "on",
  };
}

// NOTE: requires 0067 applied (customer_financials must exist) -- ships in
// the same deploy as 0067/0068, never before.
async function writeCustomerFinancials(customerId: string, organizationId: string, formData: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("customer_financials").upsert(
    { customer_id: customerId, organization_id: organizationId, payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 30 },
    { onConflict: "customer_id" }
  );
  if (error) throw new Error(error.message);
}

// Bespoke rather than insertRecord() -- see carriers/actions.ts's
// createCarrier for why (redirect() inside the helper would abort before
// a second write could run).
export async function createCustomer(formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data, error } = await supabase.from("customers").insert({ ...customerValues(formData), organization_id: organizationId }).select("id").single();
  if (error) throw new Error(error.message);
  await writeCustomerFinancials(data.id, organizationId, formData);
  await supabase.rpc("log_activity", { p_entity_type: "customer", p_entity_id: data.id, p_action: "created" });
  revalidatePath("/customers");
  redirect("/customers");
}

export async function updateCustomer(id: string, formData: FormData) {
  const organizationId = await getCurrentOrgId();
  await writeCustomerFinancials(id, organizationId, formData);
  await updateRecord("customers", id, customerValues(formData), "/customers");
}
