"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getCurrentOrgId } from "@/lib/actions/records";
import { createClient } from "@/lib/supabase/server";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { requireRole } from "@/lib/auth/require-role";

// Phase 2G.10 writer cutover: payment_terms_days goes to
// broker_financials, not brokers. credit_rating/average_days_to_pay are
// not part of brokerValues() at all -- confirmed by inspection that no
// form in this app has ever written them; nothing to cut over for those
// two fields. brokers.notes is a plain general-notes field, unrelated to
// this financial-isolation work, and stays on brokers untouched.
function brokerValues(formData: FormData) {
  const legalName = String(formData.get("legal_name") || formData.get("company_name") || "").trim();
  // Server-side authority for the "required" legal name: the HTML
  // `required` attribute on the form field is a UX nicety only -- a direct
  // POST to this Server Action skips it entirely, and brokers.legal_name
  // is NOT NULL but does not reject an empty string. This is the single
  // choke point both createBroker() and updateBroker() route through, so
  // fixing it here covers both without duplicating the check.
  if (!legalName) throw new Error("Legal name is required.");
  const status = String(formData.get("status") || "prospect");
  return {
    company_name: legalName,
    legal_name: legalName,
    dba_name: emptyToNull(formData.get("dba_name")),
    mc_number: emptyToNull(formData.get("mc_number")),
    dot_number: emptyToNull(formData.get("dot_number")),
    website: emptyToNull(formData.get("website")),
    contact_name: emptyToNull(formData.get("contact_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    status,
    onboarding_status: String(formData.get("onboarding_status") || "not_started"),
    is_blacklisted: status === "do_not_use",
    notes: emptyToNull(formData.get("notes")),
  };
}

// NOTE: requires 0067 applied (broker_financials must exist) -- ships in
// the same deploy as 0067/0068, never before.
async function writeBrokerFinancials(brokerId: string, organizationId: string, formData: FormData) {
  const supabase = await createClient();
  const { error } = await supabase.from("broker_financials").upsert(
    { broker_id: brokerId, organization_id: organizationId, payment_terms_days: toNumber(formData.get("payment_terms_days")) ?? 30,
      credit_status: String(formData.get("credit_status") || "review"), credit_limit: toNumber(formData.get("credit_limit")),
      payment_method: emptyToNull(formData.get("payment_method")), financial_notes: emptyToNull(formData.get("financial_notes")) },
    { onConflict: "broker_id" }
  );
  if (error) throw new Error(error.message);
}

// Bespoke rather than insertRecord() -- see carriers/actions.ts.
export async function createBroker(formData: FormData) {
  const role = await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data, error } = await supabase.from("brokers").insert({ ...brokerValues(formData), organization_id: organizationId }).select("id").single();
  if (error) throw new Error(error.message);
  if (role === "owner" || role === "admin") {
    await writeBrokerFinancials(data.id, organizationId, formData);
  } else {
    const { error: financialError } = await supabase.from("broker_financials").insert({
      broker_id: data.id,
      organization_id: organizationId,
      payment_terms_days: 30,
      credit_status: "review",
    });
    if (financialError) throw new Error(financialError.message);
  }
  await supabase.rpc("log_activity", { p_entity_type: "broker", p_entity_id: data.id, p_action: "broker_created" });
  revalidatePath("/brokers");
  redirect("/brokers");
}

export async function updateBroker(id: string, formData: FormData) {
  const role = await requireRole(["owner", "admin", "dispatcher", "accountant"]);
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  // Compute (and validate) the brokers-table payload before ANY mutation
  // runs -- owner/admin write financials first below, so validating late
  // (at the .update() call site) would let a blank-legal-name submission
  // commit the financial half before throwing. Accountants never touch
  // this table -- their legal_name field is `disabled` in the shared
  // Profile form, so it's simply absent from formData -- skip validation
  // for them entirely rather than reject a financial-only save over a
  // field they never submitted.
  const values = role !== "accountant" ? brokerValues(formData) : null;
  if (role === "owner" || role === "admin" || role === "accountant") await writeBrokerFinancials(id, organizationId, formData);
  if (values) {
    const { error } = await supabase.from("brokers").update(values).eq("id", id);
    if (error) throw new Error(error.message);
  }
  await supabase.rpc("log_activity", {
    p_entity_type: "broker",
    p_entity_id: id,
    p_action: "broker_updated",
    p_changes: { categories: role === "dispatcher" ? ["operational"] : role === "accountant" ? ["financial"] : ["operational", "financial"] },
  });
  revalidatePath(`/brokers/${id}`);
  redirect(`/brokers/${id}`);
}

export async function saveBrokerContact(brokerId: string, formData: FormData) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_broker_contact", {
    p_broker_id: brokerId, p_contact_id: emptyToNull(formData.get("contact_id")),
    p_contact_type: String(formData.get("contact_type") || "general"), p_name: String(formData.get("name") || ""),
    p_title: String(formData.get("title") || ""), p_department: String(formData.get("department") || ""),
    p_email: String(formData.get("email") || ""), p_phone: String(formData.get("phone") || ""),
    p_extension: String(formData.get("extension") || ""), p_is_primary: formData.get("is_primary") === "on",
    p_notes: String(formData.get("notes") || ""),
  });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}`);
}

export async function deleteBrokerContact(brokerId: string, contactId: string) {
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_broker_contact", { p_broker_id: brokerId, p_contact_id: contactId });
  if (error) throw new Error(error.message);
  revalidatePath(`/brokers/${brokerId}`);
}

export async function archiveBroker(id: string) {
  await requireRole(["owner", "admin"]); const supabase=await createClient();
  const { error }=await supabase.rpc("archive_broker",{p_broker_id:id}); if(error) throw new Error(error.message);
  revalidatePath("/brokers"); revalidatePath(`/brokers/${id}`);
}
export async function restoreBroker(id: string) {
  await requireRole(["owner", "admin"]); const supabase=await createClient();
  const { error }=await supabase.rpc("restore_broker",{p_broker_id:id}); if(error) throw new Error(error.message);
  revalidatePath("/brokers"); revalidatePath(`/brokers/${id}`);
}
export async function deleteBroker(id: string): Promise<{ok:true}|{ok:false;error:string}> {
  await requireRole(["owner", "admin"]); const supabase=await createClient();
  const {data,error}=await supabase.rpc("delete_broker_safely",{p_broker_id:id});
  if(error) return {ok:false,error:error.message.includes("not found")?"Broker not found.":error.message};
  const result=data as {deletion_status:string;message?:string};
  if(result.deletion_status!=="deleted") return {ok:false,error:result.message??"This broker cannot be permanently deleted."};
  revalidatePath("/brokers"); return {ok:true};
}
