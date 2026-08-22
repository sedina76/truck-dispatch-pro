import "server-only";
import { createHash } from "node:crypto";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { runBoundedStorageUpload, storageUploadErrorStatus } from "@/lib/carrier-setup-packages/storage-retry";
import { renderExecutedAgreementPdf, type ExecutedAgreementClause } from "./executed-pdf";

const BUCKET = "carrier-onboarding-documents";
const MAX_BYTES = 10 * 1024 * 1024;
const RETRY_DELAY_MS = 250;

export type ExecutedDocumentGenerationResult =
  | { state: "generated"; documentId: string }
  | { state: "generating" }
  | { state: "failed"; error: string };

type ReservationRow = {
  reservation_status: "pending" | "generating" | "generated" | "failed";
  reservation_token: string | null;
  generated_document_id: string | null;
};

export async function generateExecutedAgreementDocument(signingId: string): Promise<ExecutedDocumentGenerationResult> {
  const service = createServiceRoleClient();
  const { data: reservationData, error: reservationError } = await service.rpc("reserve_carrier_agreement_executed_document", { p_signing_id: signingId });
  if (reservationError) return { state: "failed", error: "Could not reserve executed agreement generation." };
  const reservation = (Array.isArray(reservationData) ? reservationData[0] : reservationData) as ReservationRow | null;
  if (!reservation) return { state: "failed", error: "Could not reserve executed agreement generation." };
  if (reservation.reservation_status === "generated" && reservation.generated_document_id) return { state: "generated", documentId: reservation.generated_document_id };
  if (!reservation.reservation_token) return { state: "generating" };

  const token = reservation.reservation_token;
  try {
    const source = await loadExecutedAgreementSource(signingId);
    const bytes = await renderExecutedAgreementPdf(source.pdfInput);
    if (bytes.length <= 0 || bytes.length > MAX_BYTES) throw new Error("The executed agreement PDF exceeds the 10 MB limit.");
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const path = `${source.organizationId}/${source.applicationId}/${signingId}/executed-agreement-v${source.templateVersion}.pdf`;
    const filename = `${sanitize(source.templateName)}-executed-v${source.templateVersion}.pdf`;
    const confirmObject = async () => {
      const { data, error } = await service.storage.from(BUCKET).download(path);
      if (error) {
        const message = `${error.name ?? ""} ${error.message ?? ""}`.toLowerCase();
        return storageUploadErrorStatus(error) === 404 || /not found|does not exist/.test(message) ? "absent" as const : "unknown" as const;
      }
      const existing = new Uint8Array(await data.arrayBuffer());
      return existing.length === bytes.length && createHash("sha256").update(existing).digest("hex") === sha256 ? "matching" as const : "mismatch" as const;
    };

    const existing = await confirmObject();
    if (existing === "mismatch" || existing === "unknown") throw new Error("The executed agreement storage path could not be adopted safely.");
    if (existing === "absent") {
      const upload = await runBoundedStorageUpload({
        upload: async () => {
          const { error } = await service.storage.from(BUCKET).upload(path, bytes, { contentType: "application/pdf", upsert: false });
          if (error && storageUploadErrorStatus(error) === 409 && await confirmObject() === "matching") return null;
          return error;
        },
        confirmObject,
        delay: () => new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS)),
        onAttemptError: (error, attempt) => console.error("Executed agreement storage upload failed", {
          operation: "executed_agreement_upload", signingId, attempt, bucket: BUCKET, path,
          bytes: bytes.length, status: storageUploadErrorStatus(error),
          errorName: error instanceof Error ? error.name : undefined,
        }),
      });
      if (!upload.ok) throw new Error("Could not store the executed agreement PDF.");
    }

    const { data: documentId, error: finalizeError } = await service.rpc("finalize_carrier_agreement_executed_document", {
      p_signing_id: signingId,
      p_reservation_token: token,
      p_storage_path: path,
      p_file_name: filename,
      p_file_size_bytes: bytes.length,
      p_executed_pdf_sha256: sha256,
    });
    if (finalizeError || !documentId) throw new Error("Could not finalize the executed agreement document.");
    return { state: "generated", documentId: documentId as string };
  } catch (error) {
    await service.rpc("fail_carrier_agreement_executed_document", {
      p_signing_id: signingId,
      p_reservation_token: token,
      p_failure_reason: error instanceof Error ? error.message : "Executed agreement generation failed.",
    });
    return { state: "failed", error: "Your signed agreement is being prepared." };
  }
}

async function loadExecutedAgreementSource(signingId: string) {
  const service = createServiceRoleClient();
  const { data: signing } = await service.from("carrier_agreement_signings")
    .select("id, organization_id, application_id, agreement_template_id, status, signer_name, signer_title, typed_signature, consent_text_version, consent_accepted_at, signed_at, content_hash, evidence_hash")
    .eq("id", signingId).maybeSingle();
  if (!signing || !["completed", "voided"].includes(signing.status) || !signing.signed_at || !signing.signer_name || !signing.typed_signature || !signing.consent_text_version || !signing.consent_accepted_at || !signing.content_hash || !signing.evidence_hash) {
    throw new Error("Completed signing evidence is incomplete.");
  }
  const [{ data: template }, { data: clauses }, { data: initials }, { data: organization }, { data: computedHash, error: hashError }] = await Promise.all([
    service.from("carrier_agreement_templates").select("id, organization_id, name, version_number, content_hash").eq("id", signing.agreement_template_id).maybeSingle(),
    service.from("carrier_agreement_clauses").select("id, organization_id, title, body, display_order, requires_initials").eq("agreement_template_id", signing.agreement_template_id).order("display_order").order("id"),
    service.from("carrier_agreement_initials").select("clause_id, typed_initials").eq("signing_instance_id", signing.id),
    service.from("organizations").select("name").eq("id", signing.organization_id).maybeSingle(),
    service.rpc("compute_carrier_agreement_content_hash", { p_template_id: signing.agreement_template_id }),
  ]);
  if (!template || template.organization_id !== signing.organization_id || hashError || template.content_hash !== signing.content_hash || computedHash !== signing.content_hash) {
    throw new Error("Agreement template content does not match the signing snapshot.");
  }
  const initialByClause = new Map((initials ?? []).map((initial) => [initial.clause_id, initial.typed_initials]));
  const renderedClauses: ExecutedAgreementClause[] = (clauses ?? []).map((clause) => {
    if (clause.organization_id !== signing.organization_id) throw new Error("Agreement clause organization is inconsistent.");
    const typedInitials = initialByClause.get(clause.id) ?? null;
    if (clause.requires_initials && !typedInitials) throw new Error("Required signing initials are missing.");
    return { title: clause.title, body: clause.body, displayOrder: clause.display_order, requiresInitials: clause.requires_initials, typedInitials };
  });
  return {
    organizationId: signing.organization_id,
    applicationId: signing.application_id,
    templateVersion: template.version_number,
    templateName: template.name,
    pdfInput: {
      signingId: signing.id, templateId: template.id, templateName: template.name,
      templateVersion: template.version_number, signedAt: signing.signed_at,
      signerName: signing.signer_name, signerTitle: signing.signer_title,
      typedSignature: signing.typed_signature, consentVersion: signing.consent_text_version,
      consentAcceptedAt: signing.consent_accepted_at, contentHash: signing.content_hash,
      evidenceHash: signing.evidence_hash, organizationReferenceName: organization?.name ?? null,
      clauses: renderedClauses,
    },
  };
}

function sanitize(value: string) {
  return value.normalize("NFKD").replace(/[^a-zA-Z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 80) || "dispatch-agreement";
}
