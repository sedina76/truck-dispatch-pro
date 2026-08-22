"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentOrgId } from "@/lib/actions/records";
import { issueCarrierOnboardingInvitation } from "@/lib/carrier-onboarding/invitation";
import { resolveEmailAuthorizationContext } from "@/lib/email/authorization";
import { sendTenantEmail } from "@/lib/email/send-pipeline";
import { generateExecutedAgreementDocument } from "@/lib/carrier-agreements/executed-document";
import { getStaffExecutedAgreementSignedUrl } from "@/lib/carrier-agreements/signed-url";
import { ExecutedAgreementAccessDeniedError, ExecutedAgreementResourceNotFoundError } from "@/lib/carrier-agreements/errors";

// ---------------------------------------------------------------------------
// Staff-side onboarding workspace actions. Everything that only needs
// RLS-scoped table access uses the regular (authenticated) client -- the
// exact same 0081/0082 policies already gate owner/admin/dispatcher
// correctly. service-role is used ONLY for the two things RLS
// structurally cannot do: issuing a hashed invitation into a
// zero-policy table, and generating a signed URL against a
// zero-Storage-RLS bucket -- both re-verify the caller's own org/role via
// the regular client FIRST, mirroring drivers/applications/actions.ts's
// own getApplicationDocumentUrl() precedent exactly.
// ---------------------------------------------------------------------------

function str(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  if (typeof v !== "string") return null;
  const trimmed = v.trim();
  return trimmed === "" ? null : trimmed;
}

type RequiredAgreementRpcResult = {
  requirement_count?: number;
  assigned_count?: number;
  existing_count?: number;
  template_keys?: string[];
};

type AgreementAssignmentRpcResult = {
  assignment_status?: "assigned" | "conflict";
  signing_id?: string;
};

const ACTIVITY_WARNING = "The workflow completed, but its activity log could not be recorded. Contact support before retrying.";

async function logCarrierOnboardingActivity(
  supabase: Awaited<ReturnType<typeof createClient>>,
  applicationId: string,
  action: string,
  changes: Record<string, unknown>,
): Promise<string | null> {
  const { error } = await supabase.rpc("log_activity", {
    p_entity_type: "carrier_onboarding_application",
    p_entity_id: applicationId,
    p_action: action,
    p_changes: changes,
  });
  if (!error) return null;
  console.error("Carrier onboarding activity logging failed.", {
    action,
    applicationId,
    code: error.code,
  });
  return ACTIVITY_WARNING;
}

export async function generateExecutedAgreement(applicationId: string, signingId: string): Promise<{ ok: true; state: "generated" | "generating" } | { ok: false; error: string }> {
  const supabase = await createClient();
  const [{ data: role }, { data: signing }] = await Promise.all([
    supabase.rpc("current_role"),
    supabase.from("carrier_agreement_signings").select("id, status, application_id, generated_document_id").eq("id", signingId).eq("application_id", applicationId).maybeSingle(),
  ]);
  if (!signing) return { ok: false, error: "Agreement not found." };
  if (!["owner", "admin"].includes((role as string | null) ?? "viewer")) return { ok: false, error: "Only owners and admins may generate executed agreements." };
  if (!["completed", "voided"].includes(signing.status)) return { ok: false, error: "Only completed signing evidence can generate an executed agreement." };
  const result = await generateExecutedAgreementDocument(signing.id);
  if (result.state === "failed") return { ok: false, error: result.error };
  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true, state: result.state };
}

export async function getExecutedAgreementUrl(applicationId: string, signingId: string, download = false): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  try {
    const result = await getStaffExecutedAgreementSignedUrl(applicationId, signingId, download);
    return { ok: true, url: result.url };
  } catch (error) {
    if (error instanceof ExecutedAgreementResourceNotFoundError) return { ok: false, error: "Signed agreement not found." };
    if (error instanceof ExecutedAgreementAccessDeniedError) return { ok: false, error: "You do not have permission to access executed agreements." };
    return { ok: false, error: "Could not open the signed agreement." };
  }
}

