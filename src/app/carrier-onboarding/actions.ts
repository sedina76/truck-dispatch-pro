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
import { runCarrierW9Generation } from "@/lib/carrier-w9/generate-workflow";
import { W9_BUCKET, w9StoragePath, type CarrierW9Row, type W9TaxClassification, type W9TinType } from "@/lib/carrier-w9/types";

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

// ---------------------------------------------------------------------------
// Phase 2N.2 -- Carrier W-9. NOT YET LIVE: depends on migration 0099,
// which has not been applied. Included here for review alongside the rest
// of this phase's implementation.
//
// Every function below follows this file's own established rule: resolve
// identity via getCarrierActionIdentity() first, then verify ownership
// (here, via the RPCs' own p_organization_id argument plus the row's
// onboarding_application_id, checked against identity.applicationId --
// never trusting a client-supplied w9Id's ownership implicitly).
// ---------------------------------------------------------------------------

async function requireOwnedW9(supabase: ReturnType<typeof createServiceRoleClient>, applicationId: string, w9Id: string): Promise<CarrierW9Row | null> {
  const { data } = await supabase.from("carrier_w9s").select("*").eq("id", w9Id).eq("onboarding_application_id", applicationId).maybeSingle();
  return (data as unknown as CarrierW9Row) ?? null;
}

export async function getMyW9(): Promise<CarrierW9Row | null> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return null;
  const supabase = createServiceRoleClient();
  const { data } = await supabase
    .from("carrier_w9s")
    .select("*")
    .eq("onboarding_application_id", identity.applicationId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return (data as unknown as CarrierW9Row) ?? null;
}

// W9-FIX: this is the one and only caller of createMyW9Draft() --
// OnboardingW9Page (page.tsx) calls it directly, in its own Server
// Component body, to lazy-create the draft row the first time the
// carrier opens the page with none on file yet. That means this function
// runs DURING the render of /carrier-onboarding/w9 itself, not from a
// client-triggered mutation -- calling revalidatePath() on that same
// route from inside its own render is exactly what Next.js forbids
// ("used during render which is unsupported"), which is what broke the
// route. No revalidation is actually needed here anyway: the page's own
// render already re-fetches getMyW9() immediately after this call
// returns and renders that fresh row directly -- there is no separate
// cached response for this call to invalidate. Every OTHER W-9 mutation
// below (saveMyW9Draft, setMyW9Tin, certifyAndGenerateMyW9) is only ever
// invoked from the client form's onClick/useTransition handlers, never
// from render, so their revalidatePath calls are legitimate and unchanged.
export async function createMyW9Draft(): Promise<{ ok: true; id: string } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();
  const { data, error } = await supabase.rpc("create_carrier_w9_draft", {
    p_organization_id: identity.organizationId, p_onboarding_application_id: identity.applicationId, p_carrier_id: null,
  });
  if (error) return { ok: false, error: error.message };
  return { ok: true, id: data as string };
}

