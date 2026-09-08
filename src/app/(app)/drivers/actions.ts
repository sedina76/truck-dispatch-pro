"use server";

import { redirect } from "next/navigation";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId, updateRecord } from "@/lib/actions/records";
import { emptyToNull, toNumber } from "@/lib/utils/form";

const SSN_FORMAT = /^\d{3}-\d{2}-\d{4}$/;

function driverValues(formData: FormData) {
  return {
    carrier_id: String(formData.get("carrier_id")),
    first_name: String(formData.get("first_name")),
    middle_name: emptyToNull(formData.get("middle_name")),
    last_name: String(formData.get("last_name")),
    phone: emptyToNull(formData.get("phone")),
    email: emptyToNull(formData.get("email")),
    status: String(formData.get("status") || "active"),
    // Employment
    employee_number: emptyToNull(formData.get("employee_number")),
    department: emptyToNull(formData.get("department")),
    hire_date: emptyToNull(formData.get("hire_date")),
    home_terminal_city: emptyToNull(formData.get("home_terminal_city")),
    home_terminal_state: emptyToNull(formData.get("home_terminal_state")),
    // Personal
    date_of_birth: emptyToNull(formData.get("date_of_birth")),
    gender: emptyToNull(formData.get("gender")),
    address_line1: emptyToNull(formData.get("address_line1")),
    city: emptyToNull(formData.get("city")),
    state: emptyToNull(formData.get("state")),
    postal_code: emptyToNull(formData.get("postal_code")),
    emergency_contact_name: emptyToNull(formData.get("emergency_contact_name")),
    emergency_contact_phone: emptyToNull(formData.get("emergency_contact_phone")),
    photo_url: emptyToNull(formData.get("photo_url")),
    photo_shareable: formData.get("photo_shareable") === "on",
    // License & medical
    cdl_number: emptyToNull(formData.get("cdl_number")),
    cdl_state: emptyToNull(formData.get("cdl_state")),
    cdl_class: emptyToNull(formData.get("cdl_class")),
    cdl_restrictions: emptyToNull(formData.get("cdl_restrictions")),
    cdl_endorsements: emptyToNull(formData.get("cdl_endorsements")),
    cdl_expiry_date: emptyToNull(formData.get("cdl_expiry_date")),
    medical_card_number: emptyToNull(formData.get("medical_card_number")),
    medical_card_expiry_date: emptyToNull(formData.get("medical_card_expiry_date")),
    // Certifications & screening
    drug_test_date: emptyToNull(formData.get("drug_test_date")),
    drug_test_expiry_date: emptyToNull(formData.get("drug_test_expiry_date")),
    background_check_date: emptyToNull(formData.get("background_check_date")),
    background_check_status: emptyToNull(formData.get("background_check_status")),
    mvr_date: emptyToNull(formData.get("mvr_date")),
    mvr_status: emptyToNull(formData.get("mvr_status")),
    twic_expiry_date: emptyToNull(formData.get("twic_expiry_date")),
    hazmat_endorsement_expiry_date: emptyToNull(formData.get("hazmat_endorsement_expiry_date")),
    // Identification & work authorization
    passport_number: emptyToNull(formData.get("passport_number")),
    passport_expiry_date: emptyToNull(formData.get("passport_expiry_date")),
    work_authorization_status: emptyToNull(formData.get("work_authorization_status")),
    work_authorization_expiry_date: emptyToNull(formData.get("work_authorization_expiry_date")),
    // Payroll -- pay_type/pay_rate deliberately excluded here, see
    // writeDriverCompensation() below (Phase 2G.10 writer cutover).
    direct_deposit_bank_name: emptyToNull(formData.get("direct_deposit_bank_name")),
    notes: emptyToNull(formData.get("notes")),
  };
}

