"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { FINANCIAL_ROLES } from "@/lib/auth/require-role";
import { emptyToNull } from "@/lib/utils/form";
import {
  validateOptionalEmail,
  validateOptionalWebsite,
  validatePercent,
  validateOptionalNonNegative,
  validateFeeTiming,
  validateRecourseType,
  validateEffectiveRange,
} from "@/lib/factoring/validation";

const PATH = "/settings/factoring";

export type FactoringActionResult = { ok: true } | { ok: false; error: string };

// ---------------------------------------------------------------------------
// Every mutation below independently re-derives user/org/role from the
// authenticated session (never trusts a client-supplied organization_id,
// spec section 16) then re-verifies the row being acted on actually
// belongs to THAT organization before touching it (spec section 15/16) --
// same shape as requireEmailAdmin()/requireExceptionOwnership() elsewhere
// in this app. FINANCIAL_ROLES (owner/admin/dispatcher/accountant), not
// owner/admin-only -- spec section 14 grants this whole area to every
// financial role, matching the Billing nav section's own tier exactly.
// RLS (0071) is the real, unconditional backstop underneath all of this.
// ---------------------------------------------------------------------------
async function requireFactoringAccess(): Promise<{ organizationId: string; userId: string } | { error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { error: "Not authenticated." };

  let organizationId: string;
  try {
    organizationId = await getCurrentOrgId();
  } catch {
    return { error: "No organization on this account." };
  }

  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !FINANCIAL_ROLES.includes(profile.role)) {
    return { error: "You do not have access to factoring settings." };
  }

  return { organizationId, userId: user.id };
}

// entity_type (public.entity_type, 0001) is a closed enum with no
// 'factoring_company'/'factoring_relationship' value, and adding one is a
// migration this phase is explicitly not to make just for logging (the
// standing instruction: no new migration unless a genuine schema defect
// is found). 'organization' is the same generic bucket
// settings/email/actions.ts already uses for its own sub-features
// (domains/senders) that likewise have no dedicated entity_type -- not a
// new convention, the existing one for exactly this situation.
async function logFactoringActivity(organizationId: string, action: string, changes: Record<string, unknown>) {
  const service = createServiceRoleClient();
  const { error } = await service.rpc("log_activity", {
    p_entity_type: "organization",
    p_entity_id: organizationId,
    p_action: action,
    p_changes: changes,
    p_organization_id: organizationId,
  });
  if (error) console.error("[settings/factoring] log_activity failed:", error);
}

// Postgres error codes surfaced by PostgREST -- mapped to the human
// -readable messages spec section 17 requires, never shown raw.
function friendlyDbError(error: { code?: string; message: string }, context: "company_delete" | "company_deactivate" | "relationship" | "generic"): string {
  if (error.code === "23503" && context === "company_delete") {
    return "This factoring company cannot be deleted because it has existing history. Deactivate it instead.";
  }
  // guard_factoring_company_deactivation() (0072) raises a plain `raise
  // exception` (SQLSTATE P0001) whose message text IS already the
  // friendly sentence spec Phase 2H.3A section 1 specifies verbatim --
  // this branch exists to make that intentional (not an accident of the
  // generic fallback below), and to keep this call site immune if some
  // OTHER, genuinely raw P0001 ever needed different handling later.
  if (error.code === "P0001" && context === "company_deactivate") {
    return error.message;
  }
  if (error.code === "23505") {
    return "That value is already in use.";
  }
  if (error.code === "23514") {
    return context === "relationship" ? "One of the values entered is outside the allowed range." : "One of the values entered is invalid.";
  }
  return error.message;
}

// ---------------------------------------------------------------------------
// Factoring companies
// ---------------------------------------------------------------------------

function companyValuesFromForm(formData: FormData): { ok: true; values: Record<string, unknown> } | { ok: false; error: string } {
  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { ok: false, error: "Company name is required." };

  const email = validateOptionalEmail("Email", formData.get("email") as string | null);
  if (!email.ok) return email;
  const website = validateOptionalWebsite("Website", formData.get("website") as string | null);
  if (!website.ok) return website;

  return {
    ok: true,
    values: {
      name,
      legal_name: emptyToNull(formData.get("legal_name")),
      contact_name: emptyToNull(formData.get("contact_name")),
      email: email.value,
      phone: emptyToNull(formData.get("phone")),
      website: website.value,
      address_line1: emptyToNull(formData.get("address_line1")),
      city: emptyToNull(formData.get("city")),
      state: emptyToNull(formData.get("state")),
      postal_code: emptyToNull(formData.get("postal_code")),
      account_number: emptyToNull(formData.get("account_number")),
      notes: emptyToNull(formData.get("notes")),
    },
  };
}

export async function createFactoringCompany(formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };
  const parsed = companyValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  const service = createServiceRoleClient();
  const { data, error } = await service.from("factoring_companies").insert({ ...parsed.values, organization_id: auth.organizationId }).select("id").single();
  if (error) return { ok: false, error: friendlyDbError(error, "generic") };

  await logFactoringActivity(auth.organizationId, "factoring_company_created", { factoring_company_id: data.id, name: parsed.values.name });
  revalidatePath(PATH);
  return { ok: true };
}