export async function inviteCarrier(formData: FormData): Promise<{ ok: true; applicationId: string; url: string; expiresAt: string; emailSent: boolean; auditWarning?: string } | { ok: false; error: string }> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  const legalName = str(formData, "legal_name");
  const contactName = str(formData, "contact_name");
  const email = str(formData, "email");
  if (!legalName || !contactName || !email) {
    return { ok: false, error: "Company name, contact name, and email are required." };
  }

  const { data: application, error: appError } = await supabase
    .from("carrier_onboarding_applications")
    .insert({
      organization_id: organizationId,
      status: "draft",
      legal_name: legalName,
      dba_name: str(formData, "dba_name"),
      contact_name: contactName,
      email,
      phone: str(formData, "phone"),
      mc_number: str(formData, "mc_number"),
      dot_number: str(formData, "dot_number"),
      proposed_dispatch_fee_percentage: formData.get("dispatch_fee_percentage") ? Number(formData.get("dispatch_fee_percentage")) : null,
      proposed_payment_terms_days: formData.get("payment_terms_days") ? Number(formData.get("payment_terms_days")) : null,
      factoring_company_name: str(formData, "factoring_company_name"),
      has_factoring: formData.get("has_factoring") === "on",
    })
    .select("id")
    .single();
  if (appError || !application) return { ok: false, error: appError?.message ?? "Could not create the application." };

  const { data: initialized, error: initializeError } = await supabase.rpc("initialize_carrier_required_agreements", {
    p_application_id: application.id,
  });
  if (initializeError) {
    return { ok: false, error: "The application was saved, but its required agreements could not be prepared. Open the application and initialize its required agreements before sending an invitation." };
  }
  const initialization = (initialized ?? {}) as RequiredAgreementRpcResult;
  let auditWarning = await logCarrierOnboardingActivity(
    supabase,
    application.id,
    "carrier_agreement_requirements_initialized",
    { requirement_count: initialization.requirement_count ?? 0, template_keys: initialization.template_keys ?? [] },
  );

  const invitation = await issueCarrierOnboardingInvitation({ applicationId: application.id, organizationId, createdBy: user.id });

  auditWarning ??= await logCarrierOnboardingActivity(supabase, application.id, "invitation_sent", {});

  // Email is best-effort ONLY -- invitation creation must never fail or
  // appear to fail because a provider isn't configured (spec section 14).
  // Staff always get the Copy Invitation Link regardless of this result.
  let emailSent = false;
  const auth = await resolveEmailAuthorizationContext();
  if (auth.ok) {
    const result = await sendTenantEmail({
      authContext: auth.context,
      emailPurpose: "carrier_onboarding_invitation",
      to: [email],
      subject: `${legalName} -- Carrier Onboarding Invitation`,
      text: `Hello ${contactName},\n\nPlease complete your carrier onboarding packet using the secure link below. This link expires in 14 days.\n\n${invitation.url}`,
      entityType: "carrier_onboarding_application",
      entityId: application.id,
      sentBy: user.id,
      idempotencyBaseKey: `carrier_onboarding_invitation_sent:${application.id}`,
    });
    emailSent = result.ok;
  }

  revalidatePath("/carriers/onboarding");
  return { ok: true, applicationId: application.id, url: invitation.url, expiresAt: invitation.expiresAt.toISOString(), emailSent, ...(auditWarning ? { auditWarning } : {}) };
}

