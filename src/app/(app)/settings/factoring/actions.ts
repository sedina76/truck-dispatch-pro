"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { FINANCIAL_ROLES, OWNER_ADMIN_ROLES, type OrgRole } from "@/lib/auth/require-role";
import { emptyToNull } from "@/lib/utils/form";
import type { CarrierFactoringMode } from "@/lib/factoring/types";
import { resolveStructuredRpcResult, type StructuredRpcResult } from "@/lib/factoring/rpc-result";
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
// authenticated session (never trusts a client-supplied organization_id)
// then re-verifies the row being acted on actually belongs to THAT
// organization before touching it -- same shape as
// requireEmailAdmin()/requireExceptionOwnership() elsewhere in this app.
// RLS (0071/0140) is the real, unconditional backstop underneath all of
// this -- these functions are UX (a clean message before a round trip),
// never the actual boundary.
//
// Phase 3B.1.3 (Section C): every mutation in this file executes through
// the CALLER'S OWN authenticated session (createClient(), never
// createServiceRoleClient()) -- this server never treats "holds an
// authenticated web session" as if it were a trusted migration/service
// context; that posture is reserved for actual migrations and the
// SECURITY DEFINER RPCs below, which derive their own authorization from
// auth.uid()/current_org_id()/has_role() internally, never from anything
// this file passes them.
//
// Phase 3B.1.4 (Section A) authorization matrix, replacing the original
// Phase 2H.3 "every FINANCIAL_ROLES member may do everything here" design
// (0071's own RLS, since narrowed by migration 0140):
//   requireFactoringAccess()            -- READ-ONLY gate (all FINANCIAL_
//                                           ROLES: owner/admin/dispatcher/
//                                           accountant may still VIEW).
//   requireFactoringEditAccess()        -- owner/admin/accountant may edit
//                                           ORDINARY relationship terms
//                                           (advance/fee/reserve/timing/
//                                           payment terms) and toggle
//                                           is_active. Dispatcher excluded.
//   requireOwnerAdminFactoringAccess()  -- owner/admin only: create/delete
//                                           a company or relationship,
//                                           change company identity, set
//                                           default, approve NOA, change
//                                           factoring policy.
// Dispatcher oversight means visibility across authorized carriers, not
// authority to configure where carrier receivables are sent (Section A).
// ---------------------------------------------------------------------------
async function requireFactoringAccess(): Promise<{ organizationId: string; userId: string; role: OrgRole } | { error: string }> {
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

  return { organizationId, userId: user.id, role: profile.role as OrgRole };
}

const EDIT_ROLES: OrgRole[] = ["owner", "admin", "accountant"];

// owner/admin/accountant -- ordinary relationship terms + is_active only.
// Dispatcher is excluded (Section A: view-only, never configuration).
async function requireFactoringEditAccess(): Promise<{ organizationId: string; userId: string } | { error: string }> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return auth;
  if (!EDIT_ROLES.includes(auth.role)) {
    return { error: "Only an owner, admin, or accountant may make this change." };
  }
  return auth;
}

// Owner/admin-only gate -- app-layer mirror of what the protected RPCs
// below (set_carrier_factoring_policy, approve_factoring_relationship_noa,
// set_default_factoring_relationship) and 0140's tightened RLS already
// enforce at the database layer. This is UX (a clean message before a
// round trip), never the real boundary -- dispatcher/accountant are
// rejected by RLS/the RPC itself regardless of what this function does.
async function requireOwnerAdminFactoringAccess(): Promise<{ organizationId: string; userId: string } | { error: string }> {
  const auth = await requireFactoringAccess();
  if ("error" in auth) return auth;
  if (!OWNER_ADMIN_ROLES.includes(auth.role)) {
    return { error: "Only an owner or admin may make this change." };
  }
  return auth;
}

