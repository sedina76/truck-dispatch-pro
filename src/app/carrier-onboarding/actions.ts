"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import {
  CarrierOnboardingSessionUnavailableError,
  requireCarrierOnboardingSession,
  type CarrierOnboardingIdentity,
} from "@/lib/carrier-onboarding/session";
import { getEffectiveOnboardingRequirements, type RequirementItem } from "@/lib/carrier-onboarding/requirements";
import { validateUploadedFile } from "@/lib/documents/validate-upload";
import { generateExecutedAgreementDocument } from "@/lib/carrier-agreements/executed-document";
import { getCarrierExecutedAgreementSignedUrl } from "@/lib/carrier-agreements/signed-url";
import { ExecutedAgreementResourceNotFoundError } from "@/lib/carrier-agreements/errors";
import { getRequiredAgreementReadiness } from "@/lib/carrier-agreements/required-readiness";

// ---------------------------------------------------------------------------
// Every action here follows the exact rule driver-portal/actions.ts already
// established (see that file's own header comment): resolve the
// session-derived application/organization identity FIRST via
// requireCarrierOnboardingSession(), then verify ownership of whatever
// record is being touched -- never a client-supplied application_id/
// organization_id/signing_id trusted as-is. The carrier portal has no
// Supabase Auth session at all, so service-role is used deliberately, with
// the session/ownership check standing in for RLS.
// ---------------------------------------------------------------------------

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // matches the bucket's own file_size_limit (0081)
const ALLOWED_UPLOAD_TYPES = new Set(["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif"]);
const SESSION_ENDED_MESSAGE = "Your onboarding session has ended. Please use your invitation link again.";

async function requireCarrierPageIdentity(): Promise<CarrierOnboardingIdentity> {
  try {
    return await requireCarrierOnboardingSession();
  } catch (error) {
    if (error instanceof CarrierOnboardingSessionUnavailableError) redirect("/carrier-onboarding/invalid");
    throw error;
  }
}

async function getCarrierActionIdentity(): Promise<CarrierOnboardingIdentity | null> {
  try {
    return await requireCarrierOnboardingSession();
  } catch (error) {
    if (error instanceof CarrierOnboardingSessionUnavailableError) return null;
    throw error;
  }
}

async function clientIp(): Promise<string | null> {
  const h = await headers();
  const forwardedFor = h.get("x-forwarded-for");
  return forwardedFor ? forwardedFor.split(",")[0].trim() : null;
}
async function clientUserAgent(): Promise<string | null> {
  const h = await headers();
  return h.get("user-agent");
}

// ---------------------------------------------------------------------------
// Application data
// ---------------------------------------------------------------------------

export type MyApplication = {
  id: string;
  status: string;
  legalName: string | null;
  dbaName: string | null;
  mcNumber: string | null;
  dotNumber: string | null;
  contactName: string | null;
  phone: string | null;
  email: string | null;
  addressLine1: string | null;
  addressLine2: string | null;
  city: string | null;
  state: string | null;
  postalCode: string | null;
  country: string | null;
  einLast4: string | null;
  factoringCompanyName: string | null;
  hasFactoring: boolean | null;
  proposedDispatchFeePercentage: number | null;
  proposedPaymentTermsDays: number | null;
  equipmentData: Record<string, unknown> | null;
  reviewNotes: string | null;
};

const APPLICATION_SELECT =
  "id, status, legal_name, dba_name, mc_number, dot_number, contact_name, phone, email, address_line1, address_line2, city, state, postal_code, country, ein_last4, factoring_company_name, has_factoring, proposed_dispatch_fee_percentage, proposed_payment_terms_days, equipment_data, review_notes";

export async function getMyApplication(): Promise<MyApplication> {
  const identity = await requireCarrierPageIdentity();
  const supabase = createServiceRoleClient();
  const { data, error } = await supabase.from("carrier_onboarding_applications").select(APPLICATION_SELECT).eq("id", identity.applicationId).single();
  if (error || !data) throw new Error("Application not found.");

  return {
    id: data.id,
    status: data.status,
    legalName: data.legal_name,
    dbaName: data.dba_name,
    mcNumber: data.mc_number,
    dotNumber: data.dot_number,
    contactName: data.contact_name,
    phone: data.phone,
    email: data.email,
    addressLine1: data.address_line1,
    addressLine2: data.address_line2,
    city: data.city,
    state: data.state,
    postalCode: data.postal_code,
    country: data.country,
    einLast4: data.ein_last4,
    factoringCompanyName: data.factoring_company_name,
    hasFactoring: data.has_factoring,
    proposedDispatchFeePercentage: data.proposed_dispatch_fee_percentage != null ? Number(data.proposed_dispatch_fee_percentage) : null,
    proposedPaymentTermsDays: data.proposed_payment_terms_days,
    equipmentData: (data.equipment_data as Record<string, unknown> | null) ?? null,
    reviewNotes: data.review_notes,
  };
}