export async function resendInvitation(applicationId: string): Promise<{ ok: true; url: string; emailSent: boolean; auditWarning?: string } | { ok: false; error: string }> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };

  const { data: application, error } = await supabase
    .from("carrier_onboarding_applications")
    .select("id, legal_name, contact_name, email, status, agreement_requirements_initialized_at")
    .eq("id", applicationId)
    .maybeSingle();
  if (error || !application) return { ok: false, error: "Application not found." };
  if (!["draft", "needs_correction"].includes(application.status)) {
    return { ok: false, error: "This application is no longer waiting on the carrier -- an invitation can't be resent." };
  }
  if (!application.email) return { ok: false, error: "No email address on file for this application." };
  if (!application.agreement_requirements_initialized_at) {
    return { ok: false, error: "Agreement requirements have not been initialized. Initialize Required Agreements before resending the invitation." };
  }

  const { data: reconciled, error: reconcileError } = await supabase.rpc("assign_missing_carrier_required_agreements", {
    p_application_id: applicationId,
  });
  if (reconcileError) return { ok: false, error: "Required agreements could not be prepared. Resolve the agreement requirement issue before resending the invitation." };
  const reconciliation = (reconciled ?? {}) as RequiredAgreementRpcResult;
  let auditWarning: string | null = null;
  if ((reconciliation.assigned_count ?? 0) > 0) {
    auditWarning = await logCarrierOnboardingActivity(
      supabase,
      applicationId,
      "carrier_required_agreements_assigned",
      { assigned_count: reconciliation.assigned_count, template_keys: reconciliation.template_keys ?? [] },
    );
  }

  // Revoke any still-active prior invitations for this application so
  // only the freshest link ever works -- avoids two simultaneously-valid
  // links being confusing (or one leaked older link staying usable
  // indefinitely).
  const service = createServiceRoleClient();
  await service
    .from("carrier_onboarding_invitations")
    .update({ revoked_at: new Date().toISOString(), revoked_by: user.id })
    .eq("application_id", applicationId)
    .is("revoked_at", null)
    .is("submitted_at", null);

  const invitation = await issueCarrierOnboardingInvitation({ applicationId, organizationId, createdBy: user.id });

  auditWarning ??= await logCarrierOnboardingActivity(supabase, applicationId, "invitation_resent", {});

  let emailSent = false;
  const auth = await resolveEmailAuthorizationContext();
  if (auth.ok) {
    const result = await sendTenantEmail({
      authContext: auth.context,
      emailPurpose: "carrier_onboarding_invitation",
      to: [application.email],
      subject: `${application.legal_name ?? "Carrier"} -- Carrier Onboarding Invitation`,
      text: `Hello ${application.contact_name ?? ""},\n\nHere is a fresh secure link to complete your carrier onboarding packet. This link expires in 14 days.\n\n${invitation.url}`,
      entityType: "carrier_onboarding_application",
      entityId: applicationId,
      sentBy: user.id,
      idempotencyBaseKey: `carrier_onboarding_invitation_resent:${applicationId}:${invitation.invitationId}`,
    });
    emailSent = result.ok;
  }

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true, url: invitation.url, emailSent, ...(auditWarning ? { auditWarning } : {}) };
}

export async function cancelInvitation(applicationId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const service = createServiceRoleClient();
  await service
    .from("carrier_onboarding_invitations")
    .update({ revoked_at: new Date().toISOString(), revoked_by: user?.id ?? null })
    .eq("application_id", applicationId)
    .is("revoked_at", null);
  await service.from("carrier_onboarding_sessions").update({ revoked_at: new Date().toISOString() }).eq("application_id", applicationId).is("revoked_at", null);

  const { error } = await supabase.from("carrier_onboarding_applications").update({ status: "cancelled" }).eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  revalidatePath("/carriers/onboarding");
  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true };
}

export async function requestCorrection(applicationId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const notes = str(formData, "notes");
  if (!notes) return { ok: false, error: "Please describe what needs to be corrected." };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { error } = await supabase
    .from("carrier_onboarding_applications")
    .update({ status: "needs_correction", review_notes: notes, reviewed_at: new Date().toISOString(), reviewed_by: user?.id ?? null })
    .eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  revalidatePath("/carriers/onboarding");
  return { ok: true };
}

export async function approveApplication(applicationId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { error } = await supabase
    .from("carrier_onboarding_applications")
    .update({ status: "approved", reviewed_at: new Date().toISOString(), reviewed_by: user?.id ?? null, review_notes: null })
    .eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  revalidatePath("/carriers/onboarding");
  return { ok: true };
}

export async function rejectApplication(applicationId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const notes = str(formData, "notes");
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { error } = await supabase
    .from("carrier_onboarding_applications")
    .update({ status: "rejected", review_notes: notes, reviewed_at: new Date().toISOString(), reviewed_by: user?.id ?? null })
    .eq("id", applicationId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  revalidatePath("/carriers/onboarding");
  return { ok: true };
}

export async function convertApplication(applicationId: string): Promise<{ ok: true; carrierId: string } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("convert_carrier_onboarding_application", { p_application_id: applicationId });
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  revalidatePath("/carriers/onboarding");
  revalidatePath("/carriers");
  return { ok: true, carrierId: data as string };
}