// entity_type (public.entity_type, 0001) is a closed enum with no
// 'factoring_company'/'factoring_relationship' value, and adding one is a
// migration this phase is explicitly not to make just for logging (the
// standing instruction: no new migration unless a genuine schema defect
// is found). 'organization' is the same generic bucket
// settings/email/actions.ts already uses for its own sub-features
// (domains/senders) that likewise have no dedicated entity_type -- not a
// new convention, the existing one for exactly this situation. Uses the
// caller's own session (log_activity is SECURITY DEFINER, 0009/0044/0046
// -- it does not need RLS bypassed to write activity_logs).
async function logFactoringActivity(organizationId: string, action: string, changes: Record<string, unknown>) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("log_activity", {
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
  if (error.code === "42501") {
    return "You do not have permission to make this change.";
  }
  return error.message;
}

// ---------------------------------------------------------------------------
// Structured RPC-result handling (Phase 3B.1.3, Section D). 0138/0139's
// protected RPCs (set_default_factoring_relationship,
// set_carrier_factoring_policy) return a NORMAL (non-exception) jsonb
// result for business-rule rejections -- {success:false, ...} -- so a
// caller that only checks the Postgres/transport-level `error` and never
// looks at `data` will silently treat a rejected change as if it
// succeeded. The actual decision logic lives in the framework-independent
// lib/factoring/rpc-result.ts (unit-tested directly, without a Supabase
// client) -- this is a thin wrapper that adapts a Supabase `.rpc()` call
// (a PromiseLike, not a plain Promise) to it. It is never sufficient to
// check `error` alone.
// ---------------------------------------------------------------------------
async function resolveStructuredRpc<T extends StructuredRpcResult>(
  call: PromiseLike<{ data: T | null; error: { message: string } | null }>
): Promise<{ ok: true; data: T } | { ok: false; error: string }> {
  const { data, error } = await call;
  return resolveStructuredRpcResult(data, error);
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
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };
  const parsed = companyValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  const supabase = await createClient();
  const { data, error } = await supabase.from("factoring_companies").insert({ ...parsed.values, organization_id: auth.organizationId }).select("id").single();
  if (error) return { ok: false, error: friendlyDbError(error, "generic") };

  await logFactoringActivity(auth.organizationId, "factoring_company_created", { factoring_company_id: data.id, name: parsed.values.name });
  revalidatePath(PATH);
  return { ok: true };
}

export async function updateFactoringCompany(companyId: string, formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };
  const parsed = companyValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  const supabase = await createClient();
  const { data: existing } = await supabase.from("factoring_companies").select("id").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring company not found." };

  const { error } = await supabase.from("factoring_companies").update(parsed.values).eq("id", companyId);
  if (error) return { ok: false, error: friendlyDbError(error, "generic") };

  await logFactoringActivity(auth.organizationId, "factoring_company_updated", { factoring_company_id: companyId, name: parsed.values.name });
  revalidatePath(PATH);
  return { ok: true };
}

// Deactivation (isActive = false) can be rejected by
// guard_factoring_company_deactivation() (0072/0138) when this company owns
// a carrier's current active default relationship -- surfaced as a clean
// typed-result message via friendlyDbError's "company_deactivate"
// context, never a raw Postgres error or a route-boundary exception. The
// trigger deliberately does not offer to clear the default or deactivate
// the relationship for the user; the fix is to set a different
// relationship as default first (setDefaultFactoringRelationship), then
// retry deactivating this company.
export async function setFactoringCompanyActive(companyId: string, isActive: boolean): Promise<FactoringActionResult> {
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const supabase = await createClient();
  const { data: existing } = await supabase.from("factoring_companies").select("id, name").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring company not found." };

  const { error } = await supabase.from("factoring_companies").update({ is_active: isActive }).eq("id", companyId);
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
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const supabase = await createClient();
  const { data: existing } = await supabase.from("factoring_companies").select("id, name").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring company not found." };

  const { error } = await supabase.from("factoring_companies").delete().eq("id", companyId);
  if (error) return { ok: false, error: friendlyDbError(error, "company_delete") };

  await logFactoringActivity(auth.organizationId, "factoring_company_deleted", { factoring_company_id: companyId, name: existing.name });
  revalidatePath(PATH);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Factoring relationships -- Phase 3B.1.3 (Section B): every relationship
// now belongs to exactly one carrier, chosen at creation from carriers
// authorized for the current user, active-only. Changing the carrier
// later is not offered anywhere in this file -- a relationship pointed at
// the wrong carrier is corrected by creating a new one, never by
// repointing history (matches carrier_id's own UPDATE-revoked column
// privilege, 0138/0139: even a hand-crafted request could not repoint it).
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

// The one place that decides whether `carrierId` may be used for a NEW
// factoring relationship: must belong to the caller's own organization
// AND be active (Section B.2/B.3 -- same predicate
// carrier_ids_selectable_for_new_records(), 0130, documents as ITS OWN
// contract; queried directly here rather than through that RPC so the
// exact failure -- "not found/wrong org" vs. "inactive" -- can be told
// apart and reported with a distinct message, which a bare id-set RPC
// result cannot do on its own).
async function validateCarrierForNewRelationship(carrierId: string, organizationId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!carrierId) return { ok: false, error: "A carrier is required." };
  const supabase = await createClient();
  const { data: carrier } = await supabase.from("carriers").select("id, is_active").eq("id", carrierId).eq("organization_id", organizationId).maybeSingle();
  if (!carrier) return { ok: false, error: "That carrier is not available." };
  if (!carrier.is_active) return { ok: false, error: "That carrier is inactive and cannot be used for a new factoring relationship." };
  return { ok: true };
}