function str(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  if (typeof v !== "string") return null;
  const trimmed = v.trim();
  return trimmed === "" ? null : trimmed;
}

export async function saveCompanyInfo(formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();

  const legalName = str(formData, "legal_name");
  if (!legalName) return { ok: false, error: "Legal company name is required." };

  const patch: Record<string, unknown> = {
    legal_name: legalName,
    dba_name: str(formData, "dba_name"),
    contact_name: str(formData, "contact_name"),
    phone: str(formData, "phone"),
    email: str(formData, "email"),
    address_line1: str(formData, "address_line1"),
    address_line2: str(formData, "address_line2"),
    city: str(formData, "city"),
    state: str(formData, "state"),
    postal_code: str(formData, "postal_code"),
    country: str(formData, "country") ?? "US",
    mc_number: str(formData, "mc_number"),
    dot_number: str(formData, "dot_number"),
    factoring_company_name: str(formData, "factoring_company_name"),
    has_factoring: formData.get("has_factoring") === "on" || formData.get("has_factoring") === "true",
  };

  // EIN: the form field is NEVER prefilled with a real value (the page
  // only ever shows a masked "on file: ***1234" hint) -- so a blank
  // submission here means "leave it unchanged," never "clear it." Only a
  // genuinely typed value triggers encryption + overwrite. Encryption
  // itself happens exclusively inside encrypt_carrier_onboarding_ein()
  // (0084), whose EXECUTE grant is restricted to service_role -- exactly
  // the client this action already uses.
  const ein = str(formData, "ein");
  if (ein) {
    const digits = ein.replace(/[^0-9]/g, "");
    if (digits.length !== 9) return { ok: false, error: "EIN must be 9 digits (formatted as XX-XXXXXXX or digits only)." };
    const { data: encrypted, error: encryptError } = await supabase.rpc("encrypt_carrier_onboarding_ein", { p_ein: digits });
    if (encryptError) return { ok: false, error: "Could not securely store the EIN. Please try again." };
    patch.ein_encrypted = encrypted;
    patch.ein_last4 = digits.slice(-4);
  }

  const { error } = await supabase.from("carrier_onboarding_applications").update(patch).eq("id", identity.applicationId);
  if (error) return { ok: false, error: error.message };

  revalidatePath("/carrier-onboarding/company");
  revalidatePath("/carrier-onboarding/review");
  return { ok: true };
}

export type EquipmentData = {
  equipment_type: string | null;
  truck_count: number | null;
  trailer_count: number | null;
  trailer_types: string[];
  preferred_freight: string | null;
  operating_regions: string[];
};

export async function saveEquipment(equipment: EquipmentData): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();
  const { error } = await supabase.from("carrier_onboarding_applications").update({ equipment_data: equipment }).eq("id", identity.applicationId);
  if (error) return { ok: false, error: error.message };
  revalidatePath("/carrier-onboarding/equipment");
  revalidatePath("/carrier-onboarding/review");
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

export type ChecklistItem = RequirementItem & {
  status: "missing" | "uploaded" | "rejected" | "accepted";
  documentId: string | null;
  fileName: string | null;
  rejectionReason: string | null;
};

