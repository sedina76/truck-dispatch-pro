"use server";

import { headers } from "next/headers";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { requireDriverOnboardingSession, DriverOnboardingSessionUnavailableError } from "@/lib/driver-onboarding/session";
import { runDriverW9Generation } from "@/lib/driver-w9/generate-workflow";
import {
  workerTypeRequiresW9,
  type DriverWorkerType,
  type DriverW9Row,
  type W9TaxClassification,
  type W9TinType,
} from "@/lib/driver-w9/types";

// ---------------------------------------------------------------------------
// Phase 2Q.2 -- driver-facing onboarding actions. Mirrors the exact
// pattern already established by src/app/carrier-onboarding/actions.ts:
// resolve identity via requireDriverOnboardingSession() first (never trust
// any id the browser supplies), then operate on driver_applications
// through the service-role client -- there is no Supabase Auth session
// here to lean on RLS for, same reasoning as the carrier portal.
//
// Every write is additionally scoped to identity.applicationId AND
// identity.organizationId (belt-and-suspenders: the session row itself
// already proves ownership of exactly one application, but every mutation
// re-states both anyway, matching this file's sibling's own convention).
//
// 0108 is confirmed live. The carrier_id/worker_type columns and the
// Driver W-9 (driver_w9s) functions this file also uses below depend on
// migration 0109, NOT YET APPLIED -- those specific additions cannot run
// against the live database until it is.
// ---------------------------------------------------------------------------

const EDITABLE_STATUSES = new Set(["in_progress", "needs_correction"]);

export type ActionResult = { ok: true } | { ok: false; error: string };

function str(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  if (typeof v !== "string") return null;
  const trimmed = v.trim();
  return trimmed === "" ? null : trimmed;
}

function bool(formData: FormData, key: string): boolean {
  return formData.get(key) === "on" || formData.get(key) === "true";
}

async function requireIdentity() {
  try {
    return await requireDriverOnboardingSession();
  } catch (e) {
    if (e instanceof DriverOnboardingSessionUnavailableError) throw e;
    throw new DriverOnboardingSessionUnavailableError();
  }
}

// Shared guard: every save action must confirm the application is still
// in an editable state before writing anything (Section L -- "after
// submission, ordinary driver edits should be limited"). Fetches only
// `status`, cheap and always fresh (never trusts a stale value the client
// might hold).
async function requireEditableApplication(applicationId: string, organizationId: string, service: ReturnType<typeof createServiceRoleClient>) {
  const { data } = await service.from("driver_applications").select("status").eq("id", applicationId).eq("organization_id", organizationId).maybeSingle();
  if (!data) throw new Error("Application not found.");
  if (!EDITABLE_STATUSES.has(data.status)) {
    throw new Error("This application can no longer be edited. Contact the company that invited you if you need to make a change.");
  }
}

export type UploadedDocument = { label: string; storage_path: string; file_name: string; uploaded_at: string };

type DriverOnboardingApplication = {
  id: string;
  organization_id: string;
  status: string;
  carrier_id: string | null;
  worker_type: DriverWorkerType | null;
  first_name: string;
  middle_name: string | null;
  last_name: string;
  phone: string | null;
  email: string | null;
  date_of_birth: string | null;
  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  emergency_contact_name: string | null;
  emergency_contact_phone: string | null;
  cdl_number: string | null;
  cdl_state: string | null;
  cdl_class: string | null;
  cdl_endorsements: string | null;
  cdl_expiry_date: string | null;
  has_valid_medical_card: boolean | null;
  medical_card_expiry_date: string | null;
  years_of_experience: number | null;
  equipment_experience: string | null;
  employment_history: unknown;
  has_been_convicted_of_dui: boolean | null;
  has_had_license_suspended: boolean | null;
  has_had_preventable_accident: boolean | null;
  driving_record_explanation: string | null;
  uploaded_documents: UploadedDocument[];
  signature_name: string | null;
  signature_agreed_at: string | null;
  correction_reason: string | null;
};