export async function createFactoringRelationship(carrierId: string, companyId: string, formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const carrierCheck = await validateCarrierForNewRelationship(carrierId, auth.organizationId);
  if (!carrierCheck.ok) return carrierCheck;

  const supabase = await createClient();
  const { data: company } = await supabase.from("factoring_companies").select("id, name").eq("id", companyId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!company) return { ok: false, error: "Factoring company not found." };

  const parsed = relationshipValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  // Deliberately never sets is_default here (spec section 6 treats "Set
  // Default" as its own distinct action/step, not a create-time option) --
  // every new relationship starts is_default = false, is_active = true
  // (0071's own column defaults), so it can never collide with
  // factoring_relationships_one_default_per_carrier (0138) on insert.
  // guard_factoring_relationship_org() (0071/0136) independently re-checks
  // carrier_id's organization at the database layer regardless of what
  // this app-layer check above already confirmed.
  const { data, error } = await supabase
    .from("factoring_relationships")
    .insert({ ...parsed.values, organization_id: auth.organizationId, factoring_company_id: companyId, carrier_id: carrierId })
    .select("id")
    .single();
  if (error) return { ok: false, error: friendlyDbError(error, "relationship") };

  await logFactoringActivity(auth.organizationId, "factoring_relationship_created", { factoring_relationship_id: data.id, factoring_company_id: companyId, carrier_id: carrierId, company_name: company.name });
  revalidatePath(PATH);
  return { ok: true };
}