export async function getDocumentChecklist(): Promise<ChecklistItem[]> {
  const identity = await requireCarrierPageIdentity();
  const supabase = createServiceRoleClient();

  const requirements = await getEffectiveOnboardingRequirements(supabase, identity.organizationId);
  const { data: docs } = await supabase
    .from("documents")
    .select("id, document_type, file_name, is_verified, rejected_at, rejection_reason, created_at")
    .eq("entity_type", "carrier_onboarding_application")
    .eq("entity_id", identity.applicationId)
    .order("created_at", { ascending: false });

  const latestByType = new Map<string, NonNullable<typeof docs>[number]>();
  for (const d of docs ?? []) {
    if (!latestByType.has(d.document_type)) latestByType.set(d.document_type, d);
  }

  return requirements.map((req) => {
    const doc = latestByType.get(req.documentType);
    if (!doc) return { ...req, status: "missing", documentId: null, fileName: null, rejectionReason: null };
    if (doc.rejected_at) return { ...req, status: "rejected", documentId: doc.id, fileName: doc.file_name, rejectionReason: doc.rejection_reason };
    if (doc.is_verified) return { ...req, status: "accepted", documentId: doc.id, fileName: doc.file_name, rejectionReason: null };
    return { ...req, status: "uploaded", documentId: doc.id, fileName: doc.file_name, rejectionReason: null };
  });
}

