"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId, insertRecord, deleteRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { isValidIanaTimezone } from "@/lib/timezone/iana";
import { validateDeviationThresholds } from "@/lib/tracking/route-deviation";

const METERS_PER_MILE = 1609.344;
function milesToMeters(formData: FormData, name: string, fallbackMiles: number): number {
  const miles = toNumber(formData.get(name));
  return Math.round((miles ?? fallbackMiles) * METERS_PER_MILE);
}

// Phase 2P.6B -- 0107's two escalation-threshold columns are deliberately
// wider-permission than the rest of this page: the surrounding
// organization form is Owner-only (see organization/page.tsx's own
// isOwner-gated <fieldset>), but this specific setting is Owner/Admin per
// explicit product decision -- its own separate <FormCard>/action, not
// folded into updateOrganization(), so the two permission models never
// collide. A sensible upper bound (7 days) rejects nonsensical values
// without inventing an unrequested general-purpose validation framework.
const MAX_ESCALATION_MINUTES = 10080; // 7 days

function parseEscalationMinutes(formData: FormData, name: string): number | null {
  const raw = String(formData.get(name) ?? "").trim();
  if (raw === "") return null; // blank = disabled
  const n = Number(raw);
  if (!Number.isInteger(n) || n <= 0 || n > MAX_ESCALATION_MINUTES) {
    throw new Error(`${name === "critical_exception_escalation_minutes" ? "Critical" : "High"} exception escalation must be a whole number of minutes between 1 and ${MAX_ESCALATION_MINUTES}, or left blank to disable.`);
  }
  return n;
}

export async function updateExceptionEscalationSettings(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error("Not authenticated.");

  // Server-side role enforcement, independent of the page's own disabled
  // fieldset -- the client-side disable is UX only, never the boundary.
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  if (!profile || !["owner", "admin"].includes(profile.role)) throw new Error("Only Owner or Admin may change exception escalation settings.");

  const orgId = await getCurrentOrgId(); // organization derived server-side, never a client-supplied id

  const criticalMinutes = parseEscalationMinutes(formData, "critical_exception_escalation_minutes");
  const highMinutes = parseEscalationMinutes(formData, "high_exception_escalation_minutes");

  // A plain UPDATE of two nullable integer columns -- never touches
  // escalated_at/notifications, so saving settings creates no exception
  // notification by construction.
  const { error } = await supabase
    .from("organizations")
    .update({ critical_exception_escalation_minutes: criticalMinutes, high_exception_escalation_minutes: highMinutes })
    .eq("id", orgId);
  if (error) throw new Error("Could not save exception escalation settings.");

  revalidatePath("/settings/organization");
}