export async function getMyDriverApplication(): Promise<DriverOnboardingApplication | null> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  const { data } = await service
    .from("driver_applications")
    .select(
      `id, organization_id, status, carrier_id, worker_type, first_name, middle_name, last_name, phone, email, date_of_birth,
       address_line1, city, state, postal_code, emergency_contact_name, emergency_contact_phone,
       cdl_number, cdl_state, cdl_class, cdl_endorsements, cdl_expiry_date,
       has_valid_medical_card, medical_card_expiry_date,
       years_of_experience, equipment_experience, employment_history,
       has_been_convicted_of_dui, has_had_license_suspended, has_had_preventable_accident, driving_record_explanation,
       uploaded_documents, signature_name, signature_agreed_at, correction_reason`
    )
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId)
    .maybeSingle();
  return (data as unknown as DriverOnboardingApplication) ?? null;
}

export async function saveDriverPersonalInfo(formData: FormData): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }

  const firstName = str(formData, "first_name");
  const lastName = str(formData, "last_name");
  if (!firstName || !lastName) return { ok: false, error: "First and last name are required." };

  const { error } = await service
    .from("driver_applications")
    .update({
      first_name: firstName,
      middle_name: str(formData, "middle_name"),
      last_name: lastName,
      phone: str(formData, "phone"),
      email: str(formData, "email"),
      date_of_birth: str(formData, "date_of_birth"),
      address_line1: str(formData, "address_line1"),
      city: str(formData, "city"),
      state: str(formData, "state"),
      postal_code: str(formData, "postal_code"),
      emergency_contact_name: str(formData, "emergency_contact_name"),
      emergency_contact_phone: str(formData, "emergency_contact_phone"),
      updated_at: new Date().toISOString(),
    })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function saveDriverLicenseInfo(formData: FormData): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }

  const cdlClass = str(formData, "cdl_class");
  if (cdlClass && !["A", "B", "C"].includes(cdlClass)) return { ok: false, error: "CDL class must be A, B, or C." };

  const { error } = await service
    .from("driver_applications")
    .update({
      cdl_number: str(formData, "cdl_number"),
      cdl_state: str(formData, "cdl_state"),
      cdl_class: cdlClass,
      cdl_endorsements: str(formData, "cdl_endorsements"),
      cdl_expiry_date: str(formData, "cdl_expiry_date"),
      updated_at: new Date().toISOString(),
    })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function saveDriverMedicalCard(formData: FormData): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }

  const { error } = await service
    .from("driver_applications")
    .update({
      has_valid_medical_card: bool(formData, "has_valid_medical_card"),
      medical_card_expiry_date: str(formData, "medical_card_expiry_date"),
      updated_at: new Date().toISOString(),
    })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function saveDriverEmploymentInfo(formData: FormData): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }

  const years = formData.get("years_of_experience");
  const yearsNum = years && String(years).trim() !== "" ? Number(years) : null;

  const { error } = await service
    .from("driver_applications")
    .update({
      years_of_experience: Number.isFinite(yearsNum) ? yearsNum : null,
      equipment_experience: str(formData, "equipment_experience"),
      has_been_convicted_of_dui: formData.has("has_been_convicted_of_dui") ? bool(formData, "has_been_convicted_of_dui") : null,
      has_had_license_suspended: formData.has("has_had_license_suspended") ? bool(formData, "has_had_license_suspended") : null,
      has_had_preventable_accident: formData.has("has_had_preventable_accident") ? bool(formData, "has_had_preventable_accident") : null,
      driving_record_explanation: str(formData, "driving_record_explanation"),
      updated_at: new Date().toISOString(),
    })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

// Appends a scanned/uploaded document to uploaded_documents, replacing any
// prior entry with the same label (same "one current file per label"
// convention the public /driver-application form already uses client-side
// -- here it's persisted server-side immediately on each upload instead of
// held in browser state, since this session can span multiple visits).
export async function attachDriverOnboardingDocument(doc: UploadedDocument): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }
  if (!doc.storage_path.startsWith(`${identity.applicationId}/`)) {
    return { ok: false, error: "Document does not belong to this application." };
  }

  const { data: current } = await service.from("driver_applications").select("uploaded_documents").eq("id", identity.applicationId).maybeSingle();
  const existing = ((current?.uploaded_documents ?? []) as UploadedDocument[]).filter((d) => d.label !== doc.label);
  const { error } = await service
    .from("driver_applications")
    .update({ uploaded_documents: [...existing, doc], updated_at: new Date().toISOString() })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function signDriverOnboardingAgreement(formData: FormData): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }

  const signatureName = str(formData, "signature_name");
  const agreed = bool(formData, "agreed");
  if (!signatureName || !agreed) return { ok: false, error: "Type your full legal name and check the certification box to continue." };

  const headerList = await headers();
  const forwardedFor = headerList.get("x-forwarded-for");
  const submittedFromIp = forwardedFor ? forwardedFor.split(",")[0].trim() : null;

  const { error } = await service
    .from("driver_applications")
    .update({
      signature_name: signatureName,
      signature_agreed_at: new Date().toISOString(),
      submitted_from_ip: submittedFromIp,
      updated_at: new Date().toISOString(),
    })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

