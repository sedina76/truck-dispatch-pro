"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { emptyToNull } from "@/lib/utils/form";
import { resolveStructuredRpcResult, type StructuredRpcResult } from "@/lib/factoring/rpc-result";
import { validateOptionalEmail, validatePercent, validateRecourseType, validateSubmissionSetup, validateNoaApproval } from "@/lib/factoring/validation";
import { isUuid } from "@/lib/factoring/carrier-invoice-issuance";

// "Set up factoring" on a carrier's invoice page: the six steps of Settings ->
// Factoring in one form, run in the same order through the same database
// checks (owner/admin; every RPC re-checks the role, organization, carrier
// and readiness itself): factoring company -> link to the carrier (terms) ->
// remit-to + how it takes paperwork -> approve the NOA -> carrier's default
// -> switch the carrier to "Factors". Each step is skipped when already done,
// so a retry after a refusal picks up where it stopped. Verified end to end on
// the production twin (supabase/TEST_INVOICE_FACTORING_SETUP.sql).

export type FactoringSetupResult = { ok: true } | { ok: false; error: string };

const clean = (m: string) => m.replace(/^[a-z_]+:\s*/, "").replace(/^./, (c) => c.toUpperCase());

async function ownerAdmin() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;
  const [{ data: profile }, { data: org }] = await Promise.all([supabase.from("profiles").select("role").eq("id", user.id).maybeSingle(), supabase.rpc("current_org_id")]);
  if (!org || (profile?.role !== "owner" && profile?.role !== "admin")) return null;
  return { supabase, org: String(org) };
}

function refresh(carrierId: string, invoiceId: string) {
  revalidatePath(`/carrier-invoices/${invoiceId}`);
  revalidatePath(`/carriers/${carrierId}`);
  revalidatePath("/settings/factoring");
}