export async function updateFactoringCompany(companyId: string, formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };
  const parsed = companyValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  const service = createServiceRoleClient();
  const { data: existing } = await service.from("factoring_companies").select("id").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring company not found." };

  const { error } = await service.from("factoring_companies").update(parsed.values).eq("id", companyId);
  if (error) return { ok: false, error: friendlyDbError(error, "generic") };

  await logFactoringActivity(auth.organizationId, "factoring_company_updated", { factoring_company_id: companyId, name: parsed.values.name });
  revalidatePath(PATH);
  return { ok: true };
}

// Deactivation (isActive = false) can be rejected by
// guard_factoring_company_deactivation() (0072) when this company owns
// the org's current active default relationship -- surfaced as a clean
// typed-result message via friendlyDbError's "company_deactivate"
// context, never a raw Postgres error or a route-boundary exception. The
// trigger deliberately does not offer to clear the default or deactivate
// the relationship for the user; the fix is to set a different
// relationship as default first (setDefaultFactoringRelationship), then
// retry deactivating this company.
export async function setFactoringCompanyActive(companyId: string, isActive: boolean): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const service = createServiceRoleClient();
  const { data: existing } = await service.from("factoring_companies").select("id, name").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring company not found." };

  const { error } = await service.from("factoring_companies").update({ is_active: isActive }).eq("id", companyId);
  if (error) return { ok: false, error: friendlyDbError(error, isActive ? "generic" : "company_deactivate") };

  await logFactoringActivity(auth.organizationId, isActive ? "factoring_company_reactivated" : "factoring_company_deactivated", { factoring_company_id: companyId, name: existing.name });
  revalidatePath(PATH);
  return { ok: true };
}

// Structurally backstopped by 0071's ON DELETE RESTRICT from
// factoring_relationships/factored_invoices -- a company with any history
// simply cannot be deleted at the database level; this only translates
// that into the friendly message spec section 17 asks for, it doesn't
// weaken or route around the restriction.
export async function deleteFactoringCompany(companyId: string): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const service = createServiceRoleClient();
  const { data: existing } = await service.from("factoring_companies").select("id, name").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring company not found." };

  const { error } = await service.from("factoring_companies").delete().eq("id", companyId);
  if (error) return { ok: false, error: friendlyDbError(error, "company_delete") };

  await logFactoringActivity(auth.organizationId, "factoring_company_deleted", { factoring_company_id: companyId, name: existing.name });
  revalidatePath(PATH);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Factoring relationships
// ---------------------------------------------------------------------------

function relationshipValuesFromForm(formData: FormData): { ok: true; values: Record<string, unknown> } | { ok: false; error: string } {
  const advance = validatePercent("Advance percentage", formData.get("default_advance_percentage"));
  if (!advance.ok) return advance;
  const fee = validatePercent("Factoring fee percentage", formData.get("default_factoring_fee_percentage"));
  if (!fee.ok) return fee;
  const reserve = validatePercent("Reserve percentage", formData.get("default_reserve_percentage"));
  if (!reserve.ok) return reserve;

  const feeTiming = validateFeeTiming(formData.get("fee_timing"));
  if (!feeTiming.ok) return feeTiming;
  const recourseType = validateRecourseType(formData.get("recourse_type"));
  if (!recourseType.ok) return recourseType;

  const minimumFee = validateOptionalNonNegative("Minimum fee", formData.get("minimum_fee"));
  if (!minimumFee.ok) return minimumFee;
  const wireFee = validateOptionalNonNegative("Wire fee", formData.get("wire_fee"));
  if (!wireFee.ok) return wireFee;
  const achFee = validateOptionalNonNegative("ACH fee", formData.get("ach_fee"));
  if (!achFee.ok) return achFee;
  const otherFee = validateOptionalNonNegative("Other default fee", formData.get("other_fee_default"));
  if (!otherFee.ok) return otherFee;

  const effectiveFrom = emptyToNull(formData.get("effective_from"));
  const effectiveTo = emptyToNull(formData.get("effective_to"));
  const range = validateEffectiveRange(effectiveFrom, effectiveTo);
  if (!range.ok) return range;

  const paymentTermsDaysRaw = emptyToNull(formData.get("payment_terms_days"));
  const paymentTermsDays = paymentTermsDaysRaw === null ? null : Number(paymentTermsDaysRaw);
  if (paymentTermsDays !== null && (Number.isNaN(paymentTermsDays) || paymentTermsDays < 0)) {
    return { ok: false, error: "Payment terms (days) must be a non-negative number." };
  }

  return {
    ok: true,
    values: {
      relationship_name: emptyToNull(formData.get("relationship_name")),
      default_advance_percentage: advance.value,
      default_factoring_fee_percentage: fee.value,
      default_reserve_percentage: reserve.value,
      fee_timing: feeTiming.value,
      recourse_type: recourseType.value,
      payment_terms_days: paymentTermsDays,
      minimum_fee: minimumFee.value,
      wire_fee: wireFee.value,
      ach_fee: achFee.value,
      other_fee_default: otherFee.value,
      effective_from: effectiveFrom ?? new Date().toISOString().slice(0, 10),
      effective_to: effectiveTo,
    },
  };
}