export async function uploadOnboardingDocument(documentType: string, formData: FormData): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };

  const file = formData.get("file");
  if (!(file instanceof File)) return { ok: false, error: "No file provided." };
  if (file.size === 0) return { ok: false, error: "The file is empty." };
  if (file.size > MAX_UPLOAD_BYTES) return { ok: false, error: "File is too large (10 MB max)." };
  if (!ALLOWED_UPLOAD_TYPES.has(file.type)) return { ok: false, error: "Unsupported file type. Use PDF, JPG, PNG, or HEIC." };

  const validation = await validateUploadedFile(file);
  if (!validation.ok) return { ok: false, error: validation.error };

  const supabase = createServiceRoleClient();
  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, "_").slice(-100);
  const storagePath = `${identity.organizationId}/${identity.applicationId}/${Date.now()}_${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from("carrier-onboarding-documents")
    .upload(storagePath, await file.arrayBuffer(), { contentType: file.type, upsert: false });
  if (uploadError) return { ok: false, error: uploadError.message };

  const { error: insertError } = await supabase.from("documents").insert({
    organization_id: identity.organizationId,
    entity_type: "carrier_onboarding_application",
    entity_id: identity.applicationId,
    document_type: documentType,
    file_name: file.name,
    file_path: storagePath,
    file_size_bytes: file.size,
    mime_type: file.type,
    uploaded_by: null,
  });
  if (insertError) return { ok: false, error: insertError.message };

  revalidatePath("/carrier-onboarding/documents");
  revalidatePath("/carrier-onboarding/review");
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Agreement / initials / signature
// ---------------------------------------------------------------------------

export type ClauseForSigning = { id: string; title: string; body: string; displayOrder: number; requiresInitials: boolean; typedInitials: string | null };
export type SigningForCarrier = {
  signingId: string;
  status: string;
  templateName: string;
  templateVersion: number;
  isRequiredForOnboarding: boolean;
  requiresSignerTitle: boolean;
  signedAt: string | null;
  generatedDocumentId: string | null;
  documentGenerationStatus: string;
  clauses: ClauseForSigning[];
};

// Phase 2L.4A -- there can legitimately be MORE THAN ONE active (non-
// voided) signing per application at once, one per distinct logical
// agreement family (template_key) -- 0084's own
// carrier_agreement_signings_active_uniqueness_guard trigger is what
// guarantees at most ONE per family, never that there's only one overall.
// The portal must never pick a single "winner" among different families by
// ordering/recency -- every active signing is returned and rendered/
// processed explicitly. (Multiple ACTIVE signings of the *same* family are
// now structurally impossible -- the trigger rejects that at the DB layer
// -- so there is no remaining ambiguity to resolve for a single family.)
async function listActiveSignings(supabase: ReturnType<typeof createServiceRoleClient>, applicationId: string) {
  const { data } = await supabase
    .from("carrier_agreement_signings")
    .select("id, status, agreement_template_id, content_hash, signed_at, generated_document_id, document_generation_status")
    .eq("application_id", applicationId)
    .neq("status", "voided")
    .order("assigned_at", { ascending: true });
  return data ?? [];
}

// Ownership check for a client-supplied signingId -- every action that
// takes one must call this FIRST and never trust the id blindly (spec
// section 26 -- never trust a client-supplied id without independent
// verification). A signing belongs to this session's application iff its
// own application_id matches exactly.
async function requireOwnedSigning(supabase: ReturnType<typeof createServiceRoleClient>, applicationId: string, signingId: string) {
  const { data } = await supabase
    .from("carrier_agreement_signings")
    .select("id, status, agreement_template_id, content_hash, application_id")
    .eq("id", signingId)
    .maybeSingle();
  if (!data || data.application_id !== applicationId) return null;
  return data;
}

export async function getAgreementsForSigning(): Promise<SigningForCarrier[]> {
  const identity = await requireCarrierPageIdentity();
  const supabase = createServiceRoleClient();

  const signings = await listActiveSignings(supabase, identity.applicationId);
  if (signings.length === 0) return [];

  const templateIds = signings.map((s) => s.agreement_template_id);
  const { data: templates } = await supabase
    .from("carrier_agreement_templates")
    .select("id, name, version_number, requires_signer_title, is_required_for_onboarding")
    .in("id", templateIds);
  const templateById = new Map((templates ?? []).map((t) => [t.id, t]));

  const { data: clauseRows } = await supabase
    .from("carrier_agreement_clauses")
    .select("id, agreement_template_id, title, body, display_order, requires_initials")
    .in("agreement_template_id", templateIds)
    .order("display_order");

  const { data: initialRows } = await supabase
    .from("carrier_agreement_initials")
    .select("signing_instance_id, clause_id, typed_initials")
    .in("signing_instance_id", signings.map((s) => s.id));
  const initialsBySigningClause = new Map((initialRows ?? []).map((i) => [`${i.signing_instance_id}:${i.clause_id}`, i.typed_initials]));

  return signings.map((signing) => {
    const template = templateById.get(signing.agreement_template_id);
    const clauses = (clauseRows ?? []).filter((c) => c.agreement_template_id === signing.agreement_template_id);
    return {
      signingId: signing.id,
      status: signing.status,
      templateName: template?.name ?? "Dispatch Agreement",
      templateVersion: template?.version_number ?? 1,
      isRequiredForOnboarding: template?.is_required_for_onboarding ?? false,
      requiresSignerTitle: template?.requires_signer_title ?? true,
      signedAt: signing.signed_at,
      generatedDocumentId: signing.generated_document_id,
      documentGenerationStatus: signing.document_generation_status ?? "pending",
      clauses: clauses.map((c) => ({
        id: c.id,
        title: c.title,
        body: c.body,
        displayOrder: c.display_order,
        requiresInitials: c.requires_initials,
        typedInitials: initialsBySigningClause.get(`${signing.id}:${c.id}`) ?? null,
      })),
    };
  });
}

export async function getMyRequiredAgreementReadiness() {
  const identity = await requireCarrierPageIdentity();
  return getRequiredAgreementReadiness(createServiceRoleClient(), identity.applicationId);
}

export async function recordInitial(signingId: string, clauseId: string, typedInitials: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const trimmed = typedInitials.trim().toUpperCase();
  if (!trimmed || trimmed.length > 8) return { ok: false, error: "Enter your initials (up to 8 characters)." };

  const supabase = createServiceRoleClient();
  const signing = await requireOwnedSigning(supabase, identity.applicationId, signingId);
  if (!signing) return { ok: false, error: "Agreement not found." };

  const ip = await clientIp();
  const ua = await clientUserAgent();

  // Upsert on the table's own unique (signing_instance_id, clause_id) --
  // this is exactly "carrier may correct initials before completion"
  // (spec section 13). guard_carrier_agreement_initial_consistency (0082)
  // independently re-verifies clause/template/org agreement and that the
  // signing hasn't already completed -- belt-and-suspenders, not trusted
  // to this action's own checks alone.
  const { error } = await supabase
    .from("carrier_agreement_initials")
    .upsert(
      { organization_id: identity.organizationId, signing_instance_id: signing.id, clause_id: clauseId, typed_initials: trimmed, ip_address: ip, user_agent: ua, updated_at: new Date().toISOString() },
      { onConflict: "signing_instance_id,clause_id" }
    );
  if (error) return { ok: false, error: "Could not save your initials. Please try again." };

  await supabase.from("carrier_agreement_audit_events").insert({
    organization_id: identity.organizationId,
    signing_instance_id: signing.id,
    event_type: "initial_recorded",
    actor_type: "carrier_signer",
    ip_address: ip,
    user_agent: ua,
    event_data: { clause_id: clauseId },
  });

  revalidatePath("/carrier-onboarding/agreement");
  return { ok: true };
}

const CONSENT_TEXT_VERSION = "carrier_agreement_econsent_v1";

export async function completeSigning(
  signingId: string,
  input: {
    signerName: string;
    signerTitle: string;
    typedSignature: string;
    consentAccepted: boolean;
  }
): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  if (!input.consentAccepted) return { ok: false, error: "You must agree to use electronic records and signatures." };

  const supabase = createServiceRoleClient();
  const signing = await requireOwnedSigning(supabase, identity.applicationId, signingId);
  if (!signing) return { ok: false, error: "Agreement not found." };

  const ip = await clientIp();
  const ua = await clientUserAgent();

  const { data, error } = await supabase.rpc("complete_carrier_agreement_signing", {
    p_signing_id: signing.id,
    p_signer_name: input.signerName.trim(),
    p_signer_title: input.signerTitle.trim() || null,
    p_typed_signature: input.typedSignature.trim(),
    p_consent_text_version: CONSENT_TEXT_VERSION,
    p_ip_address: ip,
    p_user_agent: ua,
  });
  if (error) return { ok: false, error: error.message };
  if (!data || (Array.isArray(data) && data.length === 0)) return { ok: false, error: "Could not complete the agreement. Please try again." };

  // Signing completion is already committed. Artifact failure must never
  // invalidate the legal signing or ask the carrier to sign again.
  await generateExecutedAgreementDocument(signing.id);

  revalidatePath("/carrier-onboarding/agreement");
  revalidatePath("/carrier-onboarding/review");
  return { ok: true };
}

export async function getMyExecutedAgreementUrl(signingId: string, download = false): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const service = createServiceRoleClient();
  const signing = await requireOwnedSigning(service, identity.applicationId, signingId);
  if (!signing) return { ok: false, error: "Signed agreement not found." };
  try {
    const result = await getCarrierExecutedAgreementSignedUrl(identity.applicationId, signingId, download);
    return { ok: true, url: result.url };
  } catch (error) {
    if (error instanceof ExecutedAgreementResourceNotFoundError) return { ok: false, error: "Signed agreement not found." };
    return { ok: false, error: "Could not open the signed agreement." };
  }
}

// ---------------------------------------------------------------------------
// Submission
// ---------------------------------------------------------------------------

export async function submitApplication(): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();

  const { data: application } = await supabase
    .from("carrier_onboarding_applications")
    .select("id, status, legal_name, contact_name, email, phone")
    .eq("id", identity.applicationId)
    .single();
  if (!application) return { ok: false, error: "Application not found." };
  if (!["draft", "needs_correction"].includes(application.status)) {
    return { ok: false, error: "This application has already been submitted." };
  }
  if (!application.legal_name || !application.contact_name || !application.email || !application.phone) {
    return { ok: false, error: "Please complete Company Information before submitting." };
  }

  const requirements = await getEffectiveOnboardingRequirements(supabase, identity.organizationId);
  const requiredTypes = requirements.filter((r) => r.requirement === "required").map((r) => r.documentType);
  if (requiredTypes.length > 0) {
    const { data: docs } = await supabase
      .from("documents")
      .select("document_type, rejected_at")
      .eq("entity_type", "carrier_onboarding_application")
      .eq("entity_id", identity.applicationId);
    const uploadedTypes = new Set((docs ?? []).filter((d) => !d.rejected_at).map((d) => d.document_type));
    const missing = requiredTypes.filter((t) => !uploadedTypes.has(t));
    if (missing.length > 0) return { ok: false, error: "Please upload all required documents before submitting." };
  }

  const agreementReadiness = await getRequiredAgreementReadiness(supabase, identity.applicationId);
  if (!agreementReadiness.initialized) {
    return { ok: false, error: "Your required agreements are still being prepared. Please contact the dispatch office before submitting." };
  }
  if (!agreementReadiness.ready) {
    return { ok: false, error: "Please complete all required dispatch agreements before submitting." };
  }

  const { error } = await supabase
    .from("carrier_onboarding_applications")
    .update({ status: "submitted", submitted_at: new Date().toISOString() })
    .eq("id", identity.applicationId);
  if (error) return { ok: false, error: error.message };

  await supabase.from("carrier_onboarding_invitations").update({ submitted_at: new Date().toISOString() }).eq("application_id", identity.applicationId).is("submitted_at", null);

  revalidatePath("/carrier-onboarding/review");
  return { ok: true };
}