export async function updateOrganization(formData: FormData) {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  // Spec section 33: reject invalid timezone with a business-friendly
  // error rather than letting a free-text/abbreviated value into the
  // database -- this is the one place organizations.timezone can be
  // written going forward.
  const timezone = String(formData.get("timezone") || "");
  if (!isValidIanaTimezone(timezone)) {
    throw new Error("Please select a valid timezone for this organization.");
  }

  // Route deviation thresholds (spec section 8/38) -- validated up front,
  // before any writes, same as the timezone check above: a bad value
  // rejects the whole submit rather than saving everything else and
  // silently skipping just this one section.
  const warningM = milesToMeters(formData, "route_deviation_warning_mi", 0.5);
  const confirmedM = milesToMeters(formData, "route_deviation_confirmed_mi", 1.0);
  const recoveryM = milesToMeters(formData, "route_deviation_recovery_mi", 0.25);
  const thresholdError = validateDeviationThresholds({ warningM, confirmedM, recoveryM });
  if (thresholdError) throw new Error(thresholdError);

  const { error } = await supabase
    .from("organizations")
    .update({
      timezone,
      name: String(formData.get("name")),
      dba_name: emptyToNull(formData.get("dba_name")),
      mc_number: emptyToNull(formData.get("mc_number")),
      dot_number: emptyToNull(formData.get("dot_number")),
      ein: emptyToNull(formData.get("ein")),
      business_phone: emptyToNull(formData.get("business_phone")),
      fax: emptyToNull(formData.get("fax")),
      business_email: emptyToNull(formData.get("business_email")),
      website: emptyToNull(formData.get("website")),
      address_line1: emptyToNull(formData.get("address_line1")),
      city: emptyToNull(formData.get("city")),
      state: emptyToNull(formData.get("state")),
      postal_code: emptyToNull(formData.get("postal_code")),
      mailing_address_line1: emptyToNull(formData.get("mailing_address_line1")),
      mailing_city: emptyToNull(formData.get("mailing_city")),
      mailing_state: emptyToNull(formData.get("mailing_state")),
      mailing_postal_code: emptyToNull(formData.get("mailing_postal_code")),
      usdot_authority_status: emptyToNull(formData.get("usdot_authority_status")),
      broker_authority_status: emptyToNull(formData.get("broker_authority_status")),
      dispatch_authority_status: emptyToNull(formData.get("dispatch_authority_status")),
      safety_rating: emptyToNull(formData.get("safety_rating")),
      safety_rating_date: emptyToNull(formData.get("safety_rating_date")),
      default_payment_terms_days: toNumber(formData.get("default_payment_terms_days")) ?? 30,
      invoice_footer: emptyToNull(formData.get("invoice_footer")),
      default_invoice_notes: emptyToNull(formData.get("default_invoice_notes")),
    })
    .eq("id", orgId);

  if (error) throw new Error(error.message);

  // Detention (0057) and geofence/automation (0059) fields -- deliberately
  // SEPARATE updates, not bundled into the one above. PostgREST fails an
  // ENTIRE .update() call over a single unknown column, so if either
  // migration hasn't landed yet, bundling either in would break saving
  // every other Company Profile field too (the same lesson board-actions.ts
  // already learned the hard way). Both are best-effort here: logged, not
  // thrown -- this form's core fields must always be able to save.
  const { error: detentionError } = await supabase
    .from("organizations")
    .update({
      pickup_detention_free_minutes: toNumber(formData.get("pickup_detention_free_minutes")) ?? 120,
      delivery_detention_free_minutes: toNumber(formData.get("delivery_detention_free_minutes")) ?? 120,
    })
    .eq("id", orgId);
  if (detentionError) console.warn("[settings] detention settings not saved (likely migration 0057 not applied yet):", detentionError.message);

  const { error: gpsError } = await supabase
    .from("organizations")
    .update({
      pickup_geofence_radius_m: toNumber(formData.get("pickup_geofence_radius_m")) ?? 300,
      delivery_geofence_radius_m: toNumber(formData.get("delivery_geofence_radius_m")) ?? 300,
      gps_automation_mode: String(formData.get("gps_automation_mode") || "suggest"),
    })
    .eq("id", orgId);
  if (gpsError) console.warn("[settings] GPS tracking settings not saved (likely migration 0059 not applied yet):", gpsError.message);

  // Route deviation (0062) -- deliberately a FOURTH separate update, same
  // reasoning as the two above: a not-yet-applied migration must never
  // break saving the rest of this form. Thresholds are entered in miles
  // (matching this product's existing display convention) and converted to
  // meters for storage (spec section 40: never store thresholds as
  // floating-point miles) -- already computed/validated above.
  const { error: deviationError } = await supabase
    .from("organizations")
    .update({
      route_deviation_enabled: formData.get("route_deviation_enabled") === "on",
      route_deviation_warning_m: warningM,
      route_deviation_confirmed_m: confirmedM,
      route_deviation_recovery_m: recoveryM,
    })
    .eq("id", orgId);
  if (deviationError) console.warn("[settings] route deviation settings not saved (likely migration 0062 not applied yet):", deviationError.message);

  revalidatePath("/settings/organization");
}

