import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

const SSN_FORMAT = /^\d{3}-\d{2}-\d{4}$/;

function str(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const trimmed = v.trim();
  return trimmed === "" ? null : trimmed;
}

function bool(v: unknown): boolean | null {
  if (v === true || v === "true" || v === "yes") return true;
  if (v === false || v === "false" || v === "no") return false;
  return null;
}

function num(v: unknown): number | null {
  if (typeof v !== "number" && typeof v !== "string") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

// Public, anonymous endpoint -- the applicant has no Supabase Auth session.
// Server-side re-validation of everything the client already checks (SSN
// format/match, required fields): client-side validation is a UX nicety,
// never a security boundary, especially on a form anyone on the internet
// can POST to directly without ever loading the page's JS.
export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => null);
  if (!body) return NextResponse.json({ error: "Invalid request body." }, { status: 400 });

  const firstName = str(body.first_name);
  const lastName = str(body.last_name);
  const signatureName = str(body.signature_name);
  const agreedToCertification = body.agreed_to_certification === true;
  const ssn = str(body.ssn);
  const confirmSsn = str(body.confirm_ssn);
  const applicationId = str(body.application_id);

  if (!applicationId || !/^[0-9a-f-]{36}$/i.test(applicationId)) {
    return NextResponse.json({ error: "Invalid application id." }, { status: 400 });
  }
  if (!firstName || !lastName) {
    return NextResponse.json({ error: "First and last name are required." }, { status: 400 });
  }
  if (!signatureName || !agreedToCertification) {
    return NextResponse.json(
      { error: "You must type your full legal name and certify the application to submit." },
      { status: 400 }
    );
  }
  if (ssn || confirmSsn) {
    if (ssn !== confirmSsn) {
      return NextResponse.json(
        { error: "Social Security Number and Confirm Social Security Number do not match." },
        { status: 400 }
      );
    }
    if (!SSN_FORMAT.test(ssn!)) {
      return NextResponse.json(
        { error: "Social Security Number must be in the format XXX-XX-XXXX." },
        { status: 400 }
      );
    }
  }

  const supabase = createServiceRoleClient();

  // Single-tenant simplification: this demo has one organization applicants
  // apply to. A real multi-tenant deployment would need a per-company
  // application link (e.g. /driver-application/[orgSlug]) instead of
  // resolving "the" org here.
  const { data: org, error: orgError } = await supabase
    .from("organizations")
    .select("id")
    .order("created_at", { ascending: true })
    .limit(1)
    .single();
  if (orgError || !org) {
    return NextResponse.json({ error: "No organization is configured to receive applications." }, { status: 500 });
  }

  const forwardedFor = request.headers.get("x-forwarded-for");
  const submittedFromIp = forwardedFor ? forwardedFor.split(",")[0].trim() : null;

  const { data, error } = await supabase.rpc("submit_driver_application", {
    p_id: applicationId,
    p_organization_id: org.id,
    p_position_applied_for: str(body.position_applied_for),
    p_availability: str(body.availability),
    p_first_name: firstName,
    p_middle_name: str(body.middle_name),
    p_last_name: lastName,
    p_date_of_birth: str(body.date_of_birth),
    p_ssn: ssn,
    p_phone: str(body.phone),
    p_email: str(body.email),
    p_address_line1: str(body.address_line1),
    p_city: str(body.city),
    p_state: str(body.state),
    p_postal_code: str(body.postal_code),
    p_cdl_number: str(body.cdl_number),
    p_cdl_state: str(body.cdl_state),
    p_cdl_class: str(body.cdl_class),
    p_cdl_endorsements: str(body.cdl_endorsements),
    p_cdl_expiry_date: str(body.cdl_expiry_date),
    p_years_of_experience: num(body.years_of_experience),
    p_equipment_experience: str(body.equipment_experience),
    p_employment_history: Array.isArray(body.employment_history) ? body.employment_history : [],
    p_has_been_convicted_of_dui: bool(body.has_been_convicted_of_dui),
    p_has_had_license_suspended: bool(body.has_had_license_suspended),
    p_has_had_preventable_accident: bool(body.has_had_preventable_accident),
    p_driving_record_explanation: str(body.driving_record_explanation),
    p_has_valid_medical_card: bool(body.has_valid_medical_card),
    p_medical_card_expiry_date: str(body.medical_card_expiry_date),
    p_uploaded_documents: Array.isArray(body.uploaded_documents) ? body.uploaded_documents : [],
    p_emergency_contact_name: str(body.emergency_contact_name),
    p_emergency_contact_phone: str(body.emergency_contact_phone),
    p_signature_name: signatureName,
    p_submitted_from_ip: submittedFromIp,
  });

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 400 });
  }

  return NextResponse.json({ ok: true, id: data });
}