export async function assignAgreementTemplate(applicationId: string, templateId: string): Promise<{ ok: true; auditWarning?: string } | { ok: false; error: string }> {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc("assign_carrier_agreement_template", {
    p_application_id: applicationId,
    p_template_id: templateId,
  });
  if (error) {
    if (error.code === "P2703") {
      return { ok: false, error: "Only a published template can be assigned." };
    }
    if (error.code === "P2704") {
      return { ok: false, error: "This agreement template has not been published correctly and cannot be assigned." };
    }
    if (error.code === "P2702") {
      return { ok: false, error: "Application or agreement template not found." };
    }
    if (error.code === "P2701") {
      return { ok: false, error: "You do not have permission to assign carrier agreements." };
    }
    return { ok: false, error: "Could not assign the agreement. Please try again." };
  }
  const assignment = (data ?? {}) as AgreementAssignmentRpcResult;
  if (assignment.assignment_status === "conflict") {
    return { ok: false, error: "An active version of this agreement is already assigned. Void the existing agreement before assigning another version." };
  }
  if (assignment.assignment_status !== "assigned" || !assignment.signing_id) {
    return { ok: false, error: "Could not assign the agreement. Please try again." };
  }

  const auditWarning = await logCarrierOnboardingActivity(
    supabase,
    applicationId,
    "agreement_assigned",
    { signing_id: assignment.signing_id, template_id: templateId },
  );

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true, ...(auditWarning ? { auditWarning } : {}) };
}

export async function initializeRequiredAgreements(applicationId: string): Promise<{ ok: true; auditWarning?: string } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };
  const { data, error } = await supabase.rpc("initialize_carrier_required_agreements", { p_application_id: applicationId });
  if (error) return { ok: false, error: error.message };
  const result = (data ?? {}) as RequiredAgreementRpcResult;
  const auditWarning = await logCarrierOnboardingActivity(
    supabase,
    applicationId,
    "carrier_agreement_requirements_initialized",
    { requirement_count: result.requirement_count ?? 0, template_keys: result.template_keys ?? [] },
  );
  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true, ...(auditWarning ? { auditWarning } : {}) };
}

export async function assignMissingRequiredAgreements(applicationId: string): Promise<{ ok: true; auditWarning?: string } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "Not authenticated." };
  const { data, error } = await supabase.rpc("assign_missing_carrier_required_agreements", { p_application_id: applicationId });
  if (error) return { ok: false, error: error.message };
  const result = (data ?? {}) as RequiredAgreementRpcResult;
  let auditWarning: string | null = null;
  if ((result.assigned_count ?? 0) > 0) {
    auditWarning = await logCarrierOnboardingActivity(
      supabase,
      applicationId,
      "carrier_required_agreements_assigned",
      { assigned_count: result.assigned_count, template_keys: result.template_keys ?? [] },
    );
  }
  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true, ...(auditWarning ? { auditWarning } : {}) };
}

export async function verifyOnboardingDocument(documentId: string, applicationId: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { error } = await supabase
    .from("documents")
    .update({ is_verified: true, verified_by: user?.id ?? null, verified_at: new Date().toISOString(), rejected_at: null, rejected_by: null, rejection_reason: null })
    .eq("id", documentId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true };
}

export async function rejectOnboardingDocument(documentId: string, applicationId: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const reason = str(formData, "reason");
  if (!reason) return { ok: false, error: "A rejection reason is required." };

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { error } = await supabase
    .from("documents")
    .update({ is_verified: false, rejected_at: new Date().toISOString(), rejected_by: user?.id ?? null, rejection_reason: reason })
    .eq("id", documentId);
  if (error) return { ok: false, error: error.message };

  revalidatePath(`/carriers/onboarding/${applicationId}`);
  return { ok: true };
}

// Documents live in a private, zero-Storage-RLS bucket (0081) -- generate
// a short-lived signed URL server-side, mirroring
// drivers/applications/actions.ts's getApplicationDocumentUrl() exactly:
// verify org/role access via the regular RLS-scoped client FIRST, then
// use service-role only for the signed-URL call itself.
export async function getOnboardingDocumentUrl(applicationId: string, storagePath: string): Promise<string> {
  const supabase = await createClient();
  const organizationId = await getCurrentOrgId();
  const { data: application, error } = await supabase.from("carrier_onboarding_applications").select("id").eq("id", applicationId).maybeSingle();
  if (error || !application) throw new Error("Application not found or you don't have access to it.");
  if (!storagePath.startsWith(`${organizationId}/${applicationId}/`)) {
    throw new Error("Document does not belong to this application.");
  }

  const service = createServiceRoleClient();
  const { data, error: signError } = await service.storage.from("carrier-onboarding-documents").createSignedUrl(storagePath, 300);
  if (signError || !data) throw new Error(signError?.message ?? "Could not generate a document link.");
  return data.signedUrl;
}