export async function updateFactoringRelationship(relationshipId: string, formData: FormData): Promise<FactoringActionResult> {
  const auth = await requireFactoringEditAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const supabase = await createClient();
  const { data: existing } = await supabase.from("factoring_relationships").select("id").eq("id", relationshipId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring relationship not found." };

  const parsed = relationshipValuesFromForm(formData);
  if (!parsed.ok) return { ok: false, error: parsed.error };

  // Terms-only update, in place -- 0071's snapshot design (advance/fee/
  // reserve percentages + fee_timing copied onto factored_invoices at
  // submission time, Phase 2H.4) means this can never rewrite an
  // already-submitted transaction's numbers; only future submissions that
  // read this relationship's CURRENT values are affected. carrier_id/
  // is_default/is_active are never included in `parsed.values` -- the
  // carrier a relationship belongs to is immutable after creation (Section
  // B.7/B.9), and is_default/is_active are separate, dedicated actions.
  const { error } = await supabase.from("factoring_relationships").update(parsed.values).eq("id", relationshipId);
  if (error) return { ok: false, error: friendlyDbError(error, "relationship") };

  await logFactoringActivity(auth.organizationId, "factoring_relationship_updated", { factoring_relationship_id: relationshipId });
  revalidatePath(PATH);
  return { ok: true };
}

// Phase 2H.3A / 3B.1 (0072 -> 0138): a single atomic, carrier-scoped RPC.
// Called through the CALLER'S OWN session client (never service_role) --
// org/role/carrier are derived and re-verified INSIDE the function itself
// (current_org_id()/has_role(), 0138), never trusted from this action's
// own arguments. Phase 3B.1.3 (Section D) fix: the RPC's own STRUCTURED
// result is now the authority on success, not merely a null transport
// error -- resolveStructuredRpc() maps {success:false, incomplete:true,
// ...} (a normal, non-exception result the RPC returns for "this
// relationship isn't complete enough to become the default yet") to a
// failed FactoringActionResult exactly the same as a raised exception
// (SFAUT/SFROL/SFDNF/SFCAR/SFINV/SFCMP) would be -- this action can no
// longer report success while the database's own is_default flag never
// actually changed.
export async function setDefaultFactoringRelationship(relationshipId: string): Promise<FactoringActionResult> {
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const supabase = await createClient();
  const resolved = await resolveStructuredRpc(supabase.rpc("set_default_factoring_relationship", { p_relationship_id: relationshipId }));
  if (!resolved.ok) return { ok: false, error: resolved.error };

  await logFactoringActivity(auth.organizationId, "factoring_relationship_set_default", {
    factoring_relationship_id: relationshipId,
    carrier_id: resolved.data.carrier_id,
  });
  revalidatePath(PATH);
  return { ok: true };
}

// Deactivating the CURRENT default is blocked outright (spec section 9 /
// 17's own required message) rather than silently auto-clearing
// is_default alongside is_active -- 0071's
// factoring_relationships_default_must_be_active CHECK would force that
// combination anyway, but surfacing it as a hard stop here means a user
// is never surprised to discover, only after the fact, that their
// carrier quietly lost its default. To deactivate the current default,
// set a different relationship as that SAME carrier's default first
// (which clears this one's is_default), then deactivate it.
export async function setFactoringRelationshipActive(relationshipId: string, isActive: boolean): Promise<FactoringActionResult> {
  const auth = await requireFactoringEditAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  const supabase = await createClient();
  const { data: existing } = await supabase.from("factoring_relationships").select("id, is_default, carrier_id").eq("id", relationshipId).eq("organization_id", auth.organizationId).maybeSingle();
  if (!existing) return { ok: false, error: "Factoring relationship not found." };
  if (!isActive && existing.is_default) {
    return { ok: false, error: "This factoring relationship cannot be deactivated while it is this carrier's default." };
  }

  const { error } = await supabase.from("factoring_relationships").update({ is_active: isActive }).eq("id", relationshipId);
  if (error) return { ok: false, error: friendlyDbError(error, "relationship") };

  await logFactoringActivity(auth.organizationId, isActive ? "factoring_relationship_reactivated" : "factoring_relationship_deactivated", { factoring_relationship_id: relationshipId, carrier_id: existing.carrier_id });
  revalidatePath(PATH);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Carrier factoring policy (Phase 3B.1.3 -- the app's one entry point to
// public.set_carrier_factoring_policy(), 0139). Owner/admin only, app
// layer AND database layer both -- see requireOwnerAdminFactoringAccess()
// above and the RPC's own has_role() check. A reason is mandatory (the
// RPC itself rejects an empty one); p_expected_updated_at makes this
// optimistic-concurrency-safe the same way setDefaultFactoringRelationship
// is. Never broadens dispatcher/accountant authority: they can still view
// a carrier's policy/readiness (read-only, via the classifier), never
// change it.
// ---------------------------------------------------------------------------
export async function setCarrierFactoringPolicy(
  carrierId: string,
  mode: CarrierFactoringMode,
  reason: string,
  expectedUpdatedAt: string
): Promise<FactoringActionResult> {
  const auth = await requireOwnerAdminFactoringAccess();
  if ("error" in auth) return { ok: false, error: auth.error };

  if (!reason.trim()) return { ok: false, error: "A reason is required." };
  if (!expectedUpdatedAt) return { ok: false, error: "Missing the carrier's current version -- please refresh and try again." };

  const supabase = await createClient();
  const resolved = await resolveStructuredRpc(
    supabase.rpc("set_carrier_factoring_policy", {
      p_carrier_id: carrierId,
      p_mode: mode,
      p_reason: reason,
      p_expected_updated_at: expectedUpdatedAt,
      p_idempotency_key: null,
    })
  );
  if (!resolved.ok) return { ok: false, error: resolved.error };

  revalidatePath(PATH);
  return { ok: true };
}