export async function createBankAccount(formData: FormData) {
  await insertRecord(
    "organization_bank_accounts",
    {
      bank_name: String(formData.get("bank_name")),
      account_nickname: emptyToNull(formData.get("account_nickname")),
      account_type: String(formData.get("account_type") || "checking"),
      is_primary: formData.get("is_primary") === "on",
    },
    "/settings/organization/bank-accounts"
  );
}

export async function deleteBankAccount(id: string) {
  await deleteRecord("organization_bank_accounts", id, "/settings/organization/bank-accounts");
}

export async function setBankAccountNumber(
  bankAccountId: string,
  field: "account_number" | "routing_number",
  value: string
) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_bank_account_pii", {
    p_bank_account_id: bankAccountId,
    p_field: field,
    p_value: value,
  });
  if (error) throw new Error(error.message);
  revalidatePath("/settings/organization/bank-accounts");
}

export async function revealBankAccountNumber(
  bankAccountId: string,
  field: "account_number" | "routing_number"
): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reveal_bank_account_pii", {
    p_bank_account_id: bankAccountId,
    p_field: field,
  });
  if (error) throw new Error(error.message);
  return data as string | null;
}

export async function updateOwnProfile(formData: FormData) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) throw new Error("Not authenticated");

  const { error } = await supabase
    .from("profiles")
    .update({
      full_name: String(formData.get("full_name")),
      phone: emptyToNull(formData.get("phone")),
    })
    .eq("id", user.id);

  if (error) throw new Error(error.message);
  revalidatePath("/settings/profile");
}

export async function updateUserRole(profileId: string, formData: FormData) {
  const supabase = await createClient();
  const { error } = await supabase
    .from("profiles")
    .update({ role: String(formData.get("role")) })
    .eq("id", profileId);
  if (error) throw new Error(error.message);
  revalidatePath("/settings/users");
}

export async function toggleUserActive(profileId: string, currentlyActive: boolean) {
  const supabase = await createClient();
  await supabase.from("profiles").update({ is_active: !currentlyActive }).eq("id", profileId);
  revalidatePath("/settings/users");
}

// Real integration lifecycle management (test/enable/disable/disconnect,
// with role checks + audit log) now lives in
// src/app/(app)/settings/integrations/actions.ts -- this file's old
// toggleIntegration/enableIntegration were a bare boolean flip with no
// role check, no audit trail, and no distinction between "disabled" and
// "disconnected" (spec: "Do not make an Enable button imply a live
// integration when it only toggles a boolean").

// LEGACY, grandfathered-only. This is a bare local plan_id switch with NO
// Stripe involvement -- it must never be the purchase mechanism for a
// billing-required organization (that path is startSubscriptionCheckout()
// -> audited Stripe Checkout in src/lib/stripe/checkout.ts). Phase D.2.8
// removed its only caller from the billing page and fenced it to
// owner/admin + a grandfathered org, so it can neither fake a paid plan nor
// run for a non-admin. RLS on organization_subscriptions (service-role
// writes only) is the unconditional backstop underneath.
export async function changePlan(
  planId: string
): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();

  const { data: allowed } = await supabase.rpc("has_role", { p_roles: ["owner", "admin"] });
  if (!allowed) return { ok: false, error: "Only an owner or admin can change the plan." };

  const orgId = await getCurrentOrgId();
  const { data: row } = await supabase
    .from("organization_subscriptions")
    .select("grandfathered_at")
    .eq("organization_id", orgId)
    .maybeSingle();

  if (!row || (row as { grandfathered_at: string | null }).grandfathered_at === null) {
    return {
      ok: false,
      error: "This organization changes plans through Stripe checkout, not here.",
    };
  }

  const { error } = await supabase
    .from("organization_subscriptions")
    .update({ plan_id: planId })
    .eq("organization_id", orgId);
  if (error) return { ok: false, error: "Could not change the plan. Please try again." };

  revalidatePath("/settings/subscription");
  return { ok: true };
}