export async function saveMyW9Draft(
  w9Id: string,
  input: {
    nameOnTaxReturn: string; businessName: string; taxClassification: W9TaxClassification; llcClassification: string;
    otherClassificationDescription: string; hasForeignPartnersOwners: boolean; exemptPayeeCode: string; fatcaExemptionCode: string;
    addressLine1: string; city: string; state: string; postalCode: string;
  }
): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();
  const owned = await requireOwnedW9(supabase, identity.applicationId, w9Id);
  if (!owned) return { ok: false, error: "W-9 draft not found." };

  const { error } = await supabase.rpc("update_carrier_w9_draft", {
    p_w9_id: w9Id, p_organization_id: identity.organizationId,
    p_name_on_tax_return: input.nameOnTaxReturn, p_business_name: input.businessName,
    p_tax_classification: input.taxClassification, p_llc_classification: input.llcClassification,
    p_other_classification_description: input.otherClassificationDescription, p_has_foreign_partners_owners: input.hasForeignPartnersOwners,
    p_exempt_payee_code: input.exemptPayeeCode, p_fatca_exemption_code: input.fatcaExemptionCode,
    p_address_line1: input.addressLine1, p_city: input.city, p_state: input.state, p_postal_code: input.postalCode,
    p_requester_name_address: null, p_account_numbers: null,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/carrier-onboarding/w9");
  return { ok: true };
}

export async function setMyW9Tin(w9Id: string, tinType: W9TinType, tin: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();
  const owned = await requireOwnedW9(supabase, identity.applicationId, w9Id);
  if (!owned) return { ok: false, error: "W-9 draft not found." };

  // Plaintext TIN lives in this one argument for as short a time as this
  // architecture allows (2N.2 section 6) -- it is never logged, never
  // returned, never placed in any other variable here.
  const { error } = await supabase.rpc("set_carrier_w9_tin", { p_w9_id: w9Id, p_organization_id: identity.organizationId, p_tin_type: tinType, p_tin: tin });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/carrier-onboarding/w9");
  return { ok: true };
}

// Certification and generation are one carrier-facing action (the carrier
// never sees an intermediate "generating" state) -- certify_carrier_w9()
// freezes the row, then runCarrierW9Generation() renders/uploads/
// finalizes immediately after, all before this function returns. The
// plaintext TIN is re-derived here ONLY for the render step (it must
// reach the PDF filler somehow) -- reveal_carrier_w9_tin() is
// deliberately NOT used for this (that path is staff-only, reason-
// audited, and would log an inappropriate reveal event for what is
// actually routine generation, not a staff reveal). This function instead
// re-derives the plaintext directly, scoped to this generation call only.
export async function certifyAndGenerateMyW9(
  w9Id: string,
  input: { certifiedName: string; certifiedTitle: string; tinType: W9TinType; tin: string }
): Promise<{ ok: true } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();
  const owned = await requireOwnedW9(supabase, identity.applicationId, w9Id);
  if (!owned) return { ok: false, error: "W-9 draft not found." };

  const { error: tinError } = await supabase.rpc("set_carrier_w9_tin", { p_w9_id: w9Id, p_organization_id: identity.organizationId, p_tin_type: input.tinType, p_tin: input.tin });
  if (tinError) return { ok: false, error: tinError.message };

  const { error: certifyError } = await supabase.rpc("certify_carrier_w9", {
    p_w9_id: w9Id, p_organization_id: identity.organizationId, p_certified_name: input.certifiedName, p_certified_title: input.certifiedTitle || null,
  });
  if (certifyError) return { ok: false, error: certifyError.message };

  const result = await runCarrierW9Generation(w9Id, identity.organizationId, input.tin);
  revalidatePath("/carrier-onboarding/w9");
  revalidatePath("/carrier-onboarding/review");
  if (!result.ok) return { ok: false, error: "Your W-9 was certified, but the official PDF could not be generated. Please contact your dispatch company." };
  return { ok: true };
}

export async function getMyW9Url(w9Id: string, download = false): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  const identity = await getCarrierActionIdentity();
  if (!identity) return { ok: false, error: SESSION_ENDED_MESSAGE };
  const supabase = createServiceRoleClient();
  const owned = await requireOwnedW9(supabase, identity.applicationId, w9Id);
  if (!owned || !["completed", "superseded"].includes(owned.status) || !owned.generated_storage_path) {
    return { ok: false, error: "W-9 not found." };
  }
  const expected = w9StoragePath(owned);
  if (owned.generated_storage_path !== expected) return { ok: false, error: "W-9 storage path is invalid." };
  const filename = `w9-v${owned.version}.pdf`;
  const { data: signed, error } = await supabase.storage.from(W9_BUCKET).createSignedUrl(expected, 300, download ? { download: filename } : undefined);
  if (error || !signed) return { ok: false, error: "Could not create a secure W-9 link." };
  return { ok: true, url: signed.signedUrl };
}
