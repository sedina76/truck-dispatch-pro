"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { requireOperationalAccess } from "@/lib/billing/operational-access";
import { issueDriverOnboardingInvitation } from "@/lib/driver-onboarding/invitation";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import { sendTenantEmail } from "@/lib/email/send-pipeline";

const VALID_STATUSES = [
  "submitted", "under_review", "interview", "approved", "rejected", "converted",
  // Phase 2Q.2 -- carrier-invited workflow states.
  "invited", "in_progress", "needs_correction", "expired", "cancelled",
];

function str(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  if (typeof v !== "string") return null;
  const trimmed = v.trim();
  return trimmed === "" ? null : trimmed;
}

// Phase 2Q.2C repair -- root cause of the reported "Approved silently
// reverted" defect. Traced every write to driver_applications.status
// reachable from applicant-side onboarding code (the [token] bootstrap
// route: only invited->in_progress; submitDriverOnboardingApplication():
// refuses outright unless status is in_progress/needs_correction; every
// saveDriver*Info()/attachDriverOnboardingDocument(): blocked by
// requireEditableApplication() under the identical rule) -- NONE of them
// can reach or overwrite an approved/converted/rejected/cancelled/expired
// row. This function was the ONE place that could, and it had two real
// defects of its own: (1) no guard against the CURRENT status at all --
// a plain unconditional overwrite to whatever the form said; (2) the
// calling page used an uncontrolled <select defaultValue=...>, which
// React never re-applies to an already-mounted input on a Next.js
// server-action soft-refresh (the exact bug class already found and
// fixed once this engagement, 2M.2A's Broker Packet Requirements
// Checklist) -- so a staff member with this page open from BEFORE an
// approval could submit a stale, no-longer-current option and silently
// regress it. Fixed here (LOCKED_STATUSES guard) and in the calling page
// (now a controlled, always-current status control) together.
const LOCKED_STATUSES = new Set(["approved", "converted", "rejected", "cancelled", "expired"]);