export async function createFactoringRelationship(companyId: string, formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const service = createServiceRoleClient();
  const { data: company } = await service.from("factoring_companies").select("id, name").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!company) return { ok: false, error: "Factoring company not found." };

  const parsed = relationshipValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  // Deliberately never sets is_default here (spec section 6 treats "Set
  // Default" as its own distinct action/step, not a create-time option) --
  // every new relationship starts is_default = false, is_active = true
  // (0071's own column defaults), so it can never collide with
  // factoring_relationships_one_default_per_org on insert.
  const { data, error } = await service.from("factoring_relationships").insert({ ...parsed.values, organization_id: auth.organizationId, factoring_company_id: companyId }).select("id").single();
  if (error) return { ok: false, error: friendlyDbError(error, "relationship") };

  await logFactoringActivity(auth.organizationId, "factoring_relationship_created", { factoring_relationship_id: data.id, factoring_company_id: companyId, company_name: company.name });
  revalidatePath(PATH);
  return { ok: true };
}

export async function updateFactoringRelationship(relationshipId: string, formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const service = createServiceRoleClient();
  const { data: existing } = await service.from("factoring_relationships").select("id").eq("id", relationshipId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring relationship not found." };

  const parsed = relationshipValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  // Terms-only update, in place -- 0071's snapshot design (advance/fee/
  // reserve percentages + fee_timing copied onto factored_invoices at
  // submission time, Phase 2H.4) means this can never rewrite an
  // already-submitted transaction's numbers; only future submissions that
  // read this relationship's CURRENT values are affected. is_default/
  // is_active are separate actions below, never touched here.
  const { error } = await service.from("factoring_relationships").update(parsed.values).eq("id", relationshipId);
  if (error) return { ok: false, error: friendlyDbError(error, "relationship") };

  await logFactoringActivity(auth.organizationId, "factoring_relationship_updated", { factoring_relationship_id: relationshipId });
  revalidatePath(PATH);
  return { ok: true };
}

// Phase 2H.3A: a single atomic RPC (0072_factoring_default_relationship_rpc.sql
// -- proposed, not yet applied), not the two-sequential-update "clear then
// set" pattern this used to share with setDefaultEmailSender/
// setDefaultEmailDomain. Phase 2H.4 will treat the org's default
// relationship as the authoritative source for financial snapshots on
// every new factored invoice, so the brief "nobody is default"/"who wins"
// windows that pattern tolerates for a cosmetic email preference are not
// acceptable here. Called through the CALLER'S OWN session client (never
// the service-role client) -- the RPC is SECURITY INVOKER specifically so
// factoring_relationships' RLS applies to it exactly as it would to a
// direct query, and org/role are derived from that session inside the
// function itself (current_org_id()/has_role()), never trusted from this
// action's own arguments.
export async function setDefaultFactoringRelationship(relationshipId: string): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_default_factoring_relationship", { p_relationship_id: relationshipId });
  // The function's own raise exception messages ARE the human-readable
  // messages (spec section 7's exact three strings, plus the inactive
  // -company one) -- passed straight through rather than re-mapped, since
  // there's no raw constraint name to hide here (the function's checks
  // preempt every constraint it could otherwise hit).
  if (error) return { ok: false, error: error.message };

  const service = createServiceRoleClient();
  const { data: relationship } = await service.from("factoring_relationships").select("factoring_company_id").eq("id", relationshipId).maybeSingle();
  await logFactoringActivity(auth.organizationId, "factoring_relationship_set_default", { factoring_relationship_id: relationshipId, factoring_company_id: relationship?.factoring_company_id });
  revalidatePath(PATH);
  return { ok: true };
}

// Deactivating the CURRENT default is blocked outright (spec section 9 /
// 17's own required message) rather than silently auto-clearing
// is_default alongside is_active -- 0071's
// factoring_relationships_default_must_be_active CHECK would force that
// combination anyway, but surfacing it as a hard stop here means a user
// is never surprised to discover, only after the fact, that their
// organization quietly lost its default. To deactivate the current
// default, set a different relationship as default first (which clears
// this one's is_default), then deactivate it.
export async function setFactoringRelationshipActive(relationshipId: string, isActive: boolean): Promise<FactoringActionResult> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const service = createServiceRoleClient();
  const { data: existing } = await service.from("factoring_relationships").select("id, is_default, factoring_company_id").eq("id", relationshipId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring relationship not found." };
  if (!isActive && existing.is_default) {
    return { ok: false, error: "This factoring relationship cannot be deactivated while it is the default." };
  }

  const { error } = await service.from("factoring_relationships").update({ is_active: isActive }).eq("id", relationshipId);
  if (error) return { ok: false, error: friendlyDbError(error, "relationship") };

  await logFactoringActivity(auth.organizationId, isActive ? "factoring_relationship_reactivated" : "factoring_relationship_deactivated", { factoring_relationship_id: relationshipId, factoring_company_id: existing.factoring_company_id });
  revalidatePath(PATH);
  return { ok: true };
}