// The submission gate (Section L): re-validates every required field
// server-side, never relies on a disabled Review & Submit button alone.
// Only CDL is a hard document requirement here -- Medical Card is
// captured as expiry/on-file status like the rest of this table already
// does for the public flow; a missing scan doesn't block submission any
// more than it would there, but a missing CDL document does, since a
// license number with no image of the license itself isn't something
// staff can actually verify.
export async function submitDriverOnboardingApplication(): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();

  const { data: app } = await service
    .from("driver_applications")
    .select(
      "status, first_name, last_name, phone, email, cdl_number, cdl_state, cdl_expiry_date, uploaded_documents, signature_name, worker_type"
    )
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId)
    .maybeSingle();
  if (!app) return { ok: false, error: "Application not found." };
  if (!EDITABLE_STATUSES.has(app.status)) {
    return { ok: false, error: "This application has already been submitted." };
  }

  const missing: string[] = [];
  if (!app.first_name || !app.last_name) missing.push("Personal Information");
  if (!app.phone && !app.email) missing.push("a phone number or email address");
  if (!app.cdl_number || !app.cdl_state || !app.cdl_expiry_date) missing.push("License / CDL");
  const documents = (app.uploaded_documents ?? []) as UploadedDocument[];
  if (!documents.some((d) => d.label === "CDL")) missing.push("a scan or photo of your CDL");
  if (!app.signature_name) missing.push("Agreements & Signature");

  // Section M: W-9 blocks submission ONLY for 1099-style workers
  // (independent_contractor/owner_operator) -- never for a W-2 company
  // driver, and always enforced here server-side, not just by hiding/
  // disabling the Submit button.
  if (workerTypeRequiresW9(app.worker_type as DriverWorkerType | null)) {
    // finalize_driver_w9()'s supersession logic (0109) guarantees at most
    // one 'completed' row exists at a time per subject -- a plain
    // .eq("status","completed") is therefore always "the current one".
    const { data: w9 } = await service.from("driver_w9s").select("id").eq("application_id", identity.applicationId).eq("status", "completed").maybeSingle();
    if (!w9) missing.push("Tax (W-9)");
  }

  if (missing.length > 0) {
    return { ok: false, error: `Please complete: ${missing.join(", ")}.` };
  }

  const { error } = await service
    .from("driver_applications")
    .update({ status: "submitted", submitted_at: new Date().toISOString(), updated_at: new Date().toISOString() })
    .eq("id", identity.applicationId)
    .eq("organization_id", identity.organizationId);
  if (error) return { ok: false, error: error.message };

  await service.from("driver_onboarding_invitations").update({ submitted_at: new Date().toISOString() }).eq("application_id", identity.applicationId).is("submitted_at", null);

  await service.from("activity_logs").insert({
    organization_id: identity.organizationId,
    entity_type: "driver_application",
    entity_id: identity.applicationId,
    action: "driver_onboarding_submitted",
    actor_id: null,
    changes: {},
  });

  return { ok: true };
}

// ---------------------------------------------------------------------------
// Phase 2Q.2B -- Driver W-9. Mirrors src/app/carrier-onboarding/actions.ts's
// own W-9 section exactly: resolve identity via requireDriverOnboardingSession()
// first, then call the driver_w9s RPCs (0109) through the service-role
// client with an explicit p_organization_id, the same dual-caller pattern
// carrier_w9s' own RPCs use. Depends on migration 0109, NOT YET APPLIED.
// ---------------------------------------------------------------------------

