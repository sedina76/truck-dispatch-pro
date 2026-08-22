import "server-only";
import { createClient } from "@/lib/supabase/server";
import { SetupPackageResourceNotFoundError } from "./errors";
import { DEFAULT_DOCUMENT_TYPES, DOCUMENT_LABELS, MAX_SINGLE_SOURCE_BYTES } from "./types";

export type SetupDocumentCandidate = {
  candidateKey: string;
  documentId: string | null;
  documentType: string;
  label: string;
  fileName: string | null;
  mimeType: string | null;
  fileSizeBytes: number | null;
  uploadedAt: string | null;
  expiryDate: string | null;
  verifiedAt: string | null;
  status: "eligible" | "missing" | "unverified" | "rejected" | "expired" | "unsupported" | "too_large" | "unavailable";
  statusMessage: string;
  defaultSelected: boolean;
};

const OPTIONAL_DOCUMENT_TYPES = ["vehicle_registration", "ifta_credential", "inspection_report", "other"];
const ALLOWED_DOCUMENT_TYPES = new Set([...DEFAULT_DOCUMENT_TYPES, ...OPTIONAL_DOCUMENT_TYPES]);

export async function listSetupPackageCandidates(applicationId: string): Promise<SetupDocumentCandidate[]> {
  const supabase = await createClient();
  const { data: application } = await supabase
    .from("carrier_onboarding_applications")
    .select("id")
    .eq("id", applicationId)
    .maybeSingle();
  if (!application) throw new SetupPackageResourceNotFoundError();

  const [{ data }, { data: signingRows }] = await Promise.all([
    supabase.from("documents")
      .select("id, document_type, file_name, file_path, mime_type, file_size_bytes, created_at, expiry_date, is_verified, verified_at, rejected_at")
      .eq("entity_type", "carrier_onboarding_application").eq("entity_id", applicationId)
      .order("created_at", { ascending: false }).order("id", { ascending: false }),
    supabase.from("carrier_agreement_signings")
      .select("id, agreement_template_id, signed_at, generated_document_id, executed_pdf_sha256, document_generation_status")
      .eq("application_id", applicationId).eq("status", "completed")
      .not("generated_document_id", "is", null).order("signed_at", { ascending: false }),
  ]);

  const latest = new Map<string, NonNullable<typeof data>[number]>();
  for (const document of data ?? []) if (!latest.has(document.document_type)) latest.set(document.document_type, document);

  const ordinary = [...DEFAULT_DOCUMENT_TYPES, ...OPTIONAL_DOCUMENT_TYPES.filter((type) => latest.has(type))].map((documentType) => {
    const document = latest.get(documentType);
    if (!document) return candidate(null, documentType, "missing", "No current document on file.");
    let status: SetupDocumentCandidate["status"] = "eligible";
    let message = "Verified and current";
    if (document.rejected_at) [status, message] = ["rejected", "The current document was rejected."];
    else if (!document.is_verified || !document.verified_at) [status, message] = ["unverified", "Verification is required before inclusion."];
    else if (document.expiry_date && document.expiry_date < new Date().toISOString().slice(0, 10)) [status, message] = ["expired", "This document is expired."];
    else if (document.mime_type === "image/heic") [status, message] = ["unsupported", "Convert this HEIC document to PDF, JPG, or PNG before including it."];
    else if (!["application/pdf", "image/jpeg", "image/png"].includes(document.mime_type ?? "")) [status, message] = ["unsupported", "Only PDF, JPG, and PNG documents can be included."];
    else if (!document.file_size_bytes || document.file_size_bytes > MAX_SINGLE_SOURCE_BYTES) [status, message] = ["too_large", "The source must have a known size of 10 MB or less."];
    if (!ALLOWED_DOCUMENT_TYPES.has(documentType)) return candidate(null, documentType, "unavailable", "This document type is not approved for broker setup packages.");
    return {
      candidateKey: document.id,
      documentId: document.id,
      documentType,
      label: DOCUMENT_LABELS[documentType] ?? documentType.replaceAll("_", " "),
      fileName: document.file_name,
      mimeType: document.mime_type,
      fileSizeBytes: document.file_size_bytes,
      uploadedAt: document.created_at,
      expiryDate: document.expiry_date,
      verifiedAt: document.verified_at,
      status,
      statusMessage: message,
      defaultSelected: status === "eligible" && (DEFAULT_DOCUMENT_TYPES as readonly string[]).includes(documentType),
    };
  });

  const templateIds = [...new Set((signingRows ?? []).map((signing) => signing.agreement_template_id))];
  const { data: templates } = templateIds.length
    ? await supabase.from("carrier_agreement_templates").select("id, name, version_number").in("id", templateIds)
    : { data: [] as { id: string; name: string; version_number: number }[] };
  const templateById = new Map((templates ?? []).map((template) => [template.id, template]));
  const documentById = new Map((data ?? []).map((document) => [document.id, document]));
  const agreements: SetupDocumentCandidate[] = [];
  for (const signing of signingRows ?? []) {
    const document = signing.generated_document_id ? documentById.get(signing.generated_document_id) : null;
    const template = templateById.get(signing.agreement_template_id);
    if (!document || !template || signing.document_generation_status !== "generated" || !/^[0-9a-f]{64}$/.test(signing.executed_pdf_sha256 ?? "")) continue;
    const expectedSuffix = `/${signing.id}/executed-agreement-v${template.version_number}.pdf`;
    let status: SetupDocumentCandidate["status"] = "eligible";
    let statusMessage = "Executed, verified, and eligible";
    if (document.document_type !== "signed_agreement" || document.mime_type !== "application/pdf" || !document.file_path.endsWith(expectedSuffix)) [status, statusMessage] = ["unavailable", "The executed artifact relationship is invalid."];
    else if (!document.is_verified || !document.verified_at || document.rejected_at) [status, statusMessage] = ["unverified", "The executed artifact is not verified."];
    else if (!document.file_size_bytes || document.file_size_bytes > MAX_SINGLE_SOURCE_BYTES) [status, statusMessage] = ["too_large", "The executed agreement exceeds the 10 MB source limit."];
    agreements.push({
      candidateKey: signing.id,
      documentId: document.id,
      documentType: "signed_agreement",
      label: `Signed Dispatch Agreement - ${template.name} - v${template.version_number} - Signed ${formatDate(signing.signed_at)}`,
      fileName: document.file_name,
      mimeType: document.mime_type,
      fileSizeBytes: document.file_size_bytes,
      uploadedAt: document.created_at,
      expiryDate: null,
      verifiedAt: document.verified_at,
      status,
      statusMessage,
      defaultSelected: false,
    });
  }
  return [...ordinary, ...agreements];
}

function candidate(documentId: null, documentType: string, status: SetupDocumentCandidate["status"], statusMessage: string): SetupDocumentCandidate {
  return { candidateKey: documentType, documentId, documentType, label: DOCUMENT_LABELS[documentType] ?? documentType, fileName: null, mimeType: null, fileSizeBytes: null, uploadedAt: null, expiryDate: null, verifiedAt: null, status, statusMessage, defaultSelected: false };
}

function formatDate(value: string | null) {
  return value ? new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(new Date(value)) : "Unknown date";
}