export async function updateApplicationStatus(applicationId: string, status: string): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!VALID_STATUSES.includes(status)) {
    return { ok: false, error: "Invalid status." };
  }

  const supabase = await createClient();
  const { data: current } = await supabase.from("driver_applications").select("status").eq("id", applicationId).maybeSingle();
  if (!current) return { ok: false, error: "Application not found." };
  if (LOCKED_STATUSES.has(current.status)) {
    return { ok: false, error: `This application is already ${current.status} and cannot be changed from this control. Use the dedicated action for that state, or contact support.` };
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("driver_applications")
    .update({ status, reviewed_by: user?.id ?? null, reviewed_at: new Date().toISOString() })
    .eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/drivers/applications/${applicationId}`);
  revalidatePath("/drivers/applications");
  return { ok: true };
}

export async function updateApplicationReviewNotes(applicationId: string, formData: FormData) {
  const reviewNotes = String(formData.get("review_notes") || "");
  const supabase = await createClient();
  const { error } = await supabase
    .from("driver_applications")
    .update({ review_notes: reviewNotes || null })
    .eq("id", applicationId);
  if (error) throw new Error(error.message);
  revalidatePath(`/drivers/applications/${applicationId}`);
}

// reveal_driver_application_pii is owner/admin-only and logs every call --
// see migration 0018. This wrapper never returns anything but the plain
// decrypted string (or null); it's never written back to a column or logged.
export async function revealApplicationSsn(applicationId: string, reason?: string): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("reveal_driver_application_pii", {
    p_application_id: applicationId,
    p_reason: reason ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string | null;
}

// Pilot readiness audit P1-1 hardening -- identical rationale and identical
// logic to src/lib/carrier-onboarding/invitation.ts's own copy of this
// function (see that file's header comment for why this is duplicated
// rather than centralized: no shared helper exists anywhere in the
// codebase today for this single-call-site check).
function isUsableProductionSiteUrl(value: string): boolean {
  if (!value.trim()) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  const host = parsed.hostname.toLowerCase();
  return host !== "localhost" && host !== "127.0.0.1" && host !== "::1" && !host.startsWith("127.");
}

// Phase 2Q.2: converting now also provisions the new driver's Driver
// Portal login (spec Section O) -- set_driver_portal_pin() is the exact
// same staff action already used from the driver detail page (2015), just
// invoked here automatically with a random PIN instead of a staff-chosen
// one, since there is no staff-facing "set a PIN" step in this flow. Never
// gives the driver any staff-system credential -- driver_portal_credentials
// is a wholly separate, phone+PIN-only auth surface from Supabase Auth.
// Best-effort and non-blocking: a PIN/email failure here must never make
// an otherwise-successful conversion look like it failed, since the real
// driver record (and its documents/compliance data) is already committed
// by this point.
async function provisionDriverPortalAccess(supabase: Awaited<ReturnType<typeof createClient>>, driverId: string, phone: string | null, email: string | null, firstName: string, orgName: string | null) {
  if (!phone) return; // set_driver_portal_pin() requires a phone number; nothing to do without one
  const pin = String(Math.floor(100000 + Math.random() * 900000)); // 6 digits, matches the 4-6 digit rule in set_driver_portal_pin()
  const { error } = await supabase.rpc("set_driver_portal_pin", { p_driver_id: driverId, p_phone: phone, p_pin: pin });
  if (error) {
    console.error("[drivers/applications] driver portal PIN provisioning failed:", error.message);
    return;
  }
  if (!email) return;
  const auth = await resolveEmailAuthorizationContext();
  if (!auth.ok) return;
  // Pilot readiness audit P1-1 hardening: this function is deliberately
  // best-effort/non-blocking (see header comment above) -- failing safely
  // here means skipping the email entirely, exactly like the PIN failure
  // case above, never throwing. A driver conversion that otherwise
  // succeeded must never appear to fail because of this.
  const rawSiteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "";
  if (process.env.NODE_ENV === "production" && !isUsableProductionSiteUrl(rawSiteUrl)) {
    console.error("[drivers/applications] NEXT_PUBLIC_SITE_URL is not set to a real production URL -- skipping driver portal access email to avoid sending a localhost link.");
    return;
  }
  const baseUrl = rawSiteUrl || "http://localhost:3000";
  await sendTenantEmail({
    authContext: auth.context,
    emailPurpose: "driver_portal_access",
    to: [email],
    subject: `${orgName ?? "Your new employer"} -- Your Driver Portal Access`,
    text: `Hi ${firstName},\n\nWelcome aboard! You can now sign in to the Driver Portal using your phone number and the PIN below.\n\nPhone: ${phone}\nPIN: ${pin}\n\nSign in here: ${baseUrl}/driver-portal\n\nKeep this PIN private -- it is the only way to access your Driver Portal account.`,
    entityType: "driver",
    entityId: driverId,
    sentBy: null,
    idempotencyBaseKey: `driver_portal_access_provisioned:${driverId}`,
  }).catch((e) => console.error("[drivers/applications] driver portal access email failed:", e));
}

// Phase 2Q.2B: the carrier_id form field is now only meaningful for a
// LEGACY application that predates carrier-at-invite-time (carrier_id is
// null on the row) -- the public, anonymous /driver-application flow is
// the one remaining real case, since it has never had a carrier-selection
// step. For every carrier-invited application, carrier_id is already set
// and immutable from Invite Driver onward; convert_driver_application_to_
// driver() (0109) uses THAT value unconditionally and ignores whatever
// this form field carries, so a stray/tampered client value can never
// redirect a carrier-bound application to a different carrier (Section G).
export async function convertApplicationToDriver(applicationId: string, formData: FormData) {
  await requireOperationalAccess(); // D.2.11 SaaS paywall -- before any write.
  const carrierIdField = String(formData.get("carrier_id") || "") || null;

  const supabase = await createClient();
  const [{ data: application }, { data: org }] = await Promise.all([
    supabase.from("driver_applications").select("first_name, phone, email, carrier_id").eq("id", applicationId).maybeSingle(),
    getCurrentOrgId().then((id) => supabase.from("organizations").select("name").eq("id", id).maybeSingle()),
  ]);
  if (!application) throw new Error("Application not found.");
  if (!application.carrier_id && !carrierIdField) throw new Error("Select a carrier to convert this application into a driver record.");

  const { data: driverId, error } = await supabase.rpc("convert_driver_application_to_driver", {
    p_application_id: applicationId,
    p_carrier_id: carrierIdField,
  });
  if (error) throw new Error(error.message);

  await provisionDriverPortalAccess(supabase, driverId as string, application.phone, application.email, application.first_name, org?.name ?? null);

  revalidatePath("/drivers/applications");
  redirect(`/drivers/${driverId}`);
}

// Documents live in a private Storage bucket -- generate a short-lived
// signed URL server-side rather than exposing the bucket to the client.
// Re-checks the same owner/admin/dispatcher gate the table's RLS policy
// uses, since the service-role client bypasses RLS entirely.
export async function getApplicationDocumentUrl(applicationId: string, storagePath: string): Promise<string> {
  const supabase = await createClient();
  const { data: application, error: appError } = await supabase
    .from("driver_applications")
    .select("id")
    .eq("id", applicationId)
    .maybeSingle();
  if (appError || !application) {
    throw new Error("Application not found or you don't have access to it.");
  }
  if (!storagePath.startsWith(`${applicationId}/`)) {
    throw new Error("Document does not belong to this application.");
  }

  const serviceClient = createServiceRoleClient();
  const { data, error } = await serviceClient.storage
    .from("driver-application-documents")
    .createSignedUrl(storagePath, 300);
  if (error || !data) throw new Error(error?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}

// ---------------------------------------------------------------------------
// Phase 2Q.2 -- carrier-invited driver onboarding: invite / resend / cancel
// / needs-correction. Mirrors src/app/(app)/carriers/onboarding/actions.ts's
// inviteCarrier()/resendInvitation() exactly (organization derived
// server-side from getCurrentOrgId(), never trusted from the browser).
// NOT YET LIVE: depends on migration 0108, not applied.
// ---------------------------------------------------------------------------

// Owner/admin only -- deliberately NOT extended to dispatcher (spec
// Section C explicitly asks this to be audited, not granted
// automatically). Dispatcher already has update/review rights over an
// EXISTING application (0018's driver_applications_update policy), but
// creating a new one and emailing an invitation on the org's behalf is a
// more consequential, outward-facing action; recommend keeping this
// owner/admin-only unless the business decides otherwise (2Q.2 report
// Section 5).
async function requireInviteRole(supabase: Awaited<ReturnType<typeof createClient>>) {
  const { data: role } = await supabase.rpc("current_role");
  if (!["owner", "admin"].includes((role as string | null) ?? "")) {
    throw new Error("Only owners and admins may invite a driver.");
  }
}

export async function inviteDriverApplication(formData: FormData): Promise<{ ok: true; applicationId: string; url: string; emailSent: boolean } | { ok: false; error: string }> {
  const supabase = await createClient();
  try {
    await requireInviteRole(supabase);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Not authorized." };
  }
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  const firstName = str(formData, "first_name");
  const lastName = str(formData, "last_name");
  const email = str(formData, "email");
  const phone = str(formData, "phone");
  const carrierId = str(formData, "carrier_id");
  const workerTypeRaw = str(formData, "worker_type");
  const workerType = (["company_driver", "independent_contractor", "owner_operator"] as const).includes(workerTypeRaw as never) ? workerTypeRaw : "company_driver";
  if (!firstName || !lastName) return { ok: false, error: "First and last name are required." };
  if (!email && !phone) return { ok: false, error: "A phone number or email address is required to send the invitation." };

  // Phase 2Q.2B: carrier is never trusted at face value from the browser
  // -- re-validated here (belongs to this org, is active) in addition to
  // the identical check the driver_applications_insert_staff RLS policy
  // (0109) independently enforces at the database layer. A foreign or
  // random carrier id fails this exact same generic message either way.
  if (!carrierId) return { ok: false, error: "Select which carrier this driver will work for." };
  const { data: carrier } = await supabase.from("carriers").select("id, legal_name").eq("id", carrierId).eq("organization_id", organizationId).eq("is_active", true).maybeSingle();
  if (!carrier) return { ok: false, error: "Carrier not found in your organization." };

  const { data: application, error: appError } = await supabase
    .from("driver_applications")
    .insert({
      organization_id: organizationId,
      status: "invited",
      first_name: firstName,
      last_name: lastName,
      email,
      phone,
      carrier_id: carrier.id,
      worker_type: workerType,
      signature_name: "", // required not-null column; the driver provides the real signature at the Agreement step
      invited_by: user.id,
    })
    .select("id")
    .single();
  if (appError || !application) return { ok: false, error: appError?.message ?? "Could not create the invitation." };

  const invitation = await issueDriverOnboardingInvitation({ applicationId: application.id, organizationId, createdBy: user.id });

  await supabase.rpc("log_activity", { p_entity_type: "driver_application", p_entity_id: application.id, p_action: "driver_invited", p_changes: {} });

  // Phase 2Q.2B: names the SELECTED CARRIER, not the tenant organization
  // -- the two can genuinely differ in a multi-carrier org (confirmed
  // root cause of the "invitations only say Kali" report: this email
  // previously always used organizations.name regardless of which
  // carrier the driver would actually work for). Never names any OTHER
  // carrier the same organization manages.
  let emailSent = false;
  if (email) {
    const auth = await resolveEmailAuthorizationContext();
    if (auth.ok) {
      const result = await sendTenantEmail({
        authContext: auth.context,
        emailPurpose: "driver_onboarding_invitation",
        to: [email],
        subject: `${carrier.legal_name} has invited you to complete Driver Onboarding`,
        text: `Hi ${firstName},\n\n${carrier.legal_name} would like to bring you on as a driver. Please complete your driver onboarding using the secure link below. This link expires in 14 days.\n\n${invitation.url}\n\nIf you have any questions, contact ${carrier.legal_name} directly.`,
        entityType: "driver_application",
        entityId: application.id,
        sentBy: user.id,
        idempotencyBaseKey: `driver_onboarding_invitation_sent:${application.id}`,
      });
      emailSent = result.ok;
    }
  }

  revalidatePath("/drivers/applications");
  revalidatePath("/drivers");
  return { ok: true, applicationId: application.id, url: invitation.url, emailSent };
}

export async function resendDriverOnboardingInvitation(applicationId: string): Promise<{ ok: true; url: string; emailSent: boolean } | { ok: false; error: string }> {
  const supabase = await createClient();
  try {
    await requireInviteRole(supabase);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Not authorized." };
  }
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  const { data: application } = await supabase.from("driver_applications").select("id, first_name, email, status, carrier_id, carriers(legal_name)").eq("id", applicationId).maybeSingle();
  if (!application) return { ok: false, error: "Application not found." };
  if (!["invited", "in_progress", "needs_correction"].includes(application.status)) {
    return { ok: false, error: "This application is no longer waiting on the driver -- an invitation can't be resent." };
  }
  if (!application.email) return { ok: false, error: "No email address on file for this application." };

  const service = createServiceRoleClient();
  await service
    .from("driver_onboarding_invitations")
    .update({ revoked_at: new Date().toISOString(), revoked_by: user.id })
    .eq("application_id", applicationId)
    .is("revoked_at", null)
    .is("submitted_at", null);

  const invitation = await issueDriverOnboardingInvitation({ applicationId, organizationId, createdBy: user.id });
  await supabase.rpc("log_activity", { p_entity_type: "driver_application", p_entity_id: applicationId, p_action: "driver_invitation_resent", p_changes: {} });

  // Same carrier-naming rule as inviteDriverApplication() -- names the
  // application's own carrier, falling back to "the company" only for a
  // legacy pre-2Q.2B application with no carrier_id at all.
  const carrierName = (application.carriers as unknown as { legal_name: string } | null)?.legal_name ?? "the company";
  let emailSent = false;
  const auth = await resolveEmailAuthorizationContext();
  if (auth.ok) {
    const result = await sendTenantEmail({
      authContext: auth.context,
      emailPurpose: "driver_onboarding_invitation",
      to: [application.email],
      subject: `${carrierName} has invited you to complete Driver Onboarding`,
      text: `Hi ${application.first_name},\n\nHere is a fresh secure link to complete your driver onboarding with ${carrierName}. This link expires in 14 days.\n\n${invitation.url}`,
      entityType: "driver_application",
      entityId: applicationId,
      sentBy: user.id,
      idempotencyBaseKey: `driver_onboarding_invitation_resent:${applicationId}:${invitation.invitationId}`,
    });
    emailSent = result.ok;
  }

  revalidatePath(`/drivers/applications/${applicationId}`);
  return { ok: true, url: invitation.url, emailSent };
}

export async function cancelDriverOnboardingInvitation(applicationId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  try {
    await requireInviteRole(supabase);
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "Not authorized." };
  }
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: application } = await supabase.from("driver_applications").select("id, status").eq("id", applicationId).maybeSingle();
  if (!application) return { ok: false, error: "Application not found." };
  if (["converted", "cancelled"].includes(application.status)) {
    return { ok: false, error: "This application cannot be cancelled." };
  }

  const { error } = await supabase.from("driver_applications").update({ status: "cancelled" }).eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  const service = createServiceRoleClient();
  await service
    .from("driver_onboarding_invitations")
    .update({ revoked_at: new Date().toISOString(), revoked_by: user?.id ?? null })
    .eq("application_id", applicationId)
    .is("revoked_at", null);

  await supabase.rpc("log_activity", { p_entity_type: "driver_application", p_entity_id: applicationId, p_action: "driver_invitation_cancelled", p_changes: {} });

  revalidatePath(`/drivers/applications/${applicationId}`);
  revalidatePath("/drivers/applications");
  return { ok: true };
}

export async function setDriverApplicationNeedsCorrection(applicationId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const reason = str(formData, "correction_reason");
  if (!reason) return { ok: false, error: "A reason is required so the driver knows what to correct." };
  if (reason.length > 2000) return { ok: false, error: "Reason is too long (2000 characters max)." };

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { error } = await supabase
    .from("driver_applications")
    .update({ status: "needs_correction", correction_reason: reason, reviewed_by: user?.id ?? null, reviewed_at: new Date().toISOString() })
    .eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  await supabase.rpc("log_activity", { p_entity_type: "driver_application", p_entity_id: applicationId, p_action: "driver_needs_correction", p_changes: {} });

  revalidatePath(`/drivers/applications/${applicationId}`);
  revalidatePath("/drivers/applications");
  return { ok: true };
}

// driver_onboarding_invitations has RLS enabled with ZERO policies
// (service-role-only, see 0108's table comment) -- this re-checks the
// caller's own org/role via the authenticated client FIRST, exactly like
// getApplicationDocumentUrl() above, before using the service-role client
// for the one thing RLS structurally cannot do here.
export async function getDriverOnboardingInvitations(applicationId: string) {
  const supabase = await createClient();
  const { data: application } = await supabase.from("driver_applications").select("id").eq("id", applicationId).maybeSingle();
  if (!application) return [];

  const service = createServiceRoleClient();
  const { data } = await service
    .from("driver_onboarding_invitations")
    .select("id, expires_at, created_at, first_viewed_at, last_viewed_at, revoked_at, submitted_at")
    .eq("application_id", applicationId)
    .order("created_at", { ascending: false });
  return data ?? [];
}
