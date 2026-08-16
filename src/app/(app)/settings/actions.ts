"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId, insertRecord, deleteRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";
import { isValidIanaTimezone } from "@/lib/timezone/iana";

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

export async function changePlan(planId: string) {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();
  await supabase
    .from("organization_subscriptions")
    .update({ plan_id: planId })
    .eq("organization_id", orgId);
  revalidatePath("/settings/subscription");
}