export async function setUpCarrierFactoring(carrierId: string, invoiceId: string, formData: FormData): Promise<FactoringSetupResult> {
  if (!isUuid(carrierId) || !isUuid(invoiceId)) return { ok: false, error: "Carrier not found." };
  const s = await ownerAdmin();
  if (!s) return { ok: false, error: "Only an owner or admin can set up factoring." };
  const { supabase, org } = s;

  const { data: carrier } = await supabase.from("carriers").select("id, legal_name, factoring_mode, updated_at, is_active").eq("id", carrierId).maybeSingle();
  if (!carrier) return { ok: false, error: "Carrier not found." };

  // 1. Factoring company: an existing one, or a new one from the form.
  let companyId = String(formData.get("company_id") ?? "");
  if (companyId === "new" || !companyId) {
    const name = String(formData.get("company_name") ?? "").trim();
    if (!name) return { ok: false, error: "Enter the factoring company's name (or pick one from the list)." };
    const email = validateOptionalEmail("Factoring company email", formData.get("company_email") as string | null);
    if (!email.ok) return email;
    const { data, error } = await supabase
      .from("factoring_companies")
      .insert({
        organization_id: org,
        name,
        email: email.value,
        phone: emptyToNull(formData.get("company_phone")),
        address_line1: emptyToNull(formData.get("company_address")),
        city: emptyToNull(formData.get("company_city")),
        state: emptyToNull(formData.get("company_state")),
        postal_code: emptyToNull(formData.get("company_zip")),
      })
      .select("id")
      .single();
    if (error || !data) return { ok: false, error: error?.code === "23505" ? "A factoring company with that name already exists -- pick it from the list." : `Could not add the factoring company${error ? `: ${error.message}` : "."}` };
    companyId = String(data.id);
  } else if (!isUuid(companyId)) {
    return { ok: false, error: "Choose a factoring company." };
  }
  const { data: company } = await supabase.from("factoring_companies").select("id, name, is_active").eq("id", companyId).maybeSingle();
  if (!company) return { ok: false, error: "Factoring company not found." };
  if (!company.is_active) return { ok: false, error: `${company.name} is turned off in Settings -> Factoring. Turn it back on or pick another.` };

  // 2. Link it to the carrier (reuse an active link with this company).
  const { data: existing } = await supabase
    .from("factoring_relationships")
    .select("id, is_default, is_active, noa_approved")
    .eq("carrier_id", carrierId)
    .eq("factoring_company_id", companyId)
    .eq("is_active", true)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  let relId = existing?.id ? String(existing.id) : "";
  if (!relId) {
    const advance = validatePercent("Advance %", formData.get("advance_pct"));
    if (!advance.ok) return advance;
    const fee = validatePercent("Factoring fee %", formData.get("fee_pct"));
    if (!fee.ok) return fee;
    const reserve = validatePercent("Reserve %", formData.get("reserve_pct") ?? "0");
    if (!reserve.ok) return reserve;
    const recourse = validateRecourseType(formData.get("recourse_type"));
    if (!recourse.ok) return recourse;
    const { data, error } = await supabase
      .from("factoring_relationships")
      .insert({
        organization_id: org,
        factoring_company_id: companyId,
        carrier_id: carrierId,
        default_advance_percentage: advance.value,
        default_factoring_fee_percentage: fee.value,
        default_reserve_percentage: reserve.value,
        fee_timing: "deducted_at_funding",
        recourse_type: recourse.value,
        effective_from: new Date().toISOString().slice(0, 10),
      })
      .select("id")
      .single();
    if (error || !data) return { ok: false, error: `Could not link ${company.name} to the carrier${error ? `: ${error.message}` : "."}` };
    relId = String(data.id);
  }

  // 3. Where brokers send payment + how the factor takes paperwork.
  const setup = validateSubmissionSetup(
    {
      remittance_instructions: formData.get("remittance_instructions"),
      remittance_reference: null,
      submission_method: formData.get("submission_method"),
      submission_destination_email: formData.get("submission_email"),
      submission_notes: null,
    },
    null
  );
  if (!setup.ok) return setup;
  if (!setup.values.remittance_instructions) return { ok: false, error: "Enter where brokers must send payment (the factor's remit-to)." };
  if (!setup.values.submission_method) return { ok: false, error: "Choose how the factor takes paperwork." };
  {
    const { error } = await supabase.from("factoring_relationships").update(setup.values).eq("id", relId);
    if (error) return { ok: false, error: `Could not save the remit-to and paperwork method: ${error.message}` };
  }

  // 4. Notice of Assignment.
  if (!existing?.noa_approved) {
    if (formData.get("noa_confirmed") !== "on") return { ok: false, error: "Confirm you have the signed Notice of Assignment." };
    const noa = validateNoaApproval({
      noa_reference: formData.get("noa_reference"),
      noa_effective_date: formData.get("noa_effective_date"),
      noa_template_text: formData.get("noa_text"),
      noa_document_id: null,
    });
    if (!noa.ok) return noa;
    const { data, error } = await supabase.rpc("approve_factoring_relationship_noa", {
      p_relationship_id: relId,
      p_noa_reference: noa.values.reference,
      p_noa_effective_date: noa.values.effectiveDate,
      p_noa_template_text: noa.values.templateText,
      p_noa_document_id: null,
    });
    if (error) return { ok: false, error: clean(error.message) };
    if (!data || (data as { success?: boolean }).success !== true) return { ok: false, error: "The Notice of Assignment could not be approved." };
  }

  // 5. The carrier's default factor.
  if (!existing?.is_default) {
    const { data, error } = await supabase.rpc("set_default_factoring_relationship", { p_relationship_id: relId });
    const r = resolveStructuredRpcResult(data as StructuredRpcResult | null, error);
    if (!r.ok) return { ok: false, error: clean(r.error) };
  }

  // 6. Switch the carrier to "Factors".
  if (carrier.factoring_mode !== "factored") {
    const { data: fresh } = await supabase.from("carriers").select("updated_at").eq("id", carrierId).maybeSingle();
    const { data, error } = await supabase.rpc("set_carrier_factoring_policy", {
      p_carrier_id: carrierId,
      p_mode: "factored",
      p_reason: `Factors with ${company.name} (set up from the invoice page)`,
      p_expected_updated_at: fresh?.updated_at ?? carrier.updated_at,
      p_idempotency_key: null,
    });
    const r = resolveStructuredRpcResult(data as StructuredRpcResult | null, error);
    if (!r.ok) return { ok: false, error: clean(r.error) };
  }

  refresh(carrierId, invoiceId);
  return { ok: true };
}

/** "Stop factoring": the carrier goes back to "Doesn't factor" (brokers pay the carrier). */
export async function stopCarrierFactoring(carrierId: string, invoiceId: string): Promise<FactoringSetupResult> {
  if (!isUuid(carrierId) || !isUuid(invoiceId)) return { ok: false, error: "Carrier not found." };
  const s = await ownerAdmin();
  if (!s) return { ok: false, error: "Only an owner or admin can change factoring." };
  const { data: carrier } = await s.supabase.from("carriers").select("updated_at, factoring_mode").eq("id", carrierId).maybeSingle();
  if (!carrier) return { ok: false, error: "Carrier not found." };
  if (carrier.factoring_mode === "direct") return { ok: true };
  const { data, error } = await s.supabase.rpc("set_carrier_factoring_policy", {
    p_carrier_id: carrierId,
    p_mode: "direct",
    p_reason: "Stopped factoring (from the invoice page)",
    p_expected_updated_at: carrier.updated_at,
    p_idempotency_key: null,
  });
  const r = resolveStructuredRpcResult(data as StructuredRpcResult | null, error);
  if (!r.ok) return { ok: false, error: clean(r.error) };
  refresh(carrierId, invoiceId);
  return { ok: true };
}