// NOTE: requires 0067 applied (driver_compensation must exist) -- ships in
// the same deploy as 0067/0068, never before.
//
// Phase 2G.12: the Payroll section (pay_type/pay_rate inputs) is now gated
// to canSeeFinancials on Driver Detail -- driver/viewer submitting a save
// for some OTHER field on the same page (phone, CDL info, ...) send a
// FormData with pay_type/pay_rate simply absent, not blank. formData.has()
// distinguishes that from "the field was present and the user cleared it"
// -- only keys actually submitted are included in the upsert, so an
// unauthorized-role save can never blank out a driver's real compensation
// data it was never shown in the first place.
async function writeDriverCompensation(supabase: Awaited<ReturnType<typeof createClient>>, driverId: string, organizationId: string, formData: FormData) {
  if (!formData.has("pay_type") && !formData.has("pay_rate")) return;
  const { error } = await supabase.from("driver_compensation").upsert(
    {
      driver_id: driverId,
      organization_id: organizationId,
      ...(formData.has("pay_type") ? { pay_type: emptyToNull(formData.get("pay_type")) } : {}),
      ...(formData.has("pay_rate") ? { pay_rate: toNumber(formData.get("pay_rate")) } : {}),
    },
    { onConflict: "driver_id" }
  );
  if (error) throw new Error(error.message);
}

// Bespoke rather than built on the generic insertRecord() helper: SSN needs
// a *second* write after the driver row exists (set_driver_pii takes the new
// driver's id), and insertRecord ends in redirect(), which throws to unwind
// the stack -- anything after that call never runs (see createDispatch for
// the same lesson learned earlier). So this does both writes itself, then
// redirects once at the end.
//
// The raw SSN passed in only ever touches: this function's local variables,
// then the set_driver_pii RPC call (which encrypts it server-side before any
// write). It's never logged, never included in an error message, and never
// stored in a plain column -- only ssn_last4 (harmless on its own) and the
// pgp_sym_encrypt() ciphertext are persisted.
export async function createDriver(formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const ssn = String(formData.get("ssn") || "").trim();
  const confirmSsn = String(formData.get("confirm_ssn") || "").trim();

  if (ssn || confirmSsn) {
    if (ssn !== confirmSsn) {
      throw new Error("Social Security Number and Confirm Social Security Number do not match.");
    }
    if (!SSN_FORMAT.test(ssn)) {
      throw new Error("Social Security Number must be in the format XXX-XX-XXXX.");
    }
  }

  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();

  const { data, error } = await supabase
    .from("drivers")
    .insert({ ...driverValues(formData), organization_id: organizationId })
    .select("id")
    .single();
  if (error) throw new Error(error.message);

  await writeDriverCompensation(supabase, data.id, organizationId, formData);

  if (ssn) {
    const { error: piiError } = await supabase.rpc("set_driver_pii", {
      p_driver_id: data.id,
      p_field: "ssn",
      p_value: ssn,
    });
    // The driver record itself was already created successfully -- surface
    // this as a distinct message rather than a generic failure, since the
    // user needs to know the SSN specifically needs to be set again (from
    // the driver's detail page) rather than retrying the whole form.
    if (piiError) throw new Error(`Driver created, but saving the SSN failed: ${piiError.message}`);
  }

  await supabase.rpc("log_activity", { p_entity_type: "driver", p_entity_id: data.id, p_action: "created" });
  revalidatePath("/drivers");
  redirect("/drivers");
}

export async function updateDriver(id: string, formData: FormData) {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  await writeDriverCompensation(supabase, id, organizationId, formData);
  await updateRecord("drivers", id, driverValues(formData), "/drivers");
}

export async function setDriverPii(driverId: string, field: "ssn" | "direct_deposit_account" | "direct_deposit_routing", value: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_driver_pii", {
    p_driver_id: driverId,
    p_field: field,
    p_value: value,
  });
  if (error) throw new Error(error.message);
  revalidatePath(`/drivers/${driverId}`);
}

export async function revealDriverPii(
  driverId: string,
  field: "ssn" | "direct_deposit_account" | "direct_deposit_routing",
  reason?: string
): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reveal_driver_pii", {
    p_driver_id: driverId,
    p_field: field,
    p_reason: reason ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string | null;
}

export async function setDriverPortalPin(driverId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const phone = String(formData.get("portal_phone") || "");
  const pin = String(formData.get("portal_pin") || "");
  const { error } = await supabase.rpc("set_driver_portal_pin", {
    p_driver_id: driverId,
    p_phone: phone,
    p_pin: pin,
  });
  if (error) throw new Error(error.message);
  revalidatePath(`/drivers/${driverId}`);
}

export async function revokeDriverPortalAccess(driverId: string) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const supabase = await createClient();
  const { error } = await supabase.rpc("revoke_driver_portal_access", { p_driver_id: driverId });
  if (error) throw new Error(error.message);
  revalidatePath(`/drivers/${driverId}`);
}