export async function getMyDriverW9(): Promise<DriverW9Row | null> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  const { data } = await service
    .from("driver_w9s")
    .select("*")
    .eq("application_id", identity.applicationId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data as unknown as DriverW9Row) ?? null;
}

export async function createMyDriverW9Draft(): Promise<{ ok: true; id: string } | { ok: false; error: string }> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  // Phase 2Q.2C repair -- the driver-facing W-9 actions had no editable-
  // status guard at all (every OTHER onboarding save action already
  // requires in_progress/needs_correction via requireEditableApplication()).
  // A driver whose browser session was still open after staff had already
  // approved/converted the application could otherwise keep creating or
  // certifying W-9 versions against a decided application.
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }
  const { data, error } = await service.rpc("create_driver_w9_draft", {
    p_organization_id: identity.organizationId, p_application_id: identity.applicationId, p_driver_id: null,
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true, id: data as string };
}

export async function saveMyDriverW9Draft(
  w9Id: string,
  input: {
    nameOnTaxReturn: string; businessName: string; taxClassification: W9TaxClassification; llcClassification: string;
    otherClassificationDescription: string; hasForeignPartnersOwners: boolean; exemptPayeeCode: string; fatcaExemptionCode: string;
    addressLine1: string; city: string; state: string; postalCode: string;
  }
): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }
  const { error } = await service.rpc("update_driver_w9_draft", {
    p_w9_id: w9Id, p_organization_id: identity.organizationId,
    p_name_on_tax_return: input.nameOnTaxReturn, p_business_name: input.businessName,
    p_tax_classification: input.taxClassification, p_llc_classification: input.llcClassification,
    p_other_classification_description: input.otherClassificationDescription, p_has_foreign_partners_owners: input.hasForeignPartnersOwners,
    p_exempt_payee_code: input.exemptPayeeCode, p_fatca_exemption_code: input.fatcaExemptionCode,
    p_address_line1: input.addressLine1, p_city: input.city, p_state: input.state, p_postal_code: input.postalCode,
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

export async function setMyDriverW9Tin(w9Id: string, tinType: W9TinType, tin: string): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }
  // Plaintext TIN lives in this one argument for as short a time as this
  // architecture allows, mirroring setMyW9Tin() (carrier onboarding)
  // exactly -- never logged, never returned, never placed in another
  // variable here.
  const { error } = await service.rpc("set_driver_w9_tin", { p_w9_id: w9Id, p_organization_id: identity.organizationId, p_tin_type: tinType, p_tin: tin });
  if (error) return { ok: false, error: error.message };
  return { ok: true };
}

// Certification and generation are one driver-facing action, mirroring
// certifyAndGenerateMyW9() (carrier onboarding) exactly -- the driver
// never sees an intermediate "generating" state. The plaintext TIN is
// re-derived here ONLY for the render step, scoped to this call only --
// reveal_driver_w9_tin() (staff-only, reason-audited) is never used for
// this routine generation.
export async function certifyAndGenerateMyDriverW9(
  w9Id: string,
  input: { certifiedName: string; certifiedTitle: string; tinType: W9TinType; tin: string }
): Promise<ActionResult> {
  const identity = await requireIdentity();
  const service = createServiceRoleClient();
  try {
    await requireEditableApplication(identity.applicationId, identity.organizationId, service);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Could not save." };
  }

  const { error: tinError } = await service.rpc("set_driver_w9_tin", { p_w9_id: w9Id, p_organization_id: identity.organizationId, p_tin_type: input.tinType, p_tin: input.tin });
  if (tinError) return { ok: false, error: tinError.message };

  const { error: certifyError } = await service.rpc("certify_driver_w9", {
    p_w9_id: w9Id, p_organization_id: identity.organizationId, p_certified_name: input.certifiedName, p_certified_title: input.certifiedTitle || null,
  });
  if (certifyError) return { ok: false, error: certifyError.message };

  const result = await runDriverW9Generation(w9Id, identity.organizationId, input.tin);
  if (!result.ok) return { ok: false, error: "Your W-9 was certified, but the official PDF could not be generated. Please contact the company that invited you." };
  return { ok: true };
}
